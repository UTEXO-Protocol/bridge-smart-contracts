// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { ECDSA }  from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { IMultisigProxy } from './interfaces/IMultisigProxy.sol';
import { IBridge }        from './interfaces/IBridge.sol';
import { IRouteRegistry } from './interfaces/IRouteRegistry.sol';

/// @notice Minimal view of the LayerZero adapter's outbound entry point. The
///         adapter itself lives in the `utexo-usdt0-contracts` repo; this
///         interface pins the ABI `lzFundsOut` calls. Keep it in sync with
///         `UtexoLZAdapter.sendOut`.
interface ILZAdapterSendOut {
    function sendOut(
        uint32  dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes   calldata extraOptions
    ) external payable;
}

/// @notice Minimal view of the Bridge's custodied-token getter. `Bridge`
///         exposes `TOKEN` as a public immutable; this avoids adding it to
///         `IBridge` (which would clash with the `BridgeBase` state variable).
interface IBridgeToken {
    function TOKEN() external view returns (address);
}

contract MultisigProxy is IMultisigProxy {
    using ECDSA for bytes32;

    // =========================================================================
    // State
    // =========================================================================

    address public bridge;
    address public commissionManager;

    /// @notice Routing target for `AdminExecuteAdapter` proposals. Settable via
    ///         `UpdateLZAdapter` after the adapter is deployed; `address(0)`
    ///         until then (closes adapter-execute by default).
    address public lzAdapter;

    /// @notice Per-source-chain enclave signer sets. Each source network (RGB,
    ///         Concordium/Arch, …) is validated by its own TEE code and therefore
    ///         has its own key set; a release for `sourceChainId` is authorised
    ///         only by the set registered for that chain. Selected on the release
    ///         path via `params.sourceChainId`, which is already committed to in
    ///         the enclave EIP-712 digest — so a signature for one source chain
    ///         cannot be replayed against another.
    mapping(uint256 sourceChainId => address[]) private _enclaveSigners;

    /// @notice Per-source-chain enclave quorum. `0` means the source chain is
    ///         not registered — used as the existence guard on the release path.
    mapping(uint256 sourceChainId => uint256) public enclaveThreshold;

    /// @notice Registered enclave source chains, for enumeration and the
    ///         cross-set disjointness checks. Bounded by `MAX_ENCLAVE_SOURCE_CHAINS`.
    uint256[] private _enclaveSourceChains;

    address[] private _federationSigners;
    uint256 public federationThreshold;

    address public commissionRecipient;

    /// @notice Per-source-chain nonce for the typed TEE methods (`fundsOutCall`
    ///         / `lzFundsOutCall`). Each source chain has its own lane, so the
    ///         TEE operating one network cannot invalidate another network's
    ///         pre-signed release. Each successful call must match the current
    ///         value for its `sourceChainId` and then increments it.
    mapping(uint256 sourceChainId => uint256) public teeNonce;

    /// @notice Federation proposals.
    mapping(bytes32 => Proposal) private _proposals;

    /// @notice Sequential nonce for the regular federation lane: `_propose`
    ///         (all typed proposals) and `cancelProposal`.
    uint256 public proposalNonce;

    /// @notice Sequential nonce for the emergency lane: `emergencyPause` /
    ///         `emergencyUnpause`. Kept separate from `proposalNonce` so an
    ///         emergency action cannot invalidate an already-signed regular
    ///         proposal. Cross-lane replay is independently prevented by
    ///         each operation's distinct EIP-712 typehash.
    uint256 public emergencyNonce;

    /// @notice Minimum delay (seconds) between proposal creation and execution.
    uint256 public timelockDuration;

    /// @notice Lower bound for `timelockDuration`, fixed at deploy time.
    /// @dev Immutable so the governance observation/veto window can never be
    ///      reduced below this floor — not by a `SetTimelockDuration` proposal
    ///      and not by any later action. Set in the constructor and validated to
    ///      be in (0, MAX_PROPOSAL_LIFETIME).
    uint256 public immutable MIN_TIMELOCK;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum allowed time between proposal creation and its deadline.
    uint256 public constant MAX_PROPOSAL_LIFETIME = 30 days;

    /// @notice Maximum allowed lifetime of a TEE-signed `fundsOutCall` /
    ///         `lzFundsOutCall` deadline. Tighter than `MAX_PROPOSAL_LIFETIME` because enclave
    ///         operations (e.g. `fundsOut`) are meant to be executed promptly
    ///         after signing; a short ceiling limits how long a leaked or
    ///         pre-signed payload stays executable while its nonce is unconsumed.
    uint256 public constant MAX_TEE_DEADLINE = 1 days;

    /// @notice Hard upper bound on the size of either signer set. Bounds the
    ///         O(N^2) duplicate/disjointness checks and stays far within the
    ///         `uint256` signature-bitmap width (so no signer index is ever
    ///         unreachable). 20 is ample for an enclave/federation committee.
    uint256 public constant MAX_SIGNERS = 20;

    /// @notice Hard upper bound on the number of registered enclave source
    ///         chains. Bounds the cross-set disjointness loop (run on every
    ///         signer rotation), keeping governance updates gas-predictable.
    uint256 public constant MAX_ENCLAVE_SOURCE_CHAINS = 32;

    /// @notice Length of a Solidity function selector (`bytes4`) in bytes. Used
    ///         to guard `callData` against payloads too short to even carry a
    ///         selector before it is sliced via `calldataload`.
    uint256 public constant SELECTOR_LENGTH = 4;

    /// @notice CommissionManager withdrawal selectors that the generic
    ///         `AdminExecuteCommissionManager` path is NOT allowed to call —
    ///         they take a free recipient and would bypass the pinned
    ///         `commissionRecipient`. Withdrawals must go through the
    ///         dedicated WithdrawTokenCommissionCM / WithdrawNativeCommissionCM
    ///         ops, which force the recipient to `commissionRecipient`.
    bytes4 private constant _SEL_WITHDRAW_TOKEN      = bytes4(keccak256('withdrawTokenCommission(address,address,uint256)'));
    bytes4 private constant _SEL_WITHDRAW_NATIVE     = bytes4(keccak256('withdrawNativeCommission(address,uint256)'));
    bytes4 private constant _SEL_WITHDRAW_ALL_TOKEN  = bytes4(keccak256('withdrawAllTokenCommission(address,address)'));
    bytes4 private constant _SEL_WITHDRAW_ALL_NATIVE = bytes4(keccak256('withdrawAllNativeCommission(address)'));

    uint256 private immutable _cachedChainId;
    bytes32 private immutable _cachedDomainSeparator;

    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
    );

    // TEE — typed enclave release operations
    bytes32 private constant _TEE_FUNDS_OUT_TYPEHASH = keccak256(
        'TeeFundsOut(address recipient,uint256 amount,uint256 burnId,uint256 sourceChainId,uint256 destinationChainId,string sourceAddress,bytes proof,bytes settlementData,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _TEE_LZ_FUNDS_OUT_TYPEHASH = keccak256(
        'TeeLzFundsOut(uint256 amount,uint256 burnId,uint256 sourceChainId,uint256 destinationChainId,string sourceAddress,bytes proof,bytes settlementData,uint32 dstEid,bytes32 recipient,uint256 minAmountLD,bytes extraOptions,uint256 nonce,uint256 deadline)'
    );

    // Federation propose — typed EIP-712 structs per operation (Bridge side)
    bytes32 private constant _PROPOSE_ADMIN_EXECUTE_TYPEHASH = keccak256(
        'ProposeAdminExecute(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_UPDATE_ENCLAVE_SIGNERS_TYPEHASH = keccak256(
        'ProposeUpdateEnclaveSigners(uint256 sourceChainId,address[] newSigners,uint256 newThreshold,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_UPDATE_FEDERATION_SIGNERS_TYPEHASH = keccak256(
        'ProposeUpdateFederationSigners(address[] newSigners,uint256 newThreshold,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_UPDATE_BRIDGE_TYPEHASH = keccak256(
        'ProposeUpdateBridge(address newBridge,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_SET_COMMISSION_RECIPIENT_TYPEHASH = keccak256(
        'ProposeSetCommissionRecipient(address newRecipient,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_SET_TIMELOCK_DURATION_TYPEHASH = keccak256(
        'ProposeSetTimelockDuration(uint256 newDuration,uint256 nonce,uint256 deadline)'
    );

    // Federation propose — CommissionManager side
    bytes32 private constant _PROPOSE_ADMIN_EXECUTE_CM_TYPEHASH = keccak256(
        'ProposeAdminExecuteCommissionManager(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_ADMIN_EXECUTE_ROUTE_REGISTRY_TYPEHASH = keccak256(
        'ProposeAdminExecuteRouteRegistry(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_WITHDRAW_TOKEN_COMMISSION_CM_TYPEHASH = keccak256(
        'ProposeWithdrawTokenCommissionCM(address token,uint256 amount,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_WITHDRAW_NATIVE_COMMISSION_CM_TYPEHASH = keccak256(
        'ProposeWithdrawNativeCommissionCM(uint256 amount,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_UPDATE_COMMISSION_MANAGER_TYPEHASH = keccak256(
        'ProposeUpdateCommissionManager(address newCommissionManager,uint256 nonce,uint256 deadline)'
    );

    // Federation propose — LZAdapter side
    bytes32 private constant _PROPOSE_ADMIN_EXECUTE_ADAPTER_TYPEHASH = keccak256(
        'ProposeAdminExecuteAdapter(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_UPDATE_LZ_ADAPTER_TYPEHASH = keccak256(
        'ProposeUpdateLZAdapter(address newLZAdapter,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_DISABLE_LZ_ADAPTER_TYPEHASH = keccak256(
        'ProposeDisableLZAdapter(uint256 nonce,uint256 deadline)'
    );

    // Federation propose — RouteRegistry side
    bytes32 private constant _PROPOSE_SET_ROUTE_TYPEHASH = keccak256(
        'ProposeSetRoute(uint256 sourceChainId,uint256 destChainId,bool enabled,address finalityVerifier,address settlementModule,uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_UPDATE_ROUTE_REGISTRY_TYPEHASH = keccak256(
        'ProposeUpdateRouteRegistry(address newRouteRegistry,uint256 nonce,uint256 deadline)'
    );

    // Cancel
    bytes32 private constant _CANCEL_PROPOSAL_TYPEHASH = keccak256(
        'CancelProposal(bytes32 proposalId,uint256 nonce,uint256 deadline)'
    );

    // Emergency
    bytes32 private constant _EMERGENCY_PAUSE_TYPEHASH = keccak256(
        'EmergencyPause(uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _EMERGENCY_UNPAUSE_TYPEHASH = keccak256(
        'EmergencyUnpause(uint256 nonce,uint256 deadline)'
    );

    // Federation propose — planned inflow-only pause (timelocked)
    bytes32 private constant _PROPOSE_PAUSE_INFLOW_TYPEHASH = keccak256(
        'ProposePauseInflow(uint256 nonce,uint256 deadline)'
    );
    bytes32 private constant _PROPOSE_UNPAUSE_INFLOW_TYPEHASH = keccak256(
        'ProposeUnpauseInflow(uint256 nonce,uint256 deadline)'
    );

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address bridge_,
        address commissionManager_,
        address[] memory enclaveSigners_,
        uint256 enclaveThreshold_,
        uint256 initialEnclaveSourceChain_,
        address[] memory federationSigners_,
        uint256 federationThreshold_,
        address commissionRecipient_,
        uint256 timelockDuration_,
        uint256 minTimelock_
    ) {
        if (bridge_ == address(0)) revert ZeroBridge();
        if (commissionManager_ == address(0)) revert ZeroCommissionManager();
        if (enclaveSigners_.length == 0) revert NoSigners();
        if (initialEnclaveSourceChain_ == 0) revert UnknownSourceChain(0);
        _requireValidThreshold(enclaveThreshold_, enclaveSigners_.length);
        if (federationSigners_.length == 0) revert NoSigners();
        _requireValidThreshold(federationThreshold_, federationSigners_.length);
        if (commissionRecipient_ == address(0)) revert ZeroCommissionRecipient();
        if (minTimelock_ == 0 || minTimelock_ >= MAX_PROPOSAL_LIFETIME) revert InvalidMinTimelock();
        if (timelockDuration_ < minTimelock_) revert TimelockTooShort();
        if (timelockDuration_ >= MAX_PROPOSAL_LIFETIME) revert TimelockTooLong();

        _validateSigners(enclaveSigners_);
        _validateSigners(federationSigners_);
        // The enclave and federation are distinct trust domains; an address in
        // both would count toward quorum in each, collapsing that separation.
        _requireDisjoint(enclaveSigners_, federationSigners_);

        bridge = bridge_;
        commissionManager = commissionManager_;
        _enclaveSigners[initialEnclaveSourceChain_] = enclaveSigners_;
        enclaveThreshold[initialEnclaveSourceChain_] = enclaveThreshold_;
        _enclaveSourceChains.push(initialEnclaveSourceChain_);
        _federationSigners = federationSigners_;
        federationThreshold = federationThreshold_;
        commissionRecipient = commissionRecipient_;
        timelockDuration = timelockDuration_;
        MIN_TIMELOCK = minTimelock_;

        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    // =========================================================================
    // TEE-authorized
    // =========================================================================

    /// @inheritdoc IMultisigProxy
    /// @dev Typed enclave release: the only call this makes is `Bridge.fundsOut`.
    function fundsOutCall(
        IBridge.FundsOutParams calldata params,
        uint256 nonce,
        uint256 deadline,
        uint256 enclaveBitmap,
        bytes[] calldata enclaveSigs
    ) external {
        _checkTeeTiming(deadline);
        // Select the enclave set by the release's source chain. `sourceChainId`
        // is committed to in the digest below, so a signature is bound to the
        // set of exactly one source chain. A zero threshold = unregistered.
        if (enclaveThreshold[params.sourceChainId] == 0) revert UnknownSourceChain(params.sourceChainId);
        if (nonce != teeNonce[params.sourceChainId]) revert InvalidNonce();

        _verifySignatures(
            _hashTypedData(_fundsOutStructHash(params, nonce, deadline)),
            enclaveBitmap, enclaveSigs, _enclaveSigners[params.sourceChainId], enclaveThreshold[params.sourceChainId]
        );

        teeNonce[params.sourceChainId]++;

        IBridge(bridge).fundsOut(params);

        emit FundsOutExecuted(params.sourceChainId, nonce, enclaveBitmap);
    }

    /// @dev EIP-712 struct hash for `TeeFundsOut`. Isolated in its own frame to
    ///      keep `fundsOutCall` within stack limits.
    function _fundsOutStructHash(
        IBridge.FundsOutParams calldata params,
        uint256 nonce,
        uint256 deadline
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(
            _TEE_FUNDS_OUT_TYPEHASH,
            params.recipient,
            params.amount,
            params.burnId,
            params.sourceChainId,
            params.destinationChainId,
            keccak256(bytes(params.sourceAddress)),
            keccak256(params.proof),
            keccak256(params.settlementData),
            nonce,
            deadline
        ));
    }

    /// @inheritdoc IMultisigProxy
    /// @dev Typed Flow-4 release: releases to the LZ adapter and bridges onward
    ///      in one signed operation. The Bridge recipient is forced to
    ///      `lzAdapter`, and the amount sent out is the balance actually
    ///      delivered to the adapter (measured here), so the two legs are bound
    ///      on-chain and cannot be mismatched (R-W-16).
    function lzFundsOutCall(
        LzFundsOutParams calldata params,
        uint256 nonce,
        uint256 deadline,
        uint256 enclaveBitmap,
        bytes[] calldata enclaveSigs
    ) external payable {
        _checkTeeTiming(deadline);
        if (enclaveThreshold[params.sourceChainId] == 0) revert UnknownSourceChain(params.sourceChainId);
        if (nonce != teeNonce[params.sourceChainId]) revert InvalidNonce();

        address adapter = lzAdapter;
        if (adapter == address(0)) revert LZAdapterNotSet();

        _verifySignatures(
            _hashTypedData(_lzFundsOutStructHash(params, nonce, deadline)),
            enclaveBitmap, enclaveSigs, _enclaveSigners[params.sourceChainId], enclaveThreshold[params.sourceChainId]
        );

        teeNonce[params.sourceChainId]++;

        // Release to the adapter, then bridge exactly what the adapter received,
        // so the release and the cross-chain send are bound on-chain. The Bridge
        // recipient is forced to the adapter (not taken from params).
        uint256 delivered;
        {
            address token = IBridgeToken(bridge).TOKEN();
            uint256 balanceBefore = IERC20(token).balanceOf(adapter);
            IBridge(bridge).fundsOut(IBridge.FundsOutParams({
                recipient:          adapter,
                amount:             params.amount,
                burnId:             params.burnId,
                sourceChainId:      params.sourceChainId,
                destinationChainId: params.destinationChainId,
                sourceAddress:      params.sourceAddress,
                proof:              params.proof,
                settlementData:     params.settlementData
            }));
            delivered = IERC20(token).balanceOf(adapter) - balanceBefore;
        }

        ILZAdapterSendOut(adapter).sendOut{ value: msg.value }(
            params.dstEid, params.recipient, delivered, params.minAmountLD, params.extraOptions
        );

        emit LzFundsOutExecuted(params.sourceChainId, nonce, enclaveBitmap, params.dstEid, params.recipient, delivered);
    }

    /// @dev EIP-712 struct hash for `TeeLzFundsOut`. Isolated in its own frame
    ///      to keep `lzFundsOutCall` within stack limits.
    function _lzFundsOutStructHash(
        LzFundsOutParams calldata params,
        uint256 nonce,
        uint256 deadline
    ) private pure returns (bytes32) {
        // Built in two `abi.encode` halves joined with `bytes.concat`. Every
        // field is a 32-byte word (dynamic ones are pre-hashed), so the result
        // is byte-identical to encoding all fields at once, but each half is
        // shallow enough to compile without the optimizer (e.g. `forge coverage`).
        return keccak256(bytes.concat(
            abi.encode(
                _TEE_LZ_FUNDS_OUT_TYPEHASH,
                params.amount,
                params.burnId,
                params.sourceChainId,
                params.destinationChainId,
                keccak256(bytes(params.sourceAddress)),
                keccak256(params.proof)
            ),
            abi.encode(
                keccak256(params.settlementData),
                params.dstEid,
                params.recipient,
                params.minAmountLD,
                keccak256(params.extraOptions),
                nonce,
                deadline
            )
        ));
    }

    /// @dev Shared timing guard for the typed enclave methods: not expired, and
    ///      the signed deadline cannot sit further than `MAX_TEE_DEADLINE` ahead.
    function _checkTeeTiming(uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (deadline > block.timestamp + MAX_TEE_DEADLINE) revert DeadlineTooFar();
    }

    // =========================================================================
    // Federation instant (emergency, no timelock)
    // =========================================================================

    /// @inheritdoc IMultisigProxy
    function emergencyPause(
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external {
        if (block.timestamp > deadline) revert Expired();
        if (nonce != emergencyNonce) revert InvalidNonce();

        bytes32 digest = _hashTypedData(
            keccak256(abi.encode(_EMERGENCY_PAUSE_TYPEHASH, nonce, deadline))
        );
        _verifySignatures(digest, fedBitmap, fedSigs, _federationSigners, federationThreshold);

        emergencyNonce++;

        // Emergency freeze of BOTH inflow and outflow — no timelock, federation
        // signatures only. Also halts the enclave/TEE release path (it routes
        // through Bridge.fundsOut, now gated by whenOutflowNotPaused).
        (bool ok, bytes memory ret) = bridge.call(abi.encodeWithSignature('emergencyPauseAll()'));
        _propagateRevert(ok, ret);

        emit EmergencyPaused(nonce, fedBitmap);
    }

    /// @inheritdoc IMultisigProxy
    function emergencyUnpause(
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external {
        if (block.timestamp > deadline) revert Expired();
        if (nonce != emergencyNonce) revert InvalidNonce();

        bytes32 digest = _hashTypedData(
            keccak256(abi.encode(_EMERGENCY_UNPAUSE_TYPEHASH, nonce, deadline))
        );
        _verifySignatures(digest, fedBitmap, fedSigs, _federationSigners, federationThreshold);

        emergencyNonce++;

        // Lift the emergency freeze on BOTH inflow and outflow.
        (bool ok, bytes memory ret) = bridge.call(abi.encodeWithSignature('emergencyUnpauseAll()'));
        _propagateRevert(ok, ret);

        emit EmergencyUnpaused(nonce, fedBitmap);
    }

    // =========================================================================
    // Federation propose (Phase 1) — Bridge side
    // =========================================================================

    /// @inheritdoc IMultisigProxy
    function proposeAdminExecute(
        bytes calldata callData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        if (callData.length < SELECTOR_LENGTH) revert CallDataTooShort();

        bytes4 selector;
        assembly { selector := calldataload(callData.offset) }

        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_ADMIN_EXECUTE_TYPEHASH, selector, keccak256(callData), nonce, deadline
        ));

        return _propose(OperationType.AdminExecute, callData, nonce, deadline, structHash, fedBitmap, fedSigs);
    }

    /// @inheritdoc IMultisigProxy
    function proposeUpdateEnclaveSigners(
        uint256 sourceChainId,
        address[] calldata newSigners,
        uint256 newThreshold,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        // Validate the proposed set up front so a malformed rotation reverts
        // here instead of consuming a nonce + timelock slot and failing only at
        // execution. Disjointness is intentionally left to execute time: it
        // depends on the live federation and other enclave sets, which may
        // change before then.
        if (sourceChainId == 0) revert UnknownSourceChain(0);
        if (newSigners.length == 0) revert NoSigners();
        _requireValidThreshold(newThreshold, newSigners.length);
        _validateSigners(newSigners);

        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_UPDATE_ENCLAVE_SIGNERS_TYPEHASH,
            sourceChainId, _hashAddressArray(newSigners), newThreshold, nonce, deadline
        ));

        return _propose(
            OperationType.UpdateEnclaveSigners,
            abi.encode(sourceChainId, newSigners, newThreshold),
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    function proposeUpdateFederationSigners(
        address[] calldata newSigners,
        uint256 newThreshold,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        // Validate up front (see proposeUpdateEnclaveSigners); disjointness is
        // enforced at execution against the live enclave set.
        if (newSigners.length == 0) revert NoSigners();
        _requireValidThreshold(newThreshold, newSigners.length);
        _validateSigners(newSigners);

        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_UPDATE_FEDERATION_SIGNERS_TYPEHASH,
            _hashAddressArray(newSigners), newThreshold, nonce, deadline
        ));

        return _propose(
            OperationType.UpdateFederationSigners,
            abi.encode(newSigners, newThreshold),
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    function proposeUpdateBridge(
        address newBridge,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_UPDATE_BRIDGE_TYPEHASH, newBridge, nonce, deadline
        ));

        return _propose(
            OperationType.UpdateBridge,
            abi.encode(newBridge),
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    function proposeSetCommissionRecipient(
        address newRecipient,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_SET_COMMISSION_RECIPIENT_TYPEHASH, newRecipient, nonce, deadline
        ));

        return _propose(
            OperationType.SetCommissionRecipient,
            abi.encode(newRecipient),
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    function proposeSetTimelockDuration(
        uint256 newDuration,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_SET_TIMELOCK_DURATION_TYPEHASH, newDuration, nonce, deadline
        ));

        return _propose(
            OperationType.SetTimelockDuration,
            abi.encode(newDuration),
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    // =========================================================================
    // Federation propose (Phase 1) — CommissionManager side
    // =========================================================================

    /// @inheritdoc IMultisigProxy
    function proposeAdminExecuteCommissionManager(
        bytes calldata callData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        if (callData.length < SELECTOR_LENGTH) revert CallDataTooShort();

        bytes4 selector;
        assembly { selector := calldataload(callData.offset) }

        // Commission withdrawals must use the pinned-recipient ops; reject them
        // on the generic path up front (fail-fast, no wasted proposal slot).
        _requireNotCommissionWithdrawSelector(selector);

        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_ADMIN_EXECUTE_CM_TYPEHASH, selector, keccak256(callData), nonce, deadline
        ));

        return _propose(
            OperationType.AdminExecuteCommissionManager,
            callData,
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    function proposeAdminExecuteRouteRegistry(
        bytes calldata callData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        if (callData.length < SELECTOR_LENGTH) revert CallDataTooShort();

        bytes4 selector;
        assembly { selector := calldataload(callData.offset) }

        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_ADMIN_EXECUTE_ROUTE_REGISTRY_TYPEHASH, selector, keccak256(callData), nonce, deadline
        ));

        return _propose(
            OperationType.AdminExecuteRouteRegistry,
            callData,
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    function proposeWithdrawTokenCommissionCM(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_WITHDRAW_TOKEN_COMMISSION_CM_TYPEHASH, token, amount, nonce, deadline
        ));

        return _propose(
            OperationType.WithdrawTokenCommissionCM,
            abi.encode(token, amount),
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    function proposeWithdrawNativeCommissionCM(
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_WITHDRAW_NATIVE_COMMISSION_CM_TYPEHASH, amount, nonce, deadline
        ));

        return _propose(
            OperationType.WithdrawNativeCommissionCM,
            abi.encode(amount),
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    function proposeUpdateCommissionManager(
        address newCommissionManager,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_UPDATE_COMMISSION_MANAGER_TYPEHASH, newCommissionManager, nonce, deadline
        ));

        return _propose(
            OperationType.UpdateCommissionManager,
            abi.encode(newCommissionManager),
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    // =========================================================================
    // Federation propose (Phase 1) — LZAdapter side
    // =========================================================================

    /// @inheritdoc IMultisigProxy
    function proposeAdminExecuteAdapter(
        bytes calldata callData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        if (callData.length < SELECTOR_LENGTH) revert CallDataTooShort();

        bytes4 selector;
        assembly { selector := calldataload(callData.offset) }

        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_ADMIN_EXECUTE_ADAPTER_TYPEHASH, selector, keccak256(callData), nonce, deadline
        ));

        return _propose(
            OperationType.AdminExecuteAdapter,
            callData,
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    function proposeUpdateLZAdapter(
        address newLZAdapter,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_UPDATE_LZ_ADAPTER_TYPEHASH, newLZAdapter, nonce, deadline
        ));

        return _propose(
            OperationType.UpdateLZAdapter,
            abi.encode(newLZAdapter),
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    function proposeDisableLZAdapter(
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_DISABLE_LZ_ADAPTER_TYPEHASH, nonce, deadline
        ));

        return _propose(
            OperationType.DisableLZAdapter,
            '',
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    // =========================================================================
    // Federation propose — RouteRegistry side
    // =========================================================================

    /// @inheritdoc IMultisigProxy
    function proposeSetRoute(
        uint256 sourceChainId,
        uint256 destChainId,
        bool    enabled,
        address finalityVerifier,
        address settlementModule,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_SET_ROUTE_TYPEHASH,
            sourceChainId, destChainId, enabled, finalityVerifier, settlementModule,
            nonce, deadline
        ));

        return _propose(
            OperationType.SetRoute,
            abi.encode(sourceChainId, destChainId, enabled, finalityVerifier, settlementModule),
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    function proposeUpdateRouteRegistry(
        address newRouteRegistry,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_UPDATE_ROUTE_REGISTRY_TYPEHASH, newRouteRegistry, nonce, deadline
        ));

        return _propose(
            OperationType.UpdateRouteRegistry,
            abi.encode(newRouteRegistry),
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    /// @dev Planned inflow-only pause: freezes deposits while leaving
    ///      withdrawals open (e.g. to migrate liquidity during an upgrade).
    ///      Runs through the timelocked propose -> execute path, so the
    ///      federation has an observation window. The emergency, no-timelock
    ///      freeze of BOTH paths is `emergencyPause` instead. Carries no payload.
    function proposePauseInflow(
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_PAUSE_INFLOW_TYPEHASH, nonce, deadline
        ));

        return _propose(
            OperationType.PauseInflow,
            '',
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    /// @inheritdoc IMultisigProxy
    /// @dev Resumes the inflow path, reversing `proposePauseInflow`. Timelocked.
    function proposeUnpauseInflow(
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            _PROPOSE_UNPAUSE_INFLOW_TYPEHASH, nonce, deadline
        ));

        return _propose(
            OperationType.UnpauseInflow,
            '',
            nonce, deadline, structHash, fedBitmap, fedSigs
        );
    }

    // =========================================================================
    // Cancel
    // =========================================================================

    /// @inheritdoc IMultisigProxy
    function cancelProposal(
        bytes32 proposalId,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external {
        if (block.timestamp > deadline) revert Expired();
        if (nonce != proposalNonce) revert InvalidNonce();

        Proposal storage p = _proposals[proposalId];
        if (p.status != ProposalStatus.Pending) revert NotPending();

        bytes32 digest = _hashTypedData(
            keccak256(abi.encode(_CANCEL_PROPOSAL_TYPEHASH, proposalId, nonce, deadline))
        );
        _verifySignatures(digest, fedBitmap, fedSigs, _federationSigners, federationThreshold);

        proposalNonce++;
        p.status = ProposalStatus.Cancelled;

        emit ProposalCancelled(proposalId);
    }

    // =========================================================================
    // Execute (Phase 2 — permissionless after timelock)
    // =========================================================================

    /// @inheritdoc IMultisigProxy
    function executeProposal(bytes32 proposalId, bytes calldata opData) external {
        Proposal storage p = _proposals[proposalId];
        if (p.status != ProposalStatus.Pending) revert NotPending();
        // Enforce the timelock that was in force when the proposal was created,
        // not the current one — a later SetTimelockDuration cannot reschedule.
        if (block.timestamp < p.proposedAt + p.timelockSnapshot) revert TimelockActive();
        if (block.timestamp > p.deadline) revert ProposalExpired();
        if (keccak256(opData) != p.dataHash) revert DataMismatch();

        p.status = ProposalStatus.Executed;

        _executeByType(p.opType, opData);

        emit ProposalExecuted(proposalId, p.opType);
    }

    // =========================================================================
    // View
    // =========================================================================

    /// @inheritdoc IMultisigProxy
    function verifyEnclaveSignature(
        uint256 sourceChainId,
        bytes32 digest,
        bytes calldata signature,
        uint256 signerIndex
    ) external view returns (bool) {
        address[] storage set = _enclaveSigners[sourceChainId];
        if (signerIndex >= set.length) revert IndexOutOfRange();
        address recovered = ECDSA.recover(digest, signature);
        return recovered == set[signerIndex];
    }


    /// @inheritdoc IMultisigProxy
    function getEnclaveSigners(uint256 sourceChainId) external view returns (address[] memory) {
        return _enclaveSigners[sourceChainId];
    }

    /// @inheritdoc IMultisigProxy
    function getEnclaveSourceChains() external view returns (uint256[] memory) {
        return _enclaveSourceChains;
    }

    /// @inheritdoc IMultisigProxy
    function getFederationSigners() external view returns (address[] memory) {
        return _federationSigners;
    }

    /// @inheritdoc IMultisigProxy
    function getProposal(bytes32 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }

    // =========================================================================
    // Internal — propose helper
    // =========================================================================

    /// @dev Common logic for all propose functions.
    function _propose(
        OperationType opType,
        bytes memory opData,
        uint256 nonce,
        uint256 deadline,
        bytes32 structHash,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) private returns (bytes32 proposalId) {
        if (block.timestamp > deadline) revert Expired();
        if (deadline > block.timestamp + MAX_PROPOSAL_LIFETIME) revert DeadlineTooFar();
        if (deadline < block.timestamp + timelockDuration) revert DeadlineBeforeTimelock();
        if (nonce != proposalNonce) revert InvalidNonce();

        bytes32 digest = _hashTypedData(structHash);
        _verifySignatures(digest, fedBitmap, fedSigs, _federationSigners, federationThreshold);

        proposalNonce++;

        bytes32 dataHash = keccak256(opData);
        proposalId = keccak256(abi.encode(opType, dataHash, nonce));

        if (_proposals[proposalId].status != ProposalStatus.None) revert ProposalExists();

        _proposals[proposalId] = Proposal({
            dataHash: dataHash,
            proposedAt: block.timestamp,
            deadline: deadline,
            timelockSnapshot: timelockDuration,
            opType: opType,
            status: ProposalStatus.Pending
        });

        emit ProposalCreated(proposalId, opType, opData, nonce, deadline, fedBitmap);
    }

    // =========================================================================
    // Internal — execute router
    // =========================================================================

    /// @dev Routes an executed proposal to the appropriate handler.
    function _executeByType(OperationType opType, bytes calldata opData) private {
        if (opType == OperationType.AdminExecute) {
            // opData = raw bridge callData
            (bool ok, bytes memory ret) = bridge.call(opData);
            _propagateRevert(ok, ret);

        } else if (opType == OperationType.UpdateEnclaveSigners) {
            (uint256 sourceChainId, address[] memory newSigners, uint256 newThreshold) =
                abi.decode(opData, (uint256, address[], uint256));
            if (sourceChainId == 0) revert UnknownSourceChain(0);
            if (newSigners.length == 0) revert NoSigners();
            _requireValidThreshold(newThreshold, newSigners.length);
            _validateSigners(newSigners);
            // Keep every trust domain independent: disjoint from the federation
            // and from every *other* enclave source chain (skip this chain, so a
            // partial rotation that keeps some of its own keys is allowed).
            _requireDisjoint(newSigners, _federationSigners);
            _requireDisjointFromAllEnclaveSets(newSigners, sourceChainId);

            // Register a brand-new source chain (bounded); existing ones just
            // overwrite their set/threshold.
            if (enclaveThreshold[sourceChainId] == 0) {
                if (_enclaveSourceChains.length >= MAX_ENCLAVE_SOURCE_CHAINS) {
                    revert TooManyEnclaveSourceChains(_enclaveSourceChains.length + 1, MAX_ENCLAVE_SOURCE_CHAINS);
                }
                _enclaveSourceChains.push(sourceChainId);
            }
            _enclaveSigners[sourceChainId] = newSigners;
            enclaveThreshold[sourceChainId] = newThreshold;
            emit EnclaveSignersUpdated(sourceChainId, newSigners, newThreshold);

        } else if (opType == OperationType.UpdateFederationSigners) {
            (address[] memory newSigners, uint256 newThreshold) = abi.decode(opData, (address[], uint256));
            if (newSigners.length == 0) revert NoSigners();
            _requireValidThreshold(newThreshold, newSigners.length);
            _validateSigners(newSigners);
            // Federation must stay disjoint from every enclave source-chain set.
            _requireDisjointFromAllEnclaveSets(newSigners, 0);
            _federationSigners = newSigners;
            federationThreshold = newThreshold;
            emit FederationSignersUpdated(newSigners, newThreshold);

        } else if (opType == OperationType.UpdateBridge) {
            address newBridge = abi.decode(opData, (address));
            if (newBridge == address(0)) revert ZeroBridge();
            address oldBridge = bridge;
            bridge = newBridge;
            emit BridgeAddressUpdated(oldBridge, newBridge);

        } else if (opType == OperationType.SetCommissionRecipient) {
            address newRecipient = abi.decode(opData, (address));
            if (newRecipient == address(0)) revert ZeroRecipient();
            address old = commissionRecipient;
            commissionRecipient = newRecipient;
            emit CommissionRecipientUpdated(old, newRecipient);

        } else if (opType == OperationType.SetTimelockDuration) {
            uint256 newDuration = abi.decode(opData, (uint256));
            if (newDuration < MIN_TIMELOCK) revert TimelockTooShort();
            if (newDuration >= MAX_PROPOSAL_LIFETIME) revert TimelockTooLong();
            timelockDuration = newDuration;
            emit TimelockDurationUpdated(newDuration);

        } else if (opType == OperationType.AdminExecuteCommissionManager) {
            // opData = raw CommissionManager callData. Enforce (again, at the
            // execution boundary) that this generic path cannot call a
            // withdrawal selector and re-point commission away from the pinned
            // `commissionRecipient`.
            _requireNotCommissionWithdrawSelector(_firstSelector(opData));
            (bool ok, bytes memory ret) = commissionManager.call(opData);
            _propagateRevert(ok, ret);

        } else if (opType == OperationType.AdminExecuteRouteRegistry) {
            // opData = raw RouteRegistry callData. Registry resolved from Bridge
            // (single source of truth), same as SetRoute. Enables ownership
            // migration (transferOwnership / acceptOwnership) for the Ownable2Step
            // RouteRegistry.
            address registry = IBridge(bridge).routeRegistry();
            if (registry == address(0)) revert ZeroTarget();
            (bool ok, bytes memory ret) = registry.call(opData);
            _propagateRevert(ok, ret);

        } else if (opType == OperationType.WithdrawTokenCommissionCM) {
            (address token, uint256 amount) = abi.decode(opData, (address, uint256));
            address recipient = commissionRecipient;
            (bool ok, bytes memory ret) = commissionManager.call(
                abi.encodeWithSignature(
                    'withdrawTokenCommission(address,address,uint256)',
                    token, recipient, amount
                )
            );
            _propagateRevert(ok, ret);
            emit CommissionWithdrawn(token, amount, recipient);

        } else if (opType == OperationType.WithdrawNativeCommissionCM) {
            uint256 amount = abi.decode(opData, (uint256));
            address recipient = commissionRecipient;
            (bool ok, bytes memory ret) = commissionManager.call(
                abi.encodeWithSignature(
                    'withdrawNativeCommission(address,uint256)',
                    recipient, amount
                )
            );
            _propagateRevert(ok, ret);
            emit NativeCommissionWithdrawn(amount, recipient);

        } else if (opType == OperationType.UpdateCommissionManager) {
            address newCm = abi.decode(opData, (address));
            if (newCm == address(0)) revert ZeroCommissionManager();
            address old = commissionManager;
            commissionManager = newCm;
            emit CommissionManagerUpdated(old, newCm);

        } else if (opType == OperationType.AdminExecuteAdapter) {
            // opData = raw LZAdapter callData. The adapter must be wired in
            // first via UpdateLZAdapter; a zero target closes the path.
            if (lzAdapter == address(0)) revert ZeroTarget();
            (bool ok, bytes memory ret) = lzAdapter.call(opData);
            _propagateRevert(ok, ret);

        } else if (opType == OperationType.UpdateLZAdapter) {
            address newAdapter = abi.decode(opData, (address));
            if (newAdapter == address(0)) revert InvalidLZAdapter();
            address oldAdapter = lzAdapter;
            lzAdapter = newAdapter;
            emit LZAdapterUpdated(oldAdapter, newAdapter);

        } else if (opType == OperationType.DisableLZAdapter) {
            address oldAdapter = lzAdapter;
            lzAdapter = address(0);
            emit LZAdapterDisabled(oldAdapter);

        } else if (opType == OperationType.SetRoute) {
            // Forwards to RouteRegistry, looked up dynamically from Bridge to
            // keep registry pointer as a single source of truth.
            (
                uint256 sourceChainId,
                uint256 destChainId,
                bool    enabled,
                address finalityVerifier,
                address settlementModule
            ) = abi.decode(opData, (uint256, uint256, bool, address, address));

            address registry = IBridge(bridge).routeRegistry();
            if (registry == address(0)) revert ZeroTarget();
            IRouteRegistry(registry).setRoute(
                sourceChainId, destChainId, enabled, finalityVerifier, settlementModule
            );

        } else if (opType == OperationType.UpdateRouteRegistry) {
            // Rotates Bridge's `routeRegistry` immutable-shaped slot. The new
            // registry MUST be deployed with Bridge's address as its
            // constructor `bridge_`; otherwise dispatcher calls revert
            // `NotBridge` and the route plane goes dark.
            address newRegistry = abi.decode(opData, (address));
            IBridge(bridge).setRouteRegistry(newRegistry);

        } else if (opType == OperationType.PauseInflow) {
            // Planned inflow-only freeze (no payload). Withdrawals stay open.
            (bool ok, bytes memory ret) = bridge.call(abi.encodeWithSignature('pauseInflow()'));
            _propagateRevert(ok, ret);

        } else if (opType == OperationType.UnpauseInflow) {
            (bool ok, bytes memory ret) = bridge.call(abi.encodeWithSignature('unpauseInflow()'));
            _propagateRevert(ok, ret);

        } else {
            revert UnknownOperationType();
        }
    }

    // =========================================================================
    // Internal — cryptography helpers
    // =========================================================================

    /// @notice EIP-712 domain separator for this contract on the current chain.
    /// @dev Returns the value cached at deploy while `block.chainid` is
    ///      unchanged; after a chain-id change it is rebuilt, so pre-fork
    ///      signatures are not valid on the forked chain (R-W-13).
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return _domainSeparator();
    }

    /// @dev Cached domain separator on the original chain; rebuilt on a fork.
    function _domainSeparator() private view returns (bytes32) {
        return block.chainid == _cachedChainId
            ? _cachedDomainSeparator
            : _buildDomainSeparator();
    }

    /// @dev Computes the EIP-712 domain separator over the current chain id.
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            _DOMAIN_TYPEHASH,
            keccak256('MultisigProxy'),
            keccak256('1'),
            block.chainid,
            address(this)
        ));
    }

    /// @dev Wraps a struct hash into a full EIP-712 digest.
    function _hashTypedData(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked('\x19\x01', _domainSeparator(), structHash));
    }

    /// @dev Verifies M-of-N bitmap signatures against the given signer set.
    function _verifySignatures(
        bytes32 digest,
        uint256 bitmap,
        bytes[] calldata sigs,
        address[] storage signerSet,
        uint256 threshold
    ) private view {
        uint256 signersLen = signerSet.length;

        if (bitmap >> signersLen != 0) revert BitmapOutOfRange();

        uint256 setBits = _popcount(bitmap);
        if (setBits < threshold) revert BelowThreshold();
        if (sigs.length != setBits) revert SigCountMismatch();

        uint256 sigIdx = 0;
        for (uint256 i = 0; i < signersLen; i++) {
            if (bitmap & (1 << i) != 0) {
                address recovered = ECDSA.recover(digest, sigs[sigIdx++]);
                if (recovered != signerSet[i]) revert InvalidSignature();
            }
        }
    }

    // =========================================================================
    // Internal — utility helpers
    // =========================================================================

    /// @dev Validates no zero addresses and no duplicates. O(n^2), fine for <20 signers.
    /// @dev Enforces the quorum policy shared by both signer sets (enclave and
    ///      federation), in the constructor and the signer-update handlers:
    ///        - at least 2 signers (no single-key set);
    ///        - threshold of at least 2 (no single signer can authorise alone);
    ///        - threshold a strict majority (`2 * threshold > n`), which rejects
    ///          1-of-N and any sub-majority quorum;
    ///        - threshold not exceeding the signer count.
    ///      The smallest valid sets are 2-of-2 and 2-of-3. This upholds the
    ///      spec invariant "one signer MUST NOT authorise fundsOut alone".
    function _requireValidThreshold(uint256 threshold, uint256 n) private pure {
        if (n < 2 || threshold < 2 || threshold > n || 2 * threshold <= n) {
            revert InvalidThreshold();
        }
    }

    /// @dev Reverts if any address in `candidate` also appears in `counterpart`.
    ///      Used to keep the enclave and federation signer sets disjoint so the
    ///      two trust domains stay independent (R-W-14). O(n*m), bounded by the
    ///      signer-set sizes.
    function _requireDisjoint(address[] memory candidate, address[] memory counterpart) private pure {
        for (uint256 i = 0; i < candidate.length; i++) {
            for (uint256 j = 0; j < counterpart.length; j++) {
                if (candidate[i] == counterpart[j]) revert SignerSetsOverlap(candidate[i]);
            }
        }
    }

    /// @dev Reverts if `candidate` overlaps any registered enclave source-chain
    ///      set, skipping `exceptSourceChain` (pass `0` to skip none). Used to
    ///      keep every enclave set disjoint from the others and from the
    ///      federation. Cost is bounded by `MAX_ENCLAVE_SOURCE_CHAINS` *
    ///      `MAX_SIGNERS` * candidate length.
    function _requireDisjointFromAllEnclaveSets(address[] memory candidate, uint256 exceptSourceChain) private view {
        uint256[] memory chains = _enclaveSourceChains;
        for (uint256 i = 0; i < chains.length; i++) {
            if (chains[i] == exceptSourceChain) continue;
            _requireDisjoint(candidate, _enclaveSigners[chains[i]]);
        }
    }

    function _validateSigners(address[] memory signers) private pure {
        // Bound the set before the O(N^2) duplicate scan below, and keep every
        // signer index within the uint256 signature bitmap (R-I-06).
        if (signers.length > MAX_SIGNERS) revert TooManySigners(signers.length, MAX_SIGNERS);
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == address(0)) revert ZeroAddressSigner();
            for (uint256 j = i + 1; j < signers.length; j++) {
                if (signers[i] == signers[j]) revert DuplicateSigner();
            }
        }
    }

    /// @dev EIP-712 array encoding for address[].
    function _hashAddressArray(address[] calldata arr) private pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            words[i] = bytes32(uint256(uint160(arr[i])));
        }
        return keccak256(abi.encodePacked(words));
    }

    function _popcount(uint256 x) private pure returns (uint256 count) {
        while (x != 0) {
            count += x & 1;
            x >>= 1;
        }
    }

    /// @dev Propagates a revert reason from a low-level call.
    function _propagateRevert(bool ok, bytes memory ret) private pure {
        if (!ok) {
            if (ret.length > 0) {
                assembly { revert(add(ret, 32), mload(ret)) }
            } else {
                revert CallFailed();
            }
        }
    }

    /// @dev First 4 bytes of `data` as a selector, or `0x00000000` if `data` is
    ///      shorter than a selector (such a payload can never be a withdrawal
    ///      call and the downstream raw call rejects it anyway).
    function _firstSelector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length >= SELECTOR_LENGTH) {
            assembly { selector := mload(add(data, 0x20)) }
        }
    }

    /// @dev Reverts if `selector` is one of the CommissionManager withdrawal
    ///      selectors, which the generic AdminExecuteCommissionManager path must
    ///      not reach (they bypass the pinned `commissionRecipient`).
    function _requireNotCommissionWithdrawSelector(bytes4 selector) private pure {
        if (
            selector == _SEL_WITHDRAW_TOKEN ||
            selector == _SEL_WITHDRAW_NATIVE ||
            selector == _SEL_WITHDRAW_ALL_TOKEN ||
            selector == _SEL_WITHDRAW_ALL_NATIVE
        ) {
            revert ForbiddenCommissionManagerSelector(selector);
        }
    }
}
