// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {BridgeBaseUpgradeable} from "../../src/BridgeBaseUpgradeable.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {EmergencyPauseHarness} from "../helpers/EmergencyPauseHarness.sol";
import {EmergencyUnpauseHarness} from "../helpers/EmergencyUnpauseHarness.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice Federation and guardian emergency operations enforce separate authorization.
contract MultisigEmergencyTest is MultisigProxyTestBase {
    function _emergencySignatures(bool unpause, uint256 nonce, uint256 deadline)
        private
        view
        returns (uint256 bitmap, bytes[] memory signatures)
    {
        bytes32 digest = unpause
            ? MultisigHelper.digestEmergencyUnpause(domainSep, nonce, deadline)
            : MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory keys, uint256 bits) = _fedSigSet2of3();
        return (bits, MultisigHelper.signAll(vm, digest, keys));
    }

    function _submitEmergency(bool unpause, uint256 nonce, uint256 deadline, uint256 bitmap, bytes[] memory signatures)
        private
    {
        if (unpause) proxy.emergencyUnpause(nonce, deadline, bitmap, signatures);
        else proxy.emergencyPause(nonce, deadline, bitmap, signatures);
    }

    function test_emergencyPause_pausesBothFlowsAndAdvancesEmergencyNonce() public {
        uint256 nonce = proxy.emergencyNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(false, false, false, true, address(proxy));
        emit IMultisigProxy.EmergencyPaused(nonce, bitmap);

        proxy.emergencyPause(nonce, deadline, bitmap, sigs);

        assertTrue(bridge.paused(), "inflow paused");
        assertTrue(bridge.outflowPaused(), "outflow paused");
        assertEq(proxy.emergencyNonce(), nonce + 1, "emergency lane advanced");
        assertEq(proxy.proposalNonce(), 0, "proposal lane untouched by emergency");
    }

    function test_emergencyPause_revertsOnExpired() public {
        uint256 nonce = proxy.emergencyNonce();
        uint256 deadline = vm.getBlockTimestamp() - 1;

        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.emergencyPause(nonce, deadline, bitmap, sigs);
    }

    function test_emergencyPause_revertsOnWrongNonce() public {
        uint256 nonce = 99;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.emergencyPause(nonce, deadline, bitmap, sigs);
    }

    function test_emergencyUnpause_resumesBothFlowsAndAdvancesEmergencyNonce() public {
        test_emergencyPause_pausesBothFlowsAndAdvancesEmergencyNonce();

        uint256 nonce = proxy.emergencyNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestEmergencyUnpause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(false, false, false, true, address(proxy));
        emit IMultisigProxy.EmergencyUnpaused(nonce, bitmap);

        proxy.emergencyUnpause(nonce, deadline, bitmap, sigs);
        assertFalse(bridge.paused(), "inflow resumed");
        assertFalse(bridge.outflowPaused(), "outflow resumed");
        assertEq(proxy.emergencyNonce(), nonce + 1, "emergency lane advanced");
        assertEq(proxy.proposalNonce(), 0, "proposal lane untouched");
    }

    function test_guardianPause_invalidatesPreviouslySignedPauseAndUnpause() public {
        uint256 nonce = proxy.emergencyNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint256 bitmap, bytes[] memory pauseSignatures) = _emergencySignatures(false, nonce, deadline);
        (, bytes[] memory unpauseSignatures) = _emergencySignatures(true, nonce, deadline);
        uint256 proposalNonceBefore = proxy.proposalNonce();
        uint256 teeNonceBefore = proxy.teeNonce(RGB_CHAIN_ID);
        vm.prank(emergencyGuardian);
        proxy.guardianEmergencyPause();

        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.emergencyPause(nonce, deadline, bitmap, pauseSignatures);
        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.emergencyUnpause(nonce, deadline, bitmap, unpauseSignatures);
        assertTrue(bridge.paused());
        assertTrue(bridge.outflowPaused());
        assertEq(proxy.emergencyNonce(), nonce + 1);
        assertEq(proxy.proposalNonce(), proposalNonceBefore);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), teeNonceBefore);

        (, bytes[] memory freshSignatures) = _emergencySignatures(true, nonce + 1, deadline);
        proxy.emergencyUnpause(nonce + 1, deadline, bitmap, freshSignatures);
        assertFalse(bridge.paused());
        assertFalse(bridge.outflowPaused());
        assertEq(proxy.emergencyNonce(), nonce + 2);
    }

    function test_guardianPause_repeatedPauseInvalidatesNewlyCollectedUnpause() public {
        vm.prank(emergencyGuardian);
        proxy.guardianEmergencyPause();
        uint256 nonce = proxy.emergencyNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint256 bitmap, bytes[] memory signatures) = _emergencySignatures(true, nonce, deadline);
        vm.prank(emergencyGuardian);
        proxy.guardianEmergencyPause();
        assertEq(proxy.emergencyNonce(), nonce + 1);
        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.emergencyUnpause(nonce, deadline, bitmap, signatures);
        assertTrue(bridge.paused());
        assertTrue(bridge.outflowPaused());
    }

    function test_guardianEmergencyPause_rejectedCallPreservesEmergencyNonce() public {
        uint256 nonce = proxy.emergencyNonce();
        vm.mockCallRevert(
            address(bridge),
            abi.encodeWithSignature("emergencyPauseAll()"),
            abi.encodeWithSignature("Error(string)", "bridge failure")
        );
        vm.prank(emergencyGuardian);
        vm.expectRevert(bytes("bridge failure"));
        proxy.guardianEmergencyPause();
        assertEq(proxy.emergencyNonce(), nonce);
        assertFalse(bridge.paused());
        assertFalse(bridge.outflowPaused());
    }

    function test_emergencyTiming_rejectsDistantDeadlinesForBothActions() public {
        uint256 nonce = proxy.emergencyNonce();
        uint256 proposalNonceBefore = proxy.proposalNonce();
        uint256[2] memory deadlines =
            [vm.getBlockTimestamp() + proxy.MAX_EMERGENCY_DEADLINE() + 1, vm.getBlockTimestamp() + 10 * 365 days];
        for (uint256 action; action < 2; ++action) {
            for (uint256 i; i < deadlines.length; ++i) {
                (uint256 bitmap, bytes[] memory signatures) = _emergencySignatures(action == 1, nonce, deadlines[i]);
                vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
                _submitEmergency(action == 1, nonce, deadlines[i], bitmap, signatures);
                assertEq(proxy.emergencyNonce(), nonce);
                assertEq(proxy.proposalNonce(), proposalNonceBefore);
                assertFalse(bridge.paused());
                assertFalse(bridge.outflowPaused());
            }
        }
    }

    function test_emergencyTiming_acceptsExactDeadlineBoundaries() public {
        uint256[2] memory deadlines = [vm.getBlockTimestamp(), vm.getBlockTimestamp() + proxy.MAX_EMERGENCY_DEADLINE()];
        for (uint256 i; i < deadlines.length; ++i) {
            uint256 nonce = proxy.emergencyNonce();
            (uint256 bitmap, bytes[] memory signatures) = _emergencySignatures(false, nonce, deadlines[i]);
            proxy.emergencyPause(nonce, deadlines[i], bitmap, signatures);
            assertTrue(bridge.paused());
            assertTrue(bridge.outflowPaused());
            (, signatures) = _emergencySignatures(true, nonce + 1, deadlines[i]);
            proxy.emergencyUnpause(nonce + 1, deadlines[i], bitmap, signatures);
            assertFalse(bridge.paused());
            assertFalse(bridge.outflowPaused());
            assertEq(proxy.emergencyNonce(), nonce + 2);
        }
    }

    function test_emergencyTiming_rejectsExpiredUnpauseWithoutConsumingNonce() public {
        vm.prank(emergencyGuardian);
        proxy.guardianEmergencyPause();
        uint256 nonce = proxy.emergencyNonce();
        uint256 deadline = vm.getBlockTimestamp() - 1;
        (uint256 bitmap, bytes[] memory signatures) = _emergencySignatures(true, nonce, deadline);
        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.emergencyUnpause(nonce, deadline, bitmap, signatures);
        assertEq(proxy.emergencyNonce(), nonce);
        assertTrue(bridge.paused());
        assertTrue(bridge.outflowPaused());
    }

    function test_guardianEmergencyPause_advancesOnlyEmergencyNonce() public {
        uint256 emergencyNonceBefore = proxy.emergencyNonce();
        uint256 proposalNonceBefore = proxy.proposalNonce();

        vm.expectEmit(true, false, false, true, address(proxy));
        emit IMultisigProxy.GuardianEmergencyPaused(emergencyGuardian);
        vm.prank(emergencyGuardian);
        proxy.guardianEmergencyPause();

        assertTrue(bridge.paused(), "inflow frozen");
        assertTrue(bridge.outflowPaused(), "outflow frozen");
        assertEq(proxy.emergencyNonce(), emergencyNonceBefore + 1, "guardian invalidates emergency signatures");
        assertEq(proxy.proposalNonce(), proposalNonceBefore, "proposal lane unchanged");
    }

    function test_guardianEmergencyPause_revertsForUnauthorizedCaller() public {
        uint256 nonce = proxy.emergencyNonce();
        uint256 proposalNonceBefore = proxy.proposalNonce();
        address attacker = makeAddr("guardian-attacker");
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnauthorizedEmergencyGuardian.selector, attacker));
        vm.prank(attacker);
        proxy.guardianEmergencyPause();
        assertEq(proxy.emergencyNonce(), nonce);
        assertEq(proxy.proposalNonce(), proposalNonceBefore);
    }

    function test_guardian_cannotLiftFederationFreeze() public {
        test_emergencyPause_pausesBothFlowsAndAdvancesEmergencyNonce();
        uint256 nonce = proxy.emergencyNonce();
        uint256 proposalNonceBefore = proxy.proposalNonce();

        vm.prank(emergencyGuardian);
        (bool success,) = address(proxy).call(abi.encodeWithSignature("guardianEmergencyUnpause()"));
        assertFalse(success, "removed guardian selector must revert");
        assertTrue(bridge.paused());
        assertTrue(bridge.outflowPaused());

        vm.prank(emergencyGuardian);
        vm.expectRevert(IMultisigProxy.BelowThreshold.selector);
        proxy.emergencyUnpause(nonce, vm.getBlockTimestamp() + 1 hours, 0, new bytes[](0));
        assertTrue(bridge.paused());
        assertTrue(bridge.outflowPaused());
        assertEq(proxy.emergencyNonce(), nonce);
        assertEq(proxy.proposalNonce(), proposalNonceBefore);

        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestEmergencyUnpause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        proxy.emergencyUnpause(nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks));
        assertFalse(bridge.paused());
        assertFalse(bridge.outflowPaused());
        assertEq(proxy.emergencyNonce(), nonce + 1);
        assertEq(proxy.proposalNonce(), proposalNonceBefore);
    }

    function test_proposeSetEmergencyGuardian_rotatesAfterTimelock() public {
        address newGuardian = makeAddr("new-emergency-guardian");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeSetEmergencyGuardian(domainSep, newGuardian, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();

        bytes32 id = proxy.proposeSetEmergencyGuardian(
            newGuardian, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks)
        );

        assertEq(proxy.emergencyGuardian(), emergencyGuardian, "guardian unchanged during timelock");
        vm.expectRevert(IMultisigProxy.TimelockActive.selector);
        proxy.executeProposal(id, abi.encode(newGuardian));

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.EmergencyGuardianUpdated(emergencyGuardian, newGuardian);
        proxy.executeProposal(id, abi.encode(newGuardian));

        assertEq(proxy.emergencyGuardian(), newGuardian);

        vm.expectRevert(
            abi.encodeWithSelector(IMultisigProxy.UnauthorizedEmergencyGuardian.selector, emergencyGuardian)
        );
        vm.prank(emergencyGuardian);
        proxy.guardianEmergencyPause();

        vm.prank(newGuardian);
        proxy.guardianEmergencyPause();
        assertTrue(bridge.paused());
        assertTrue(bridge.outflowPaused());
    }

    function test_proposeSetEmergencyGuardian_allowsZeroToDisable() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeSetEmergencyGuardian(domainSep, address(0), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposeSetEmergencyGuardian(
            address(0), nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks)
        );

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(address(0)));
        assertEq(proxy.emergencyGuardian(), address(0), "guardian disabled");

        vm.expectRevert(
            abi.encodeWithSelector(IMultisigProxy.UnauthorizedEmergencyGuardian.selector, emergencyGuardian)
        );
        vm.prank(emergencyGuardian);
        proxy.guardianEmergencyPause();
    }

    function test_proposeSetEmergencyGuardian_signatureBindsNewGuardian() public {
        address signedGuardian = makeAddr("signed-guardian");
        address submittedGuardian = makeAddr("submitted-guardian");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeSetEmergencyGuardian(domainSep, signedGuardian, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();

        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.proposeSetEmergencyGuardian(
            submittedGuardian, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks)
        );
    }

    /// @notice After nonce lanes diverge, production pause preparation selects
    ///         emergencyNonce and produces its canonical digest.
    function test_emergencyPauseScript_usesEmergencyNonceAfterLanesDiverge() public {
        uint256 regularNonce = proxy.proposalNonce();
        uint256 regularDeadline = vm.getBlockTimestamp() + 1 days;
        address newBridge = makeAddr("emergency-pause-regular-proposal");
        bytes32 regularDigest =
            MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, regularNonce, regularDeadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        proxy.proposeUpdateBridge(
            newBridge, regularNonce, regularDeadline, bitmap, MultisigHelper.signAll(vm, regularDigest, pks)
        );

        assertEq(proxy.proposalNonce(), 1, "regular lane advanced");
        assertEq(proxy.emergencyNonce(), 0, "emergency lane untouched");

        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        // A signed emergency digest using proposalNonce selects the wrong
        // nonce lane and must be rejected.
        uint256 wrongNonce = proxy.proposalNonce();
        bytes32 wrongDigest = MultisigHelper.digestEmergencyPause(domainSep, wrongNonce, deadline);
        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.emergencyPause(wrongNonce, deadline, bitmap, MultisigHelper.signAll(vm, wrongDigest, pks));

        // Exercise the exact preparation function called by EmergencyPause.run().
        EmergencyPauseHarness harness = new EmergencyPauseHarness();
        (uint256 scriptNonce, bytes32 scriptDigest) = harness.prepare(proxy, deadline);
        bytes32 expectedStructHash =
            keccak256(abi.encode(keccak256("EmergencyPause(uint256 nonce,uint256 deadline)"), uint256(0), deadline));
        bytes32 expectedDigest = keccak256(abi.encodePacked("\x19\x01", domainSep, expectedStructHash));

        assertEq(scriptNonce, 0, "script reads emergency lane");
        assertEq(scriptDigest, expectedDigest, "script produces canonical pause digest");

        proxy.emergencyPause(scriptNonce, deadline, bitmap, MultisigHelper.signAll(vm, scriptDigest, pks));

        assertTrue(bridge.paused(), "emergency pause succeeds");
        assertEq(proxy.emergencyNonce(), 1, "emergency lane advanced");
        assertEq(proxy.proposalNonce(), 1, "regular lane unchanged");
    }

    /// @dev Known-answer regression for the production unpause script.
    ///      Both lanes are deliberately non-equal before digest construction.
    function test_emergencyUnpauseScript_usesEmergencyNonceAfterLanesDiverge() public {
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();

        uint256 pauseNonce = proxy.emergencyNonce();
        uint256 pauseDeadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 pauseDigest = MultisigHelper.digestEmergencyPause(domainSep, pauseNonce, pauseDeadline);
        proxy.emergencyPause(pauseNonce, pauseDeadline, bitmap, MultisigHelper.signAll(vm, pauseDigest, pks));
        assertTrue(bridge.paused(), "precondition: bridge paused");

        // Advance the regular lane twice so proposalNonce=2, emergencyNonce=1.
        for (uint256 i = 0; i < 2; i++) {
            uint256 regularNonce = proxy.proposalNonce();
            uint256 regularDeadline = vm.getBlockTimestamp() + 1 days;
            address newBridge = makeAddr(string.concat("emergency-unpause-regular-proposal-", vm.toString(i)));
            bytes32 regularDigest =
                MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, regularNonce, regularDeadline);
            proxy.proposeUpdateBridge(
                newBridge, regularNonce, regularDeadline, bitmap, MultisigHelper.signAll(vm, regularDigest, pks)
            );
        }

        assertEq(proxy.proposalNonce(), 2, "regular lane advanced independently");
        assertEq(proxy.emergencyNonce(), 1, "pause advanced emergency lane once");

        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        EmergencyUnpauseHarness harness = new EmergencyUnpauseHarness();
        (uint256 scriptNonce, bytes32 scriptDigest) = harness.prepare(proxy, deadline);
        bytes32 expectedStructHash =
            keccak256(abi.encode(keccak256("EmergencyUnpause(uint256 nonce,uint256 deadline)"), uint256(1), deadline));
        bytes32 expectedDigest = keccak256(abi.encodePacked("\x19\x01", domainSep, expectedStructHash));

        assertEq(scriptNonce, 1, "script reads emergency lane");
        assertEq(scriptDigest, expectedDigest, "script produces canonical unpause digest");

        proxy.emergencyUnpause(scriptNonce, deadline, bitmap, MultisigHelper.signAll(vm, scriptDigest, pks));

        assertFalse(bridge.paused(), "emergency unpause succeeds");
        assertEq(proxy.emergencyNonce(), 2, "emergency lane advanced");
        assertEq(proxy.proposalNonce(), 2, "regular lane unchanged");
    }

    /// @dev The no-timelock emergency pause freezes the OUTFLOW path too —
    ///      including the enclave/TEE release, which routes through
    ///      Bridge.fundsOut. A signed fundsOut executed straight after
    ///      emergencyPause must revert OutflowEnforcedPause, and inbound deposits
    ///      must be frozen as well.
    function test_emergencyPause_freezesEnclaveFundsOut() public {
        // Federation triggers the emergency freeze (both paths).
        uint256 nonce = proxy.emergencyNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory fpks, uint256 fbitmap) = _fedSigSet2of3();
        proxy.emergencyPause(nonce, deadline, fbitmap, MultisigHelper.signAll(vm, digest, fpks));

        assertTrue(bridge.paused(), "inflow frozen");
        assertTrue(bridge.outflowPaused(), "outflow frozen");

        // Inbound deposits are frozen.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, abi.encode(RGB_OP_ID));

        // Enclave-signed release is frozen too — the revert propagates from
        // Bridge.fundsOut through proxy.fundsOutCall.
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 encNonce = proxy.teeNonce(RGB_CHAIN_ID);
        bytes32 encDigest = MultisigHelper.digestTeeFundsOut(domainSep, params, encNonce, deadline);
        (uint256[] memory epks, uint256 ebitmap) = _encSigSet2of3();
        bytes[] memory esigs = MultisigHelper.signAll(vm, encDigest, epks);

        vm.expectRevert(BridgeBaseUpgradeable.OutflowEnforcedPause.selector);
        proxy.fundsOutCall(params, encNonce, deadline, ebitmap, esigs);
    }
}
