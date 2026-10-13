// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice Adapter registration, rotation and disabling use federation proposals.
contract MultisigAdapterGovernanceTest is MultisigProxyTestBase {
    function _proposeUpdateLZAdapter(address newAdapter) private returns (bytes32 id) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateLZAdapter(domainSep, newAdapter, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        id = proxy.proposeUpdateLZAdapter(newAdapter, nonce, deadline, bitmap, sigs);
    }

    function _proposeDisableLZAdapter() private returns (bytes32 id) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeDisableLZAdapter(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        id = proxy.proposeDisableLZAdapter(nonce, deadline, bitmap, sigs);
    }

    function test_lzAdapter_defaultsToZero() public view {
        assertEq(proxy.lzAdapter(), address(0));
    }

    function test_proposeUpdateLZAdapter_executeSetsAdapter() public {
        address newAdapter = makeAddr("lzAdapter");
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.LZAdapterUpdated(address(0), newAdapter);

        proxy.executeProposal(id, abi.encode(newAdapter));
        assertEq(proxy.lzAdapter(), newAdapter);
    }

    function test_proposeUpdateLZAdapter_rejectsZeroAtExecute() public {
        // Proposing zero succeeds (validated at execute); execution reverts —
        // DisableLZAdapter is the explicit way to clear the routing target.
        bytes32 id = _proposeUpdateLZAdapter(address(0));
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.InvalidLZAdapter.selector);
        proxy.executeProposal(id, abi.encode(address(0)));
    }

    function test_proposeDisableLZAdapter_clearsAdapterAndEmits() public {
        // Set a non-zero adapter first.
        address newAdapter = makeAddr("lzAdapter");
        _setLzAdapter(newAdapter);
        assertEq(proxy.lzAdapter(), newAdapter);

        // Explicit disable clears it and emits LZAdapterDisabled.
        bytes32 id2 = _proposeDisableLZAdapter();
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectEmit(true, false, false, true, address(proxy));
        emit IMultisigProxy.LZAdapterDisabled(newAdapter);

        proxy.executeProposal(id2, "");
        assertEq(proxy.lzAdapter(), address(0));
    }

    function test_proposeUpdateLZAdapter_revertsOnDataMismatch() public {
        address newAdapter = makeAddr("lzAdapter");
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        proxy.executeProposal(id, abi.encode(makeAddr("different")));
    }

    function test_proposeUpdateLZAdapter_canBeCancelled() public {
        address newAdapter = makeAddr("lzAdapter");
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        uint256 cDeadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 cDigest = MultisigHelper.digestCancelProposal(domainSep, id, cDeadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory cSigs = MultisigHelper.signAll(vm, cDigest, pks);

        vm.expectEmit(true, false, false, true, address(proxy));
        emit IMultisigProxy.ProposalCancelled(id);
        proxy.cancelProposal(id, cDeadline, bitmap, cSigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.executeProposal(id, abi.encode(newAdapter));
        assertEq(proxy.lzAdapter(), address(0));
    }

    function test_proposeAdminExecuteAdapter_revertsIfAdapterUnset() public {
        bytes memory callData = abi.encodeWithSignature("mint(address,uint256)", user, 1e18);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteAdapter(
            domainSep, proxy.lzAdapter(), bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.ZeroTarget.selector);
        proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);
        assertEq(proxy.proposalNonce(), nonce);
    }

    function test_proposeAdminExecuteAdapter_executesCallOnAdapter() public {
        MockERC20 adapter = new MockERC20("LZ Stub", "LZS");
        bytes32 idSet = _proposeUpdateLZAdapter(address(adapter));
        // Each proposal must complete its own timelock before adapter dispatch.
        uint256 firstExec = vm.getBlockTimestamp() + TIMELOCK + 1;
        vm.warp(firstExec);
        proxy.executeProposal(idSet, abi.encode(address(adapter)));
        assertEq(proxy.lzAdapter(), address(adapter));

        bytes memory callData = abi.encodeWithSignature("mint(address,uint256)", recipient, 1e18);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = firstExec + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteAdapter(
            domainSep, proxy.lzAdapter(), bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);

        vm.warp(firstExec + TIMELOCK + 1);
        proxy.executeProposal(id, callData);

        assertEq(adapter.balanceOf(recipient), 1e18);
    }

    function test_proposeAdminExecuteAdapter_revertsOnEmptyCallData() public {
        bytes memory callData = "";
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = new bytes[](pks.length);
        for (uint256 i = 0; i < pks.length; i++) {
            sigs[i] = new bytes(65);
        }

        vm.expectRevert(IMultisigProxy.CallDataTooShort.selector);
        proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);
    }

    function test_executeProposal_wrapsEmptyAdapterRevertAsCallFailed() public {
        MockERC20 adapter = new MockERC20("LZ Stub", "LZS");
        bytes32 idSet = _proposeUpdateLZAdapter(address(adapter));
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(idSet, abi.encode(address(adapter)));

        bytes memory callData = abi.encodeWithSignature("nonExistent()");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteAdapter(
            domainSep, proxy.lzAdapter(), bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        // The stub has no fallback; the proxy wraps its empty revert as CallFailed.
        vm.expectRevert(IMultisigProxy.CallFailed.selector);
        proxy.executeProposal(id, callData);
        assertEq(uint256(proxy.getProposal(id).status), uint256(IMultisigProxy.ProposalStatus.Pending));
    }
}
