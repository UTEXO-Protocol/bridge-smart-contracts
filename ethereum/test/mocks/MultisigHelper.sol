// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Vm } from 'forge-std/Vm.sol';

import { IBridge }        from '../../src/interfaces/IBridge.sol';
import { IMultisigProxy } from '../../src/interfaces/IMultisigProxy.sol';

/// @title MultisigHelper
/// @notice EIP-712 digest builders and signature bitmap helpers for MultisigProxy tests.
library MultisigHelper {
    bytes32 internal constant DOMAIN_TYPEHASH = keccak256(
        'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
    );

    bytes32 internal constant TEE_FUNDS_OUT_TYPEHASH = keccak256(
        'TeeFundsOut(address recipient,uint256 amount,uint256 burnId,uint256 sourceChainId,uint256 destinationChainId,string sourceAddress,bytes proof,bytes settlementData,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant TEE_LZ_FUNDS_OUT_TYPEHASH = keccak256(
        'TeeLzFundsOut(uint256 amount,uint256 burnId,uint256 sourceChainId,uint256 destinationChainId,string sourceAddress,bytes proof,bytes settlementData,uint32 dstEid,bytes32 recipient,uint256 minAmountLD,bytes extraOptions,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant EMERGENCY_PAUSE_TYPEHASH = keccak256(
        'EmergencyPause(uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant EMERGENCY_UNPAUSE_TYPEHASH = keccak256(
        'EmergencyUnpause(uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_PAUSE_INFLOW_TYPEHASH = keccak256(
        'ProposePauseInflow(uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_UNPAUSE_INFLOW_TYPEHASH = keccak256(
        'ProposeUnpauseInflow(uint256 nonce,uint256 deadline)'
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

    bytes32 internal constant PROPOSE_SET_TIMELOCK_DURATION_TYPEHASH = keccak256(
        'ProposeSetTimelockDuration(uint256 newDuration,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant CANCEL_PROPOSAL_TYPEHASH = keccak256(
        'CancelProposal(bytes32 proposalId,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_ADMIN_EXECUTE_CM_TYPEHASH = keccak256(
        'ProposeAdminExecuteCommissionManager(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_ADMIN_EXECUTE_ROUTE_REGISTRY_TYPEHASH = keccak256(
        'ProposeAdminExecuteRouteRegistry(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)'
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
    bytes32 internal constant PROPOSE_DISABLE_LZ_ADAPTER_TYPEHASH = keccak256(
        'ProposeDisableLZAdapter(uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_SET_ROUTE_TYPEHASH = keccak256(
        'ProposeSetRoute(uint256 sourceChainId,uint256 destChainId,bool enabled,address finalityVerifier,address settlementModule,uint256 nonce,uint256 deadline)'
    );

    bytes32 internal constant PROPOSE_UPDATE_ROUTE_REGISTRY_TYPEHASH = keccak256(
        'ProposeUpdateRouteRegistry(address newRouteRegistry,uint256 nonce,uint256 deadline)'
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

    /// @dev EIP-712 digest for the typed `fundsOutCall` (TeeFundsOut).
    function digestTeeFundsOut(
        bytes32 domainSep,
        IBridge.FundsOutParams memory p,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            TEE_FUNDS_OUT_TYPEHASH,
            p.recipient,
            p.amount,
            p.burnId,
            p.sourceChainId,
            p.destinationChainId,
            keccak256(bytes(p.sourceAddress)),
            keccak256(p.proof),
            keccak256(p.settlementData),
            nonce,
            deadline
        )));
    }

    /// @dev EIP-712 digest for the typed `lzFundsOutCall` (TeeLzFundsOut). Built
    ///      in two `abi.encode` halves joined with `bytes.concat`, matching the
    ///      contract (byte-identical, and compiles without the optimizer).
    function digestTeeLzFundsOut(
        bytes32 domainSep,
        IMultisigProxy.LzFundsOutParams memory p,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(bytes.concat(
            abi.encode(
                TEE_LZ_FUNDS_OUT_TYPEHASH,
                p.amount,
                p.burnId,
                p.sourceChainId,
                p.destinationChainId,
                keccak256(bytes(p.sourceAddress)),
                keccak256(p.proof)
            ),
            abi.encode(
                keccak256(p.settlementData),
                p.dstEid,
                p.recipient,
                p.minAmountLD,
                keccak256(p.extraOptions),
                nonce,
                deadline
            )
        )));
    }

    function digestEmergencyPause(bytes32 domainSep, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(EMERGENCY_PAUSE_TYPEHASH, nonce, deadline)));
    }

    function digestEmergencyUnpause(bytes32 domainSep, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(EMERGENCY_UNPAUSE_TYPEHASH, nonce, deadline)));
    }

    function digestProposePauseInflow(bytes32 domainSep, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(PROPOSE_PAUSE_INFLOW_TYPEHASH, nonce, deadline)));
    }

    function digestProposeUnpauseInflow(bytes32 domainSep, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(PROPOSE_UNPAUSE_INFLOW_TYPEHASH, nonce, deadline)));
    }

    function digestProposeDisableLZAdapter(bytes32 domainSep, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(PROPOSE_DISABLE_LZ_ADAPTER_TYPEHASH, nonce, deadline)));
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

    function digestProposeAdminExecuteRouteRegistry(
        bytes32 domainSep,
        bytes4 selector,
        bytes memory callData,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_ADMIN_EXECUTE_ROUTE_REGISTRY_TYPEHASH, selector, keccak256(callData), nonce, deadline
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

    function digestProposeSetRoute(
        bytes32 domainSep,
        uint256 sourceChainId,
        uint256 destChainId,
        bool    enabled,
        address finalityVerifier,
        address settlementModule,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_SET_ROUTE_TYPEHASH,
            sourceChainId, destChainId, enabled, finalityVerifier, settlementModule,
            nonce, deadline
        )));
    }

    function digestProposeUpdateRouteRegistry(
        bytes32 domainSep,
        address newRouteRegistry,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return toTypedDataHash(domainSep, keccak256(abi.encode(
            PROPOSE_UPDATE_ROUTE_REGISTRY_TYPEHASH, newRouteRegistry, nonce, deadline
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
