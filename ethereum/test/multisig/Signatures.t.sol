// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice Signature views and domain separation enforce the configured signer sets.
contract MultisigSignaturesTest is MultisigProxyTestBase {
    function test_verifyEnclaveSignature_acceptsValidSignerSignature() public view {
        bytes32 digest = keccak256("msg");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ENC_PK_1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertTrue(proxy.verifyEnclaveSignature(RGB_CHAIN_ID, digest, sig, 0));
        assertFalse(proxy.verifyEnclaveSignature(RGB_CHAIN_ID, digest, sig, 1));
    }

    function test_verifyEnclaveSignature_revertsOutOfRange() public {
        bytes32 digest = keccak256("msg");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ENC_PK_1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(IMultisigProxy.IndexOutOfRange.selector);
        proxy.verifyEnclaveSignature(RGB_CHAIN_ID, digest, sig, 3);
    }

    function test_domainSeparator_matchesHelper() public view {
        assertEq(proxy.DOMAIN_SEPARATOR(), MultisigHelper.domainSeparator(address(proxy), block.chainid));
    }

    // ========================================================================
    // Domain separator rebuild on chain-id change
    // The separator is cached at deploy with the chain id. After a chain-id
    // change (e.g. a hard fork) it is rebuilt, so a signature made before the
    // fork no longer verifies on the forked chain (no cross-fork replay).
    // ========================================================================

    function test_domainSeparator_rebuiltOnChainIdChange() public {
        uint256 originalChainId = block.chainid;
        bytes32 dsBefore = proxy.DOMAIN_SEPARATOR();
        assertEq(dsBefore, MultisigHelper.domainSeparator(address(proxy), originalChainId), "cached on original chain");

        uint256 forkedChainId = originalChainId + 1;
        vm.chainId(forkedChainId);

        bytes32 dsAfter = proxy.DOMAIN_SEPARATOR();
        assertNotEq(dsAfter, dsBefore, "separator rebuilt after chain-id change");
        assertEq(dsAfter, MultisigHelper.domainSeparator(address(proxy), forkedChainId), "rebuilt over new chain id");
    }

    function test_fundsOutCall_rejectsSignatureAfterChainIdChange() public {
        // Sign a valid TEE fundsOut on the original chain (domainSep was cached
        // at setUp for block.chainid).
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // Simulate a hard fork: same state/nonces, different chain id. The
        // domain separator is rebuilt, so the pre-fork signatures recover to the
        // wrong addresses and verification fails — the release cannot be replayed.
        vm.chainId(block.chainid + 1);
        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    // TEE keys cannot authorize a privileged federation proposal.
    function test_proposeAdminExecute_rejectsEnclaveSignatures() public {
        // A privileged call the TEE quorum might want to smuggle through.
        bytes memory callData = abi.encodeWithSignature("pauseInflow()");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        // Same proposal digest the federation would sign...
        bytes32 digest = MultisigHelper.digestProposeAdminExecute(
            domainSep, proxy.bridge(), bytes4(callData), callData, nonce, deadline
        );
        // ...but signed by the ENCLAVE (TEE) keys instead of the federation.
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // proposeAdminExecute verifies against the federation signer set, so the
        // recovered enclave addresses are not authorized: the proposal is never
        // created and the privileged call never reaches the timelock queue.
        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.proposeAdminExecute(callData, nonce, deadline, bitmap, sigs);
    }
}
