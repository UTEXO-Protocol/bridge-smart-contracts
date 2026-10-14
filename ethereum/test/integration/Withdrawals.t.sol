// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {BridgeBaseUpgradeable} from "../../src/BridgeBaseUpgradeable.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {RGBVerifier} from "../../src/verifiers/RGBVerifier.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {IntegrationTestBase} from "./IntegrationTestBase.sol";

/// @notice Signed releases enforce finality, replay, quorum and pause checks.
contract IntegrationWithdrawalsTest is IntegrationTestBase {
    function _signEnclave1(bytes32 digest) private pure returns (bytes[] memory sigs) {
        uint256[] memory pks = new uint256[](1);
        pks[0] = ENC_PK_1;
        sigs = MultisigHelper.signAll(vm, digest, pks);
    }

    /// @notice A withdraw releases against a recorded deposit: event emitted,
    ///         recipient paid, source liquidity debited, burnId consumed, record
    ///         permanent, and total tokens are conserved across all holders.
    function test_fundsOut_burnReleasesAgainstRecordedDeposit() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();
        uint256 inFee = USER_DEPOSIT - netIn;
        uint256 outFee = netIn * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT;
        uint256 netOut = netIn - outFee;

        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());

        ReleaseState memory beforeState = _releaseState(burnId);
        FundsOutAuthorization memory authorization = _prepareFundsOut(params);
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeFundsOut(
            recipient, netIn, netOut, outFee, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, "", params.settlementData
        );
        proxy.fundsOutCall(params, authorization.nonce, authorization.deadline, 3, authorization.signatures);

        _assertSuccessfulRelease(params, beforeState, outFee);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "full chain burst consumed");
        assertEq(bridge.availableGlobalOutflow(), 0, "full global burst consumed");
        assertEq(token.balanceOf(recipient), netOut, "recipient got net");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), netIn * 9, "source liquidity debited by one");
        assertTrue(bridge.consumedBurnIds(burnId), "burnId consumed");
        assertEq(rgbModule.fundsInRecords(opId), netIn, "mint record permanent");
        // Conservation: ten gross deposits are fully accounted for.
        assertEq(
            token.balanceOf(address(bridge)) + token.balanceOf(recipient) + token.balanceOf(address(cm)),
            USER_DEPOSIT * 10,
            "tokens conserved"
        );
        assertEq(token.balanceOf(address(cm)), inFee * 10 + outFee, "cm accrued both legs");
    }

    /// @notice The identical release intent cannot pay out twice: re-authorizing an already
    ///         consumed burnId reverts and leaves no additional trace.
    function test_fundsOut_burnSameBurnCannotReplay() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());
        _submitFundsOut(params);

        ReleaseState memory afterFirst = _releaseState(burnId);
        assertTrue(afterFirst.burnConsumed, "first release consumed intent");

        // Re-sign identical params with the advanced teeNonce; Bridge derives the
        // same burnId and rejects it as already consumed.
        FundsOutAuthorization memory replayAuthorization = _prepareFundsOut(params);
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, burnId));
        proxy.fundsOutCall(
            params, replayAuthorization.nonce, replayAuthorization.deadline, 3, replayAuthorization.signatures
        );

        _assertReleaseUnchanged(burnId, afterFirst);
    }

    /// @notice A withdraw below the enclave signature threshold is rejected with no trace.
    function test_fundsOut_burnBelowQuorumRejected() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        ReleaseState memory beforeState = _releaseState(burnId);

        vm.expectRevert(IMultisigProxy.BelowThreshold.selector);
        proxy.fundsOutCall(params, nonce, deadline, 1, _signEnclave1(digest)); // 1-of-3 < threshold 2

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice A withdraw larger than the bridge's token pool is rejected with no trace.
    function test_fundsOut_burnExceedsBridgePoolRejected() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();
        uint256 poolPlusOne = token.balanceOf(address(bridge)) + 1;

        (IBridge.FundsOutParams memory params, uint256 burnId) =
            _buildFundsOut(opId, netIn, poolPlusOne, "", _validProof());

        FundsOutAuthorization memory authorization = _prepareFundsOut(params);
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectRevert(BridgeBaseUpgradeable.AmountExceedBridgePool.selector);
        proxy.fundsOutCall(params, authorization.nonce, authorization.deadline, 3, authorization.signatures);

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice A withdraw without a valid BtcRelay proof (source block too shallow)
    ///         is rejected with no trace.
    function test_fundsOut_burnInvalidBtcProofRejected() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        // Use the fresh (1-confirmation) block as the source: below the 6 required.
        bytes memory shallowProof = abi.encode(LATEST_HEIGHT, LATEST_COMMIT, LATEST_HEIGHT, LATEST_COMMIT);
        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", shallowProof);

        FundsOutAuthorization memory authorization = _prepareFundsOut(params);
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectRevert(
            abi.encodeWithSelector(RGBVerifier.InsufficientSourceConfirmations.selector, uint256(1), uint256(6))
        );
        proxy.fundsOutCall(params, authorization.nonce, authorization.deadline, 3, authorization.signatures);

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice A withdraw referencing a deposit that never happened is rejected with no trace.
    function test_fundsOut_burnUnknownDepositRejected() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        bytes32 fakeOpId = keccak256("nonexistent-deposit");
        (IBridge.FundsOutParams memory params, uint256 burnId) =
            _buildFundsOut(fakeOpId, netIn, netIn, "", _validProof());

        FundsOutAuthorization memory authorization = _prepareFundsOut(params);
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectRevert(abi.encodeWithSelector(RgbSettlementModule.FundsInNotFound.selector, fakeOpId));
        proxy.fundsOutCall(params, authorization.nonce, authorization.deadline, 3, authorization.signatures);

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice A withdraw whose proof-of-mint amount differs from the recorded
    ///         deposit is rejected with no trace.
    function test_fundsOut_burnAmountMismatchRejected() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        (IBridge.FundsOutParams memory params, uint256 burnId) =
            _buildFundsOut(opId, netIn + 1, netIn, "", _validProof());

        FundsOutAuthorization memory authorization = _prepareFundsOut(params);
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectRevert(abi.encodeWithSelector(RgbSettlementModule.AmountMismatch.selector, opId, netIn + 1, netIn));
        proxy.fundsOutCall(params, authorization.nonce, authorization.deadline, 3, authorization.signatures);

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice Emergency pause freezes withdrawals; no trace on the rejected release.
    function test_fundsOut_burnEmergencyPauseStopsWithdrawals() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        vm.prank(address(proxy));
        bridge.emergencyPauseAll();

        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());

        FundsOutAuthorization memory authorization = _prepareFundsOut(params);
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectRevert(BridgeBaseUpgradeable.OutflowEnforcedPause.selector);
        proxy.fundsOutCall(params, authorization.nonce, authorization.deadline, 3, authorization.signatures);

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice Guardian pauses both paths; federation unpause allows the exact
    ///         same signed release to succeed without re-signing.
    function test_guardianPause_federationUnpauseRetriesSameSignedRelease() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();
        uint256 outFee = netIn * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT;
        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());
        FundsOutAuthorization memory authorization = _prepareFundsOut(params);
        ReleaseState memory beforeState = _releaseState(burnId);
        uint256 emergencyNonceBefore = proxy.emergencyNonce();
        uint256 proposalNonceBefore = proxy.proposalNonce();

        vm.prank(proxy.emergencyGuardian());
        proxy.guardianEmergencyPause();
        assertTrue(bridge.paused(), "guardian paused inflow");
        assertTrue(bridge.outflowPaused(), "guardian paused outflow");
        _assertReleaseUnchanged(burnId, beforeState);

        vm.expectRevert(BridgeBaseUpgradeable.OutflowEnforcedPause.selector);
        proxy.fundsOutCall(params, authorization.nonce, authorization.deadline, 3, authorization.signatures);
        _assertReleaseUnchanged(burnId, beforeState);

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(RGB_OP_ID + 100));
        _assertReleaseUnchanged(burnId, beforeState);

        uint256 unpauseNonce = proxy.emergencyNonce();
        uint256 unpauseDeadline = vm.getBlockTimestamp() + 1 hours;
        assertEq(unpauseNonce, emergencyNonceBefore + 1, "guardian consumes emergency nonce");
        bytes32 unpauseDigest = MultisigHelper.digestEmergencyUnpause(domainSep, unpauseNonce, unpauseDeadline);
        proxy.emergencyUnpause(unpauseNonce, unpauseDeadline, 3, _signFed2of3(unpauseDigest));
        assertFalse(bridge.paused(), "federation resumed inflow");
        assertFalse(bridge.outflowPaused(), "federation resumed outflow");
        assertEq(
            proxy.emergencyNonce(), emergencyNonceBefore + 2, "guardian and federation each consume an emergency nonce"
        );
        assertEq(proxy.proposalNonce(), proposalNonceBefore, "emergency operations do not consume proposal nonce");

        proxy.fundsOutCall(params, authorization.nonce, authorization.deadline, 3, authorization.signatures);
        _assertSuccessfulRelease(params, beforeState, outFee);
        assertEq(rgbModule.fundsInRecords(opId), netIn, "mint record remains permanent");
    }
}
