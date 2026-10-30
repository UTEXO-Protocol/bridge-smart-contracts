// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {CommissionManager} from "../../src/CommissionManager.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager
} from "../../src/interfaces/ICommissionManager.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {IntegrationTestBase} from "./IntegrationTestBase.sol";

/// @notice Governance revalidates mutable bindings and amount floors at execution.
contract IntegrationGovernanceTest is IntegrationTestBase {
    function _proposeCommissionManagerRotation(address candidate) private returns (bytes32 proposalId) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 7 days;
        bytes32 digest =
            MultisigHelper.digestProposeUpdateCommissionManager(domainSep, proxy.bridge(), candidate, nonce, deadline);
        proposalId = proxy.proposeUpdateCommissionManager(candidate, nonce, deadline, 3, _signFed2of3(digest));
    }

    function test_commissionManagerRotation_rechecksBindingAtExecution() public {
        CommissionManager candidate = new CommissionManager(address(bridge), commissionReceiver);
        bytes32 proposalId = _proposeCommissionManagerRotation(address(candidate));
        uint256 nonceAfterProposal = proxy.proposalNonce();
        candidate.setBridgeAddress(makeAddr("other-bridge"));
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectRevert(IBridge.InvalidCommissionManagerAddress.selector);
        proxy.executeProposal(proposalId, abi.encode(address(candidate)));

        assertEq(address(bridge.commissionManager()), address(cm));
        assertEq(proxy.commissionManager(), address(cm));
        assertEq(proxy.proposalNonce(), nonceAfterProposal);
        assertEq(uint256(proxy.getProposal(proposalId).status), uint256(IMultisigProxy.ProposalStatus.Pending));

        candidate.setBridgeAddress(address(bridge));
        proxy.executeProposal(proposalId, abi.encode(address(candidate)));
        assertEq(address(bridge.commissionManager()), address(candidate));
        assertEq(proxy.commissionManager(), address(candidate));
    }

    function test_rotatedCommissionManager_inflatedQuoteRejectsSignedReleaseAndAllowsRetry() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 amount = _netIn();
        CommissionManager replacement = new CommissionManager(address(bridge), commissionReceiver);
        replacement.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: FUNDS_OUT_PERCENT,
                baseFee: 0,
                multiplier: FUNDS_OUT_MULT,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );
        bytes32 proposalId = _proposeCommissionManagerRotation(address(replacement));
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(proposalId, abi.encode(address(replacement)));
        assertEq(address(bridge.commissionManager()), address(replacement));
        assertEq(proxy.commissionManager(), address(replacement));

        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, amount, "", _validProof());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes[] memory sigs = _signEnclave2of3(MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline));
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.mockCall(
            address(replacement),
            abi.encodeCall(
                ICommissionManager.calculateFundsOutCommission, (RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), amount)
            ),
            abi.encode(uint256(0), uint256(0), amount * 2)
        );
        vm.expectRevert(IBridge.CommissionConservationBroken.selector);
        proxy.fundsOutCall(params, nonce, deadline, 3, sigs);
        _assertReleaseUnchanged(burnId, beforeState);
        assertEq(token.balanceOf(address(replacement)), 0);
        assertEq(replacement.tokenCommissionPool(address(token)), 0);

        // Restore the configured quote and retry the same enclave authorization.
        vm.clearMockedCalls();
        proxy.fundsOutCall(params, nonce, deadline, 3, sigs);
        uint256 fee = amount * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT;
        assertEq(token.balanceOf(recipient), beforeState.recipientBalance + amount - fee);
        assertEq(token.balanceOf(address(replacement)), fee);
        assertEq(replacement.tokenCommissionPool(address(token)), fee);
        assertEq(token.balanceOf(address(cm)), beforeState.cmBalance);
        assertEq(cm.tokenCommissionPool(address(token)), beforeState.tokenPool);
        assertEq(token.balanceOf(address(bridge)), beforeState.bridgeBalance - amount);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), beforeState.chainLiquidity - amount);
        assertEq(bridge.totalLockedLiquidity(), beforeState.totalLiquidity - amount);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1);
        assertTrue(bridge.consumedBurnIds(burnId));
    }

    function test_amountFloors_pendingOutflowRaiseRechecksCurrentInflowMinimum() public {
        _proposeAndExecuteBridgeAdminCall(abi.encodeCall(IBridge.setMinFundsInAmount, (100)));
        bytes memory pendingCall = abi.encodeCall(IBridge.setMinFundsOutAmount, (80));
        bytes32 pendingId = _proposeBridgeAdminCall(pendingCall);
        _proposeAndExecuteBridgeAdminCall(abi.encodeCall(IBridge.setMinFundsInAmount, (50)));
        uint256 nonceBeforeExecution = proxy.proposalNonce();

        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidAmountFloors.selector, uint256(50), uint256(80)));
        proxy.executeProposal(pendingId, pendingCall);
        assertEq(bridge.minFundsInAmount(), 50);
        assertEq(bridge.minFundsOutAmount(), 1);
        assertEq(proxy.proposalNonce(), nonceBeforeExecution);
        assertEq(uint256(proxy.getProposal(pendingId).status), uint256(IMultisigProxy.ProposalStatus.Pending));

        _proposeAndExecuteBridgeAdminCall(abi.encodeCall(IBridge.setMinFundsInAmount, (100)));
        proxy.executeProposal(pendingId, pendingCall);
        assertEq(bridge.minFundsInAmount(), 100);
        assertEq(bridge.minFundsOutAmount(), 80);
    }

    function test_amountFloors_pendingInflowLowerRechecksCurrentOutflowMinimum() public {
        _proposeAndExecuteBridgeAdminCall(abi.encodeCall(IBridge.setMinFundsInAmount, (100)));
        bytes memory pendingCall = abi.encodeCall(IBridge.setMinFundsInAmount, (50));
        bytes32 pendingId = _proposeBridgeAdminCall(pendingCall);
        _proposeAndExecuteBridgeAdminCall(abi.encodeCall(IBridge.setMinFundsOutAmount, (80)));
        uint256 nonceBeforeExecution = proxy.proposalNonce();

        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidAmountFloors.selector, uint256(50), uint256(80)));
        proxy.executeProposal(pendingId, pendingCall);
        assertEq(bridge.minFundsInAmount(), 100);
        assertEq(bridge.minFundsOutAmount(), 80);
        assertEq(proxy.proposalNonce(), nonceBeforeExecution);
        assertEq(uint256(proxy.getProposal(pendingId).status), uint256(IMultisigProxy.ProposalStatus.Pending));

        _proposeAndExecuteBridgeAdminCall(abi.encodeCall(IBridge.setMinFundsOutAmount, (40)));
        proxy.executeProposal(pendingId, pendingCall);
        assertEq(bridge.minFundsInAmount(), 50);
        assertEq(bridge.minFundsOutAmount(), 40);
    }

    function test_guardian_unauthorizedCallsCannotChangePauseState() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnauthorizedEmergencyGuardian.selector, user));
        proxy.guardianEmergencyPause();
        assertFalse(bridge.paused(), "unauthorized caller cannot pause inflow");
        assertFalse(bridge.outflowPaused(), "unauthorized caller cannot pause outflow");

        vm.prank(proxy.emergencyGuardian());
        proxy.guardianEmergencyPause();
        vm.prank(proxy.emergencyGuardian());
        (bool success, bytes memory errorData) =
            address(proxy).call(abi.encodeWithSignature("guardianEmergencyUnpause()"));
        assertFalse(success, "guardian cannot resume its own freeze");
        assertEq(errorData, bytes(""), "unsupported unpause selector has no revert data");
        assertTrue(bridge.paused(), "unauthorized caller cannot resume inflow");
        assertTrue(bridge.outflowPaused(), "unauthorized caller cannot resume outflow");
    }
}
