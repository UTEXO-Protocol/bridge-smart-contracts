// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BridgeBaseUpgradeable} from "./BridgeBaseUpgradeable.sol";
import {IBridge} from "./interfaces/IBridge.sol";
import {ICommissionManager} from "./interfaces/ICommissionManager.sol";
import {IRouteRegistry} from "./interfaces/IRouteRegistry.sol";
import {FundsInContext, FundsOutContext} from "./interfaces/RouteTypes.sol";
import {OutflowRateLimiter} from "./libraries/OutflowRateLimiter.sol";
import {RollingOutflowLimiter} from "./libraries/RollingOutflowLimiter.sol";

/// @title Bridge
/// @notice Token custody, liquidity accounting and commission routing for the Arbitrum bridge.
/// @dev Runs behind BridgeProxy and is owned by MultisigProxy. RouteRegistry dispatches
///      finality and settlement checks. Direct deposits are public; adapter deposits
///      require the configured LayerZero adapter.
contract Bridge is BridgeBaseUpgradeable, IBridge, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using OutflowRateLimiter for OutflowRateLimiter.Bucket;
    using RollingOutflowLimiter for RollingOutflowLimiter.Window;

    /// @dev Immutable implementation identity used to reject compatibility
    ///      checks routed through another proxy. Immutables do not consume
    ///      proxy storage or affect the upgrade storage layout.
    address private immutable _IMPLEMENTATION_SELF = address(this);

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Maximum byte length of deposit destinations, release sources and both rebalance
    ///         addresses.
    uint256 public constant MAX_ADDRESS_LENGTH = 512;

    /// @notice Maximum byte length of a release or rebalance proof.
    /// @dev The current RGB proof encodes four 32-byte values (128 bytes).
    uint256 public constant MAX_PROOF_LENGTH = 1024;

    /// @notice Maximum byte length of deposit settlement data.
    /// @dev RGB deposits encode `(uint256 rgbOpId, uint64 beforeBlock)` in 64 bytes.
    uint256 public constant MAX_SETTLEMENT_DATA_IN_LENGTH = 128;

    /// @notice Maximum byte length of each release or rebalance settlement payload.
    /// @dev One dynamic bytes32 array encodes as 64 + 32 * n bytes; 90,000 bytes
    ///      allows up to 2,810 RGB record ids and bounds module processing.
    uint256 public constant MAX_SETTLEMENT_DATA_OUT_LENGTH = 90_000;

    /// @notice Basis-point denominator for outflow policies, safety limits and native-fee
    ///         tolerance.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Native commission tolerance in basis points.
    /// @dev Direct deposits accept quote to quote + 5% and refund excess.
    ///      Adapter deposits accept ±5% and collect the supplied value without a refund.
    uint256 public constant NATIVE_COMMISSION_TOLERANCE_BPS = 500;

    /// @notice Minimum rolling interval covered by the immutable safety
    ///         limiter. The bounded ring implementation retains usage for
    ///         24-25 hours, never less than this value.
    uint256 public constant OUTFLOW_SAFETY_WINDOW = 24 hours;

    /// @notice A source chain can move at most 20% of its reference liquidity
    ///         during one rolling safety window. Compile-time constant: neither
    ///         federation governance nor the enclave lane can raise it.
    uint256 public constant MAX_CHAIN_OUTFLOW_BPS = 2_000;

    /// @notice Physical token outflow across all source chains can consume at
    ///         most 20% of global reference TVL during one rolling safety
    ///         window. Compile-time constant and independent of configurable
    ///         token-bucket settings.
    uint256 public constant MAX_GLOBAL_OUTFLOW_BPS = 2_000;

    /// @notice Share units representing 100% of the liquidity reference.
    uint256 public constant SHARE_UNIT = 1e18;

    /// @notice Window over which a bucket's `refillBpsPerWindow` accrues in
    ///         full. Compile-time constant: federation cannot shorten it to
    ///         make allowance return faster.
    uint256 public constant BUCKET_REFILL_WINDOW = 24 hours;

    /// @notice Domain separator for non-RGB deposit identifiers; not an EIP-712 digest.
    bytes32 public constant FUNDS_IN_OPERATION_TYPEHASH = keccak256(
        "UtexoFundsInOperation(address bridge,uint256 sourceChainId,bytes32 sourceSender,uint256 senderNonce,address token,uint256 grossAmount,uint256 destinationChainId,bytes32 destinationAddressHash,bytes32 settlementDataHash,uint256 chainId)"
    );

    /// @notice RGB backing identity derived only from a mint and pinned config.
    /// @dev Both deposits and rebalances into RGB use this formula,
    ///      so the mint has one backing record.
    bytes32 public constant RGB_MINT_DEPOSIT_TYPEHASH = keccak256(
        "UtexoRgbMintDeposit(address bridge,uint256 chainId,address token,uint256 rgbNetwork,uint256 rgbOpId,uint256 netAmount)"
    );

    /// @notice Type hash for the replay key shared by releases and rebalances.
    /// @dev Excludes destination, recipient, proof and settlement data so changing them
    ///      cannot create a second replay key for the same canonical burn intent.
    bytes32 public constant BURN_TYPEHASH = keccak256(
        "UtexoBurnId(address bridge,uint256 chainId,address token,uint256 amount,uint256 sourceChainId,bytes32 sourceAddressHash,bytes32 sourceBurnTxId)"
    );

    /// @notice Type hash for non-RGB rebalance credit identifiers.
    /// @dev Includes the burnId to distinguish credits backed by different source burns.
    bytes32 public constant REBALANCE_OPERATION_TYPEHASH = keccak256(
        "UtexoRebalanceOperation(address bridge,uint256 sourceChainId,bytes32 sourceSender,address token,uint256 amount,uint256 destinationChainId,bytes32 destinationAddressHash,bytes32 settlementDataInHash,uint256 burnId,uint256 chainId)"
    );

    /// @inheritdoc IBridge
    /// @dev Mutable so federation can migrate to a redeployed manager through
    ///      the typed, timelocked `UpdateCommissionManager` governance op.
    ICommissionManager public override commissionManager;

    /// @inheritdoc IBridge
    /// @dev Mutable so federation can rotate registry deployments via
    ///      `UpdateRouteRegistry` governance op without redeploying the
    ///      Bridge.
    address public override routeRegistry;

    /// @inheritdoc IBridge
    address public override lzAdapter;

    /// @notice Set of Bridge-derived burn identifiers already consumed by a
    ///         successful `fundsOut` or `rebalanceLiquidity`. Both paths use the
    ///         same `BURN_TYPEHASH` and field set, so the same canonical source
    ///         burn derives the same id on either path and can settle only once.
    mapping(uint256 burnId => bool consumed) public consumedBurnIds;

    /// @notice Per-`(sourceChainId, sourceSender)` monotonic nonce. Folded into
    ///         non-RGB `operationId` so otherwise-identical deposits from the same
    ///         sender still produce distinct ids. Incremented once per successful
    ///         `fundsIn`; a downstream revert rolls the increment back.
    mapping(uint256 sourceChainId => mapping(bytes32 sourceSender => uint256 nonce)) public sourceSenderNonces;

    /// @notice Accounted liquidity available to each remote network.
    /// @dev Deposits credit their destination; releases debit their source. Rebalances
    ///      move liquidity between buckets without moving tokens. A debit cannot exceed
    ///      its source bucket's current allocation.
    mapping(uint256 chainId => uint256 locked) public lockedLiquidity;

    /// @notice Total accounted bridge liquidity across all isolated chain
    ///         buckets. Direct token donations are deliberately excluded so
    ///         they cannot inflate the immutable global safety allowance.
    ///         `fundsIn` increases it, `fundsOut` decreases it and
    ///         `rebalanceLiquidity` preserves it.
    uint256 public totalLockedLiquidity;

    /// @notice Per-source-chain limiter consumed by releases and rebalances.
    /// @dev Raw bucket values are shares; `availableOutflow` returns token units.
    mapping(uint256 chainId => OutflowRateLimiter.Bucket) public chainBuckets;

    /// @notice Aggregate limiter for physical releases across all source chains.
    /// @dev Caps aggregate releases if a shared TEE is compromised across source chains.
    ///      Raw bucket values are shares; `availableGlobalOutflow` returns token units.
    OutflowRateLimiter.Bucket public globalBucket;

    /// @dev Immutable-security rolling usage. Federation-configurable token
    ///      buckets may only make outflow stricter; these windows cannot be
    ///      reconfigured or disabled.
    mapping(uint256 chainId => RollingOutflowLimiter.Window) private _chainSafetyWindows;
    RollingOutflowLimiter.Window private _globalSafetyWindow;

    /// @inheritdoc IBridge
    /// @dev Non-zero minimum configured at initialization and adjustable by the owner.
    uint256 public override minFundsInAmount;

    /// @inheritdoc IBridge
    /// @dev Non-zero release minimum; must not exceed minFundsInAmount.
    uint256 public override minFundsOutAmount;

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev Restricts a function to the configured `lzAdapter`. Until
    ///      federation sets a non-zero adapter, the modifier closes the
    ///      function for every caller.
    modifier onlyLZAdapter() {
        if (msg.sender != lzAdapter) revert NotLZAdapter();
        _;
    }

    /// @inheritdoc IBridge
    function bridgeProxyCompatibilityUUID() external view override returns (bytes32) {
        if (address(this) != _IMPLEMENTATION_SELF) revert ProxyCompatibilityCheckMustBeDirect();
        return keccak256("utexo.bridge.proxy.compatibility.v1");
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Atomically initializes proxy storage for the first Bridge implementation.
    /// @dev Must be supplied as BridgeProxy constructor calldata; it can execute only once.
    ///      Amount floors must be non-zero with the inbound floor at least the outbound floor.
    function initialize(
        address usdt0_,
        address routeRegistry_,
        address payable commissionManager_,
        address lzAdapter_,
        uint256 minFundsInAmount_,
        uint256 minFundsOutAmount_,
        address initialOwner_
    ) external override initializer {
        __BridgeBaseUpgradeable_init(usdt0_, initialOwner_);

        if (routeRegistry_ == address(0)) revert InvalidRouteRegistryAddress();
        if (commissionManager_ == address(0)) revert InvalidCommissionManagerAddress();
        if (minFundsInAmount_ == 0) revert InvalidMinFundsInAmount();
        if (minFundsOutAmount_ == 0) revert InvalidMinFundsOutAmount();
        if (minFundsInAmount_ < minFundsOutAmount_) {
            revert InvalidAmountFloors(minFundsInAmount_, minFundsOutAmount_);
        }

        routeRegistry = routeRegistry_;
        commissionManager = ICommissionManager(commissionManager_);
        lzAdapter = lzAdapter_;
        minFundsInAmount = minFundsInAmount_;
        minFundsOutAmount = minFundsOutAmount_;
    }

    // =========================================================================
    // External — admin
    // =========================================================================

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation governance gates this call
    ///      on its M-of-N timelock flow. Rotation only — rejects `address(0)`
    ///      so an accidental zero cannot silently close the path; use
    ///      `disableLZAdapter` for an explicit, separately-logged shutdown.
    function setLZAdapter(address newAdapter) external override onlyOwner {
        if (newAdapter == address(0)) revert InvalidLZAdapter();
        address old = lzAdapter;
        lzAdapter = newAdapter;
        emit LZAdapterUpdated(old, newAdapter);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`. Explicit disable, emitting
    ///      `LZAdapterDisabled` so monitoring can tell a shutdown from a
    ///      rotation.
    function disableLZAdapter() external override onlyOwner {
        address old = lzAdapter;
        lzAdapter = address(0);
        emit LZAdapterDisabled(old);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its M-of-N
    ///      timelock flow via `proposeUpdateRouteRegistry`.
    function setRouteRegistry(address newRouteRegistry) external override onlyOwner {
        if (newRouteRegistry == address(0) || newRouteRegistry.code.length == 0) revert InvalidRouteRegistryAddress();
        address old = routeRegistry;
        routeRegistry = newRouteRegistry;
        emit RouteRegistryUpdated(old, newRouteRegistry);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; its typed `UpdateCommissionManager`
    ///      operation updates this pointer and the proxy's own target atomically.
    ///      Validate deployed code and the live Bridge binding at execution.
    function setCommissionManager(address newCommissionManager) external override onlyOwner {
        if (newCommissionManager.code.length == 0) revert InvalidCommissionManagerAddress();
        if (ICommissionManager(payable(newCommissionManager)).bridgeAddress() != address(this)) {
            revert InvalidCommissionManagerAddress();
        }
        address old = address(commissionManager);
        commissionManager = ICommissionManager(payable(newCommissionManager));
        emit CommissionManagerUpdated(old, newCommissionManager);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its M-of-N
    ///      timelock flow (generic `proposeAdminExecute` -> execute). Must be
    ///      non-zero: a non-zero floor is what rejects zero-amount and dust
    ///      deposits on the inbound path. Must be at least the current outbound floor.
    function setMinFundsInAmount(uint256 newMinimum) external override onlyOwner {
        if (newMinimum == 0) revert InvalidMinFundsInAmount();
        if (newMinimum < minFundsOutAmount) revert InvalidAmountFloors(newMinimum, minFundsOutAmount);
        uint256 old = minFundsInAmount;
        minFundsInAmount = newMinimum;
        emit MinFundsInAmountUpdated(old, newMinimum);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its M-of-N
    ///      timelock flow (generic `proposeAdminExecute` -> execute). Must be
    ///      non-zero and no higher than the current inbound floor.
    function setMinFundsOutAmount(uint256 newMinimum) external override onlyOwner {
        if (newMinimum == 0) revert InvalidMinFundsOutAmount();
        if (newMinimum > minFundsInAmount) revert InvalidAmountFloors(minFundsInAmount, newMinimum);
        uint256 old = minFundsOutAmount;
        minFundsOutAmount = newMinimum;
        emit MinFundsOutAmountUpdated(old, newMinimum);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its timelock flow.
    ///      Validation is liquidity-independent, so a policy can be installed
    ///      before any deposit exists — including at deployment.
    function setOutflowLimit(uint256 chainId, uint256 burstBps, uint256 refillBpsPerWindow)
        external
        override
        onlyOwner
    {
        if (chainId == 0) revert InvalidOutflowLimit();
        _validateOutflowBps(burstBps, refillBpsPerWindow, MAX_CHAIN_OUTFLOW_BPS);

        OutflowRateLimiter.Settings memory cfg = _buildOutflowConfig(burstBps, refillBpsPerWindow);
        OutflowRateLimiter.validate(cfg, false);
        chainBuckets[chainId].configurePrimed(cfg);
        emit OutflowLimitUpdated(chainId, burstBps, refillBpsPerWindow, chainBuckets[chainId].tokens);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its timelock flow.
    function setGlobalOutflowLimit(uint256 burstBps, uint256 refillBpsPerWindow) external override onlyOwner {
        _validateOutflowBps(burstBps, refillBpsPerWindow, MAX_GLOBAL_OUTFLOW_BPS);

        OutflowRateLimiter.Settings memory cfg = _buildOutflowConfig(burstBps, refillBpsPerWindow);
        OutflowRateLimiter.validate(cfg, false);
        globalBucket.configurePrimed(cfg);
        emit GlobalOutflowLimitUpdated(burstBps, refillBpsPerWindow, globalBucket.tokens);
    }

    /// @inheritdoc IBridge
    function availableOutflow(uint256 chainId) external view override returns (uint256) {
        uint256 shares = OutflowRateLimiter.currentState(chainBuckets[chainId]).tokens;
        return _fromShares(shares, lockedLiquidity[chainId]);
    }

    /// @inheritdoc IBridge
    function availableGlobalOutflow() external view override returns (uint256) {
        uint256 shares = OutflowRateLimiter.currentState(globalBucket).tokens;
        return _fromShares(shares, totalLockedLiquidity);
    }

    /// @inheritdoc IBridge
    function availableChainSafetyOutflow(uint256 chainId) external view override returns (uint256) {
        uint256 spent = _chainSafetyWindows[chainId].current();
        return _remainingSafetyAllowance(lockedLiquidity[chainId] + spent, spent, MAX_CHAIN_OUTFLOW_BPS);
    }

    /// @inheritdoc IBridge
    function availableGlobalSafetyOutflow() external view override returns (uint256) {
        uint256 spent = _globalSafetyWindow.current();
        return _remainingSafetyAllowance(totalLockedLiquidity + spent, spent, MAX_GLOBAL_OUTFLOW_BPS);
    }

    /// @inheritdoc IBridge
    function chainOutflowReference(uint256 chainId) external view override returns (uint256) {
        return lockedLiquidity[chainId];
    }

    /// @inheritdoc IBridge
    function globalOutflowReference() external view override returns (uint256) {
        return totalLockedLiquidity;
    }

    /// @inheritdoc IBridge
    function effectiveAvailableOutflow(uint256 chainId) external view override returns (uint256) {
        uint256 chainSpent = _chainSafetyWindows[chainId].current();
        uint256 chainLiquidity = lockedLiquidity[chainId];
        uint256 chainSafetyRef = chainLiquidity + chainSpent;
        uint256 globalSpent = _globalSafetyWindow.current();
        uint256 globalLiquidity = totalLockedLiquidity;
        uint256 globalSafetyRef = globalLiquidity + globalSpent;

        uint256 allowed = chainLiquidity;
        allowed = Math.min(
            allowed, _fromShares(OutflowRateLimiter.currentState(chainBuckets[chainId]).tokens, chainLiquidity)
        );
        allowed = Math.min(allowed, _fromShares(OutflowRateLimiter.currentState(globalBucket).tokens, globalLiquidity));
        allowed = Math.min(allowed, _remainingSafetyAllowance(chainSafetyRef, chainSpent, MAX_CHAIN_OUTFLOW_BPS));
        allowed = Math.min(allowed, _remainingSafetyAllowance(globalSafetyRef, globalSpent, MAX_GLOBAL_OUTFLOW_BPS));
        return allowed;
    }

    // =========================================================================
    // External — user-facing
    // =========================================================================

    /// @inheritdoc IBridge
    function fundsIn(
        uint256 amount,
        uint256 destinationChainId,
        string calldata destinationAddress,
        bytes calldata settlementData
    ) external payable override whenNotPaused nonReentrant returns (bytes32 operationId) {
        // Direct deposits can refund native surplus to the caller.
        address caller = _msgSender();
        operationId = _fundsIn(
            caller,
            _toSourceSender(caller),
            amount,
            block.chainid,
            destinationChainId,
            destinationAddress,
            settlementData,
            true
        );
    }

    /// @inheritdoc IBridge
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string calldata destinationAddress,
        bytes calldata settlementData
    ) external payable override whenNotPaused nonReentrant onlyLZAdapter returns (bytes32 operationId) {
        // The adapter authenticates the source sender and forwards the user's native payment.
        // The payer is on the source chain, so no refund is sent to the adapter.
        operationId = _fundsIn(
            _msgSender(),
            sourceSender,
            amount,
            sourceChainId,
            destinationChainId,
            destinationAddress,
            settlementData,
            false
        );
    }

    // =========================================================================
    // External — owner-only (called via MultisigProxy)
    // =========================================================================

    /// @inheritdoc IBridge
    function fundsOut(FundsOutParams calldata fundsOutParams)
        external
        override
        onlyOwner
        nonReentrant
        whenOutflowNotPaused
    {
        _validateFundsOutParams(fundsOutParams);

        // Consume the burn before external calls; a revert restores it.
        if (consumedBurnIds[fundsOutParams.burnId]) revert BurnIdAlreadyConsumed(fundsOutParams.burnId);
        consumedBurnIds[fundsOutParams.burnId] = true;

        // Debit gross source-chain liquidity before calling external contracts.
        uint256 srcLiquidity = lockedLiquidity[fundsOutParams.sourceChainId];
        if (fundsOutParams.amount > srcLiquidity) {
            revert InsufficientChainLiquidity(fundsOutParams.sourceChainId, fundsOutParams.amount, srcLiquidity);
        }

        lockedLiquidity[fundsOutParams.sourceChainId] = srcLiquidity - fundsOutParams.amount;
        uint256 totalLiquidity = totalLockedLiquidity;
        totalLockedLiquidity = totalLiquidity - fundsOutParams.amount;

        // Buckets use pre-debit liquidity; rolling limits also include active usage.
        uint256 chainSpent = _chainSafetyWindows[fundsOutParams.sourceChainId].current();
        uint256 chainSafetyReference = srcLiquidity + chainSpent;
        uint256 globalSpent = _globalSafetyWindow.current();
        uint256 globalSafetyReference = totalLiquidity + globalSpent;

        // Charge per-chain and global buckets in shares. Unconfigured buckets reject releases.
        chainBuckets[fundsOutParams.sourceChainId].spend(_toShares(fundsOutParams.amount, srcLiquidity), TOKEN);
        globalBucket.spend(_toShares(fundsOutParams.amount, totalLiquidity), address(0));

        // Releases charge only token commission. Enforce conservation here
        // independently of the replaceable manager's quote implementation.
        (uint256 tokenCommission,, uint256 netAmount) = commissionManager.calculateFundsOutCommission(
            fundsOutParams.sourceChainId, fundsOutParams.destinationChainId, TOKEN, fundsOutParams.amount
        );

        // Equivalent to tokenCommission + netAmount == amount, without risking
        // overflow on an invalid quote from a replacement manager.
        if (tokenCommission > fundsOutParams.amount || netAmount != fundsOutParams.amount - tokenCommission) {
            revert CommissionConservationBroken();
        }
        if (netAmount == 0) revert ZeroNetAmount();

        // Verify finality before invoking the settlement module.
        IRouteRegistry(routeRegistry)
            .beforeFundsOut(
                FundsOutContext({
                token: TOKEN,
                recipient: fundsOutParams.recipient,
                amount: fundsOutParams.amount,
                burnId: fundsOutParams.burnId,
                sourceChainId: fundsOutParams.sourceChainId,
                destChainId: fundsOutParams.destinationChainId,
                sourceAddress: fundsOutParams.sourceAddress,
                isRebalance: false,
                sourceBurnTxId: fundsOutParams.sourceBurnTxId
            }),
                fundsOutParams.proof,
                fundsOutParams.settlementData
            );

        // Charge both rolling safety limits; failure reverts all preceding updates.
        _consumeChainSafetyOutflow(
            fundsOutParams.sourceChainId, chainSpent, chainSafetyReference, fundsOutParams.amount
        );
        _consumeGlobalSafetyOutflow(globalSpent, globalSafetyReference, fundsOutParams.amount);

        // Forward token commission to the CommissionManager pool.
        if (tokenCommission != 0) _forwardTokenCommission(tokenCommission);

        // Deliver the net amount to the recipient.
        IERC20(TOKEN).safeTransfer(fundsOutParams.recipient, netAmount);

        emit BridgeFundsOut(
            fundsOutParams.recipient,
            fundsOutParams.amount,
            netAmount,
            tokenCommission,
            fundsOutParams.burnId,
            fundsOutParams.sourceChainId,
            fundsOutParams.destinationChainId,
            fundsOutParams.sourceAddress,
            fundsOutParams.settlementData
        );
    }

    /// @inheritdoc IBridge
    /// @dev No token transfer or commission. Both settlement hooks use the same route.
    ///      Consumes source-chain outflow allowance, but not global outflow allowance.
    function rebalanceLiquidity(RebalanceParams calldata params)
        external
        override
        onlyOwner
        nonReentrant
        whenOutflowNotPaused
    {
        _validateRebalanceParams(params);

        // Pass the source-address hash to settlement and non-RGB credit-id derivation.
        // Rebalances consume a burn id rather than a deposit sender nonce.
        bytes32 sourceSender = _hashCalldataString(params.sourceAddress);

        // Enclaves must derive every burnId field canonically and never attest a second
        // intent for the same source burn; the replay key is shared with fundsOut.
        uint256 expectedBurnId = _deriveRebalanceBurnId(params);
        if (params.burnId != expectedBurnId) revert InvalidBurnId(params.burnId, expectedBurnId);
        if (consumedBurnIds[params.burnId]) revert BurnIdAlreadyConsumed(params.burnId);
        consumedBurnIds[params.burnId] = true;

        // Debit leg: the migration may only draw from the liquidity locked for
        // its source chain — identical to the `fundsOut` solvency rule.
        uint256 srcLiquidity = lockedLiquidity[params.sourceChainId];
        if (params.amount > srcLiquidity) {
            revert InsufficientChainLiquidity(params.sourceChainId, params.amount, srcLiquidity);
        }

        lockedLiquidity[params.sourceChainId] = srcLiquidity - params.amount;

        // Rebalances spend source-chain allowance only: no tokens leave custody.
        uint256 chainSpent = _chainSafetyWindows[params.sourceChainId].current();
        uint256 chainSafetyReference = srcLiquidity + chainSpent;
        chainBuckets[params.sourceChainId].spend(_toShares(params.amount, srcLiquidity), TOKEN);

        // Debit-leg verification: route verifier (view-only source proof)
        // first, then the settlement module's release check. `recipient` is
        // this Bridge — the backing never leaves custody.
        IRouteRegistry(routeRegistry)
            .beforeFundsOut(
                FundsOutContext({
                token: TOKEN,
                recipient: address(this),
                amount: params.amount,
                burnId: params.burnId,
                sourceChainId: params.sourceChainId,
                destChainId: params.destinationChainId,
                sourceAddress: params.sourceAddress,
                isRebalance: true,
                sourceBurnTxId: params.sourceBurnTxId
            }),
                params.proof,
                params.settlementDataOut
            );

        // Derive the credit id and record the destination settlement.
        bytes32 operationId = IRouteRegistry(routeRegistry)
            .usesRgbMintDepositId(params.sourceChainId, params.destinationChainId)
            ? rgbMintDepositId(params.destinationChainId, _decodeRgbOpId(params.settlementDataIn), params.amount)
            : _deriveRebalanceOperationId(params, sourceSender, expectedBurnId);
        uint256 rgbOpId = IRouteRegistry(routeRegistry)
            .onFundsIn(
                FundsInContext({
                token: TOKEN,
                sender: _msgSender(),
                sourceSender: sourceSender,
                grossAmount: params.amount,
                netAmount: params.amount,
                operationId: operationId,
                senderNonce: 0, // rebalance consumes no nonce stream; id is nonce-free
                sourceChainId: params.sourceChainId,
                destChainId: params.destinationChainId,
                destAddress: params.destinationAddress
            }),
                params.settlementDataIn
            );

        lockedLiquidity[params.destinationChainId] += params.amount;

        // Rebalance moves release capacity away from the source chain and
        // therefore consumes the same immutable per-chain safety allowance as a
        // physical release. It intentionally does not consume global allowance:
        // no token leaves custody, and the eventual fundsOut will consume it.
        // Kept after route validation so route-specific errors retain priority;
        // a safety-limit revert rolls the complete rebalance back atomically.
        _consumeChainSafetyOutflow(params.sourceChainId, chainSpent, chainSafetyReference, params.amount);

        // RGB-only correlation event, same contract as `_fundsIn`: the RGB
        // listener authorizes a mint against `FundsIn` and needs no awareness
        // of the rebalance mechanics.
        if (rgbOpId != 0) _emitRgbFundsIn(_msgSender(), rgbOpId, params.amount);
        emit BridgeRebalance(
            operationId,
            params.burnId,
            params.sourceChainId,
            params.destinationChainId,
            params.amount,
            params.sourceAddress,
            params.destinationAddress,
            params.settlementDataOut,
            params.settlementDataIn
        );
    }

    /// @notice Always reverts; ownership cannot be renounced.
    function renounceOwnership() public view override(BridgeBaseUpgradeable, IBridge) onlyOwner {
        revert RenounceOwnershipBlocked();
    }

    // =========================================================================
    // Internal
    // =========================================================================

    /// @dev Emit the RGB compatibility event without silently truncating an
    ///      EVM-native `uint256` token amount to RGB's `u64` amount range.
    function _emitRgbFundsIn(address sender, uint256 rgbOpId, uint256 amount) private {
        if (amount > type(uint64).max) revert AmountExceedsUint64(amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit FundsIn(sender, rgbOpId, uint64(amount));
    }

    function _validateFundsOutParams(FundsOutParams calldata params) private view {
        if (params.amount == 0) revert ZeroAmount();
        if (params.amount < minFundsOutAmount) revert AmountBelowMinimum(params.amount, minFundsOutAmount);
        if (params.recipient == address(0)) revert InvalidRecipientAddress();
        if (params.sourceChainId == 0) revert InvalidSourceChainId();
        if (params.destinationChainId == 0) revert InvalidDestinationChainId();
        if (params.sourceBurnTxId == bytes32(0)) revert ZeroSourceBurnTxId();

        uint256 sourceAddressLength = bytes(params.sourceAddress).length;
        if (sourceAddressLength > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(sourceAddressLength, MAX_ADDRESS_LENGTH);
        }
        if (params.proof.length > MAX_PROOF_LENGTH) revert ProofTooLong(params.proof.length, MAX_PROOF_LENGTH);
        if (params.settlementData.length > MAX_SETTLEMENT_DATA_OUT_LENGTH) {
            revert SettlementDataTooLong(params.settlementData.length, MAX_SETTLEMENT_DATA_OUT_LENGTH);
        }
        if (params.amount > IERC20(TOKEN).balanceOf(address(this))) revert AmountExceedBridgePool();

        uint256 expectedBurnId = _deriveBurnId(params);
        if (params.burnId != expectedBurnId) revert InvalidBurnId(params.burnId, expectedBurnId);
    }

    function _validateRebalanceParams(RebalanceParams calldata params) private view {
        if (params.amount == 0) revert ZeroAmount();
        if (params.sourceChainId == 0) revert InvalidSourceChainId();
        if (params.destinationChainId == 0 || params.destinationChainId == block.chainid) {
            revert InvalidDestinationChainId();
        }
        if (params.sourceChainId == params.destinationChainId) revert RebalanceSameChain(params.sourceChainId);
        if (params.sourceBurnTxId == bytes32(0)) revert ZeroSourceBurnTxId();

        uint256 sourceAddressLength = bytes(params.sourceAddress).length;
        if (sourceAddressLength > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(sourceAddressLength, MAX_ADDRESS_LENGTH);
        }
        uint256 destinationAddressLength = bytes(params.destinationAddress).length;
        if (destinationAddressLength > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(destinationAddressLength, MAX_ADDRESS_LENGTH);
        }
        if (params.proof.length > MAX_PROOF_LENGTH) revert ProofTooLong(params.proof.length, MAX_PROOF_LENGTH);
        if (params.settlementDataOut.length > MAX_SETTLEMENT_DATA_OUT_LENGTH) {
            revert SettlementDataTooLong(params.settlementDataOut.length, MAX_SETTLEMENT_DATA_OUT_LENGTH);
        }
        if (params.settlementDataIn.length > MAX_SETTLEMENT_DATA_OUT_LENGTH) {
            revert SettlementDataTooLong(params.settlementDataIn.length, MAX_SETTLEMENT_DATA_OUT_LENGTH);
        }
    }

    /// @dev Canonical credit-leg `operationId` for a rebalance. Mirrors
    ///      `_deriveOperationId` under a distinct type hash (no nonce) and folds
    ///      in the validated `burnId`, so a rebalance id can never collide with a
    ///      deposit id, is unique per rebalance intent (even when only the debit
    ///      side differs), and the backend can precompute it from the intent
    ///      alone. `burnId` is passed in already validated against the params.
    function _deriveRebalanceOperationId(RebalanceParams calldata params, bytes32 sourceSender, uint256 burnId)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                REBALANCE_OPERATION_TYPEHASH,
                address(this),
                params.sourceChainId,
                sourceSender,
                TOKEN,
                params.amount,
                params.destinationChainId,
                _hashCalldataString(params.destinationAddress),
                _hashCalldataBytes(params.settlementDataIn),
                burnId,
                block.chainid
            )
        );
    }

    /// @dev Converts basis-point policy to bucket shares and per-second refill.
    ///      Refill rounds down; validated policy values fit uint128.
    function _buildOutflowConfig(uint256 burstBps, uint256 refillBpsPerWindow)
        private
        pure
        returns (OutflowRateLimiter.Settings memory)
    {
        uint256 capacityShares = Math.mulDiv(burstBps, SHARE_UNIT, BPS_DENOMINATOR);
        uint256 rateShares = Math.mulDiv(refillBpsPerWindow, SHARE_UNIT, BPS_DENOMINATOR) / BUCKET_REFILL_WINDOW;
        return OutflowRateLimiter.Settings({
            isEnabled: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            capacity: uint128(capacityShares),
            // forge-lint: disable-next-line(unsafe-typecast)
            rate: uint128(rateShares)
        });
    }

    /// @dev Shared body for both `fundsIn` overloads. Derives the canonical
    ///      `operationId` on-chain (never caller-supplied) and returns it.
    /// @param from                   EVM caller tokens are pulled from (user, or adapter).
    /// @param sourceSender           Original source-chain sender bound into `operationId`.
    function _fundsIn(
        address from,
        bytes32 sourceSender,
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes calldata settlementData,
        bool refundNativeSurplus
    ) private returns (bytes32 operationId) {
        if (amount < minFundsInAmount) {
            revert AmountBelowMinimum(amount, minFundsInAmount);
        }
        if (bytes(destinationAddress).length > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(bytes(destinationAddress).length, MAX_ADDRESS_LENGTH);
        }
        if (settlementData.length > MAX_SETTLEMENT_DATA_IN_LENGTH) {
            revert SettlementDataTooLong(settlementData.length, MAX_SETTLEMENT_DATA_IN_LENGTH);
        }
        if (sourceChainId == 0) revert InvalidSourceChainId();
        if (destinationChainId == 0) revert InvalidDestinationChainId();

        // Quote on the requested amount; derive net liquidity from the actual token receipt.
        (uint256 tokenCommission, uint256 nativeCommission,) =
            commissionManager.calculateFundsInCommission(sourceChainId, destinationChainId, TOKEN, amount);

        // Direct deposits pay the quote and receive a surplus refund.
        // Adapter deposits pay the full supplied value within the symmetric tolerance.
        // A zero native quote requires zero msg.value.
        uint256 nativeToCollect;
        if (nativeCommission == 0) {
            if (msg.value != 0) revert NativeValueMismatch();
        } else {
            uint256 minimum;
            if (refundNativeSurplus) {
                minimum = nativeCommission;
                nativeToCollect = nativeCommission;
            } else {
                minimum = Math.mulDiv(
                    nativeCommission,
                    BPS_DENOMINATOR - NATIVE_COMMISSION_TOLERANCE_BPS,
                    BPS_DENOMINATOR,
                    Math.Rounding.Ceil
                );
                nativeToCollect = msg.value;
            }
            uint256 maximum =
                Math.mulDiv(nativeCommission, BPS_DENOMINATOR + NATIVE_COMMISSION_TOLERANCE_BPS, BPS_DENOMINATOR);
            if (msg.value < minimum || msg.value > maximum) {
                revert NativeCommissionOutOfBounds(msg.value, minimum, maximum);
            }
        }

        // Increment the event nonce for all deposits; only non-RGB ids include it.
        FundsInContext memory ctx = FundsInContext({
            token: TOKEN,
            sender: from,
            sourceSender: sourceSender,
            grossAmount: amount,
            netAmount: 0, // set below from the ACTUAL received amount
            operationId: bytes32(0), // derived after actual netAmount is known
            senderNonce: sourceSenderNonces[sourceChainId][sourceSender]++,
            sourceChainId: sourceChainId,
            destChainId: destinationChainId,
            destAddress: destinationAddress
        });
        // Measure custody received to account for transfer fees.
        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));
        IERC20(TOKEN).safeTransferFrom(from, address(this), amount);
        uint256 received = IERC20(TOKEN).balanceOf(address(this)) - balanceBefore;

        // Require positive net tokens after commission, including for transfer-fee tokens.
        if (received <= tokenCommission) revert InsufficientReceived(received, tokenCommission);
        ctx.netAmount = received - tokenCommission;

        // Forward commission before hooks so token-balance reads exclude that fee.
        if (tokenCommission != 0) _forwardTokenCommission(tokenCommission);

        // Resolve identity after commission callbacks, immediately before the
        // record write.
        ctx.operationId = _deriveOperationId(ctx, settlementData);

        // Record the deposit and obtain the optional RGB event id.
        uint256 rgbOpId = IRouteRegistry(routeRegistry).onFundsIn(ctx, settlementData);

        // Credit only the net tokens retained by Bridge.
        lockedLiquidity[destinationChainId] += ctx.netAmount;
        totalLockedLiquidity += ctx.netAmount;

        // Forward the accepted native fee; refund any direct-deposit surplus below.
        if (nativeToCollect != 0) {
            (bool ok,) = address(commissionManager).call{value: nativeToCollect}("");
            if (!ok) revert NativeValueMismatch();
        }

        // RGB-only correlation event: emitted only when the route module
        // returned a non-zero external id (the RGB OpId). Other routes skip it.
        if (rgbOpId != 0) _emitRgbFundsIn(ctx.sender, rgbOpId, ctx.netAmount);
        emit BridgeFundsIn(
            ctx.operationId,
            ctx.sourceSender,
            ctx.sender,
            ctx.senderNonce,
            ctx.grossAmount,
            ctx.netAmount,
            tokenCommission,
            nativeToCollect, // native commission actually credited to the pool
            ctx.sourceChainId,
            ctx.destChainId,
            ctx.destAddress,
            settlementData
        );

        // Refund after state updates so the recipient observes settled accounting.
        uint256 surplus = msg.value - nativeToCollect;
        if (surplus != 0) {
            (bool refunded,) = payable(from).call{value: surplus}("");
            if (!refunded) revert NativeRefundFailed(from, surplus);
        }

        operationId = ctx.operationId;
    }

    /// @dev Left-pads an EVM address into the `bytes32` source-sender encoding
    ///      used by `operationId` derivation and the LZ overload.
    function _toSourceSender(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    /// @dev Transfers commission and credits only the recipient's measured balance increase.
    ///      Excludes prior donations and accounts for transfer fees.
    function _forwardTokenCommission(uint256 amount) private {
        address cm = address(commissionManager);
        uint256 balBefore = IERC20(TOKEN).balanceOf(cm);
        IERC20(TOKEN).safeTransfer(cm, amount);
        uint256 credited = IERC20(TOKEN).balanceOf(cm) - balBefore;
        commissionManager.receiveTokenCommission(TOKEN, credited);
    }

    /// @dev Charges against pre-debit liquidity plus active usage. For releases alone,
    ///      `locked + spent` stays constant while entries remain in the window,
    ///      preventing repeated small releases from shrinking the reference geometrically.
    function _consumeChainSafetyOutflow(uint256 chainId, uint256 spent, uint256 refLiquidity, uint256 amount) private {
        uint256 limit = _safetyLimit(refLiquidity, MAX_CHAIN_OUTFLOW_BPS);
        if (spent + amount > limit) revert ChainSafetyLimitExceeded(chainId, amount, spent, limit);

        uint256 updatedSpent = _chainSafetyWindows[chainId].consume(amount);
        emit ChainSafetyOutflowConsumed(chainId, amount, updatedSpent, limit);
    }

    /// @dev Consume immutable aggregate rolling allowance for physical token
    ///      outflow. Rebalances do not call this function.
    function _consumeGlobalSafetyOutflow(uint256 spent, uint256 refLiquidity, uint256 amount) private {
        uint256 limit = _safetyLimit(refLiquidity, MAX_GLOBAL_OUTFLOW_BPS);
        if (spent + amount > limit) revert GlobalSafetyLimitExceeded(amount, spent, limit);

        uint256 updatedSpent = _globalSafetyWindow.consume(amount);
        emit GlobalSafetyOutflowConsumed(amount, updatedSpent, limit);
    }

    /// @dev Requires positive burst and refill whose sum does not exceed maxBps.
    ///      Validation is independent of current liquidity.
    function _validateOutflowBps(uint256 burstBps, uint256 refillBpsPerWindow, uint256 maxBps) private pure {
        if (
            burstBps == 0 || refillBpsPerWindow == 0 || burstBps > maxBps || refillBpsPerWindow > maxBps
                || burstBps + refillBpsPerWindow > maxBps
        ) {
            revert InvalidOutflowPolicy(burstBps, refillBpsPerWindow, maxBps);
        }
    }

    /// @dev Convert a token amount to bucket shares of `reference`. Rounds up so
    ///      a release can never be cheaper in shares than its true fraction of
    ///      the reference, and so dust cannot pass for free.
    function _toShares(uint256 amount, uint256 refLiquidity) private pure returns (uint256) {
        if (refLiquidity == 0) revert ZeroOutflowReference();
        return Math.mulDiv(amount, SHARE_UNIT, refLiquidity, Math.Rounding.Ceil);
    }

    /// @dev Convert bucket shares back to token units for the public views.
    function _fromShares(uint256 shares, uint256 refLiquidity) private pure returns (uint256) {
        return Math.mulDiv(shares, refLiquidity, SHARE_UNIT);
    }

    function _remainingSafetyAllowance(uint256 refLiquidity, uint256 spent, uint256 maxBps)
        private
        pure
        returns (uint256)
    {
        uint256 limit = _safetyLimit(refLiquidity, maxBps);
        return spent < limit ? limit - spent : 0;
    }

    function _safetyLimit(uint256 refLiquidity, uint256 maxBps) private pure returns (uint256) {
        return Math.mulDiv(refLiquidity, maxBps, BPS_DENOMINATOR);
    }

    /// @inheritdoc IBridge
    function rgbMintDepositId(uint256 rgbNetwork, uint256 rgbOpId, uint256 netAmount)
        public
        view
        override
        returns (bytes32)
    {
        return keccak256(
            abi.encode(RGB_MINT_DEPOSIT_TYPEHASH, address(this), block.chainid, TOKEN, rgbNetwork, rgbOpId, netAmount)
        );
    }

    function _decodeRgbOpId(bytes calldata settlementData) private pure returns (uint256 rgbOpId) {
        (rgbOpId,) = abi.decode(settlementData, (uint256, uint64));
        if (rgbOpId == 0) revert InvalidRgbOpId();
    }

    /// @dev RGB ids bind the mint and actual net amount; all other routes retain
    ///      the sender/nonce/gross-amount formula. The route module chooses the
    ///      mode before the record is written. ctx.operationId is ignored.
    function _deriveOperationId(FundsInContext memory ctx, bytes calldata settlementData)
        private
        view
        returns (bytes32)
    {
        if (IRouteRegistry(routeRegistry).usesRgbMintDepositId(ctx.sourceChainId, ctx.destChainId)) {
            return rgbMintDepositId(ctx.destChainId, _decodeRgbOpId(settlementData), ctx.netAmount);
        }
        return keccak256(
            abi.encode(
                FUNDS_IN_OPERATION_TYPEHASH,
                address(this),
                ctx.sourceChainId,
                ctx.sourceSender,
                ctx.senderNonce,
                TOKEN,
                ctx.grossAmount,
                ctx.destChainId,
                keccak256(bytes(ctx.destAddress)),
                keccak256(settlementData),
                block.chainid
            )
        );
    }

    /// @dev Canonical `burnId` = domain-separated hash of the settlement intent.
    ///      Identical formula for both paths — see `BURN_TYPEHASH`.
    function _deriveBurnId(FundsOutParams calldata params) private view returns (uint256) {
        return _deriveBurnIdFromFields(params.amount, params.sourceChainId, params.sourceAddress, params.sourceBurnTxId);
    }

    /// @dev Rebalance uses the same formula. Both settlement blobs are excluded:
    ///      selecting other backing records cannot create a new replay key.
    function _deriveRebalanceBurnId(RebalanceParams calldata params) private view returns (uint256) {
        return _deriveBurnIdFromFields(params.amount, params.sourceChainId, params.sourceAddress, params.sourceBurnTxId);
    }

    /// @dev The source address is hashed over its raw bytes (never its ABI
    ///      encoding), matching EIP-712 treatment of dynamic types. An empty
    ///      value therefore hashes to
    ///      `0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`,
    ///      not to `bytes32(0)`. Off-chain signers must reproduce this exactly.
    function _deriveBurnIdFromFields(
        uint256 amount,
        uint256 sourceChainId,
        string calldata sourceAddress,
        bytes32 sourceBurnTxId
    ) private view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    BURN_TYPEHASH,
                    address(this),
                    block.chainid,
                    TOKEN,
                    amount,
                    sourceChainId,
                    _hashCalldataString(sourceAddress),
                    sourceBurnTxId
                )
            )
        );
    }

    function _hashCalldataString(string calldata value) private pure returns (bytes32 result) {
        // memory-safe: allocates above the free memory pointer and advances it.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, value.offset, value.length)
            result := keccak256(ptr, value.length)
            mstore(0x40, add(ptr, and(add(value.length, 0x3f), not(0x1f))))
        }
    }

    function _hashCalldataBytes(bytes calldata value) private pure returns (bytes32 result) {
        // memory-safe: allocates above the free memory pointer and advances it.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, value.offset, value.length)
            result := keccak256(ptr, value.length)
            mstore(0x40, add(ptr, and(add(value.length, 0x3f), not(0x1f))))
        }
    }
}
