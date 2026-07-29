// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CommissionManager} from "../src/CommissionManager.sol";
import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager
} from "../src/interfaces/ICommissionManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

contract CommissionManagerTest is Test {
    CommissionManager internal cm;
    MockERC20 internal token;
    MockAggregatorV3 internal ethUsdFeed;
    MockAggregatorV3 internal sequencerFeed;

    address internal constant BRIDGE = address(0xB01);
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    /// @dev Chain identifiers are uint256: EVM uses native block.chainid;
    ///      non-EVM endpoints use ids reserved above the EVM range by
    ///      backend convention (see README).
    uint256 internal constant SRC_CHAIN_ID = 1; // Ethereum mainnet
    uint256 internal constant DST_CHAIN_ID = 1_000_001; // RGB (backend-assigned)

    // Chainlink feed defaults. ETH/USD on Arbitrum reports with 8 decimals;
    // heartbeat 86400 s in production — tests use 1 hour to keep stale-path
    // assertions snappy.
    uint8 internal constant FEED_DECIMALS = 8;
    int256 internal constant DEFAULT_ETH_USD = 2_000e8; // $2000 / ETH
    uint256 internal constant HEARTBEAT = 1 hours;
    uint256 internal constant MIN_ETH_USD = 100e8;
    uint256 internal constant MAX_ETH_USD = 100_000e8;

    event BridgeAddressUpdated(address indexed newBridge);
    event GlobalDefaultsUpdated(
        uint256 stablePercent, uint8 multiplier, CommissionSide side, CommissionCurrency currency
    );
    event EthUsdFeedUpdated(address indexed feed, uint256 heartbeat);
    event TokenCommissionReceived(address indexed token, uint256 amount);
    event SequencerUptimeFeedUpdated(address indexed feed);
    event EthUsdPriceBoundsUpdated(uint256 minPrice, uint256 maxPrice);

    function setUp() public {
        // Anvil starts at timestamp 1; warp past the heartbeat so staleness
        // tests can subtract `HEARTBEAT` from `block.timestamp` without
        // underflowing.
        vm.warp(HEARTBEAT * 10);

        vm.prank(owner);
        cm = new CommissionManager(BRIDGE, recipient);
        token = new MockERC20("Test", "TST");
        vm.prank(owner);
        cm.setGlobalDefaults(0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        // Install a complete healthy Arbitrum oracle config. R-I-14 makes the
        // sequencer feed and price band mandatory whenever a non-zero NATIVE
        // quote consumes ETH/USD.
        ethUsdFeed = new MockAggregatorV3(FEED_DECIMALS, DEFAULT_ETH_USD, block.timestamp);
        sequencerFeed = new MockAggregatorV3(0, 0, block.timestamp - cm.SEQUENCER_GRACE_PERIOD() - 1);
        vm.startPrank(owner);
        cm.setSequencerUptimeFeed(address(sequencerFeed));
        cm.setEthUsdPriceBounds(MIN_ETH_USD, MAX_ETH_USD);
        cm.setEthUsdFeed(address(ethUsdFeed), HEARTBEAT);
        vm.stopPrank();
    }

    // --- Constructor ---

    function test_constructor_setsBridgeAndOwner() public view {
        assertEq(cm.bridgeAddress(), BRIDGE);
        assertEq(cm.commissionRecipient(), recipient);
        assertEq(cm.owner(), owner);
    }

    function test_constructor_revertsOnZeroBridge() public {
        vm.expectRevert(ICommissionManager.InvalidBridgeAddress.selector);
        new CommissionManager(address(0), recipient);
    }

    function test_constructor_revertsOnZeroCommissionRecipient() public {
        vm.expectRevert(ICommissionManager.InvalidRecipient.selector);
        new CommissionManager(BRIDGE, address(0));
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
        CommissionManager freshCm = new CommissionManager(BRIDGE, recipient);
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

    function test_convertTokenFeeToNative_revertsBeforeReadingOutlierWhenBandUnset() public {
        vm.prank(owner);
        cm.setEthUsdPriceBounds(0, 0);
        ethUsdFeed.setAnswer(1); // $1e-8 — an extreme outlier
        ethUsdFeed.setUpdatedAt(block.timestamp);

        vm.expectRevert(ICommissionManager.ChainlinkHardeningNotConfigured.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_buildRouteKey_matchesEncodeHash() public view {
        address t = address(token);
        bytes32 expected = keccak256(abi.encode(SRC_CHAIN_ID, DST_CHAIN_ID, t));
        assertEq(cm.buildRouteKey(SRC_CHAIN_ID, DST_CHAIN_ID, t), expected);
    }

    // --- Global defaults ---

    function test_getGlobalDefaults_initial() public view {
        (uint256 sp, uint8 m, CommissionSide side, CommissionCurrency cur) = cm.getGlobalDefaults();
        assertEq(sp, 0);
        assertEq(m, 100);
        assertEq(uint8(side), uint8(CommissionSide.FUNDS_IN));
        assertEq(uint8(cur), uint8(CommissionCurrency.TOKEN));
    }

    function test_setGlobalDefaults_updatesAndEmits() public {
        // FUNDS_IN + NATIVE is a valid shape (the user funds the native fee on
        // deposit). NATIVE + FUNDS_OUT is rejected by the setter (R-W-04) and is
        // covered by a dedicated revert test.
        vm.expectEmit(true, true, true, true);
        emit GlobalDefaultsUpdated(200, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        vm.prank(owner);
        cm.setGlobalDefaults(200, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        (uint256 sp, uint8 m, CommissionSide side, CommissionCurrency cur) = cm.getGlobalDefaults();
        assertEq(sp, 200);
        assertEq(m, 100);
        assertEq(uint8(side), uint8(CommissionSide.FUNDS_IN));
        assertEq(uint8(cur), uint8(CommissionCurrency.NATIVE));
    }

    function test_setGlobalDefaults_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        cm.setGlobalDefaults(400, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    function test_setGlobalDefaults_revertsPercentTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.StablePercentTooHigh.selector);
        cm.setGlobalDefaults(9001, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    function test_setGlobalDefaults_acceptsZeroPercent() public {
        vm.prank(owner);
        cm.setGlobalDefaults(100, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        assertEq(cm.globalStablePercent(), 100);
        vm.prank(owner);
        cm.setGlobalDefaults(0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        (uint256 sp,,,) = cm.getGlobalDefaults();
        assertEq(sp, 0);
    }

    function test_setGlobalDefaults_revertsZeroMultiplier() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.MultiplierZero.selector);
        cm.setGlobalDefaults(400, 0, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev UT-FIX-07: setGlobalDefaults rejects the NATIVE + FUNDS_OUT shape.
    function test_setGlobalDefaults_revertsNativeFundsOut() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.NativeCommissionNotAllowedOnFundsOut.selector);
        cm.setGlobalDefaults(100, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.NATIVE);
    }

    /// @dev FUNDS_IN + NATIVE stays valid — the user funds the native fee on deposit.
    function test_setGlobalDefaults_acceptsNativeFundsIn() public {
        vm.prank(owner);
        cm.setGlobalDefaults(100, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        (,, CommissionSide side, CommissionCurrency cur) = cm.getGlobalDefaults();
        assertEq(uint8(side), uint8(CommissionSide.FUNDS_IN));
        assertEq(uint8(cur), uint8(CommissionCurrency.NATIVE));
    }

    // --- Commission calculations (globals) ---

    function test_calculateFundsInCommission_token_deductsFromAmount() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        address t = address(token);
        uint256 amount = 100_000;
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 4000); // 4% of 100_000
        assertEq(nat, 0);
        assertEq(net, amount - 4000);
    }

    function test_calculateFundsInCommission_zeroStablePercent_noTokenFee() public view {
        address t = address(token);
        uint256 amount = 100_000;
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 0);
        assertEq(nat, 0);
        assertEq(net, amount);
    }

    function test_calculateFundsInCommission_zeroStablePercent_native_skipsFeedCheck() public {
        vm.prank(owner);
        cm.setGlobalDefaults(0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        // Make the feed unhealthy: if the contract still hit it the call would
        // revert. A zero stable percent must short-circuit before the read.
        ethUsdFeed.setAnswer(0);
        address t = address(token);
        uint256 amount = 1000 ether;
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 0);
        assertEq(nat, 0);
        assertEq(net, amount);
    }

    function test_calculateFundsInCommission_native_fullAmount_bridged() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        address t = address(token);
        uint256 amount = 100_000 ether;
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        // 4% of 100_000 tokens = 4000 tokens stable fee. Delegate the math to
        // the contract — that way the test stays correct if the formula
        // changes (e.g. different feed decimals).
        uint256 expectedNat = cm.convertTokenFeeToNative(4000 ether, 18);
        assertGt(expectedNat, 0, "sanity: positive native fee");
        assertEq(tok, 0);
        assertEq(nat, expectedNat);
        assertEq(net, amount);
    }

    function test_calculateFundsInCommission_skipsWhenSideIsFundsOut() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);
        address t = address(token);
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 50_000);
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
        cm.setGlobalDefaults(400, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        address t = address(token);
        vm.expectRevert(ICommissionManager.EthUsdFeedNotSet.selector);
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 1000);
    }

    function test_calculateFundsInCommission_native_revertsWhenPriceStale() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        ethUsdFeed.setUpdatedAt(block.timestamp - HEARTBEAT - 1);
        vm.expectRevert(ICommissionManager.StalePrice.selector);
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1000);
    }

    // --- setEthUsdFeed admin --------------------------------------------------

    function test_setEthUsdFeed_setsStateAndEmits() public {
        MockAggregatorV3 newFeed = new MockAggregatorV3(FEED_DECIMALS, 3_000e8, block.timestamp);

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
        MockAggregatorV3 newFeed = new MockAggregatorV3(FEED_DECIMALS, 1e8, block.timestamp);
        vm.expectRevert(ICommissionManager.InvalidHeartbeat.selector);
        vm.prank(owner);
        cm.setEthUsdFeed(address(newFeed), 0);
    }

    function test_setEthUsdFeed_revertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        cm.setEthUsdFeed(address(0x1234), 3600);
    }

    function test_calculateFundsOutCommission_token() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);
        address t = address(token);
        uint256 amount = 80_000;
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 3200);
        assertEq(nat, 0);
        assertEq(net, amount - 3200);
    }

    function test_calculateFundsOutCommission_skipsWhenSideIsFundsIn() public view {
        address t = address(token);
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 40_000);
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

        (uint256 tok,, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 50_000);
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

    /// @dev UT-FIX-07: setCommissionRule rejects the NATIVE + FUNDS_OUT shape.
    function test_setCommissionRule_revertsNativeFundsOut() public {
        address t = address(token);
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 100,
            multiplier: 100,
            side: CommissionSide.FUNDS_OUT,
            currency: CommissionCurrency.NATIVE,
            isSet: true
        });
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.NativeCommissionNotAllowedOnFundsOut.selector);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t, cfg);
    }

    /// @dev FUNDS_OUT + TOKEN stays valid (the fee is deducted from the release).
    function test_setCommissionRule_acceptsFundsOutToken() public {
        address t = address(token);
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 100,
            multiplier: 100,
            side: CommissionSide.FUNDS_OUT,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t, cfg);

        CommissionConfig memory stored = cm.getCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t);
        assertEq(uint8(stored.side), uint8(CommissionSide.FUNDS_OUT));
        assertEq(uint8(stored.currency), uint8(CommissionCurrency.TOKEN));
    }

    // --- Fee-shape invariant (R-W-03 / UT-FIX-06) -----------------------------
    //
    // The stable-fee formula is `amount * stablePercent / multiplier / multiplier`,
    // i.e. a fee fraction of `stablePercent / multiplier^2`. If `stablePercent`
    // exceeds `multiplier^2` the quoted fee exceeds the bridged amount and the
    // later `netAmount = amount - fee` underflows (Panic 0x11), bricking the
    // route until the federation reconfigures. The setters must therefore reject
    // any `(stablePercent, multiplier)` pair where `stablePercent > multiplier^2`.
    function test_setGlobalDefaults_revertsWhenStablePercentExceedsMultiplierSquared() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, uint256(9000), uint8(1)));
        cm.setGlobalDefaults(9000, 1, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev Boundary just above the invariant: `multiplier = 10` → `multiplier^2 = 100`,
    ///      so `stablePercent = 101` is the smallest rejected value for that multiplier.
    function test_setGlobalDefaults_revertsJustAboveFeeShapeBoundary() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, uint256(101), uint8(10)));
        cm.setGlobalDefaults(101, 10, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev Exact boundary `stablePercent == multiplier^2` is accepted: it is a 100%
    ///      fee (`netAmount = 0`) which is degenerate but does not underflow, so the
    ///      invariant rejects only the strictly-greater case.
    function test_setGlobalDefaults_acceptsFeeShapeAtExactBoundary() public {
        vm.prank(owner);
        cm.setGlobalDefaults(100, 10, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        (uint256 sp, uint8 m,,) = cm.getGlobalDefaults();
        assertEq(sp, 100);
        assertEq(m, 10);
    }

    /// @dev Regression for the uint8 widening in the fix. With the default
    ///      `multiplier = 100`, `multiplier^2 = 10000`, so `stablePercent = 9000`
    ///      is a valid 90% fee and must be accepted. The audit's literal snippet
    ///      `multiplier * multiplier` evaluates in uint8 and overflows at
    ///      `100 * 100 = 10000 > 255`, which would wrongly revert this valid config;
    ///      the fix widens to uint256 before squaring.
    function test_setGlobalDefaults_acceptsHighPercentWithDefaultMultiplier() public {
        vm.prank(owner);
        cm.setGlobalDefaults(9000, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        (uint256 sp, uint8 m,,) = cm.getGlobalDefaults();
        assertEq(sp, 9000);
        assertEq(m, 100);
    }

    /// @dev Same invariant on the per-route setter: `(9000, 1)` must revert.
    function test_setCommissionRule_revertsWhenStablePercentExceedsMultiplierSquared() public {
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 9000,
            multiplier: 1,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, uint256(9000), uint8(1)));
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), cfg);
    }

    /// @dev Exact boundary `stablePercent == multiplier^2` accepted on the route setter.
    function test_setCommissionRule_acceptsFeeShapeAtExactBoundary() public {
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 100,
            multiplier: 10,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), cfg);
        CommissionConfig memory stored = cm.getCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token));
        assertEq(stored.stablePercent, 100);
        assertEq(stored.multiplier, 10);
    }

    /// @dev uint8-widening regression on the per-route setter: `(9000, 100)` is valid.
    function test_setCommissionRule_acceptsHighPercentWithDefaultMultiplier() public {
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 9000,
            multiplier: 100,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), cfg);
        CommissionConfig memory stored = cm.getCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token));
        assertEq(stored.stablePercent, 9000);
        assertEq(stored.multiplier, 100);
    }

    /// @dev End state of the invariant: a config accepted at the exact boundary
    ///      yields `fee == amount` and `netAmount == 0` without underflowing. This
    ///      is what the setter guard guarantees for every storable rule — the
    ///      `amount - fee` subtraction in the calculators can never go negative.
    function test_calculateFundsInCommission_acceptedBoundaryDoesNotUnderflow() public {
        vm.prank(owner);
        cm.setGlobalDefaults(100, 10, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        uint256 amount = 50_000;
        (uint256 tok, uint256 nat, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), amount);
        assertEq(tok, amount); // 100% fee at the boundary
        assertEq(nat, 0);
        assertEq(net, 0); // no underflow
    }

    // --- Bridge address ---

    function test_setBridgeAddress_updates() public {
        address newBridge = makeAddr("newBridge");
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
        cm.receiveTokenCommission(address(token), amt);

        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token), amt);
        assertEq(cm.tokenCommissionPool(address(token)), amt);
    }

    function test_receiveTokenCommission_revertsNothingReceived() public {
        vm.prank(BRIDGE);
        vm.expectRevert(ICommissionManager.NothingReceived.selector);
        cm.receiveTokenCommission(address(token), 0);
    }

    // After the R-I-04 fix the pool is credited by the passed `credited`, not by
    // balanceOf - pool. Crediting more than the on-chain balance can back reverts
    // BalanceBelowRecordedPool (guards against over-crediting).
    function test_receiveTokenCommission_revertsWhenCreditExceedsBalance() public {
        token.mint(address(cm), 5 ether);
        vm.prank(BRIDGE);
        vm.expectRevert(ICommissionManager.BalanceBelowRecordedPool.selector);
        cm.receiveTokenCommission(address(token), 6 ether);
    }

    // R-I-04 after-fix: an unsolicited direct transfer already sitting in the CM
    // is NOT folded into the pool. The Bridge measures only its own transfer and
    // passes that as `credited`; the donation stays as a stray balance.
    function test_receiveTokenCommission_doesNotAbsorbUnsolicitedBalance_afterFix() public {
        uint256 unsolicitedAmount = 3 ether;
        uint256 legitimateAmount = 7 ether;

        token.mint(user, unsolicitedAmount);
        vm.prank(user);
        token.transfer(address(cm), unsolicitedAmount); // donation

        token.mint(BRIDGE, legitimateAmount);
        vm.prank(BRIDGE);
        token.transfer(address(cm), legitimateAmount); // the Bridge's transfer

        assertEq(token.balanceOf(address(cm)), unsolicitedAmount + legitimateAmount, "pre cm token balance");
        assertEq(cm.tokenCommissionPool(address(token)), 0, "pre cm pool");

        // Bridge credits ONLY the amount its transfer actually delivered.
        vm.expectEmit(true, false, false, true, address(cm));
        emit TokenCommissionReceived(address(token), legitimateAmount);

        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token), legitimateAmount);

        assertEq(cm.tokenCommissionPool(address(token)), legitimateAmount, "pool credited only the legit commission");
        assertEq(token.balanceOf(address(cm)), unsolicitedAmount + legitimateAmount, "donation stays as stray balance");
    }

    function test_withdrawTokenCommission_transfersAndUpdatesPool() public {
        uint256 amt = 50 ether;
        token.mint(address(cm), amt);
        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token), amt);

        vm.prank(owner);
        cm.withdrawTokenCommission(address(token), amt);

        assertEq(cm.tokenCommissionPool(address(token)), 0);
        assertEq(token.balanceOf(recipient), amt);
    }

    function test_withdrawAllTokenCommission() public {
        uint256 amt = 30 ether;
        token.mint(address(cm), amt);
        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token), amt);

        vm.prank(owner);
        cm.withdrawAllTokenCommission(address(token));

        assertEq(cm.tokenCommissionPool(address(token)), 0);
        assertEq(token.balanceOf(recipient), amt);
    }

    function test_withdrawTokenCommission_revertsInsufficient() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.InsufficientBalance.selector);
        cm.withdrawTokenCommission(address(token), 1);
    }

    function test_legacyFreeRecipientWithdrawalSelectorsUnavailable() public {
        uint256 amount = 10 ether;
        token.mint(address(cm), amount);
        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token), amount);

        bytes[] memory legacyCalls = new bytes[](4);
        legacyCalls[0] =
            abi.encodeWithSignature("withdrawTokenCommission(address,address,uint256)", address(token), user, amount);
        legacyCalls[1] = abi.encodeWithSignature("withdrawNativeCommission(address,uint256)", user, amount);
        legacyCalls[2] = abi.encodeWithSignature("withdrawAllTokenCommission(address,address)", address(token), user);
        legacyCalls[3] = abi.encodeWithSignature("withdrawAllNativeCommission(address)", user);

        for (uint256 i = 0; i < legacyCalls.length; i++) {
            vm.prank(owner);
            (bool ok,) = address(cm).call(legacyCalls[i]);
            assertFalse(ok, "legacy free-recipient selector must not exist");
        }

        assertEq(cm.tokenCommissionPool(address(token)), amount, "failed legacy calls preserve pool");
        assertEq(token.balanceOf(user), 0, "arbitrary recipient receives nothing");
        assertEq(token.balanceOf(recipient), 0, "no valid withdrawal executed");
    }

    // --- Native commission ---

    function test_receive_onlyBridge() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool okUser,) = address(cm).call{value: 1 ether}("");
        assertFalse(okUser);

        vm.deal(BRIDGE, 1 ether);
        vm.prank(BRIDGE);
        (bool okBridge,) = address(cm).call{value: 1 ether}("");
        assertTrue(okBridge);
        assertEq(cm.nativeCommissionPool(), 1 ether);
    }

    function test_receive_revertsZeroValue() public {
        vm.prank(BRIDGE);
        (bool ok,) = address(cm).call{value: 0}("");
        assertFalse(ok); // receive() reverts with ZeroNativeAmount; call returns false
    }

    function test_withdrawNativeCommission() public {
        vm.deal(BRIDGE, 5 ether);
        vm.prank(BRIDGE);
        (bool ok,) = address(cm).call{value: 2 ether}("");
        assertTrue(ok);

        uint256 before = recipient.balance;
        vm.prank(owner);
        cm.withdrawNativeCommission(2 ether);
        assertEq(cm.nativeCommissionPool(), 0);
        assertEq(recipient.balance, before + 2 ether);
    }

    function test_withdrawAllNativeCommission() public {
        vm.deal(BRIDGE, 3 ether);
        vm.prank(BRIDGE);
        (bool ok,) = address(cm).call{value: 3 ether}("");
        assertTrue(ok);

        uint256 before = recipient.balance;
        vm.prank(owner);
        cm.withdrawAllNativeCommission();
        assertEq(cm.nativeCommissionPool(), 0);
        assertEq(recipient.balance, before + 3 ether);
    }

    function test_withdrawNativeCommission_revertsInsufficient() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.InsufficientBalance.selector);
        cm.withdrawNativeCommission(1 wei);
    }

    // --- Formula regression coverage ---

    function test_convertTokenFeeToNative_formulaAcrossTokenAndFeedDecimals() public {
        uint256[3] memory tokenFees = [uint256(100e6), uint256(1e18), uint256(25e6)];
        uint256[3] memory tokenDecimals = [uint256(6), uint256(18), uint256(6)];
        uint8[3] memory feedDecimals = [uint8(8), uint8(8), uint8(10)];
        int256[3] memory prices = [int256(2_000e8), int256(2_000e8), int256(2_500e10)];
        uint256[3] memory expectedNativeFees = [
            uint256(5e16), // 100 USD / 2000 USD per ETH = 0.05 ETH
            uint256(5e14), // 1 USD / 2000 USD per ETH = 0.0005 ETH
            uint256(1e16) // 25 USD / 2500 USD per ETH = 0.01 ETH
        ];

        // Use hand-computed expected values so this test anchors the conversion
        // formula instead of mirroring the implementation expression.
        for (uint256 i = 0; i < tokenFees.length; i++) {
            MockAggregatorV3 feed = new MockAggregatorV3(feedDecimals[i], prices[i], block.timestamp);
            uint256 decimalScale = 10 ** uint256(feedDecimals[i]);

            vm.startPrank(owner);
            cm.setEthUsdPriceBounds(100 * decimalScale, 100_000 * decimalScale);
            cm.setEthUsdFeed(address(feed), HEARTBEAT);
            vm.stopPrank();

            assertEq(
                cm.convertTokenFeeToNative(tokenFees[i], tokenDecimals[i]), expectedNativeFees[i], "native fee formula"
            );
        }
    }

    // =========================================================================
    // L2 sequencer-uptime gate + min/max price band
    // =========================================================================

    /// @dev The sequencer uptime feed is a standard AggregatorV3Interface;
    ///      MockAggregatorV3 reports `startedAt == updatedAt`, so we drive
    ///      `startedAt` via the constructor's `updatedAt` argument. `status`
    ///      is the sequencer answer (0 = up, 1 = down).
    function _sequencerFeed(int256 status, uint256 startedAt_) internal returns (MockAggregatorV3) {
        return new MockAggregatorV3(0, status, startedAt_);
    }

    function _setSequencer(int256 status, uint256 startedAt_) internal returns (MockAggregatorV3 seq) {
        seq = _sequencerFeed(status, startedAt_);
        vm.prank(owner);
        cm.setSequencerUptimeFeed(address(seq));
    }

    // --- sequencer uptime ---

    function test_convertTokenFeeToNative_revertsWhenSequencerFeedUnset() public {
        vm.prank(owner);
        cm.setSequencerUptimeFeed(address(0));

        vm.expectRevert(ICommissionManager.ChainlinkHardeningNotConfigured.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsWhenSequencerDown() public {
        _setSequencer(1, block.timestamp - 2 hours); // answer == 1 => down
        vm.expectRevert(ICommissionManager.SequencerDown.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsDuringGracePeriod() public {
        // Up, but restarted this block → within the grace window.
        _setSequencer(0, block.timestamp);
        vm.expectRevert(ICommissionManager.GracePeriodNotOver.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsAtGraceBoundary() public {
        // Exactly at the grace period: `block.timestamp - startedAt == GRACE`,
        // and the check is `<= GRACE`, so it still reverts.
        _setSequencer(0, block.timestamp - cm.SEQUENCER_GRACE_PERIOD());
        vm.expectRevert(ICommissionManager.GracePeriodNotOver.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsOnUninitializedSequencerRound() public {
        _setSequencer(0, 0);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidSequencerRound.selector, uint256(0)));
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsOnFutureSequencerRound() public {
        uint256 futureStartedAt = block.timestamp + 1;
        _setSequencer(0, futureStartedAt);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidSequencerRound.selector, futureStartedAt));
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_passesWhenSequencerUpPastGrace() public {
        _setSequencer(0, block.timestamp - cm.SEQUENCER_GRACE_PERIOD() - 1);
        assertEq(cm.convertTokenFeeToNative(1e18, 18), 5e14); // same as happy path
    }

    // --- min/max price band ---

    function test_convertTokenFeeToNative_revertsWhenBandUnset() public {
        vm.prank(owner);
        cm.setEthUsdPriceBounds(0, 0);

        vm.expectRevert(ICommissionManager.ChainlinkHardeningNotConfigured.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsWhenPriceBelowMin() public {
        vm.prank(owner);
        cm.setEthUsdPriceBounds(1_000e8, 100_000e8);
        ethUsdFeed.setAnswer(999e8); // below min
        ethUsdFeed.setUpdatedAt(block.timestamp); // keep fresh so StalePrice doesn't mask it
        vm.expectRevert(ICommissionManager.PriceOutOfBounds.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsWhenPriceAboveMax() public {
        vm.prank(owner);
        cm.setEthUsdPriceBounds(1_000e8, 100_000e8);
        ethUsdFeed.setAnswer(100_001e8); // above max
        ethUsdFeed.setUpdatedAt(block.timestamp);
        vm.expectRevert(ICommissionManager.PriceOutOfBounds.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_passesWithinBand() public {
        vm.prank(owner);
        cm.setEthUsdPriceBounds(1_000e8, 100_000e8);
        // DEFAULT_ETH_USD = 2000e8 sits inside the band.
        assertEq(cm.convertTokenFeeToNative(1e18, 18), 5e14);
    }

    function test_convertTokenFeeToNative_healthySequencerAndBandTogether() public {
        _setSequencer(0, block.timestamp - cm.SEQUENCER_GRACE_PERIOD() - 1);
        vm.prank(owner);
        cm.setEthUsdPriceBounds(1_000e8, 100_000e8);
        assertEq(cm.convertTokenFeeToNative(1e18, 18), 5e14);
    }

    // --- setters ---

    function test_setSequencerUptimeFeed_setsAndEmits() public {
        address seq = makeAddr("seqFeed");
        vm.expectEmit(true, false, false, false, address(cm));
        emit SequencerUptimeFeedUpdated(seq);
        vm.prank(owner);
        cm.setSequencerUptimeFeed(seq);
        assertEq(cm.sequencerUptimeFeed(), seq);
    }

    function test_setSequencerUptimeFeed_canDisableWithZero() public {
        vm.prank(owner);
        cm.setSequencerUptimeFeed(makeAddr("seqFeed"));
        vm.prank(owner);
        cm.setSequencerUptimeFeed(address(0));
        assertEq(cm.sequencerUptimeFeed(), address(0));

        vm.expectRevert(ICommissionManager.ChainlinkHardeningNotConfigured.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_setSequencerUptimeFeed_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        cm.setSequencerUptimeFeed(makeAddr("seqFeed"));
    }

    function test_setEthUsdPriceBounds_setsAndEmits() public {
        vm.expectEmit(false, false, false, true, address(cm));
        emit EthUsdPriceBoundsUpdated(1_000e8, 100_000e8);
        vm.prank(owner);
        cm.setEthUsdPriceBounds(1_000e8, 100_000e8);
        assertEq(cm.ethUsdMinPrice(), 1_000e8);
        assertEq(cm.ethUsdMaxPrice(), 100_000e8);
    }

    function test_setEthUsdPriceBounds_disableWithZeros() public {
        vm.prank(owner);
        cm.setEthUsdPriceBounds(1_000e8, 100_000e8);
        vm.prank(owner);
        cm.setEthUsdPriceBounds(0, 0);
        assertEq(cm.ethUsdMinPrice(), 0);
        assertEq(cm.ethUsdMaxPrice(), 0);

        vm.expectRevert(ICommissionManager.ChainlinkHardeningNotConfigured.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_setEthUsdPriceBounds_revertsOnZeroMinWithNonZeroMax() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.InvalidPriceBounds.selector);
        cm.setEthUsdPriceBounds(0, 100e8);
    }

    function test_setEthUsdPriceBounds_revertsWhenMinNotBelowMax() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.InvalidPriceBounds.selector);
        cm.setEthUsdPriceBounds(100e8, 100e8);
    }

    function test_setEthUsdPriceBounds_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        cm.setEthUsdPriceBounds(1_000e8, 100_000e8);
    }
}
