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
import { MockERC20 } from './helpers/MockERC20.sol';

contract CommissionManagerTest is Test {
    CommissionManager internal cm;
    MockERC20 internal token;

    address internal constant BRIDGE = address(0xB01);
    address internal owner = makeAddr('owner');
    address internal user = makeAddr('user');
    address internal recipient = makeAddr('recipient');

    /// @dev Chain identifiers are uint256: EVM uses native block.chainid;
    ///      non-EVM endpoints use ids reserved above the EVM range by
    ///      backend convention (see README).
    uint256 internal constant SRC_CHAIN_ID = 1;          // Ethereum mainnet
    uint256 internal constant DST_CHAIN_ID = 1_000_001;  // RGB (backend-assigned)

    event BridgeAddressUpdated(address indexed newBridge);
    event GlobalDefaultsUpdated(
        uint256 stablePercent,
        uint8 multiplier,
        CommissionSide side,
        CommissionCurrency currency
    );

    function setUp() public {
        vm.prank(owner);
        cm = new CommissionManager(BRIDGE);
        token = new MockERC20('Test', 'TST');
        vm.prank(owner);
        cm.setGlobalDefaults(0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
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

    function test_convertTokenToNative() public view {
        uint256 native = cm.convertTokenToNative(1e18, 2e9, 18);
        assertEq(native, 2e9);
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

    function test_calculateFundsInCommission_zeroStablePercent_native_skipsRateCheck() public {
        vm.prank(owner);
        cm.setGlobalDefaults(
            0,
            100,
            CommissionSide.FUNDS_IN,
            CommissionCurrency.NATIVE
        );
        address t = address(token);
        // Deliberately no setMockTokenToNativeRate: nonzero fee would revert.
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
        uint256 rate = 2000 gwei; // wei per 1 wei of token with 18 decimals — illustrative
        vm.prank(owner);
        cm.setMockTokenToNativeRateForToken(t, rate);
        (uint256 tok, uint256 nat, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        uint256 stableFee = 4000 ether; // 4% of 100_000 ether
        uint256 expectedNat = cm.convertTokenToNative(stableFee, rate, 18);
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

    function test_calculateFundsInCommission_native_revertsWhenRateUnset() public {
        vm.prank(owner);
        cm.setGlobalDefaults(
            400,
            100,
            CommissionSide.FUNDS_IN,
            CommissionCurrency.NATIVE
        );
        address t = address(token);
        vm.expectRevert(ICommissionManager.MockTokenToNativeRateNotSet.selector);
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 1000);
    }

    function test_resolvedMockTokenToNativeRate_fallsBackToGlobalMock() public {
        vm.prank(owner);
        cm.setMockTokenToNativeRate(123e9);
        assertEq(cm.resolvedMockTokenToNativeRate(address(token)), 123e9);
        vm.prank(owner);
        cm.setMockTokenToNativeRateForToken(address(token), 999e9);
        assertEq(cm.resolvedMockTokenToNativeRate(address(token)), 999e9);
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
