// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test } from 'forge-std/Test.sol';
import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';
import { CommissionManager } from '../src/CommissionManager.sol';
import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager
} from '../src/interfaces/ICommissionManager.sol';
import { MockERC20 } from './mocks/MockERC20.sol';
import { MockAggregatorV3 } from './mocks/MockAggregatorV3.sol';

contract CommissionManagerTest is Test {
    CommissionManager internal cm;
    MockERC20 internal token;
    MockAggregatorV3 internal ethUsdFeed;

    address internal constant BRIDGE = address(0xB01);
    address internal owner = makeAddr('owner');
    address internal user = makeAddr('user');
    address internal recipient = makeAddr('recipient');

    /// @dev Chain identifiers are uint256: EVM uses native block.chainid;
    ///      non-EVM endpoints use ids reserved above the EVM range by
    ///      backend convention (see README).
    uint256 internal constant SRC_CHAIN_ID = 1;          // Ethereum mainnet
    uint256 internal constant DST_CHAIN_ID = 1_000_001;  // RGB (backend-assigned)

    // Chainlink feed defaults. ETH/USD on Arbitrum reports with 8 decimals;
    // heartbeat 86400 s in production — tests use 1 hour to keep stale-path
    // assertions snappy.
    uint8   internal constant FEED_DECIMALS = 8;
    int256  internal constant DEFAULT_ETH_USD = 2_000e8; // $2000 / ETH
    uint256 internal constant HEARTBEAT = 1 hours;

    event BridgeAddressUpdated(address indexed newBridge);
    event GlobalDefaultsUpdated(
        uint256 stablePercent,
        uint8 multiplier,
        CommissionSide side,
        CommissionCurrency currency
    );
    event EthUsdFeedUpdated(address indexed feed, uint256 heartbeat);

    function setUp() public {
        // Anvil starts at timestamp 1; warp past the heartbeat so staleness
        // tests can subtract `HEARTBEAT` from `block.timestamp` without
        // underflowing.
        vm.warp(HEARTBEAT * 10);

        vm.prank(owner);
        cm = new CommissionManager(BRIDGE);
        token = new MockERC20('Test', 'TST');
        vm.prank(owner);
        cm.setGlobalDefaults(0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        // Deploy a default ETH/USD feed and wire it in. Tests that need to
        // exercise the "feed unset" branch redeploy CM without calling
        // `setEthUsdFeed` (see test_convertTokenFeeToNative_revertsIfFeedUnset).
        ethUsdFeed = new MockAggregatorV3(FEED_DECIMALS, DEFAULT_ETH_USD, block.timestamp);
        vm.prank(owner);
        cm.setEthUsdFeed(address(ethUsdFeed), HEARTBEAT);
    }

    // --- Constructor ---

    function test_constructor_setsBridgeAndOwner() public view {
        assertEq(cm.bridgeAddress(), BRIDGE);
        assertEq(cm.owner(), owner);
    }

    function test_constructor_revertsOnZeroBridge() public {
        vm.expectRevert(ICommissionManager.InvalidBridgeAddress.selector);
        new CommissionManager(address(0));
    }

    function test_renounceOwnership_blocked() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.RenounceOwnershipBlocked.selector);
        cm.renounceOwnership();
    }

    // --- Pure math helpers ---

    function test_calculateStableFee_defaultMultiplier() public view {
        // 10000 amount, 400 (=4%), mult 100 → 10000*400/10000 = 400
        assertEq(cm.calculateStableFee(10000, 400, 100), 400);
    }

    function test_convertTokenFeeToNative_happyPath_18dec() public view {
        // 1 token (18 dec, $1 stable) @ $2000/ETH → 1/2000 ETH = 5e14 wei
        assertEq(cm.convertTokenFeeToNative(1e18, 18), 5e14);
    }

    function test_convertTokenFeeToNative_happyPath_6dec() public view {
        // 100 USDT0 (6 dec, $1 stable) @ $2000/ETH → 100/2000 = 0.05 ETH = 5e16 wei
        assertEq(cm.convertTokenFeeToNative(100e6, 6), 5e16);
    }

    function test_convertTokenFeeToNative_returnsZeroForZeroFee() public view {
        // Short-circuit before reading the feed.
        assertEq(cm.convertTokenFeeToNative(0, 18), 0);
    }

    function test_convertTokenFeeToNative_revertsIfFeedUnset() public {
        // Fresh CM with no feed configured.
        vm.prank(owner);
        CommissionManager freshCm = new CommissionManager(BRIDGE);
        vm.expectRevert(ICommissionManager.EthUsdFeedNotSet.selector);
        freshCm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsIfPriceZero() public {
        ethUsdFeed.setAnswer(0);
        vm.expectRevert(ICommissionManager.InvalidPrice.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsIfPriceNegative() public {
        ethUsdFeed.setAnswer(-1);
        vm.expectRevert(ICommissionManager.InvalidPrice.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsIfStale() public {
        // updatedAt = now - heartbeat - 1 → stale by one second.
        ethUsdFeed.setUpdatedAt(block.timestamp - HEARTBEAT - 1);
        vm.expectRevert(ICommissionManager.StalePrice.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_freshAtExactHeartbeatEdge() public {
        // updatedAt = now - heartbeat → still fresh (boundary is strict `>`).
        ethUsdFeed.setUpdatedAt(block.timestamp - HEARTBEAT);
        assertEq(cm.convertTokenFeeToNative(1e18, 18), 5e14);
    }

    function test_convertTokenFeeToNative_revertsIfTokenDecimalsTooLarge() public {
        vm.expectRevert(ICommissionManager.TokenDecimalsTooLarge.selector);
        cm.convertTokenFeeToNative(1, 19);
    }

    function test_buildRouteKey_matchesEncodeHash() public view {
        address t = address(token);
        bytes32 expected = keccak256(abi.encode(SRC_CHAIN_ID, DST_CHAIN_ID, t));
        assertEq(cm.buildRouteKey(SRC_CHAIN_ID, DST_CHAIN_ID, t), expected);
    }

    // --- Global defaults ---

    function test_getGlobalDefaults_initial() public view {
        (uint256 sp, uint8 m, CommissionSide side, CommissionCurrency cur) =
            cm.getGlobalDefaults();
        assertEq(sp, 0);
        assertEq(m, 100);
        assertEq(uint8(side), uint8(CommissionSide.FUNDS_IN));
        assertEq(uint8(cur), uint8(CommissionCurrency.TOKEN));
    }

    function test_setGlobalDefaults_updatesAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit GlobalDefaultsUpdated(
            200,
            100,
            CommissionSide.FUNDS_OUT,
            CommissionCurrency.NATIVE
        );
        vm.prank(owner);
        cm.setGlobalDefaults(
            200,
            100,
            CommissionSide.FUNDS_OUT,
            CommissionCurrency.NATIVE
        );
        (uint256 sp, uint8 m, CommissionSide side, CommissionCurrency cur) =
            cm.getGlobalDefaults();
        assertEq(sp, 200);
        assertEq(m, 100);
        assertEq(uint8(side), uint8(CommissionSide.FUNDS_OUT));
        assertEq(uint8(cur), uint8(CommissionCurrency.NATIVE));
    }

    function test_setGlobalDefaults_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        cm.setGlobalDefaults(
            400,
            100,
            CommissionSide.FUNDS_IN,
            CommissionCurrency.TOKEN
        );
    }

    function test_setGlobalDefaults_revertsPercentTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.StablePercentTooHigh.selector);
        cm.setGlobalDefaults(
            9001,
            100,
            CommissionSide.FUNDS_IN,
            CommissionCurrency.TOKEN
        );
    }

    function test_setGlobalDefaults_acceptsZeroPercent() public {
        vm.prank(owner);
        cm.setGlobalDefaults(
            100,
            100,
            CommissionSide.FUNDS_IN,
            CommissionCurrency.TOKEN
        );
        assertEq(cm.globalStablePercent(), 100);
        vm.prank(owner);
        cm.setGlobalDefaults(
            0,
            100,
            CommissionSide.FUNDS_IN,
            CommissionCurrency.TOKEN
        );
        (uint256 sp,,,) = cm.getGlobalDefaults();
        assertEq(sp, 0);
    }

    function test_setGlobalDefaults_revertsZeroMultiplier() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.MultiplierZero.selector);
        cm.setGlobalDefaults(
            400,
            0,
            CommissionSide.FUNDS_IN,
            CommissionCurrency.TOKEN
        );
    }

    // --- Commission calculations (globals) ---

    function test_calculateFundsInCommission_token_deductsFromAmount() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        address t = address(token);
        uint256 amount = 100_000;
        (uint256 tok, uint256 nat, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 4000); // 4% of 100_000
        assertEq(nat, 0);
        assertEq(net, amount - 4000);
    }

    function test_calculateFundsInCommission_zeroStablePercent_noTokenFee() public view {
        address t = address(token);
        uint256 amount = 100_000;
        (uint256 tok, uint256 nat, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 0);
        assertEq(nat, 0);
        assertEq(net, amount);
    }

    function test_calculateFundsInCommission_zeroStablePercent_native_skipsFeedCheck() public {
        vm.prank(owner);
        cm.setGlobalDefaults(
            0,
            100,
            CommissionSide.FUNDS_IN,
            CommissionCurrency.NATIVE
        );
        // Make the feed unhealthy: if the contract still hit it the call would
        // revert. A zero stable percent must short-circuit before the read.
        ethUsdFeed.setAnswer(0);
        address t = address(token);
        uint256 amount = 1000 ether;
        (uint256 tok, uint256 nat, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 0);
        assertEq(nat, 0);
        assertEq(net, amount);
    }

    function test_calculateFundsInCommission_native_fullAmount_bridged() public {
        vm.prank(owner);
        cm.setGlobalDefaults(
            400,
            100,
            CommissionSide.FUNDS_IN,
            CommissionCurrency.NATIVE
        );
        address t = address(token);
        uint256 amount = 100_000 ether;
        (uint256 tok, uint256 nat, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        // 4% of 100_000 tokens = 4000 tokens stable fee. Delegate the math to
        // the contract — that way the test stays correct if the formula
        // changes (e.g. different feed decimals).
        uint256 expectedNat = cm.convertTokenFeeToNative(4000 ether, 18);
        assertGt(expectedNat, 0, 'sanity: positive native fee');
        assertEq(tok, 0);
        assertEq(nat, expectedNat);
        assertEq(net, amount);
    }

    function test_calculateFundsInCommission_skipsWhenSideIsFundsOut() public {
        vm.prank(owner);
        cm.setGlobalDefaults(
            400,
            100,
            CommissionSide.FUNDS_OUT,
            CommissionCurrency.TOKEN
        );
        address t = address(token);
        (uint256 tok, uint256 nat, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 50_000);
        assertEq(tok, 0);
        assertEq(nat, 0);
        assertEq(net, 50_000);
    }

    function test_calculateFundsInCommission_native_revertsWhenFeedUnset() public {
        // Close the NATIVE path explicitly and confirm the calculator surfaces
        // the underlying `EthUsdFeedNotSet` revert (rather than producing a
        // silent zero quote).
        vm.prank(owner);
        cm.setEthUsdFeed(address(0), 0);
        vm.prank(owner);
        cm.setGlobalDefaults(
            400,
            100,
            CommissionSide.FUNDS_IN,
            CommissionCurrency.NATIVE
        );
        address t = address(token);
        vm.expectRevert(ICommissionManager.EthUsdFeedNotSet.selector);
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 1000);
    }

    function test_calculateFundsInCommission_native_revertsWhenPriceStale() public {
        vm.prank(owner);
        cm.setGlobalDefaults(
            400,
            100,
            CommissionSide.FUNDS_IN,
            CommissionCurrency.NATIVE
        );
        ethUsdFeed.setUpdatedAt(block.timestamp - HEARTBEAT - 1);
        vm.expectRevert(ICommissionManager.StalePrice.selector);
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1000);
    }

    // --- setEthUsdFeed admin --------------------------------------------------

    function test_setEthUsdFeed_setsStateAndEmits() public {
        MockAggregatorV3 newFeed =
            new MockAggregatorV3(FEED_DECIMALS, 3_000e8, block.timestamp);

        vm.expectEmit(true, false, false, true, address(cm));
        emit EthUsdFeedUpdated(address(newFeed), 30 minutes);

        vm.prank(owner);
        cm.setEthUsdFeed(address(newFeed), 30 minutes);

        assertEq(cm.ethUsdFeed(), address(newFeed));
        assertEq(cm.ethUsdHeartbeat(), 30 minutes);
    }

    function test_setEthUsdFeed_zeroAddressClosesPath() public {
        vm.expectEmit(true, false, false, true, address(cm));
        emit EthUsdFeedUpdated(address(0), 0);

        vm.prank(owner);
        cm.setEthUsdFeed(address(0), 12345); // heartbeat is ignored when closing

        assertEq(cm.ethUsdFeed(), address(0));
        assertEq(cm.ethUsdHeartbeat(), 0);
    }

    function test_setEthUsdFeed_revertsOnZeroHeartbeat() public {
        MockAggregatorV3 newFeed =
            new MockAggregatorV3(FEED_DECIMALS, 1e8, block.timestamp);
        vm.expectRevert(ICommissionManager.InvalidHeartbeat.selector);
        vm.prank(owner);
        cm.setEthUsdFeed(address(newFeed), 0);
    }

    function test_setEthUsdFeed_revertsIfNotOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user)
        );
        vm.prank(user);
        cm.setEthUsdFeed(address(0x1234), 3600);
    }

    function test_calculateFundsOutCommission_token() public {
        vm.prank(owner);
        cm.setGlobalDefaults(
            400,
            100,
            CommissionSide.FUNDS_OUT,
            CommissionCurrency.TOKEN
        );
        address t = address(token);
        uint256 amount = 80_000;
        (uint256 tok, uint256 nat, uint256 net) =
            cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 3200);
        assertEq(nat, 0);
        assertEq(net, amount - 3200);
    }

    function test_calculateFundsOutCommission_skipsWhenSideIsFundsIn() public view {
        address t = address(token);
        (uint256 tok, uint256 nat, uint256 net) =
            cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 40_000);
        assertEq(tok, 0);
        assertEq(nat, 0);
        assertEq(net, 40_000);
    }

    // --- Per-route rules ---

    function test_setCommissionRule_overridesGlobal() public {
        address t = address(token);
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 1000,
            multiplier: 100,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t, cfg);

        (uint256 tok,, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 50_000);
        assertEq(tok, 5000); // 10%
        assertEq(net, 45_000);

        CommissionConfig memory stored = cm.getCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t);
        assertTrue(stored.isSet);
        assertEq(stored.stablePercent, 1000);
    }

    function test_clearCommissionRule_fallsBackToGlobal() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        address t = address(token);
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 1000,
            multiplier: 100,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t, cfg);
        vm.prank(owner);
        cm.clearCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t);

        CommissionConfig memory stored = cm.getCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t);
        assertFalse(stored.isSet);

        (uint256 tok,,) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 50_000);
        assertEq(tok, 2000); // back to global 4%
    }

    function test_setCommissionRule_revertsInvalidPercent() public {
        address t = address(token);
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 9001,
            multiplier: 100,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.StablePercentTooHigh.selector);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t, cfg);
    }

    // --- Bridge address ---

    function test_setBridgeAddress_updates() public {
        address newBridge = makeAddr('newBridge');
        vm.expectEmit(true, true, true, true);
        emit BridgeAddressUpdated(newBridge);
        vm.prank(owner);
        cm.setBridgeAddress(newBridge);
        assertEq(cm.bridgeAddress(), newBridge);
    }

    function test_setBridgeAddress_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.InvalidBridgeAddress.selector);
        cm.setBridgeAddress(address(0));
    }

    // --- Token commission accounting ---

    function test_receiveTokenCommission_onlyBridge() public {
        uint256 amt = 100 ether;
        token.mint(address(cm), amt);

        vm.prank(user);
        vm.expectRevert(ICommissionManager.OnlyBridge.selector);
        cm.receiveTokenCommission(address(token));

        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token));
        assertEq(cm.tokenCommissionPool(address(token)), amt);
    }

    function test_receiveTokenCommission_revertsNothingReceived() public {
        vm.prank(BRIDGE);
        vm.expectRevert(ICommissionManager.NothingReceived.selector);
        cm.receiveTokenCommission(address(token));
    }

    function test_receiveTokenCommission_revertsNothingReceived_whenNoNewTokens() public {
        uint256 amt = 10 ether;
        token.mint(address(cm), amt);
        vm.startPrank(BRIDGE);
        cm.receiveTokenCommission(address(token));
        vm.expectRevert(ICommissionManager.NothingReceived.selector);
        cm.receiveTokenCommission(address(token));
        vm.stopPrank();
    }

    function test_withdrawTokenCommission_transfersAndUpdatesPool() public {
        uint256 amt = 50 ether;
        token.mint(address(cm), amt);
        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token));

        vm.prank(owner);
        cm.withdrawTokenCommission(address(token), recipient, amt);

        assertEq(cm.tokenCommissionPool(address(token)), 0);
        assertEq(token.balanceOf(recipient), amt);
    }

    function test_withdrawAllTokenCommission() public {
        uint256 amt = 30 ether;
        token.mint(address(cm), amt);
        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token));

        vm.prank(owner);
        cm.withdrawAllTokenCommission(address(token), recipient);

        assertEq(cm.tokenCommissionPool(address(token)), 0);
        assertEq(token.balanceOf(recipient), amt);
    }

    function test_withdrawTokenCommission_revertsInsufficient() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.InsufficientBalance.selector);
        cm.withdrawTokenCommission(address(token), recipient, 1);
    }

    // --- Native commission ---

    function test_receive_onlyBridge() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool okUser,) = address(cm).call{value: 1 ether}('');
        assertFalse(okUser);

        vm.deal(BRIDGE, 1 ether);
        vm.prank(BRIDGE);
        (bool okBridge,) = address(cm).call{value: 1 ether}('');
        assertTrue(okBridge);
        assertEq(cm.nativeCommissionPool(), 1 ether);
    }

    function test_receive_revertsZeroValue() public {
        vm.prank(BRIDGE);
        (bool ok,) = address(cm).call{value: 0}('');
        assertFalse(ok); // receive() reverts with ZeroNativeAmount; call returns false
    }

    function test_withdrawNativeCommission() public {
        vm.deal(BRIDGE, 5 ether);
        vm.prank(BRIDGE);
        (bool ok,) = address(cm).call{value: 2 ether}('');
        assertTrue(ok);

        uint256 before = recipient.balance;
        vm.prank(owner);
        cm.withdrawNativeCommission(payable(recipient), 2 ether);
        assertEq(cm.nativeCommissionPool(), 0);
        assertEq(recipient.balance, before + 2 ether);
    }

    function test_withdrawAllNativeCommission() public {
        vm.deal(BRIDGE, 3 ether);
        vm.prank(BRIDGE);
        (bool ok,) = address(cm).call{value: 3 ether}('');
        assertTrue(ok);

        uint256 before = recipient.balance;
        vm.prank(owner);
        cm.withdrawAllNativeCommission(payable(recipient));
        assertEq(cm.nativeCommissionPool(), 0);
        assertEq(recipient.balance, before + 3 ether);
    }

    function test_withdrawNativeCommission_revertsInsufficient() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.InsufficientBalance.selector);
        cm.withdrawNativeCommission(payable(recipient), 1 wei);
    }
}
