// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {ICommissionManager} from "../../src/interfaces/ICommissionManager.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {CommissionManagerTestBase} from "./CommissionManagerTestBase.sol";

/// @notice Oracle freshness, sequencer recovery and price bounds gate native quotes.
contract CommissionManagerOracleTest is CommissionManagerTestBase {
    /// @dev MockAggregatorV3 reports startedAt == updatedAt; status 0 means up.
    function _setSequencer(int256 status, uint256 startedAt_) private {
        MockAggregatorV3 seq = new MockAggregatorV3(0, status, startedAt_);
        vm.prank(owner);
        cm.setSequencerUptimeFeed(address(seq));
    }

    function test_convertTokenFeeToNative_quotes18DecimalToken() public view {
        // 1 token (18 dec, $1 stable) @ $2000/ETH → 1/2000 ETH = 5e14 wei
        assertEq(cm.convertTokenFeeToNative(1e18, 18), 5e14);
    }

    function test_convertTokenFeeToNative_quotes6DecimalToken() public view {
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
        ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp() - HEARTBEAT - 1);
        vm.expectRevert(ICommissionManager.StalePrice.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_freshAtExactHeartbeatEdge() public {
        // updatedAt = now - heartbeat → still fresh (boundary is strict `>`).
        ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp() - HEARTBEAT);
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
        ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp());

        vm.expectRevert(ICommissionManager.ChainlinkHardeningNotConfigured.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_setEthUsdFeed_setsStateAndEmits() public {
        MockAggregatorV3 newFeed = new MockAggregatorV3(FEED_DECIMALS, 3_000e8, vm.getBlockTimestamp());

        vm.expectEmit(true, false, false, true, address(cm));
        emit ICommissionManager.EthUsdFeedUpdated(address(newFeed), 30 minutes);

        vm.prank(owner);
        cm.setEthUsdFeed(address(newFeed), 30 minutes);

        assertEq(cm.ethUsdFeed(), address(newFeed));
        assertEq(cm.ethUsdHeartbeat(), 30 minutes);
    }

    function test_setEthUsdFeed_zeroAddressClosesPath() public {
        vm.expectEmit(true, false, false, true, address(cm));
        emit ICommissionManager.EthUsdFeedUpdated(address(0), 0);

        vm.prank(owner);
        cm.setEthUsdFeed(address(0), 12345); // heartbeat is ignored when closing

        assertEq(cm.ethUsdFeed(), address(0));
        assertEq(cm.ethUsdHeartbeat(), 0);
    }

    function test_setEthUsdFeed_revertsOnZeroHeartbeat() public {
        MockAggregatorV3 newFeed = new MockAggregatorV3(FEED_DECIMALS, 1e8, vm.getBlockTimestamp());
        vm.expectRevert(ICommissionManager.InvalidHeartbeat.selector);
        vm.prank(owner);
        cm.setEthUsdFeed(address(newFeed), 0);
    }

    function test_setEthUsdFeed_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        cm.setEthUsdFeed(address(0x1234), 3600);
    }

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
            MockAggregatorV3 feed = new MockAggregatorV3(feedDecimals[i], prices[i], vm.getBlockTimestamp());
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

    function test_convertTokenFeeToNative_revertsWhenSequencerFeedUnset() public {
        vm.prank(owner);
        cm.setSequencerUptimeFeed(address(0));

        vm.expectRevert(ICommissionManager.ChainlinkHardeningNotConfigured.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsWhenSequencerDown() public {
        _setSequencer(1, vm.getBlockTimestamp() - 2 hours); // answer == 1 => down
        vm.expectRevert(ICommissionManager.SequencerDown.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsDuringGracePeriod() public {
        // Up, but restarted this block → within the grace window.
        _setSequencer(0, vm.getBlockTimestamp());
        vm.expectRevert(ICommissionManager.GracePeriodNotOver.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsAtGraceBoundary() public {
        // Exactly at the grace period: `block.timestamp - startedAt == GRACE`,
        // and the check is `<= GRACE`, so it still reverts.
        _setSequencer(0, vm.getBlockTimestamp() - cm.SEQUENCER_GRACE_PERIOD());
        vm.expectRevert(ICommissionManager.GracePeriodNotOver.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsOnUninitializedSequencerRound() public {
        _setSequencer(0, 0);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidSequencerRound.selector, uint256(0)));
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsOnFutureSequencerRound() public {
        uint256 futureStartedAt = vm.getBlockTimestamp() + 1;
        _setSequencer(0, futureStartedAt);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidSequencerRound.selector, futureStartedAt));
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_passesWhenSequencerUpPastGrace() public {
        _setSequencer(0, vm.getBlockTimestamp() - cm.SEQUENCER_GRACE_PERIOD() - 1);
        assertEq(cm.convertTokenFeeToNative(1e18, 18), 5e14); // same as happy path
    }

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
        ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp()); // keep fresh so StalePrice doesn't mask it
        vm.expectRevert(ICommissionManager.PriceOutOfBounds.selector);
        cm.convertTokenFeeToNative(1e18, 18);
    }

    function test_convertTokenFeeToNative_revertsWhenPriceAboveMax() public {
        vm.prank(owner);
        cm.setEthUsdPriceBounds(1_000e8, 100_000e8);
        ethUsdFeed.setAnswer(100_001e8); // above max
        ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp());
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
        _setSequencer(0, vm.getBlockTimestamp() - cm.SEQUENCER_GRACE_PERIOD() - 1);
        vm.prank(owner);
        cm.setEthUsdPriceBounds(1_000e8, 100_000e8);
        assertEq(cm.convertTokenFeeToNative(1e18, 18), 5e14);
    }

    function test_setSequencerUptimeFeed_setsAndEmits() public {
        address seq = makeAddr("seqFeed");
        vm.expectEmit(true, false, false, true, address(cm));
        emit ICommissionManager.SequencerUptimeFeedUpdated(seq);
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

    function test_setSequencerUptimeFeed_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        cm.setSequencerUptimeFeed(makeAddr("seqFeed"));
    }

    function test_setEthUsdPriceBounds_setsAndEmits() public {
        vm.expectEmit(false, false, false, true, address(cm));
        emit ICommissionManager.EthUsdPriceBoundsUpdated(1_000e8, 100_000e8);
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

    function test_setEthUsdPriceBounds_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        cm.setEthUsdPriceBounds(1_000e8, 100_000e8);
    }
}
