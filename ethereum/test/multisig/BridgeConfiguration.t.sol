// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice Bridge address proposals bind their target and emit configuration changes.
contract MultisigBridgeConfigurationTest is MultisigProxyTestBase {
    function test_proposeUpdateBridge_rotatesBridgeAfterTimelock() public {
        address newBridge = makeAddr("newBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 proposalId = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        vm.expectRevert(IMultisigProxy.TimelockActive.selector);
        proxy.executeProposal(proposalId, abi.encode(newBridge));

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.BridgeAddressUpdated(address(bridge), newBridge);

        proxy.executeProposal(proposalId, abi.encode(newBridge));
        assertEq(proxy.bridge(), newBridge);
    }

    function test_proposeUpdateBridge_revertsOnExpired() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() - 1;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr("nb"), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.proposeUpdateBridge(makeAddr("nb"), nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateBridge_revertsOnDeadlineTooFar() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + proxy.MAX_PROPOSAL_LIFETIME() + 1;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr("nb"), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
        proxy.proposeUpdateBridge(makeAddr("nb"), nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateBridge_revertsOnDeadlineBeforeTimelock() public {
        uint256 nonce = proxy.proposalNonce();
        // One second short of the timelock window → dead on arrival.
        uint256 deadline = vm.getBlockTimestamp() + proxy.timelockDuration() - 1;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr("nb"), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DeadlineBeforeTimelock.selector);
        proxy.proposeUpdateBridge(makeAddr("nb"), nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateBridge_acceptsDeadlineAtTimelockBoundary() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + proxy.timelockDuration(); // exact boundary, `==` allowed

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr("nb"), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 proposalId = proxy.proposeUpdateBridge(makeAddr("nb"), nonce, deadline, bitmap, sigs);
        assertEq(
            uint8(proxy.getProposal(proposalId).status),
            uint8(IMultisigProxy.ProposalStatus.Pending),
            "proposal at the exact boundary is created"
        );
    }

    function test_proposeUpdateBridge_executableAtTimelockBoundary() public {
        address newBridge = makeAddr("boundaryBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 timelock = proxy.timelockDuration();
        uint256 deadline = vm.getBlockTimestamp() + timelock; // deadline == proposedAt + timelock

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 proposalId = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        // Execute at the single instant where block.timestamp == proposedAt +
        // timelock == deadline: timelock has just elapsed and the deadline has
        // not yet passed (both checks use strict comparisons).
        vm.warp(vm.getBlockTimestamp() + timelock);
        proxy.executeProposal(proposalId, abi.encode(newBridge));
        assertEq(proxy.bridge(), newBridge, "boundary proposal executes at the exact instant");
    }

    function test_proposeUpdateBridge_acceptsDeadlineAtMaxLifetime() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + proxy.MAX_PROPOSAL_LIFETIME();
        address nextBridge = makeAddr("maximum-deadline-bridge");
        (uint256[] memory keys, uint256 bitmap) = _fedSigSet2of3();
        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, nextBridge, nonce, deadline);
        bytes32 id =
            proxy.proposeUpdateBridge(nextBridge, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, keys));
        IMultisigProxy.Proposal memory proposal = proxy.getProposal(id);
        assertEq(proposal.deadline, deadline, "maximum deadline is stored exactly");
        assertEq(
            uint256(proposal.status), uint256(IMultisigProxy.ProposalStatus.Pending), "boundary proposal is pending"
        );
        assertEq(proxy.proposalNonce(), nonce + 1, "accepted boundary consumes nonce");
    }

    function test_executeProposal_revertsOnZeroBridgeWithoutChangingTarget() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        (uint256[] memory keys, uint256 bitmap) = _fedSigSet2of3();
        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, address(0), nonce, deadline);
        bytes32 id =
            proxy.proposeUpdateBridge(address(0), nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, keys));
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.ZeroBridge.selector);
        proxy.executeProposal(id, abi.encode(address(0)));
        assertEq(proxy.bridge(), address(bridge), "failed execution preserves Bridge target");
        assertEq(
            uint256(proxy.getProposal(id).status),
            uint256(IMultisigProxy.ProposalStatus.Pending),
            "failed proposal remains pending"
        );
    }

    function test_proposeUpdateBridge_revertsOnConsumedNonceForDifferentTarget() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        (uint256[] memory keys, uint256 bitmap) = _fedSigSet2of3();
        address firstTarget = makeAddr("nonce-first-target");
        bytes32 firstId = proxy.proposeUpdateBridge(
            firstTarget,
            0,
            deadline,
            bitmap,
            MultisigHelper.signAll(
                vm, MultisigHelper.digestProposeUpdateBridge(domainSep, firstTarget, 0, deadline), keys
            )
        );
        address nextTarget = makeAddr("nonce-next-target");
        bytes[] memory signatures = MultisigHelper.signAll(
            vm, MultisigHelper.digestProposeUpdateBridge(domainSep, nextTarget, 0, deadline), keys
        );
        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.proposeUpdateBridge(nextTarget, 0, deadline, bitmap, signatures);
        assertEq(proxy.proposalNonce(), 1, "rejection does not advance regular nonce");
        assertEq(
            uint256(proxy.getProposal(firstId).status),
            uint256(IMultisigProxy.ProposalStatus.Pending),
            "first proposal remains pending"
        );
        bytes32 secondId = proxy.proposeUpdateBridge(
            nextTarget,
            1,
            deadline,
            bitmap,
            MultisigHelper.signAll(
                vm, MultisigHelper.digestProposeUpdateBridge(domainSep, nextTarget, 1, deadline), keys
            )
        );
        assertEq(
            uint256(proxy.getProposal(secondId).status),
            uint256(IMultisigProxy.ProposalStatus.Pending),
            "fresh nonce accepts the next target"
        );
    }
}
