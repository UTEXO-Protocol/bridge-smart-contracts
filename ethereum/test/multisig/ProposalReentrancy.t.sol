// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {ProposalCallbackBridge} from "../mocks/ProposalCallbackBridge.sol";

/// @notice Nested proposal execution is rejected without preventing sequential execution.
contract MultisigProposalReentrancyTest is Test {
    ProposalCallbackBridge private target;

    MultisigProxy private proxy;

    address private constant INITIAL_MANAGER = address(0xCA);

    address private constant FIRST_MANAGER = address(0xCB);

    address private constant SECOND_MANAGER = address(0xCC);

    bytes32 private firstId;

    bytes32 private secondId;

    uint256 private constant TIMELOCK = 1 hours;

    function setUp() public {
        target = new ProposalCallbackBridge(INITIAL_MANAGER);
        address[] memory enclaves = new address[](2);
        enclaves[0] = vm.addr(11);
        enclaves[1] = vm.addr(12);
        address[] memory federation = new address[](2);
        federation[0] = vm.addr(21);
        federation[1] = vm.addr(22);
        proxy = new MultisigProxy(
            address(target), INITIAL_MANAGER, address(0x123), enclaves, 2, 1, federation, 2, TIMELOCK, TIMELOCK
        );
        firstId = _proposeRotation(FIRST_MANAGER);
        secondId = _proposeRotation(SECOND_MANAGER);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK);
    }

    function _proposeRotation(address manager) private returns (bytes32) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateCommissionManager(
            proxy.DOMAIN_SEPARATOR(), address(target), manager, nonce, deadline
        );
        uint256[] memory keys = new uint256[](2);
        keys[0] = 21;
        keys[1] = 22;
        return
            proxy.proposeUpdateCommissionManager(manager, nonce, deadline, 3, MultisigHelper.signAll(vm, digest, keys));
    }

    function _assertStatus(bytes32 id, IMultisigProxy.ProposalStatus status) private view {
        assertEq(uint256(proxy.getProposal(id).status), uint256(status));
    }

    function test_executeProposal_nestedMaturedProposalRejectedAndSequentialExecutionSucceeds() public {
        target.configure(proxy, secondId, abi.encode(SECOND_MANAGER), true, false);
        vm.recordLogs();
        proxy.executeProposal(firstId, abi.encode(FIRST_MANAGER));
        assertEq(target.callbackError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        _assertStatus(firstId, IMultisigProxy.ProposalStatus.Executed);
        _assertStatus(secondId, IMultisigProxy.ProposalStatus.Pending);
        assertEq(proxy.commissionManager(), FIRST_MANAGER);
        assertEq(target.commissionManager(), FIRST_MANAGER);
        assertEq(target.calls(), 1);

        // The lock ends with the call, not with the transaction.
        proxy.executeProposal(secondId, abi.encode(SECOND_MANAGER));
        _assertStatus(secondId, IMultisigProxy.ProposalStatus.Executed);
        assertEq(proxy.commissionManager(), SECOND_MANAGER);
        assertEq(target.commissionManager(), SECOND_MANAGER);
        assertEq(target.calls(), 2);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 executedTopic = keccak256("ProposalExecuted(bytes32,uint8)");
        uint256 executions;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(proxy) && logs[i].topics[0] == executedTopic) {
                assertEq(logs[i].topics[1], executions == 0 ? firstId : secondId);
                executions++;
            }
        }
        assertEq(executions, 2);
    }

    function test_executeProposal_bubbledNestedFailureRollsBackAndLockCanBeRetried() public {
        target.configure(proxy, secondId, abi.encode(SECOND_MANAGER), true, true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        proxy.executeProposal(firstId, abi.encode(FIRST_MANAGER));
        _assertStatus(firstId, IMultisigProxy.ProposalStatus.Pending);
        _assertStatus(secondId, IMultisigProxy.ProposalStatus.Pending);
        assertEq(proxy.commissionManager(), INITIAL_MANAGER);
        assertEq(target.commissionManager(), INITIAL_MANAGER);
        assertEq(target.calls(), 0);

        target.configure(proxy, secondId, abi.encode(SECOND_MANAGER), false, false);
        proxy.executeProposal(firstId, abi.encode(FIRST_MANAGER));
        proxy.executeProposal(secondId, abi.encode(SECOND_MANAGER));
        _assertStatus(firstId, IMultisigProxy.ProposalStatus.Executed);
        _assertStatus(secondId, IMultisigProxy.ProposalStatus.Executed);
        assertEq(proxy.commissionManager(), SECOND_MANAGER);
        assertEq(target.commissionManager(), SECOND_MANAGER);
    }

    function test_executeProposal_sameProposalCallbackRejected() public {
        target.configure(proxy, firstId, abi.encode(FIRST_MANAGER), true, false);
        proxy.executeProposal(firstId, abi.encode(FIRST_MANAGER));
        assertEq(target.callbackError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        _assertStatus(firstId, IMultisigProxy.ProposalStatus.Executed);
        assertEq(target.calls(), 1);
    }
}
