// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Vm } from 'forge-std/Vm.sol';

/// @title MultisigHelper
/// @notice EIP-712 digest builders and signature bitmap helpers for MultisigProxy tests.
library MultisigHelper {
    bytes32 internal constant DOMAIN_TYPEHASH = keccak256(
        'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
    );

    bytes32 internal constant BRIDGE_OP_TYPEHASH = keccak256(
        'BridgeOperation(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant BRIDGE_BATCH_OP_TYPEHASH = keccak256(
        'BridgeBatchOperation(address[] targets,bytes[] callDatas,uint256[] values,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant EMERGENCY_PAUSE_TYPEHASH = keccak256(
        'EmergencyPause(uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant EMERGENCY_UNPAUSE_TYPEHASH = keccak256(
        'EmergencyUnpause(uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_ADMIN_EXECUTE_TYPEHASH = keccak256(
        'ProposeAdminExecute(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_UPDATE_ENCLAVE_SIGNERS_TYPEHASH = keccak256(
        'ProposeUpdateEnclaveSigners(address[] newSigners,uint256 newThreshold,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_UPDATE_FEDERATION_SIGNERS_TYPEHASH = keccak256(
        'ProposeUpdateFederationSigners(address[] newSigners,uint256 newThreshold,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_UPDATE_BRIDGE_TYPEHASH = keccak256(
        'ProposeUpdateBridge(address newBridge,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_SET_COMMISSION_RECIPIENT_TYPEHASH = keccak256(
        'ProposeSetCommissionRecipient(address newRecipient,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_SET_TEE_CALL_TYPEHASH = keccak256(
        'ProposeSetTeeAllowedCall(address target,bytes4 selector,bool allowed,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_SET_TIMELOCK_DURATION_TYPEHASH = keccak256(
        'ProposeSetTimelockDuration(uint256 newDuration,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant CANCEL_PROPOSAL_TYPEHASH = keccak256(
        'CancelProposal(bytes32 proposalId,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_ADMIN_EXECUTE_CM_TYPEHASH = keccak256(
        'ProposeAdminExecuteCommissionManager(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_WITHDRAW_TOKEN_COMMISSION_CM_TYPEHASH = keccak256(
        'ProposeWithdrawTokenCommissionCM(address token,uint256 amount,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_WITHDRAW_NATIVE_COMMISSION_CM_TYPEHASH = keccak256(
        'ProposeWithdrawNativeCommissionCM(uint256 amount,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_UPDATE_COMMISSION_MANAGER_TYPEHASH = keccak256(
        'ProposeUpdateCommissionManager(address newCommissionManager,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_ADMIN_EXECUTE_ADAPTER_TYPEHASH = keccak256(
        'ProposeAdminExecuteAdapter(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_UPDATE_LZ_ADAPTER_TYPEHASH = keccak256(
        'ProposeUpdateLZAdapter(address newLZAdapter,uint256 nonce,uint256 deadline)'
    );

    /// @dev Builds the EIP-712 domain separator the same way MultisigProxy does.
    function domainSeparator(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256('MultisigProxy'),
            keccak256('1'),
            chainId,
            verifyingContract
        ));
    }

    /// @dev Wraps a struct hash into the full EIP-712 digest.
    function toTypedDataHash(bytes32 domainSep, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked('\x19\x01', domainSep, structHash));
    }

    /// @dev EIP-712 array encoding for address[].
    function hashAddressArray(address[] memory arr) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            words[i] = bytes32(uint256(uint160(arr[i])));
        }
        return keccak256(abi.encodePacked(words));
    }

    // ========================================================================
    // Digest builders
    // ========================================================================

    function digestBridgeOp(
        bytes32 domainSep,
        bytes4 selector,
        bytes memory callData,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            BRIDGE_OP_TYPEHASH, selector, keccak256(callData), nonce, deadline
        )));
    }

    function digestBridgeBatchOp(
        bytes32 domainSep,
        address[] memory targets,
        bytes[]   memory callDatas,
        uint256[] memory values,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        bytes32[] memory cdHashes = new bytes32[](callDatas.length);
        for (uint256 i = 0; i < callDatas.length; i++) {
            cdHashes[i] = keccak256(callDatas[i]);
        }
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            BRIDGE_BATCH_OP_TYPEHASH,
            keccak256(abi.encodePacked(targets)),
            keccak256(abi.encodePacked(cdHashes)),
            keccak256(abi.encodePacked(values)),
            nonce,
            deadline
        )));
    }

    function digestEmergencyPause(bytes32 domainSep, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(EMERGENCY_PAUSE_TYPEHASH, nonce, deadline)));
    }

    function digestEmergencyUnpause(bytes32 domainSep, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(EMERGENCY_UNPAUSE_TYPEHASH, nonce, deadline)));
    }

    function digestProposeAdminExecute(
        bytes32 domainSep,
        bytes4 selector,
        bytes memory callData,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_ADMIN_EXECUTE_TYPEHASH, selector, keccak256(callData), nonce, deadline
        )));
    }

    function digestProposeUpdateEnclaveSigners(
        bytes32 domainSep,
        address[] memory newSigners,
        uint256 newThreshold,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_UPDATE_ENCLAVE_SIGNERS_TYPEHASH,
            hashAddressArray(newSigners), newThreshold, nonce, deadline
        )));
    }

    function digestProposeUpdateFederationSigners(
        bytes32 domainSep,
        address[] memory newSigners,
        uint256 newThreshold,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_UPDATE_FEDERATION_SIGNERS_TYPEHASH,
            hashAddressArray(newSigners), newThreshold, nonce, deadline
        )));
    }

    function digestProposeUpdateBridge(
        bytes32 domainSep,
        address newBridge,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_UPDATE_BRIDGE_TYPEHASH, newBridge, nonce, deadline
        )));
    }

    function digestProposeSetTeeAllowedCall(
        bytes32 domainSep,
        address target,
        bytes4 selector,
        bool allowed,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_SET_TEE_CALL_TYPEHASH, target, selector, allowed, nonce, deadline
        )));
    }

    function digestProposeSetTimelockDuration(
        bytes32 domainSep,
        uint256 newDuration,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_SET_TIMELOCK_DURATION_TYPEHASH, newDuration, nonce, deadline
        )));
    }

    function digestProposeAdminExecuteCM(
        bytes32 domainSep,
        bytes4 selector,
        bytes memory callData,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_ADMIN_EXECUTE_CM_TYPEHASH, selector, keccak256(callData), nonce, deadline
        )));
    }

    function digestProposeWithdrawTokenCommissionCM(
        bytes32 domainSep,
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_WITHDRAW_TOKEN_COMMISSION_CM_TYPEHASH, token, amount, nonce, deadline
        )));
    }

    function digestProposeWithdrawNativeCommissionCM(
        bytes32 domainSep,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_WITHDRAW_NATIVE_COMMISSION_CM_TYPEHASH, amount, nonce, deadline
        )));
    }

    function digestProposeUpdateCommissionManager(
        bytes32 domainSep,
        address newCm,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_UPDATE_COMMISSION_MANAGER_TYPEHASH, newCm, nonce, deadline
        )));
    }

    function digestProposeAdminExecuteAdapter(
        bytes32 domainSep,
        bytes4 selector,
        bytes memory callData,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_ADMIN_EXECUTE_ADAPTER_TYPEHASH, selector, keccak256(callData), nonce, deadline
        )));
    }

    function digestProposeUpdateLZAdapter(
        bytes32 domainSep,
        address newLZAdapter,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_UPDATE_LZ_ADAPTER_TYPEHASH, newLZAdapter, nonce, deadline
        )));
    }

    function digestCancelProposal(
        bytes32 domainSep,
        bytes32 proposalId,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            CANCEL_PROPOSAL_TYPEHASH, proposalId, nonce, deadline
        )));
    }

    // ========================================================================
    // Signatures
    // ========================================================================

    /// @dev Signs a digest with each private key and returns concatenated [r,s,v] 65-byte signatures.
    function signAll(Vm vm, bytes32 digest, uint256[] memory privateKeys) internal pure returns (bytes[] memory sigs) {
        sigs = new bytes[](privateKeys.length);
        for (uint256 i = 0; i < privateKeys.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKeys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }
}
