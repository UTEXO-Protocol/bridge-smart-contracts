// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Vm} from "forge-std/Test.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {RouteRegistry} from "../../src/RouteRegistry.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {IBridgeProxy} from "../../src/interfaces/IBridgeProxy.sol";
import {CommissionConfig, CommissionCurrency, CommissionSide} from "../../src/interfaces/ICommissionManager.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice Proposal execution, cancellation and managed ownership preserve federation authority.
contract MultisigGovernanceTest is MultisigProxyTestBase {
    /// @dev Assert that a protected selector is rejected before federation
    ///      signature verification on every generic raw-call lane. Applying
    ///      each policy selector-wide closes mutable-target aliasing.
    function _assertGenericPathsRejectSelector(bytes memory callData, bytes4 errorSelector) private {
        bytes4 selector = bytes4(callData);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes[] memory noSigs = new bytes[](0);
        bytes memory expected = abi.encodeWithSelector(errorSelector, selector);

        vm.expectRevert(expected);
        proxy.proposeAdminExecute(callData, nonce, deadline, 0, noSigs);

        vm.expectRevert(expected);
        proxy.proposeAdminExecuteCommissionManager(callData, nonce, deadline, 0, noSigs);

        vm.expectRevert(expected);
        proxy.proposeAdminExecuteRouteRegistry(callData, nonce, deadline, 0, noSigs);

        vm.expectRevert(expected);
        proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, 0, noSigs);
    }

    function _prepareCancellation(uint256 cancelDeadline)
        private
        returns (bytes32 id, uint256 bitmap, bytes[] memory cancelSigs)
    {
        address newBridge = makeAddr("cancel-deadline-bridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 proposalDeadline = vm.getBlockTimestamp() + 1 days;
        (uint256[] memory pks, uint256 bits) = _fedSigSet2of3();
        bitmap = bits;
        bytes32 proposalDigest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, proposalDeadline);
        id = proxy.proposeUpdateBridge(
            newBridge, nonce, proposalDeadline, bitmap, MultisigHelper.signAll(vm, proposalDigest, pks)
        );
        cancelSigs = MultisigHelper.signAll(vm, MultisigHelper.digestCancelProposal(domainSep, id, cancelDeadline), pks);
    }

    function _assertFederationRotationLogs(
        Vm.Log[] memory entries,
        address[] memory expectedSigners,
        uint256 expectedThreshold,
        uint256 expectedVersion
    ) private view {
        bytes32 combinedTopic = keccak256("FederationSignersUpdated(address[],uint256,uint256)");
        bytes32 legacySignersTopic = keccak256("FederationSignersUpdated(address[],uint256)");
        bytes32 legacyVersionTopic = keccak256("FederationSignerSetVersionUpdated(uint256)");
        uint256 count;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter != address(proxy) || entries[i].topics.length == 0) continue;
            bytes32 topic = entries[i].topics[0];
            assertTrue(topic != legacySignersTopic, "legacy signer event must not be emitted");
            assertTrue(topic != legacyVersionTopic, "legacy version event must not be emitted");
            if (topic != combinedTopic) continue;
            count++;
            assertEq(entries[i].topics.length, 2, "version is the only indexed field");
            assertEq(entries[i].topics[1], bytes32(expectedVersion), "indexed version");
            assertEq(entries[i].data, abi.encode(expectedSigners, expectedThreshold), "signers and threshold");
        }
        assertEq(count, 1, "one complete event per rotation");
        assertEq(proxy.federationSignerSetVersion(), expectedVersion);
        assertEq(proxy.getFederationSigners(), expectedSigners);
        assertEq(proxy.federationThreshold(), expectedThreshold);
    }

    function _proposeManagedOwnership(address target, address newOwner)
        private
        returns (bytes32 id, bytes memory opData)
    {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeTransferManagedOwnership(domainSep, target, newOwner, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        id = proxy.proposeTransferManagedOwnership(
            target, newOwner, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks)
        );
        opData = abi.encode(target, newOwner);
    }

    function _proposeAcceptOwnership(address target, bytes memory callData) private returns (bytes32) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest;
        if (target == address(bridge)) {
            digest = MultisigHelper.digestProposeAdminExecute(
                domainSep, target, bytes4(callData), callData, nonce, deadline
            );
        } else if (target == address(cm)) {
            digest = MultisigHelper.digestProposeAdminExecuteCM(
                domainSep, target, bytes4(callData), callData, nonce, deadline
            );
        } else {
            digest = MultisigHelper.digestProposeAdminExecuteRouteRegistry(
                domainSep, target, bytes4(callData), callData, nonce, deadline
            );
        }
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory signatures = MultisigHelper.signAll(vm, digest, pks);
        if (target == address(bridge)) return proxy.proposeAdminExecute(callData, nonce, deadline, bitmap, signatures);
        if (target == address(cm)) {
            return proxy.proposeAdminExecuteCommissionManager(callData, nonce, deadline, bitmap, signatures);
        }
        return proxy.proposeAdminExecuteRouteRegistry(callData, nonce, deadline, bitmap, signatures);
    }

    function test_proposeAdminExecute_canCallBridge() public {
        bytes memory callData = abi.encodeWithSignature("pauseInflow()");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecute(
            domainSep, proxy.bridge(), bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecute(callData, nonce, deadline, bitmap, sigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(id, callData);

        assertTrue(bridge.paused());
    }

    function test_adminExecute_rejectsFundsOutSelectorInAllLanes() public {
        bytes memory callData = abi.encodeCall(IBridge.fundsOut, (_fundsOutParams()));
        _assertGenericPathsRejectSelector(callData, IMultisigProxy.ForbiddenBridgeReleaseSelector.selector);
    }

    function test_adminExecute_rejectsRebalanceSelectorInAllLanes() public {
        bytes memory callData = abi.encodeCall(IBridge.rebalanceLiquidity, (_rebalanceParams()));
        _assertGenericPathsRejectSelector(callData, IMultisigProxy.ForbiddenBridgeReleaseSelector.selector);
    }

    function test_adminExecute_rejectsProxyUpgradeSelectorInAllLanes() public {
        bytes memory callData = abi.encodeCall(IBridgeProxy.upgradeToAndCall, (makeAddr("implementation"), bytes("")));
        _assertGenericPathsRejectSelector(callData, IMultisigProxy.ForbiddenBridgeProxySelector.selector);
    }

    function test_adminExecute_rejectsCommissionBindingSelectorsInAllLanes() public {
        bytes memory callData = abi.encodeCall(IBridge.setCommissionManager, (makeAddr("genericCm")));
        _assertGenericPathsRejectSelector(callData, IMultisigProxy.ForbiddenCommissionManagerSelector.selector);
    }

    function test_proposeUpdateCommissionManager_updatesManagerAfterTimelock() public {
        CommissionManager newCm = new CommissionManager(address(bridge), commissionReceiver);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateCommissionManager(
            domainSep, proxy.bridge(), address(newCm), nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateCommissionManager(address(newCm), nonce, deadline, bitmap, sigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.CommissionManagerUpdated(address(cm), address(newCm));
        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.CommissionManagerUpdated(address(cm), address(newCm));

        proxy.executeProposal(id, abi.encode(address(newCm)));
        assertEq(proxy.commissionManager(), address(newCm));
        assertEq(address(bridge.commissionManager()), address(newCm));
    }

    function test_proposeWithdrawTokenCommissionCM_paysFixedRecipientAfterTimelock() public {
        // Seed commission by setting a fundsIn TOKEN rule and doing a deposit.
        vm.prank(address(proxy));
        cm.setCommissionRule(
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: 400, // 4%
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        uint256 depositAmount = 1e18;
        vm.prank(user);
        bridge.fundsIn(depositAmount, RGB_CHAIN_ID, DST_ADDR, abi.encode(RGB_OP_ID));

        uint256 expectedCommission = (depositAmount * 400) / 100 / 100;
        assertEq(cm.tokenCommissionPool(address(token)), expectedCommission);

        // Propose withdrawal.
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeWithdrawTokenCommissionCM(
            domainSep, proxy.commissionManager(), address(token), expectedCommission, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id =
            proxy.proposeWithdrawTokenCommissionCM(address(token), expectedCommission, nonce, deadline, bitmap, sigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        uint256 recipientBefore = token.balanceOf(commissionReceiver);

        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.CommissionWithdrawn(address(token), expectedCommission, commissionReceiver);

        proxy.executeProposal(id, abi.encode(address(token), expectedCommission));

        assertEq(token.balanceOf(commissionReceiver), recipientBefore + expectedCommission);
        assertEq(cm.tokenCommissionPool(address(token)), 0);
    }

    function test_cancelProposal_revertsOnDeadlineTooFar() public {
        uint256[2] memory deadlines =
            [vm.getBlockTimestamp() + proxy.MAX_PROPOSAL_LIFETIME() + 1, vm.getBlockTimestamp() + 10 * 365 days];
        for (uint256 i; i < deadlines.length; ++i) {
            (bytes32 id, uint256 bitmap, bytes[] memory sigs) = _prepareCancellation(deadlines[i]);
            uint256 nonceBefore = proxy.proposalNonce();
            uint256 emergencyNonceBefore = proxy.emergencyNonce();
            uint256 teeNonceBefore = proxy.teeNonce(RGB_CHAIN_ID);
            vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
            proxy.cancelProposal(id, deadlines[i], bitmap, sigs);
            assertEq(uint256(proxy.getProposal(id).status), uint256(IMultisigProxy.ProposalStatus.Pending));
            assertEq(proxy.proposalNonce(), nonceBefore);
            assertEq(proxy.emergencyNonce(), emergencyNonceBefore);
            assertEq(proxy.teeNonce(RGB_CHAIN_ID), teeNonceBefore);
        }
    }

    function test_cancelProposal_acceptsExactDeadlineBoundaries() public {
        uint256[2] memory deadlines = [vm.getBlockTimestamp(), vm.getBlockTimestamp() + proxy.MAX_PROPOSAL_LIFETIME()];
        for (uint256 i; i < deadlines.length; ++i) {
            (bytes32 id, uint256 bitmap, bytes[] memory sigs) = _prepareCancellation(deadlines[i]);
            uint256 nonceBefore = proxy.proposalNonce();
            proxy.cancelProposal(id, deadlines[i], bitmap, sigs);
            assertEq(uint256(proxy.getProposal(id).status), uint256(IMultisigProxy.ProposalStatus.Cancelled));
            assertEq(proxy.proposalNonce(), nonceBefore);
        }
    }

    function test_cancelProposal_revertsOnExpiredDeadline() public {
        uint256 deadline = vm.getBlockTimestamp() - 1;
        (bytes32 id, uint256 bitmap, bytes[] memory sigs) = _prepareCancellation(deadline);
        uint256 nonceBefore = proxy.proposalNonce();
        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.cancelProposal(id, deadline, bitmap, sigs);
        assertEq(uint256(proxy.getProposal(id).status), uint256(IMultisigProxy.ProposalStatus.Pending));
        assertEq(proxy.proposalNonce(), nonceBefore);
    }

    function test_cancelProposal_marksAuthorizedProposalCancelled() public {
        address newBridge = makeAddr("newBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);
        uint256 proposalNonceAfterPropose = proxy.proposalNonce();

        uint256 cDeadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 cDigest = MultisigHelper.digestCancelProposal(domainSep, id, cDeadline);
        bytes[] memory cSigs = MultisigHelper.signAll(vm, cDigest, pks);

        vm.expectEmit(true, false, false, true, address(proxy));
        emit IMultisigProxy.ProposalCancelled(id);
        proxy.cancelProposal(id, cDeadline, bitmap, cSigs);

        assertEq(proxy.proposalNonce(), proposalNonceAfterPropose, "cancel does not consume proposal nonce");
        IMultisigProxy.Proposal memory p = proxy.getProposal(id);
        assertEq(uint8(p.status), uint8(IMultisigProxy.ProposalStatus.Cancelled));

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.executeProposal(id, abi.encode(newBridge));
    }

    function test_cancelProposal_revertsOnNotPending() public {
        bytes32 id = keccak256("ghost");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestCancelProposal(domainSep, id, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.cancelProposal(id, deadline, bitmap, sigs);
    }

    /// @notice Advancing proposalNonce through unrelated proposals cannot
    ///         invalidate a cancellation signed for a specific proposal.
    function test_cancelProposal_survivesUnrelatedProposalNonceAdvance() public {
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();

        uint256 targetNonce = proxy.proposalNonce();
        uint256 targetDeadline = vm.getBlockTimestamp() + 1 days;
        address targetBridge = makeAddr("targetBridge");
        bytes32 targetDigest =
            MultisigHelper.digestProposeUpdateBridge(domainSep, targetBridge, targetNonce, targetDeadline);
        bytes32 targetId = proxy.proposeUpdateBridge(
            targetBridge, targetNonce, targetDeadline, bitmap, MultisigHelper.signAll(vm, targetDigest, pks)
        );

        uint256 cancelDeadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 cancelDigest = MultisigHelper.digestCancelProposal(domainSep, targetId, cancelDeadline);
        bytes[] memory cancelSigs = MultisigHelper.signAll(vm, cancelDigest, pks);

        // A different, valid federation proposal advances the sequential
        // proposal lane after the cancel bundle has already been collected.
        uint256 unrelatedNonce = proxy.proposalNonce();
        address unrelatedBridge = makeAddr("unrelatedBridge");
        bytes32 unrelatedDigest =
            MultisigHelper.digestProposeUpdateBridge(domainSep, unrelatedBridge, unrelatedNonce, targetDeadline);
        proxy.proposeUpdateBridge(
            unrelatedBridge, unrelatedNonce, targetDeadline, bitmap, MultisigHelper.signAll(vm, unrelatedDigest, pks)
        );
        uint256 nonceAfterUnrelatedProposal = proxy.proposalNonce();
        assertEq(nonceAfterUnrelatedProposal, targetNonce + 2, "unrelated proposal advances its own lane");

        proxy.cancelProposal(targetId, cancelDeadline, bitmap, cancelSigs);

        assertEq(proxy.proposalNonce(), nonceAfterUnrelatedProposal, "cancel leaves proposal lane untouched");
        assertEq(
            uint256(proxy.getProposal(targetId).status),
            uint256(IMultisigProxy.ProposalStatus.Cancelled),
            "original cancel remains executable"
        );
    }

    function test_cancelProposal_replayRevertsOnCancelledStatus() public {
        address newBridge = makeAddr("cancelReplayBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 proposalDeadline = vm.getBlockTimestamp() + 1 days;
        bytes32 proposalDigest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, proposalDeadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposeUpdateBridge(
            newBridge, nonce, proposalDeadline, bitmap, MultisigHelper.signAll(vm, proposalDigest, pks)
        );

        uint256 cancelDeadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 cancelDigest = MultisigHelper.digestCancelProposal(domainSep, id, cancelDeadline);
        bytes[] memory cancelSigs = MultisigHelper.signAll(vm, cancelDigest, pks);

        proxy.cancelProposal(id, cancelDeadline, bitmap, cancelSigs);

        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.cancelProposal(id, cancelDeadline, bitmap, cancelSigs);
    }

    function test_executeProposal_revertsOnDataMismatch() public {
        address newBridge = makeAddr("newBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        proxy.executeProposal(id, abi.encode(makeAddr("different")));
    }

    function test_executeProposal_revertsOnExpiredDeadline() public {
        address newBridge = makeAddr("newBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 2 hours;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        vm.warp(deadline + 1);
        vm.expectRevert(IMultisigProxy.ProposalExpired.selector);
        proxy.executeProposal(id, abi.encode(newBridge));
    }

    function test_executeProposal_usesTimelockRecordedAtCreation() public {
        uint256 proposedAt = vm.getBlockTimestamp();
        address newBridge = makeAddr("snapshotTimelockBridge");
        uint256 newDuration = 2 hours; // raise above the 1h in force at creation
        uint256 deadline = proposedAt + 1 days;

        assertEq(proxy.timelockDuration(), TIMELOCK, "pre timelock");

        // Proposal A — created while timelockDuration == TIMELOCK (1h).
        uint256 bridgeNonce = proxy.proposalNonce();
        bytes32 bridgeDigest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, bridgeNonce, deadline);
        (uint256[] memory bridgePks, uint256 bridgeBitmap) = _fedSigSet2of3();
        bytes[] memory bridgeSigs = MultisigHelper.signAll(vm, bridgeDigest, bridgePks);
        bytes32 bridgeProposalId = proxy.proposeUpdateBridge(newBridge, bridgeNonce, deadline, bridgeBitmap, bridgeSigs);

        assertEq(proxy.getProposal(bridgeProposalId).timelockSnapshot, TIMELOCK, "timelock snapshotted at creation");

        // Raise the live timelock to 2h via its own proposal.
        uint256 timelockNonce = proxy.proposalNonce();
        bytes32 timelockDigest =
            MultisigHelper.digestProposeSetTimelockDuration(domainSep, newDuration, timelockNonce, deadline);
        (uint256[] memory timelockPks, uint256 timelockBitmap) = _fedSigSet2of3();
        bytes[] memory timelockSigs = MultisigHelper.signAll(vm, timelockDigest, timelockPks);
        bytes32 timelockProposalId =
            proxy.proposeSetTimelockDuration(newDuration, timelockNonce, deadline, timelockBitmap, timelockSigs);

        // At proposedAt + 1h + 1: both proposals' creation-time snapshot (1h)
        // has elapsed. Execute the timelock raise first.
        vm.warp(proposedAt + TIMELOCK + 1);
        proxy.executeProposal(timelockProposalId, abi.encode(newDuration));
        assertEq(proxy.timelockDuration(), newDuration, "live timelock raised to 2h");

        // Proposal A uses the 1h timelock recorded at creation, so raising
        // the live timelock to 2h does not delay it.
        proxy.executeProposal(bridgeProposalId, abi.encode(newBridge));
        assertEq(proxy.bridge(), newBridge, "snapshotted proposal executes despite the live timelock raise");
    }

    function test_federationRotation_emitsOneCompleteEventPerRotation() public {
        (address[] memory newSigners, uint256[] memory newPks) = _signerSetFromPrivateKeys(0xFA1, 3);
        (uint256[] memory currentPks, uint256 bitmap) = _fedSigSet2of3();
        assertEq(proxy.federationSignerSetVersion(), 1);

        vm.recordLogs();
        _rotateFedMeasured(newSigners, 2, currentPks, bitmap);
        _assertFederationRotationLogs(vm.getRecordedLogs(), newSigners, 2, 2);

        // Updating only the threshold is still a rotation and advances the version.
        vm.recordLogs();
        _rotateFedMeasured(newSigners, 3, _slice(newPks, 2), _bitmapFor(2));
        _assertFederationRotationLogs(vm.getRecordedLogs(), newSigners, 3, 3);
    }

    function test_federationRotation_invalidatesPreviouslyApprovedProposals() public {
        assertEq(proxy.federationSignerSetVersion(), 1, "initial federation version");

        // This proposal is valid under the original federation, but remains
        // pending while a signer rotation is proposed and executed.
        address staleBridge = makeAddr("staleBridge");
        uint256 staleNonce = proxy.proposalNonce();
        uint256 commonDeadline = vm.getBlockTimestamp() + 1 days;
        bytes32 staleDigest =
            MultisigHelper.digestProposeUpdateBridge(domainSep, staleBridge, staleNonce, commonDeadline);
        (uint256[] memory oldPks, uint256 oldBitmap) = _fedSigSet2of3();
        bytes32 staleId = proxy.proposeUpdateBridge(
            staleBridge, staleNonce, commonDeadline, oldBitmap, MultisigHelper.signAll(vm, staleDigest, oldPks)
        );
        assertEq(proxy.getProposal(staleId).federationVersion, 1, "proposal snapshots version one");

        (address[] memory newSigners, uint256[] memory newPks) = _signerSetFromPrivateKeys(0xFA1, 3);

        uint256 rotationNonce = proxy.proposalNonce();
        bytes32 rotationDigest = MultisigHelper.digestProposeUpdateFederationSigners(
            domainSep, newSigners, 2, rotationNonce, commonDeadline
        );
        bytes32 rotationId = proxy.proposeUpdateFederationSigners(
            newSigners, 2, rotationNonce, commonDeadline, oldBitmap, MultisigHelper.signAll(vm, rotationDigest, oldPks)
        );
        assertEq(proxy.getProposal(rotationId).federationVersion, 1, "rotation uses current version");

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(rotationId, abi.encode(newSigners, uint256(2)));
        assertEq(proxy.federationSignerSetVersion(), 2, "rotation advances version");

        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.StaleFederationProposal.selector, uint256(1), uint256(2)));
        proxy.executeProposal(staleId, abi.encode(staleBridge));
        assertEq(
            uint256(proxy.getProposal(staleId).status),
            uint256(IMultisigProxy.ProposalStatus.Pending),
            "stale proposal cannot execute"
        );

        // The live federation can still cancel stale records for operational
        // cleanup; cancellation intentionally has no version restriction.
        uint256 cancelDeadline = vm.getBlockTimestamp() + 1 days;
        bytes32 cancelDigest = MultisigHelper.digestCancelProposal(domainSep, staleId, cancelDeadline);
        uint256[] memory cancellingPks = _slice(newPks, 2);
        proxy.cancelProposal(staleId, cancelDeadline, 3, MultisigHelper.signAll(vm, cancelDigest, cancellingPks));
        assertEq(
            uint256(proxy.getProposal(staleId).status),
            uint256(IMultisigProxy.ProposalStatus.Cancelled),
            "live federation cleans up stale proposal"
        );
    }

    // Emergency actions run on a separate `emergencyNonce`, so an emergency
    // pause does NOT stale an already-signed regular proposal.
    function test_emergencyNonce_doesNotInvalidateRegularProposal() public {
        address newBridge = makeAddr("nonceCollisionBridge");
        uint256 regularNonce = proxy.proposalNonce();
        uint256 regularDeadline = vm.getBlockTimestamp() + 1 days;

        // Pre-sign a regular proposal at the current proposal-lane nonce.
        bytes32 regularDigest =
            MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, regularNonce, regularDeadline);
        (uint256[] memory regularPks, uint256 regularBitmap) = _fedSigSet2of3();
        bytes[] memory regularSigs = MultisigHelper.signAll(vm, regularDigest, regularPks);

        // An emergency pause runs on its own lane nonce.
        uint256 emergencyLaneNonce = proxy.emergencyNonce();
        uint256 emergencyDeadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 emergencyDigest = MultisigHelper.digestEmergencyPause(domainSep, emergencyLaneNonce, emergencyDeadline);
        (uint256[] memory emergencyPks, uint256 emergencyBitmap) = _fedSigSet2of3();
        bytes[] memory emergencySigs = MultisigHelper.signAll(vm, emergencyDigest, emergencyPks);

        proxy.emergencyPause(emergencyLaneNonce, emergencyDeadline, emergencyBitmap, emergencySigs);

        assertTrue(bridge.paused(), "bridge paused by emergency action");
        assertEq(proxy.emergencyNonce(), emergencyLaneNonce + 1, "emergency advanced only its own lane");
        assertEq(proxy.proposalNonce(), regularNonce, "proposal lane untouched by emergency");

        // The pre-signed regular proposal is still valid and submits successfully.
        bytes32 id = proxy.proposeUpdateBridge(newBridge, regularNonce, regularDeadline, regularBitmap, regularSigs);
        assertTrue(id != bytes32(0), "regular proposal created despite the emergency action");
        assertEq(proxy.proposalNonce(), regularNonce + 1, "regular proposal consumed its lane nonce");
    }

    function test_adminExecute_rejectsOwnershipTransferSelectorInAllLanes() public {
        bytes memory callData = abi.encodeWithSignature("transferOwnership(address)", user);
        _assertGenericPathsRejectSelector(callData, IMultisigProxy.ForbiddenOwnershipSelector.selector);
    }

    function test_transferManagedOwnership_initiatesBridgeOwnershipTransfer() public {
        address newOwner = makeAddr("newBridgeOwner");
        (bytes32 id, bytes memory opData) = _proposeManagedOwnership(address(bridge), newOwner);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(id, opData);

        assertEq(bridge.owner(), address(proxy), "two-step owner unchanged");
        assertEq(bridge.pendingOwner(), newOwner, "typed transfer started");
    }

    function test_transferManagedOwnership_initiatesRouteRegistryOwnershipTransfer() public {
        address newOwner = makeAddr("newRouteRegistryOwner");
        (bytes32 id, bytes memory opData) = _proposeManagedOwnership(address(routeRegistry), newOwner);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(id, opData);

        assertEq(routeRegistry.owner(), address(proxy), "RR owner unchanged (two-step)");
        assertEq(routeRegistry.pendingOwner(), newOwner, "typed RR transfer started");
    }

    // Commission withdrawals use dedicated typed operations; the manager
    // fixes their recipient at deployment.
    function test_adminExecute_rejectsCommissionWithdrawalSelectorsInAllLanes() public {
        bytes[] memory callDatas = new bytes[](4);
        callDatas[0] = abi.encodeWithSignature("withdrawTokenCommission(address,uint256)", address(token), uint256(1));
        callDatas[1] = abi.encodeWithSignature("withdrawNativeCommission(uint256)", uint256(1));
        callDatas[2] = abi.encodeWithSignature("withdrawAllTokenCommission(address)", address(token));
        callDatas[3] = abi.encodeWithSignature("withdrawAllNativeCommission()");

        for (uint256 i = 0; i < callDatas.length; i++) {
            _assertGenericPathsRejectSelector(callDatas[i], IMultisigProxy.ForbiddenCommissionManagerSelector.selector);
        }
    }

    // CommissionManager ownership migration remains available through the
    // typed lane, while its immutable recipient still pins all withdrawals.
    function test_transferManagedOwnership_commissionRecipientRemainsPinned() public {
        uint256 amount = 10 ether;
        token.mint(address(cm), amount);
        vm.prank(address(bridge));
        cm.receiveTokenCommission(address(token), amount);

        (bytes32 id, bytes memory opData) = _proposeManagedOwnership(address(cm), user);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(id, opData);

        vm.prank(user);
        cm.acceptOwnership();
        assertEq(cm.owner(), user, "typed CM ownership migration works");

        uint256 pinnedBefore = token.balanceOf(commissionReceiver);
        uint256 attackerBefore = token.balanceOf(user);
        vm.prank(user);
        cm.withdrawTokenCommission(address(token), amount);

        assertEq(token.balanceOf(commissionReceiver), pinnedBefore + amount, "immutable recipient paid");
        assertEq(token.balanceOf(user), attackerBefore, "new owner cannot redirect commission to itself");
        assertEq(proxy.commissionRecipient(), commissionReceiver, "proxy reports CM's immutable recipient");
    }

    function test_transferManagedOwnership_rejectsUnmanagedTarget() public {
        address unmanaged = makeAddr("unmanaged");
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.InvalidManagedOwnershipTarget.selector, unmanaged));
        proxy.proposeTransferManagedOwnership(unmanaged, user, 0, vm.getBlockTimestamp() + 1 days, 0, new bytes[](0));
    }

    function test_transferManagedOwnership_rejectsZeroNewOwner() public {
        vm.expectRevert(IMultisigProxy.ZeroNewOwner.selector);
        proxy.proposeTransferManagedOwnership(
            address(bridge), address(0), 0, vm.getBlockTimestamp() + 1 days, 0, new bytes[](0)
        );
    }

    function test_transferManagedOwnership_signatureBindsTargetAndNewOwner() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeTransferManagedOwnership(domainSep, address(bridge), user, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.proposeTransferManagedOwnership(address(cm), user, nonce, deadline, bitmap, sigs);

        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.proposeTransferManagedOwnership(
            address(bridge), makeAddr("differentOwner"), nonce, deadline, bitmap, sigs
        );
    }

    function test_transferManagedOwnership_rechecksTargetAtExecution() public {
        (bytes32 transferId, bytes memory transferData) =
            _proposeManagedOwnership(address(routeRegistry), makeAddr("newOwner"));

        RouteRegistry replacement = new RouteRegistry(address(bridge), address(proxy));
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateRouteRegistry(
            domainSep, proxy.bridge(), address(replacement), nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 updateId = proxy.proposeUpdateRouteRegistry(
            address(replacement), nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks)
        );

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(updateId, abi.encode(address(replacement)));

        vm.expectRevert(
            abi.encodeWithSelector(IMultisigProxy.InvalidManagedOwnershipTarget.selector, address(routeRegistry))
        );
        proxy.executeProposal(transferId, transferData);
    }

    // The generic path stays open for permitted CommissionManager setters.
    function test_adminExecuteCommissionManager_allowsConfigSelector() public {
        bytes memory callData = abi.encodeWithSignature(
            "setGlobalDefaults(uint256,uint256,uint8,uint8,uint8)",
            uint256(0),
            uint256(0),
            uint8(100),
            uint8(0),
            uint8(0)
        );
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeAdminExecuteCM(
            domainSep, proxy.commissionManager(), bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteCommissionManager(callData, nonce, deadline, bitmap, sigs);
        assertTrue(id != bytes32(0), "CM config selector accepted on the generic path");
    }

    /// @dev The proxy can complete pending ownership handoffs through signed generic proposals.
    function test_adminExecute_acceptsPendingOwnershipForManagedTargets() public {
        address[3] memory targets = [address(bridge), address(cm), address(routeRegistry)];
        for (uint256 i; i < targets.length; i++) {
            Ownable2Step target = Ownable2Step(targets[i]);
            (bytes32 transferId, bytes memory transferData) = _proposeManagedOwnership(targets[i], deployer);
            vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
            proxy.executeProposal(transferId, transferData);
            vm.startPrank(deployer);
            target.acceptOwnership();
            target.transferOwnership(address(proxy));
            vm.stopPrank();
            assertEq(target.owner(), deployer, "deployer owns target before acceptance");
            assertEq(target.pendingOwner(), address(proxy), "proxy is the pending owner");

            bytes memory callData = abi.encodeCall(Ownable2Step.acceptOwnership, ());
            bytes32 proposalId = _proposeAcceptOwnership(targets[i], callData);
            assertNotEq(proposalId, bytes32(0), "acceptOwnership proposal created");
            vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
            proxy.executeProposal(proposalId, callData);
            assertEq(target.owner(), address(proxy), "proposal completes ownership acceptance");
            assertEq(target.pendingOwner(), address(0), "pending ownership cleared");
            assertEq(
                uint256(proxy.getProposal(proposalId).status),
                uint256(IMultisigProxy.ProposalStatus.Executed),
                "acceptance proposal executed"
            );
        }
    }

    /// @dev The planned inflow-only pause runs through the timelocked
    ///      propose -> execute path and blocks deposits while leaving the
    ///      enclave release path open (liquidity migration scenario).
    function test_proposePauseInflow_blocksFundsInButAllowsFundsOut() public {
        uint256 t = vm.getBlockTimestamp(); // read once; derive all timing from it (via_ir-safe)

        // Propose the inflow-only pause (federation signed).
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = t + 1 days;
        bytes32 digest = MultisigHelper.digestProposePauseInflow(domainSep, proxy.bridge(), nonce, deadline);
        (uint256[] memory fpks, uint256 fbitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposePauseInflow(nonce, deadline, fbitmap, MultisigHelper.signAll(vm, digest, fpks));

        // Execute it after the timelock (no payload).
        vm.warp(t + TIMELOCK + 1);
        proxy.executeProposal(id, "");

        assertTrue(bridge.paused(), "inflow frozen");
        assertFalse(bridge.outflowPaused(), "outflow stays open");

        // Deposits are frozen...
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, abi.encode(RGB_OP_ID));

        // ...but the enclave release still executes.
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 encNonce = proxy.teeNonce(RGB_CHAIN_ID);
        bytes32 encDigest = MultisigHelper.digestTeeFundsOut(domainSep, params, encNonce, t + 1 days);
        (uint256[] memory epks, uint256 ebitmap) = _encSigSet2of3();
        bytes[] memory esigs = MultisigHelper.signAll(vm, encDigest, epks);

        proxy.fundsOutCall(params, encNonce, t + 1 days, ebitmap, esigs);
        assertEq(token.balanceOf(recipient), AMOUNT, "withdrawal succeeded while inflow paused");
    }

    function test_executeProposal_revertsOnZeroCommissionManagerWithoutChangingPointers() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        (uint256[] memory keys, uint256 bitmap) = _fedSigSet2of3();
        bytes32 digest = MultisigHelper.digestProposeUpdateCommissionManager(
            domainSep, address(bridge), address(0), nonce, deadline
        );
        bytes32 id = proxy.proposeUpdateCommissionManager(
            address(0), nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, keys)
        );
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.ZeroCommissionManager.selector);
        proxy.executeProposal(id, abi.encode(address(0)));
        assertEq(proxy.commissionManager(), address(cm), "proxy pointer is preserved");
        assertEq(address(bridge.commissionManager()), address(cm), "Bridge pointer is preserved");
        assertEq(
            uint256(proxy.getProposal(id).status),
            uint256(IMultisigProxy.ProposalStatus.Pending),
            "failed proposal remains pending"
        );
    }

    function test_genericProposal_revertsOnCalldataShorterThanSelectorInEveryLane() public {
        // Only a coded target is needed: short calldata fails before an adapter call.
        _setLzAdapter(address(token));
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes[] memory noSignatures = new bytes[](0);
        for (uint256 length; length < 4; ++length) {
            bytes memory data = new bytes(length);
            vm.expectRevert(IMultisigProxy.CallDataTooShort.selector);
            proxy.proposeAdminExecute(data, nonce, deadline, 0, noSignatures);
            vm.expectRevert(IMultisigProxy.CallDataTooShort.selector);
            proxy.proposeAdminExecuteCommissionManager(data, nonce, deadline, 0, noSignatures);
            vm.expectRevert(IMultisigProxy.CallDataTooShort.selector);
            proxy.proposeAdminExecuteRouteRegistry(data, nonce, deadline, 0, noSignatures);
            vm.expectRevert(IMultisigProxy.CallDataTooShort.selector);
            proxy.proposeAdminExecuteAdapter(data, nonce, deadline, 0, noSignatures);
            assertEq(proxy.proposalNonce(), nonce, "truncated calldata consumes no nonce");
        }
    }
}
