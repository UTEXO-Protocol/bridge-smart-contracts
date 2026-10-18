// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {CommissionConfig, CommissionCurrency, CommissionSide} from "../../src/interfaces/ICommissionManager.sol";
import {MockSettlementModule} from "../mocks/MockSettlementModule.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Commission forwarding, pool credits and settled custody.
contract BridgeCommissionAccountingTest is BridgeTestBase {
    function test_fundsIn_tokenCommissionRoutesToCM() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100;
        uint256 expectedNet = AMOUNT - expectedCommission;

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), expectedNet, "bridge net");
        assertEq(usdt0.balanceOf(address(cm)), expectedCommission, "cm pool");
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "cm recorded");
        assertEq(rgbModule.fundsInRecords(opId), expectedNet, "record = net");
    }

    // The flat `baseFee` rides the same path as the proportional part: it is
    // deducted from the deposit, forwarded to the CommissionManager pool, and
    // the settlement record is written against the resulting net.
    function test_fundsIn_baseFeeRoutesToCMOnTopOfPercentage() public {
        uint256 percent = 400; // 4%
        uint256 baseFee = 0.1e18;

        // The harness floor is 1 wei-unit, which no flat fee can sit under.
        // Raise it to the deposit amount first: the combined percentage and
        // flat fee remains comfortably below this floor.
        vm.prank(bridge.owner());
        bridge.setMinFundsInAmount(1e18);

        vm.prank(deployer);
        cm.setCommissionRule(
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                baseFee: baseFee,
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100 + baseFee;
        uint256 expectedNet = AMOUNT - expectedCommission;

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), expectedNet, "bridge net");
        assertEq(usdt0.balanceOf(address(cm)), expectedCommission, "cm pool holds percentage + flat");
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "cm recorded");
        assertEq(rgbModule.fundsInRecords(opId), expectedNet, "record = net");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), expectedNet, "liquidity credited net");
    }

    // A token already donated directly to the CommissionManager is NOT absorbed
    // as commission. Bridge measures the delta of its own transfer,
    // so the pool grows by exactly the real fee; the donation stays a stray balance.
    function test_fundsIn_tokenCommissionDoesNotAbsorbCmDonation() public {
        _setFundsInTokenRule(400); // 4%
        uint256 expectedCommission = (AMOUNT * 400) / 100 / 100;

        // Unsolicited direct transfer into the CommissionManager.
        address donor = makeAddr("cmDonor");
        uint256 donation = 5e18;
        usdt0.mint(donor, donation);
        vm.prank(donor);
        usdt0.transfer(address(cm), donation);

        assertEq(cm.tokenCommissionPool(address(usdt0)), 0, "pre pool (donation not counted)");
        assertEq(usdt0.balanceOf(address(cm)), donation, "pre cm balance holds donation");

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // Pool grew by exactly the real commission — the donation was not folded in.
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "pool grew only by real commission");
        assertEq(usdt0.balanceOf(address(cm)), donation + expectedCommission, "donation still present as stray balance");
    }

    function test_fundsOut_tokenCommissionRoutesToCM() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        uint256 percent = 500; // 5%
        _setFundsOutTokenRule(percent);

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100;
        uint256 expectedNet = AMOUNT - expectedCommission;

        vm.prank(multisig);
        _fundsOut(
            recipient,
            AMOUNT,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );

        assertEq(usdt0.balanceOf(recipient), expectedNet, "recipient net");
        assertEq(usdt0.balanceOf(address(cm)), expectedCommission, "cm pool");
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "cm recorded");
    }

    function test_fundsIn_revertsOnNativeValueMismatchZeroRuleButValueSent() public {
        vm.deal(user, 1 ether);
        vm.expectRevert(IBridge.NativeValueMismatch.selector);
        vm.prank(user);
        bridge.fundsIn{value: 1 ether}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_collectsTokenCommissionAndCreditsNetLiquidity() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);

        // Snapshot every balance/pool/record this TOKEN-commission flow should touch.
        bytes32 expectedOpId = _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, netAmount);
        LedgerSnapshot memory beforeState = _snapshotLedger(expectedOpId);

        assertEq(beforeState.bridgeToken, 0, "pre bridge token");
        assertEq(beforeState.cmToken, 0, "pre cm token");
        assertEq(beforeState.cmPool, 0, "pre cm pool");
        assertEq(beforeState.nativePool, 0, "pre native pool");
        assertEq(beforeState.record, 0, "pre record");

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(user, RGB_OP_ID, uint64(netAmount));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit IBridge.BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            netAmount,
            tokenCommission,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData()
        );

        // Pull user tokens, forward commission to CM, dispatch the RGB hook,
        // then emit Bridge events.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId, expectedOpId, "returned id matches derivation");

        assertEq(usdt0.balanceOf(user), beforeState.userToken - AMOUNT, "user gross spent");
        assertEq(usdt0.balanceOf(address(bridge)), beforeState.bridgeToken + netAmount, "bridge net delta");
        assertEq(usdt0.balanceOf(address(cm)), beforeState.cmToken + tokenCommission, "cm fee delta");
        assertEq(cm.tokenCommissionPool(address(usdt0)), beforeState.cmPool + tokenCommission, "cm pool delta");
        assertEq(cm.nativeCommissionPool(), beforeState.nativePool, "native pool unchanged");
        assertEq(user.balance, beforeState.userNative, "user native unchanged");
        assertEq(address(bridge).balance, beforeState.bridgeNative, "bridge native unchanged");
        assertEq(address(cm).balance, beforeState.cmNative, "cm native unchanged");
        assertEq(rgbModule.fundsInRecords(opId), beforeState.record + netAmount, "record delta = net");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), netAmount, "chain liquidity credits net receipt");
        assertEq(bridge.totalLockedLiquidity(), netAmount, "total liquidity credits net receipt");

        // Gross USDT0 is conserved between Bridge liquidity and CM commission custody.
        assertEq(
            (usdt0.balanceOf(address(bridge)) - beforeState.bridgeToken)
                + (usdt0.balanceOf(address(cm)) - beforeState.cmToken),
            AMOUNT,
            "gross token conserved"
        );
    }

    function test_fundsIn_collectsNativeCommissionAndCreditsTokenLiquidity() public {
        uint256 percent = 100; // 1%
        _setFundsInNativeRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertEq(tokenCommission, 0, "token fee is zero");
        assertGt(nativeCommission, 0, "native fee quoted");
        assertEq(netAmount, AMOUNT, "net token amount");

        vm.deal(user, nativeCommission);

        // Snapshot token/native balances, pools, and RGB record touched by native-fee fundsIn.
        bytes32 expectedOpId = _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, netAmount);
        LedgerSnapshot memory beforeState = _snapshotLedger(expectedOpId);

        assertEq(beforeState.bridgeToken, 0, "pre bridge token");
        assertEq(beforeState.cmToken, 0, "pre cm token");
        assertEq(beforeState.cmPool, 0, "pre token pool");
        assertEq(beforeState.nativePool, 0, "pre native pool");
        assertEq(beforeState.record, 0, "pre record");

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(user, RGB_OP_ID, uint64(netAmount));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit IBridge.BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            netAmount,
            0,
            nativeCommission,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData()
        );

        // Execute exact-value native commission path; token principal stays whole.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn{value: nativeCommission}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId, expectedOpId, "returned id matches derivation");

        assertEq(usdt0.balanceOf(user), beforeState.userToken - AMOUNT, "user token gross spent");
        assertEq(usdt0.balanceOf(address(bridge)), beforeState.bridgeToken + netAmount, "bridge token delta");
        assertEq(usdt0.balanceOf(address(cm)), beforeState.cmToken, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), beforeState.cmPool, "token pool unchanged");
        assertEq(cm.nativeCommissionPool(), beforeState.nativePool + nativeCommission, "native pool delta");
        assertEq(user.balance, beforeState.userNative - nativeCommission, "user native paid");
        assertEq(address(bridge).balance, beforeState.bridgeNative, "bridge native unchanged");
        assertEq(address(cm).balance, beforeState.cmNative + nativeCommission, "cm native delta");
        assertEq(rgbModule.fundsInRecords(opId), beforeState.record + netAmount, "record delta = net");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), netAmount, "chain liquidity credits full native-fee principal");
        assertEq(bridge.totalLockedLiquidity(), netAmount, "total liquidity credits full native-fee principal");

        // Native fee is conserved in CM custody while the full USDT0 principal stays in Bridge.
        assertEq(usdt0.balanceOf(address(bridge)) - beforeState.bridgeToken, AMOUNT, "gross token in bridge");
        assertEq(address(cm).balance - beforeState.cmNative, nativeCommission, "native fee conserved");
    }

    function test_fundsOut_partialReleasePaysNetAndCollectsCommission() public {
        uint256 releaseAmount = AMOUNT * 3 / 5;
        uint256 percent = 500; // 5%

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(releaseAmount);
        _setFundsOutTokenRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(usdt0), releaseAmount);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");
        assertEq(netAmount, releaseAmount - tokenCommission, "net recipient amount");

        bytes32[] memory ids = _ids(opId);

        // Snapshot the Bridge fundsOut state after a larger RGB record exists.
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore = usdt0.balanceOf(recipient);
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(opId);

        assertEq(bridgeBefore, releaseAmount * 10, "pre bridge pool satisfies configured 10% burst");
        assertEq(recipientBefore, 0, "pre recipient token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, AMOUNT, "pre record");

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(ids);
        uint256 burnId = _deriveBurnId(releaseAmount, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);
        assertFalse(bridge.consumedBurnIds(burnId), "pre burn id");

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeFundsOut(
            recipient,
            releaseAmount,
            netAmount,
            tokenCommission,
            burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            settlementData
        );

        // Settlement records are permanent proof of mint. A partial release
        // leaves the record intact; Bridge.lockedLiquidity enforces solvency.
        vm.prank(multisig);
        _fundsOut(
            recipient, releaseAmount, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData, SRC_BURN_TX_ID
        );

        assertTrue(bridge.consumedBurnIds(burnId), "burn id consumed");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore - releaseAmount, "bridge gross debit");
        assertEq(usdt0.balanceOf(recipient), recipientBefore + netAmount, "recipient net delta");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, "cm fee delta");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, "cm pool delta");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore, "record unchanged (proof-of-mint permanent)");

        // The gross Bridge debit splits into recipient net payout and CM token commission.
        assertEq(
            (usdt0.balanceOf(recipient) - recipientBefore) + (usdt0.balanceOf(address(cm)) - cmBefore),
            releaseAmount,
            "gross fundsOut conserved"
        );
    }

    function test_fundsIn_hookObservesCustodyAfterTokenCommissionForwarding() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");

        MockSettlementModule observingModule = new MockSettlementModule();
        observingModule.setFundsInBalanceProbe(address(usdt0), address(bridge));
        // Return a non-zero external id so Bridge emits the RGB-only FundsIn event.
        observingModule.setExternalIdToReturn(RGB_OP_ID);

        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(observingModule));

        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");

        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(user, RGB_OP_ID, uint64(netAmount));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit IBridge.BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            netAmount,
            tokenCommission,
            nativeCommission,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData()
        );

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(observingModule.onFundsInCount(), 1, "module called once");
        assertEq(observingModule.lastNetAmount(), netAmount, "module got net amount");
        assertEq(
            observingModule.lastObservedBalanceOnFundsIn(),
            bridgeBefore + netAmount,
            "hook sees only the retained net, not the in-flight commission"
        );
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + netAmount, "final bridge net");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, "cm token delta");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, "cm pool delta");
    }

    function test_fundsOut_baseFeeRoutesToCMOnTopOfPercentage() public {
        _seedRGB(1000e6);

        uint256 percent = 400; // 4%
        uint256 baseFee = 1e6;

        // The flat fee must fit under the release floor.
        vm.prank(multisig);
        bridge.setMinFundsInAmount(10e6);
        vm.prank(multisig);
        bridge.setMinFundsOutAmount(10e6);

        vm.prank(deployer);
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                baseFee: baseFee,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        uint256 release = 100e6;
        uint256 expectedCommission = (release * percent) / 100 / 100 + baseFee;

        uint256 recipientBefore = usdt0.balanceOf(recipient);
        uint256 poolBefore = cm.tokenCommissionPool(address(usdt0));

        _releaseRGB(release, keccak256("outbound-percentage-and-flat-fee"));

        assertEq(usdt0.balanceOf(recipient) - recipientBefore, release - expectedCommission, "recipient gets net");
        assertEq(
            cm.tokenCommissionPool(address(usdt0)) - poolBefore, expectedCommission, "pool holds percentage + flat"
        );
    }
}
