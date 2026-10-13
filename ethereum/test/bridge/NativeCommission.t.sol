// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {NonPayableDepositor} from "../mocks/NonPayableDepositor.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Native fee quote tolerance, collection and surplus refunds.
contract BridgeNativeCommissionTest is BridgeTestBase {
    /// @dev Accepted `msg.value` band on the ADAPTER overload: symmetric, since
    ///      the source-chain payer is unreachable and nothing can be refunded.
    function _adapterNativeBounds(uint256 nativeCommission) private view returns (uint256 minimum, uint256 maximum) {
        uint256 denominator = bridge.BPS_DENOMINATOR();
        uint256 tolerance = bridge.NATIVE_COMMISSION_TOLERANCE_BPS();
        minimum = Math.mulDiv(nativeCommission, denominator - tolerance, denominator, Math.Rounding.Ceil);
        maximum = Math.mulDiv(nativeCommission, denominator + tolerance, denominator);
    }

    /// @dev Accepted `msg.value` band on the DIRECT overload: the floor is the
    ///      fresh quote itself, because the headroom above it is a refundable
    ///      drift buffer rather than extra commission.
    function _directNativeBounds(uint256 nativeCommission) private view returns (uint256 minimum, uint256 maximum) {
        uint256 denominator = bridge.BPS_DENOMINATOR();
        uint256 tolerance = bridge.NATIVE_COMMISSION_TOLERANCE_BPS();
        minimum = nativeCommission;
        maximum = Math.mulDiv(nativeCommission, denominator + tolerance, denominator);
    }

    function _nativeQuote(uint256 amount) private view returns (uint256 quote) {
        (, quote,) = cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), amount);
    }

    // ========================================================================
    // Native commission drift band
    // Direct deposits: attach the quote plus optional headroom; exactly the
    // fresh quote is charged and the remainder refunded, so the protocol never
    // under-collects and the caller is never overcharged.
    // Adapter deposits: the source-chain payer is unreachable, so the band is
    // symmetric and whatever arrives inside it is collected in full.
    // ========================================================================

    function test_fundsIn_collectsExactNativeQuote() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        assertGt(quote, 0, "native fee quoted");

        vm.deal(user, quote);
        uint256 poolBefore = cm.nativeCommissionPool();

        vm.prank(user);
        bytes32 opId = bridge.fundsIn{value: quote}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), poolBefore + quote, "pool credited exactly the quote");
        assertEq(user.balance, 0, "nothing to refund");
        assertEq(address(bridge).balance, 0, "no native stranded in bridge");
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "deposit completed");
    }

    /// @dev A caller who attaches more than the quote is charged only the quote
    ///      and refunded the surplus.
    function test_fundsIn_refundsNativeSurplus() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        uint256 attached = quote + (quote * 400) / 10_000; // +4%, inside the band

        vm.deal(user, attached);
        uint256 poolBefore = cm.nativeCommissionPool();

        vm.prank(user);
        bridge.fundsIn{value: attached}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), poolBefore + quote, "protocol collected ONLY the quote");
        assertEq(user.balance, attached - quote, "caller refunded the whole surplus");
        assertEq(address(bridge).balance, 0, "no native stranded in bridge");
    }

    function test_fundsIn_acceptsUpperNativeBoundaryAndRefundsSurplus() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        (, uint256 maximum) = _directNativeBounds(quote);

        vm.deal(user, maximum);
        vm.prank(user);
        bridge.fundsIn{value: maximum}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), quote, "still only the quote is collected");
        assertEq(user.balance, maximum - quote, "full headroom refunded");
    }

    function test_fundsIn_revertsBelowNativeQuote() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _directNativeBounds(quote);
        uint256 provided = minimum - 1;

        vm.deal(user, provided);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(user);
        bridge.fundsIn{value: provided}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_revertsAboveNativeTolerance() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _directNativeBounds(quote);
        uint256 provided = maximum + 1;

        vm.deal(user, provided);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(user);
        bridge.fundsIn{value: provided}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    /// @notice An adverse price move raises the fresh native quote; the attached
    ///         buffer covers it and the unused remainder is refunded.
    function test_fundsIn_nativeBufferAbsorbsAdversePriceDrift() public {
        _setFundsInNativeRule(100);
        uint256 quotedAtSubmit = _nativeQuote(AMOUNT);
        uint256 attached = quotedAtSubmit + (quotedAtSubmit * 400) / 10_000; // +4% buffer

        // ETH depreciates ~3%: the same fee costs more wei than first quoted,
        // but less than the 4% buffer the caller attached.
        ethUsdFeed.setAnswer(1_940e8);
        uint256 freshQuote = _nativeQuote(AMOUNT);
        assertGt(freshQuote, quotedAtSubmit, "drift moved against the caller");
        assertLe(freshQuote, attached, "the buffer covers the drift, so no revert");

        vm.deal(user, attached);
        vm.prank(user);
        bridge.fundsIn{value: attached}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), freshQuote, "charged the fresh quote, not the stale one");
        assertEq(user.balance, attached - freshQuote, "remaining buffer refunded");
    }

    /// @dev Favorable drift simply returns more: the caller is charged the fresh
    ///      (lower) quote, never the stale higher one.
    function test_fundsIn_refundsLargerSurplusAfterFavorablePriceDrift() public {
        _setFundsInNativeRule(100);
        uint256 quotedAtSubmit = _nativeQuote(AMOUNT);

        ethUsdFeed.setAnswer(2_090e8); // ETH appreciates: the fee costs less wei
        uint256 freshQuote = _nativeQuote(AMOUNT);
        assertLt(freshQuote, quotedAtSubmit, "drift moved in the caller's favour");

        vm.deal(user, quotedAtSubmit);
        vm.prank(user);
        bridge.fundsIn{value: quotedAtSubmit}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), freshQuote, "charged the fresh, lower quote");
        assertEq(user.balance, quotedAtSubmit - freshQuote, "difference refunded");
    }

    /// @dev The protocol cannot be systematically under-paid: every deposit
    ///      credits exactly the quote in force at execution.
    function test_fundsIn_collectsFreshQuoteAcrossDifferentOraclePrices() public {
        _setFundsInNativeRule(100);
        uint256 expected;

        for (uint256 i; i < 3; i++) {
            ethUsdFeed.setAnswer(int256((2_000 + i * 1_000) * 1e8));
            ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp());
            uint256 quote = _nativeQuote(AMOUNT);
            (, uint256 maximum) = _directNativeBounds(quote);
            vm.deal(user, maximum);
            vm.prank(user);
            bridge.fundsIn{value: maximum}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 900 + i));
            expected += quote;
        }

        assertEq(cm.nativeCommissionPool(), expected, "collected exactly the sum of the quotes");
    }

    /// @dev A caller that cannot accept native value must send the exact quote;
    ///      attaching a buffer it cannot be refunded reverts cleanly.
    function test_fundsIn_nonpayableCallerRequiresExactNativeValue() public {
        _setFundsInNativeRule(100);
        NonPayableDepositor depositor = new NonPayableDepositor(bridge, usdt0);
        usdt0.mint(address(depositor), AMOUNT * 2);
        depositor.approveBridge(AMOUNT * 2);

        uint256 quote = _nativeQuote(AMOUNT);

        // Exact quote: nothing to refund, so the deposit goes through.
        vm.deal(address(depositor), quote);
        depositor.deposit(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), quote);
        assertEq(cm.nativeCommissionPool(), quote, "exact quote accepted from a non-payable caller");

        // With a buffer the refund cannot land, and the deposit reverts.
        uint256 attached = quote + (quote * 200) / 10_000;
        vm.deal(address(depositor), attached);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeRefundFailed.selector, address(depositor), attached - quote)
        );
        depositor.deposit(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 951), attached);
    }

    function test_fundsInFromAdapter_collectsComposeValueWithinSymmetricBand() public {
        _setFundsInNativeRule(100);

        address adapter = makeAddr("lz-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        usdt0.mint(adapter, AMOUNT * 2);
        vm.prank(adapter);
        usdt0.approve(address(bridge), AMOUNT * 2);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _adapterNativeBounds(quote);
        assertLt(minimum, quote, "adapter band extends BELOW the quote");

        // Below the quote is accepted here — and collected in full, since the
        // source-chain payer cannot be refunded.
        vm.deal(adapter, minimum);
        vm.prank(adapter);
        bridge.fundsIn{value: minimum}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        assertEq(cm.nativeCommissionPool(), minimum, "source-agreed value collected in full");
        assertEq(adapter.balance, 0, "adapter is not refunded");

        // Above the quote is likewise collected in full, not refunded.
        vm.deal(adapter, maximum);
        vm.prank(adapter);
        bridge.fundsIn{value: maximum}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 961)
        );
        assertEq(cm.nativeCommissionPool(), minimum + maximum, "upper bound also collected in full");
        assertEq(adapter.balance, 0, "adapter still not refunded");
        assertEq(address(bridge).balance, 0, "no native stranded in bridge");
    }

    function test_fundsInFromAdapter_revertsBelowNativeTolerance() public {
        _setFundsInNativeRule(100);

        address adapter = makeAddr("lz-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _adapterNativeBounds(quote);
        uint256 provided = minimum - 1;
        vm.deal(adapter, provided);

        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(adapter);
        bridge.fundsIn{value: provided}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
    }

    function test_fundsInFromAdapter_revertsAboveNativeTolerance() public {
        _setFundsInNativeRule(100);

        address adapter = makeAddr("lz-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _adapterNativeBounds(quote);
        uint256 provided = maximum + 1;
        vm.deal(adapter, provided);

        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(adapter);
        bridge.fundsIn{value: provided}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
    }

    function test_fundsIn_revertsWhenNativeRuleReceivesNoValue() public {
        _setFundsInNativeRule(100);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _directNativeBounds(quote);

        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, uint256(0), minimum, maximum)
        );
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_nativeCommissionRoutesToCM() public {
        uint256 percent = 100; // 1%
        _setFundsInNativeRule(percent);

        (uint256 tokenC, uint256 nativeC, uint256 net) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertEq(tokenC, 0);
        assertGt(nativeC, 0);
        assertEq(net, AMOUNT);

        vm.deal(user, nativeC);
        vm.prank(user);
        bytes32 opId = bridge.fundsIn{value: nativeC}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
        assertEq(address(cm).balance, nativeC);
        assertEq(cm.nativeCommissionPool(), nativeC);
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT);
    }
}
