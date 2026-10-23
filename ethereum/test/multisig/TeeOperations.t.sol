// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {CommissionConfig, CommissionCurrency, CommissionSide} from "../../src/interfaces/ICommissionManager.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice TEE-authorized releases and rebalances validate signatures and nonces.
contract MultisigTeeOperationsTest is MultisigProxyTestBase {
    struct TeeReleaseSnapshot {
        uint256 bridge;
        uint256 recipient;
        uint256 cm;
        uint256 cmPool;
        uint256 nativePool;
        uint256 record;
    }

    function test_fundsOutCall_paysRecipientNetAndCollectsTokenCommission() public {
        TeeReleaseSnapshot memory beforeState;
        uint256 percent = 500; // 5%
        vm.prank(address(proxy));
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");
        assertEq(netAmount, AMOUNT - tokenCommission, "net recipient amount");

        // Prepare signed TEE execution and snapshot proxy + Bridge accounting.
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        beforeState.bridge = token.balanceOf(address(bridge));
        beforeState.recipient = token.balanceOf(recipient);
        beforeState.cm = token.balanceOf(address(cm));
        beforeState.cmPool = cm.tokenCommissionPool(address(token));
        beforeState.nativePool = cm.nativeCommissionPool();
        beforeState.record = rgbModule.fundsInRecords(seedOpId);

        assertEq(beforeState.bridge, AMOUNT * 10, "pre bridge pool");
        assertEq(beforeState.recipient, 0, "pre recipient token");
        assertEq(beforeState.cm, 0, "pre cm token");
        assertEq(beforeState.cmPool, 0, "pre cm pool");
        assertEq(beforeState.nativePool, 0, "pre native pool");
        assertEq(beforeState.record, AMOUNT * 10, "pre record");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeFundsOut(
            recipient,
            AMOUNT,
            netAmount,
            tokenCommission,
            params.burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            params.settlementData
        );
        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.FundsOutExecuted(RGB_CHAIN_ID, nonce, bitmap);

        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "nonce incremented");
        assertTrue(bridge.consumedBurnIds(params.burnId), "burn id consumed");
        assertEq(token.balanceOf(address(bridge)), beforeState.bridge - AMOUNT, "bridge gross debit");
        assertEq(token.balanceOf(recipient), beforeState.recipient + netAmount, "recipient net delta");
        assertEq(token.balanceOf(address(cm)), beforeState.cm + tokenCommission, "cm fee delta");
        assertEq(cm.tokenCommissionPool(address(token)), beforeState.cmPool + tokenCommission, "cm pool delta");
        assertEq(cm.nativeCommissionPool(), beforeState.nativePool, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(seedOpId), beforeState.record, "record unchanged (proof-of-mint permanent)");

        // The signed Bridge gross debit splits into recipient net payout and CM token commission.
        assertEq(
            (token.balanceOf(recipient) - beforeState.recipient) + (token.balanceOf(address(cm)) - beforeState.cm),
            AMOUNT,
            "gross fundsOut conserved"
        );
    }

    function test_fundsOutCall_releasesViaBridge() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.FundsOutExecuted(RGB_CHAIN_ID, nonce, bitmap);

        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);

        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1);
    }

    function test_fundsOutCall_settlementDataRemainsSigned() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs =
            MultisigHelper.signAll(vm, MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline), pks);
        params.settlementData = bytes.concat(params.settlementData, hex"01");
        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce);
        assertFalse(bridge.consumedBurnIds(params.burnId));
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_fundsOutCall_revertsOnExpired() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() - 1;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    function test_fundsOutCall_revertsOnDeadlineTooFar() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + proxy.MAX_TEE_DEADLINE() + 1;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    function test_fundsOutCall_acceptsDeadlineAtMaxBoundary() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + proxy.MAX_TEE_DEADLINE(); // exact boundary, strict `>` lets it through

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
        assertEq(token.balanceOf(recipient), AMOUNT, "executes at the exact deadline ceiling");
    }

    function test_fundsOutCall_revertsOnWrongNonce() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = 99;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    function test_rebalanceCall_bothSettlementBlobsRemainSigned() public {
        for (uint256 field; field < 2; ++field) {
            IBridge.RebalanceParams memory params = _rebalanceParams();
            uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
            uint256 deadline = vm.getBlockTimestamp() + 1 hours;
            (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
            bytes[] memory sigs =
                MultisigHelper.signAll(vm, MultisigHelper.digestTeeRebalance(domainSep, params, nonce, deadline), pks);
            if (field == 0) params.settlementDataOut = bytes.concat(params.settlementDataOut, hex"01");
            else params.settlementDataIn = bytes.concat(params.settlementDataIn, hex"01");
            vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
            proxy.rebalanceCall(params, nonce, deadline, bitmap, sigs);
            assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce);
            assertFalse(bridge.consumedBurnIds(params.burnId));
        }
    }

    function test_rebalanceCall_executesViaBridge() public {
        IBridge.RebalanceParams memory params = _rebalanceParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeRebalance(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        uint256 srcBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(params.destinationChainId);
        uint256 custodyBefore = token.balanceOf(address(bridge));

        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.RebalanceExecuted(RGB_CHAIN_ID, params.destinationChainId, nonce, bitmap);

        proxy.rebalanceCall(params, nonce, deadline, bitmap, sigs);

        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), srcBefore - AMOUNT, "source bucket debited");
        assertEq(bridge.lockedLiquidity(params.destinationChainId), dstBefore + AMOUNT, "destination bucket credited");
        assertEq(token.balanceOf(address(bridge)), custodyBefore, "no tokens moved");
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "shared teeNonce stream advanced");
    }

    function test_rebalanceCall_revertsLocalDestinationWithoutConsumingNonce() public {
        IBridge.RebalanceParams memory params = _rebalanceParams();
        params.destinationChainId = block.chainid;
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs =
            MultisigHelper.signAll(vm, MultisigHelper.digestTeeRebalance(domainSep, params, nonce, deadline), pks);
        uint256 sourceBefore = bridge.lockedLiquidity(params.sourceChainId);
        uint256 destinationBefore = bridge.lockedLiquidity(params.destinationChainId);

        vm.expectRevert(IBridge.InvalidDestinationChainId.selector);
        proxy.rebalanceCall(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce, "rejected rebalance preserves the TEE nonce");
        assertEq(bridge.lockedLiquidity(params.sourceChainId), sourceBefore, "source bucket unchanged");
        assertEq(bridge.lockedLiquidity(params.destinationChainId), destinationBefore, "local bucket unchanged");
        assertFalse(bridge.consumedBurnIds(params.burnId), "burn id remains unused");
    }

    function test_rebalanceCall_revertsOnWrongNonce() public {
        IBridge.RebalanceParams memory params = _rebalanceParams();
        uint256 nonce = 99;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeRebalance(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.rebalanceCall(params, nonce, deadline, bitmap, sigs);
    }

    function test_rebalanceCall_revertsOnUnknownSourceChain() public {
        IBridge.RebalanceParams memory params = _rebalanceParams();
        params.sourceChainId = 555; // no enclave set registered for this chain
        uint256 nonce = 0;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeRebalance(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, 555));
        proxy.rebalanceCall(params, nonce, deadline, bitmap, sigs);
    }

    function test_rebalanceCall_revertsOnBelowThreshold() public {
        IBridge.RebalanceParams memory params = _rebalanceParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeRebalance(domainSep, params, nonce, deadline);
        uint256[] memory pks = new uint256[](1);
        pks[0] = ENC_PK_1;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.BelowThreshold.selector);
        proxy.rebalanceCall(params, nonce, deadline, 0x1, sigs);
    }

    function test_fundsOutCall_revertsOnBelowThreshold() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks = new uint256[](1);
        pks[0] = ENC_PK_1;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.BelowThreshold.selector);
        proxy.fundsOutCall(params, nonce, deadline, 0x1, sigs);
    }

    function test_fundsOutCall_revertsOnBadSignature() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks = new uint256[](2);
        pks[0] = ENC_PK_1;
        pks[1] = 0xBADBAD;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.fundsOutCall(params, nonce, deadline, 0x3, sigs);
    }

    function test_fundsOutCall_revertsOnSigCountMismatch() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks = new uint256[](3);
        pks[0] = ENC_PK_1;
        pks[1] = ENC_PK_2;
        pks[2] = ENC_PK_3;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.SigCountMismatch.selector);
        proxy.fundsOutCall(params, nonce, deadline, 0x3, sigs);
    }

    function test_fundsOutCall_revertsOnBitmapOutOfRange() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks,) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.BitmapOutOfRange.selector);
        proxy.fundsOutCall(params, nonce, deadline, 0x8, sigs);
    }

    /// @notice A consumed nonce cannot authorize another otherwise-valid burn.
    function test_fundsOutCall_revertsOnConsumedNonceForDifferentBurn() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint256[] memory keys, uint256 bitmap) = _encSigSet2of3();
        IBridge.FundsOutParams memory first = _fundsOutParams(recipient, AMOUNT / 4, keccak256("nonce-first-release"));
        proxy.fundsOutCall(
            first,
            0,
            deadline,
            bitmap,
            MultisigHelper.signAll(vm, MultisigHelper.digestTeeFundsOut(domainSep, first, 0, deadline), keys)
        );
        IBridge.FundsOutParams memory second = _fundsOutParams(recipient, AMOUNT / 4, keccak256("nonce-second-release"));
        bytes[] memory signatures =
            MultisigHelper.signAll(vm, MultisigHelper.digestTeeFundsOut(domainSep, second, 0, deadline), keys);
        assertFalse(bridge.consumedBurnIds(second.burnId), "second burn is fresh");
        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.fundsOutCall(second, 0, deadline, bitmap, signatures);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), 1, "stale nonce rejection preserves the lane");
        assertEq(token.balanceOf(recipient), AMOUNT / 4, "second burn pays nothing");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT * 10 - AMOUNT / 4, "second burn debits nothing");
        assertFalse(bridge.consumedBurnIds(second.burnId), "second burn remains fresh");

        bytes[] memory fresh =
            MultisigHelper.signAll(vm, MultisigHelper.digestTeeFundsOut(domainSep, second, 1, deadline), keys);
        proxy.fundsOutCall(second, 1, deadline, bitmap, fresh);
        assertEq(token.balanceOf(recipient), AMOUNT / 2, "fresh nonce accepts the same second payload");
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), 2, "fresh nonce advances the lane");
    }

    function test_rebalanceCall_revertsOnConsumedNonceForDifferentBurn() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint256[] memory keys, uint256 bitmap) = _encSigSet2of3();
        IBridge.RebalanceParams memory first = _rebalanceParams();
        first.amount = AMOUNT / 4;
        first.burnId = _deriveRebalanceBurnId(first);
        proxy.rebalanceCall(
            first,
            0,
            deadline,
            bitmap,
            MultisigHelper.signAll(vm, MultisigHelper.digestTeeRebalance(domainSep, first, 0, deadline), keys)
        );
        IBridge.RebalanceParams memory second = _rebalanceParams();
        second.amount = AMOUNT / 4;
        second.sourceBurnTxId = keccak256("nonce-second-rebalance");
        // The first rebalance records RGB_OP_ID + 7; a fresh mint ID lets this
        // payload succeed once it is signed with the current nonce.
        second.settlementDataIn = abi.encode(RGB_OP_ID + 8);
        second.burnId = _deriveRebalanceBurnId(second);
        bytes[] memory signatures =
            MultisigHelper.signAll(vm, MultisigHelper.digestTeeRebalance(domainSep, second, 0, deadline), keys);
        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.rebalanceCall(second, 0, deadline, bitmap, signatures);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), 1, "stale nonce rejection preserves the lane");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT * 10 - AMOUNT / 4, "source has one debit");
        assertEq(bridge.lockedLiquidity(first.destinationChainId), AMOUNT / 4, "destination has one credit");
        assertEq(token.balanceOf(address(bridge)), AMOUNT * 10, "custody unchanged by rebalances");
        assertFalse(bridge.consumedBurnIds(second.burnId), "second burn remains fresh");

        bytes[] memory fresh =
            MultisigHelper.signAll(vm, MultisigHelper.digestTeeRebalance(domainSep, second, 1, deadline), keys);
        proxy.rebalanceCall(second, 1, deadline, bitmap, fresh);
        assertEq(
            bridge.lockedLiquidity(second.destinationChainId), AMOUNT / 2, "fresh nonce accepts the same second payload"
        );
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), 2, "fresh nonce advances the lane");
    }

    function test_rebalanceCall_revertsOnUnknownSourceBeforeNonceCheck() public {
        IBridge.RebalanceParams memory params = _rebalanceParams();
        params.sourceChainId = 424_242;
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, uint256(424_242)));
        proxy.rebalanceCall(params, 1, vm.getBlockTimestamp() + 1 hours, 0, new bytes[](0));
    }
}
