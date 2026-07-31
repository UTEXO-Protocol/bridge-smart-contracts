// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "./IBridge.sol";

/// @title IMultisigProxy
/// @notice Two-level ECDSA multisig proxy that owns the Bridge and the CommissionManager.
///
/// @dev ENCLAVE SIGNERS (TEE / Nitro Enclave)
///      Authorise releases through two purpose-built, typed methods — there is
///      no generic call dispatch, so the enclave path can never reach a
///      privileged setter:
///        - `fundsOutCall`   — a single `Bridge.fundsOut` (RGB → Arbitrum);
///        - `lzFundsOutCall`  — `Bridge.fundsOut` to the LZ adapter then
///          `adapter.sendOut`, with the two legs bound on-chain (RGB → non-Arbitrum).
///      Each source chain has its own `teeNonce` lane, selected by the
///      release's `sourceChainId`, for per-network replay protection.
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
///          (CM always pays its immutable `commissionRecipient`).
///        - generic `AdminExecuteCommissionManager` for rare config changes
///          (route rules, global defaults, mock rates, ownership migration, …).
///          Withdrawal selectors are reserved for the typed operations.
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
    error TimelockTooLong();
    error TimelockTooShort();
    error InvalidMinTimelock();
    error Expired();
    error CallDataTooShort();
    error InvalidNonce();
    error NotPending();
    error TimelockActive();
    error ProposalExpired();
    error DataMismatch();
    error DeadlineTooFar();
    error DeadlineBeforeTimelock();
    error ProposalExists();
    error IndexOutOfRange();
    error BitmapOutOfRange();
    error BelowThreshold();
    error SigCountMismatch();
    error InvalidSignature();
    error ZeroAddressSigner();
    error DuplicateSigner();
    error SignerSetsOverlap(address signer);
    error TooManySigners(uint256 count, uint256 max);
    error UnknownSourceChain(uint256 sourceChainId);
    error TooManyEnclaveSourceChains(uint256 count, uint256 max);
    error CallFailed();
    error UnknownOperationType();
    error ZeroTarget();
    error ForbiddenCommissionManagerSelector(bytes4 selector);
    error ForbiddenBridgeReleaseSelector(bytes4 selector);
    error LZAdapterNotSet();
    error InvalidLZAdapter();

    // =========================================================================
    // Types
    // =========================================================================

    enum OperationType {
        AdminExecute, // 0  — generic call into Bridge
        UpdateEnclaveSigners, // 1  — replace the enclave signer set + threshold
        UpdateFederationSigners, // 2  — replace the federation signer set + threshold
        UpdateBridge, // 3  — repoint the owned Bridge address
        SetTimelockDuration, // 4  — change the governance timelock (>= MIN_TIMELOCK)
        AdminExecuteCommissionManager, // 5  — generic call into CommissionManager
        WithdrawTokenCommissionCM, // 6  — CM.withdrawTokenCommission -> immutable recipient
        WithdrawNativeCommissionCM, // 7  — CM.withdrawNativeCommission -> immutable recipient
        UpdateCommissionManager, // 8  — migrate to a new CommissionManager address
        AdminExecuteAdapter, // 9 — generic call into LZAdapter (setTrustedEntrypoint, refundStuckFunds, …)
        UpdateLZAdapter, // 10 — rotate the routing target for AdminExecuteAdapter
        SetRoute, // 11 — RouteRegistry.setRoute(src, dst, enabled, verifier, module)
        UpdateRouteRegistry, // 12 — Bridge.setRouteRegistry(newRouteRegistry)
        PauseInflow, // 13 — Bridge.pauseInflow()  (planned inflow-only freeze, timelocked)
        UnpauseInflow, // 14 — Bridge.unpauseInflow()
        DisableLZAdapter, // 15 — clear the routing target (explicit disable, distinct from UpdateLZAdapter rotation)
        AdminExecuteRouteRegistry // 16 — generic call into RouteRegistry (transferOwnership/acceptOwnership, setRoute, …)
    }

    enum ProposalStatus {
        None,
        Pending,
        Executed,
        Cancelled
    }

    /// @notice Business parameters for `lzFundsOut`, bundled to keep the call
    ///         within stack limits. Signed as the EIP-712 `TeeLzFundsOut` struct
    ///         (these fields plus `nonce` and `deadline`).
    struct LzFundsOutParams {
        uint256 amount;
        uint256 burnId;
        uint256 sourceChainId;
        uint256 destinationChainId;
        string sourceAddress;
        bytes proof;
        bytes settlementData;
        uint32 dstEid;
        bytes32 recipient;
        uint256 minAmountLD;
        bytes extraOptions;
    }

    struct Proposal {
        bytes32 dataHash;
        uint256 proposedAt;
        uint256 deadline;
        uint256 timelockSnapshot;
        OperationType opType;
        ProposalStatus status;
    }

    // =========================================================================
    // Events
    // =========================================================================

    // TEE — typed enclave releases
    event FundsOutExecuted(uint256 indexed sourceChainId, uint256 indexed nonce, uint256 enclaveBitmap);
    event RebalanceExecuted(
        uint256 indexed sourceChainId, uint256 indexed destinationChainId, uint256 nonce, uint256 enclaveBitmap
    );
    event LzFundsOutExecuted(
        uint256 indexed sourceChainId,
        uint256 indexed nonce,
        uint256 enclaveBitmap,
        uint32 dstEid,
        bytes32 recipient,
        uint256 amount
    );

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
    event EnclaveSignersUpdated(uint256 indexed sourceChainId, address[] newSigners, uint256 newThreshold);
    event FederationSignersUpdated(address[] newSigners, uint256 newThreshold);
    event BridgeAddressUpdated(address indexed oldBridge, address indexed newBridge);
    event CommissionManagerUpdated(address indexed oldCm, address indexed newCm);
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event LZAdapterDisabled(address indexed oldAdapter);
    event CommissionWithdrawn(address indexed token, uint256 amount, address indexed recipient);
    event NativeCommissionWithdrawn(uint256 amount, address indexed recipient);
    event TimelockDurationUpdated(uint256 newDuration);

    // =========================================================================
    // TEE-authorized
    // =========================================================================

    /// @notice Typed enclave release: authorise `Bridge.fundsOut` with M-of-N
    ///         enclave signatures over the release parameters. The only call this
    ///         makes is `Bridge.fundsOut` — there is no generic dispatch, so the
    ///         enclave path can never reach a privileged setter.
    function fundsOutCall(
        IBridge.FundsOutParams calldata params,
        uint256 nonce,
        uint256 deadline,
        uint256 enclaveBitmap,
        bytes[] calldata enclaveSigs
    ) external;

    /// @notice Typed enclave rebalance: authorise `Bridge.rebalanceLiquidity`
    ///         with M-of-N signatures from the SOURCE chain's enclave set (it
    ///         attests the funds left that chain). The only call this makes is
    ///         `Bridge.rebalanceLiquidity` — no generic dispatch. Shares the
    ///         per-source-chain `teeNonce` stream with `fundsOutCall` /
    ///         `lzFundsOutCall`.
    function rebalanceCall(
        IBridge.RebalanceParams calldata params,
        uint256 nonce,
        uint256 deadline,
        uint256 enclaveBitmap,
        bytes[] calldata enclaveSigs
    ) external;

    /// @notice Typed Flow-4 enclave release: release to the LZ adapter and bridge
    ///         onward in one signed operation. The Bridge recipient is forced to
    ///         `lzAdapter` and the amount sent out equals the balance the adapter
    ///         actually received, so the release and the cross-chain send are
    ///         bound on-chain. `msg.value` funds the LayerZero native fee.
    function lzFundsOutCall(
        LzFundsOutParams calldata params,
        uint256 nonce,
        uint256 deadline,
        uint256 enclaveBitmap,
        bytes[] calldata enclaveSigs
    ) external payable;

    // =========================================================================
    // Federation instant (no timelock)
    // =========================================================================

    /// @notice Emergency pause the Bridge. Instant, no timelock.
    function emergencyPause(uint256 nonce, uint256 deadline, uint256 fedBitmap, bytes[] calldata fedSigs) external;

    /// @notice Emergency unpause the Bridge. Instant, no timelock.
    function emergencyUnpause(uint256 nonce, uint256 deadline, uint256 fedBitmap, bytes[] calldata fedSigs) external;

    // =========================================================================
    // Federation propose (Phase 1 — timelock)
    // =========================================================================

    /// @notice Propose a permitted administrative Bridge call (forwarded via
    ///         `bridge.call`).
    /// @dev `Bridge.fundsOut` and `Bridge.rebalanceLiquidity` are forbidden:
    ///      value-moving operations must use the typed enclave-authorized
    ///      `fundsOutCall`, `lzFundsOutCall`, or `rebalanceCall` entrypoints.
    /// @dev opData = raw ABI-encoded bridge callData (selector + args).
    function proposeAdminExecute(
        bytes calldata callData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose replacing (or registering) the enclave signer set for a
    ///         given source chain. A `sourceChainId` with no set yet is
    ///         registered on execution (bounded by `MAX_ENCLAVE_SOURCE_CHAINS`).
    /// @dev opData = abi.encode(uint256 sourceChainId, address[] newSigners, uint256 newThreshold)
    function proposeUpdateEnclaveSigners(
        uint256 sourceChainId,
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

    /// @notice Propose a permitted generic call into the CommissionManager.
    /// @dev Used for rare configuration: setCommissionRule, setGlobalDefaults,
    ///      setMockTokenToNativeRate, setBridgeAddress, transferOwnership, …
    ///      Withdrawal selectors are reserved for the typed operations.
    /// @dev opData = raw ABI-encoded CommissionManager callData (selector + args).
    function proposeAdminExecuteCommissionManager(
        bytes calldata callData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    // --- RouteRegistry-targeted operations ---

    /// @notice Propose an arbitrary call into the RouteRegistry (resolved from
    ///         Bridge). Enables ownership migration (`transferOwnership` /
    ///         `acceptOwnership`) now that RouteRegistry is `Ownable2Step`,
    ///         alongside the dedicated `SetRoute` op.
    /// @dev opData = raw ABI-encoded RouteRegistry callData (selector + args).
    function proposeAdminExecuteRouteRegistry(
        bytes calldata callData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose an ERC-20 commission withdrawal from the CommissionManager.
    ///         The CM pays its immutable `commissionRecipient`.
    /// @dev opData = abi.encode(address token, uint256 amount)
    function proposeWithdrawTokenCommissionCM(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose a native commission withdrawal from the CommissionManager.
    ///         The CM pays its immutable `commissionRecipient`.
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
    /// @dev opData = abi.encode(address newLZAdapter). Reverts `InvalidLZAdapter`
    ///      on `address(0)` — use `proposeDisableLZAdapter` to close the path.
    function proposeUpdateLZAdapter(
        address newLZAdapter,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose clearing the LZAdapter routing target stored on this proxy
    ///         (explicit disable, emits `LZAdapterDisabled` — distinct from a
    ///         rotation via `proposeUpdateLZAdapter`).
    /// @dev opData is empty.
    function proposeDisableLZAdapter(uint256 nonce, uint256 deadline, uint256 fedBitmap, bytes[] calldata fedSigs)
        external
        returns (bytes32);

    /// @notice Propose registering or updating a route in the Bridge's
    ///         RouteRegistry.
    /// @dev opData = abi.encode(uint256 sourceChainId, uint256 destChainId,
    ///      bool enabled, address finalityVerifier, address settlementModule).
    ///      The proxy forwards the call to
    ///      `IRouteRegistry(bridge.routeRegistry()).setRoute(...)`.
    ///      Both plugin addresses MUST be non-zero — registry rejects
    ///      `address(0)`; routes that need no proof/settlement use the
    ///      explicit `NullVerifier` / `NullSettlementModule` deployments.
    function proposeSetRoute(
        uint256 sourceChainId,
        uint256 destChainId,
        bool enabled,
        address finalityVerifier,
        address settlementModule,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose rotating the RouteRegistry pointer on Bridge.
    /// @dev opData = abi.encode(address newRouteRegistry). The new registry
    ///      MUST be deployed with this Bridge's address as its `bridge_`
    ///      immutable — otherwise dispatcher calls from Bridge revert
    ///      `NotBridge` and inbound/outbound traffic on every route
    ///      simultaneously breaks.
    function proposeUpdateRouteRegistry(
        address newRouteRegistry,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap,
        bytes[] calldata fedSigs
    ) external returns (bytes32);

    /// @notice Propose a planned inflow-only pause on Bridge (`pauseInflow`).
    /// @dev Freezes deposits while leaving withdrawals open — intended for a
    ///      bridge upgrade / liquidity migration. Runs through the timelocked
    ///      propose -> execute path. For an immediate freeze of BOTH paths use
    ///      `emergencyPause`. Carries no payload (opData is empty).
    function proposePauseInflow(uint256 nonce, uint256 deadline, uint256 fedBitmap, bytes[] calldata fedSigs)
        external
        returns (bytes32);

    /// @notice Propose resuming the inflow path on Bridge (`unpauseInflow`).
    /// @dev Reverses `proposePauseInflow`. Timelocked. Carries no payload.
    function proposeUnpauseInflow(uint256 nonce, uint256 deadline, uint256 fedBitmap, bytes[] calldata fedSigs)
        external
        returns (bytes32);

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

    /// @notice Verify that `signature` over `digest` was produced by the enclave
    ///         signer at `signerIndex` for the given `sourceChainId` set.
    function verifyEnclaveSignature(
        uint256 sourceChainId,
        bytes32 digest,
        bytes calldata signature,
        uint256 signerIndex
    ) external view returns (bool);

    function teeNonce(uint256 sourceChainId) external view returns (uint256);
    function bridge() external view returns (address);
    function commissionManager() external view returns (address);
    function lzAdapter() external view returns (address);
    function getEnclaveSigners(uint256 sourceChainId) external view returns (address[] memory);
    function getEnclaveSourceChains() external view returns (uint256[] memory);
    function enclaveThreshold(uint256 sourceChainId) external view returns (uint256);
    function getFederationSigners() external view returns (address[] memory);
    function federationThreshold() external view returns (uint256);
    /// @notice Immutable recipient reported by the current CommissionManager.
    function commissionRecipient() external view returns (address);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function proposalNonce() external view returns (uint256);

    function emergencyNonce() external view returns (uint256);
    function timelockDuration() external view returns (uint256);
    function MIN_TIMELOCK() external view returns (uint256);
    function getProposal(bytes32 proposalId) external view returns (Proposal memory);
}
