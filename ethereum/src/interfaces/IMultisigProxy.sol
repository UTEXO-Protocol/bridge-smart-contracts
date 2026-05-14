// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMultisigProxy
/// @notice Two-level ECDSA multisig proxy that owns the Bridge and the CommissionManager.
///
/// @dev ENCLAVE SIGNERS (TEE / Nitro Enclave)
///      Authorise routine value-transfer operations via `execute()` (single call to
///      Bridge) or `executeBatch()` (atomic multi-call to any allowlisted target,
///      e.g. Bridge.fundsOut + LZAdapter.sendOut for outbound RGB → non-Arbitrum).
///      Restricted to a configurable per-(target, selector) allowlist.
///      Uses per-selector nonces for `execute()` and a sequential `batchNonce` for
///      `executeBatch()`.
///
///      FEDERATION SIGNERS (governance / admin nodes)
///      All administrative operations go through a two-phase timelock:
///        Phase 1 — PROPOSE: federation signs, contract stores hash, emits full data.
///        Phase 2 — EXECUTE: after timelockDuration, anyone can call executeProposal().
///      Exception: emergencyPause / emergencyUnpause are instant (no timelock).
///
///      COMMISSION MANAGER
///      This proxy is the owner of the CommissionManager. Federation can reach CM via:
///        - typed `WithdrawTokenCommissionCM` / `WithdrawNativeCommissionCM`
///          (destination is always the stored `commissionRecipient`).
///        - generic `AdminExecuteCommissionManager` for rare config changes
///          (route rules, global defaults, mock rates, transferOwnership, …).
///        - `UpdateCommissionManager` to migrate to a redeployed CM.
///
///      BITMAP ENCODING
///      Bit i of bitmap corresponds to signers[i]. sigs[] in ascending bit order.
///
///      EIP-712 DOMAIN
///      name: "MultisigProxy"  version: "1"  chainId  verifyingContract
interface IMultisigProxy {

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroBridge();
    error ZeroCommissionManager();
    error NoSigners();
    error InvalidThreshold();
    error ZeroCommissionRecipient();
    error TimelockTooLong();
    error Expired();
    error CallDataTooShort();
    error CallNotAllowed(address target, bytes4 selector);
    error InvalidNonce();
    error NotPending();
    error TimelockActive();
    error ProposalExpired();
    error DataMismatch();
    error DeadlineTooFar();
    error ProposalExists();
    error IndexOutOfRange();
    error BitmapOutOfRange();
    error BelowThreshold();
    error SigCountMismatch();
    error InvalidSignature();
    error ZeroAddressSigner();
    error DuplicateSigner();
    error CallFailed();
    error UnknownOperationType();
    error ZeroRecipient();
    error ZeroTarget();
    error BatchEmpty();
    error BatchLengthMismatch();
    error BatchTooLarge();
    error BatchValueMismatch();

    // =========================================================================
    // Types
    // =========================================================================

    enum OperationType {
        AdminExecute,                    // 0  — generic call into Bridge
        UpdateEnclaveSigners,            // 1
        UpdateFederationSigners,         // 2
        UpdateBridge,                    // 3
        SetCommissionRecipient,          // 4
        SetTeeAllowedCall,               // 5  — (target, selector, allowed) entry in TEE allowlist
        SetTimelockDuration,             // 6
        AdminExecuteCommissionManager,   // 7  — generic call into CommissionManager
        WithdrawTokenCommissionCM,       // 8  — CM.withdrawTokenCommission -> commissionRecipient
        WithdrawNativeCommissionCM,      // 9  — CM.withdrawNativeCommission -> commissionRecipient
        UpdateCommissionManager,         // 10 — migrate to a new CommissionManager address
        AdminExecuteAdapter,             // 11 — generic call into LZAdapter (setTrustedEntrypoint, refundStuckFunds, …)
        UpdateLZAdapter                  // 12 — rotate the routing target for AdminExecuteAdapter
    }

    enum ProposalStatus { None, Pending, Executed, Cancelled }

    struct Proposal {
        bytes32 dataHash;
        uint256 proposedAt;
        uint256 deadline;
        OperationType opType;
        ProposalStatus status;
    }

    // =========================================================================
    // Events
    // =========================================================================

    // TEE
    event Executed(bytes4 indexed selector, uint256 nonce, uint256 enclaveBitmap);
    event BatchExecuted(uint256 indexed nonce, uint256 enclaveBitmap, address[] targets, bytes4[] selectors);

    // Federation proposals
    event ProposalCreated(
        bytes32 indexed proposalId,
        OperationType indexed opType,
        bytes operationData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap
    );
    event ProposalCancelled(bytes32 indexed proposalId);
    event ProposalExecuted(bytes32 indexed proposalId, OperationType indexed opType);

    // Federation emergency
    event EmergencyPaused(uint256 nonce, uint256 fedBitmap);
    event EmergencyUnpaused(uint256 nonce, uint256 fedBitmap);

    // Emitted when proposals are executed
    event EnclaveSignersUpdated(address[] newSigners, uint256 newThreshold);
    event FederationSignersUpdated(address[] newSigners, uint256 newThreshold);
    event BridgeAddressUpdated(address indexed oldBridge, address indexed newBridge);
    event CommissionManagerUpdated(address indexed oldCm, address indexed newCm);
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event CommissionRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event TeeAllowedCallUpdated(address indexed target, bytes4 indexed selector, bool allowed);
    event CommissionWithdrawn(address indexed token, uint256 amount, address indexed recipient);
    event NativeCommissionWithdrawn(uint256 amount, address indexed recipient);
    event TimelockDurationUpdated(uint256 newDuration);

    // =========================================================================
    // TEE-authorized
    // =========================================================================

    /// @notice Execute a Bridge call authorised by M-of-N enclave signatures.
    ///         Selector must be in the TEE allowlist for the Bridge target. Per-selector nonces.
    function execute(
        bytes calldata callData,
        uint256 nonce,
        uint256 deadline,
        uint256 enclaveBitmap,
        bytes[] calldata enclaveSigs
    ) external;

    /// @notice Execute multiple calls atomically, authorised by a single set of M-of-N
    ///         enclave signatures over the whole batch.
    /// @dev Each `(targets[i], selector(callDatas[i]))` must be in the TEE allowlist.
    ///      `sum(values) == msg.value`. Either all succeed or the batch reverts.
    ///      Uses sequential `batchNonce` for replay protection.
    function executeBatch(
        address[] calldata targets,
        bytes[] calldata callDatas,
        uint256[] calldata values,
        uint256 nonce,
        uint256 deadline,
        uint256 enclaveBitmap,
        bytes[] calldata enclaveSigs
    ) external payable;

    // =========================================================================
    // Federation instant (no timelock)
    // =========================================================================

    /// @notice Emergency pause the Bridge. Instant, no timelock.
    function emergencyPause(
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external;

    /// @notice Emergency unpause the Bridge. Instant, no timelock.
    function emergencyUnpause(
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external;

    // =========================================================================
    // Federation propose (Phase 1 — timelock)
    // =========================================================================

    /// @notice Propose an arbitrary Bridge call (forwarded via bridge.call).
    /// @dev opData = raw ABI-encoded bridge callData (selector + args).
    function proposeAdminExecute(
        bytes calldata callData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose replacing the enclave signer set.
    /// @dev opData = abi.encode(address[] newSigners, uint256 newThreshold)
    function proposeUpdateEnclaveSigners(
        address[] calldata newSigners,
        uint256 newThreshold,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose replacing the federation signer set.
    /// @dev opData = abi.encode(address[] newSigners, uint256 newThreshold)
    function proposeUpdateFederationSigners(
        address[] calldata newSigners,
        uint256 newThreshold,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose updating the Bridge address.
    /// @dev opData = abi.encode(address newBridge)
    function proposeUpdateBridge(
        address newBridge,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose changing the commission recipient (used as the destination for
    ///         all typed `WithdrawTokenCommissionCM` / `WithdrawNativeCommissionCM` ops).
    /// @dev opData = abi.encode(address newRecipient)
    function proposeSetCommissionRecipient(
        address newRecipient,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose adding/removing a TEE-allowed (target, selector) pair.
    /// @dev opData = abi.encode(address target, bytes4 selector, bool allowed)
    function proposeSetTeeAllowedCall(
        address target,
        bytes4 selector,
        bool allowed,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose changing the timelock duration.
    /// @dev opData = abi.encode(uint256 newDuration)
    function proposeSetTimelockDuration(
        uint256 newDuration,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    // --- CommissionManager-targeted operations ---

    /// @notice Propose an arbitrary call into the CommissionManager.
    /// @dev Used for rare configuration: setCommissionRule, setGlobalDefaults,
    ///      setMockTokenToNativeRate, setBridgeAddress, transferOwnership, …
    /// @dev opData = raw ABI-encoded CommissionManager callData (selector + args).
    function proposeAdminExecuteCommissionManager(
        bytes calldata callData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose an ERC-20 commission withdrawal from the CommissionManager
    ///         to the stored `commissionRecipient`.
    /// @dev opData = abi.encode(address token, uint256 amount)
    function proposeWithdrawTokenCommissionCM(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose a native commission withdrawal from the CommissionManager
    ///         to the stored `commissionRecipient`.
    /// @dev opData = abi.encode(uint256 amount)
    function proposeWithdrawNativeCommissionCM(
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose migrating to a new CommissionManager address.
    /// @dev opData = abi.encode(address newCommissionManager)
    function proposeUpdateCommissionManager(
        address newCommissionManager,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    // --- LZAdapter-targeted operations ---

    /// @notice Propose an arbitrary call into the LZAdapter (routes through the
    ///         stored `lzAdapter` address). Federation typically uses this for
    ///         `setTrustedEntrypoint`, `refundStuckFunds`, and any other
    ///         `onlyMultisigProxy`-gated adapter admin.
    /// @dev opData = raw ABI-encoded LZAdapter callData (selector + args).
    function proposeAdminExecuteAdapter(
        bytes calldata callData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose rotating the LZAdapter routing target stored on this proxy.
    /// @dev opData = abi.encode(address newLZAdapter). `address(0)` is allowed
    ///      and closes adapter-execute until set again.
    function proposeUpdateLZAdapter(
        address newLZAdapter,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    // =========================================================================
    // Cancel & Execute
    // =========================================================================

    /// @notice Cancel a pending proposal. Requires M-of-N federation signatures.
    function cancelProposal(
        bytes32 proposalId,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external;

    /// @notice Execute a proposal after the timelock has elapsed. Permissionless.
    /// @param proposalId The proposal to execute.
    /// @param opData     The same operation data that was provided at propose time.
    function executeProposal(bytes32 proposalId, bytes calldata opData) external;

    // =========================================================================
    // View
    // =========================================================================

    /// @notice Verify that `signature` over `digest` was produced by the enclave signer at `signerIndex`.
    function verifyEnclaveSignature(
        bytes32 digest,
        bytes calldata signature,
        uint256 signerIndex
    ) external view returns (bool);

    function getNonce(bytes4 selector) external view returns (uint256);
    function bridge() external view returns (address);
    function commissionManager() external view returns (address);
    function lzAdapter() external view returns (address);
    function getEnclaveSigners() external view returns (address[] memory);
    function enclaveThreshold() external view returns (uint256);
    function getFederationSigners() external view returns (address[] memory);
    function federationThreshold() external view returns (uint256);
    function commissionRecipient() external view returns (address);
    function teeAllowedCalls(address target, bytes4 selector) external view returns (bool);
    function batchNonce() external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function proposalNonce() external view returns (uint256);
    function timelockDuration() external view returns (uint256);
    function getProposal(bytes32 proposalId) external view returns (Proposal memory);
}
