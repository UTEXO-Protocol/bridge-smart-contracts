// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 }            from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 }         from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { ReentrancyGuard }   from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import { BridgeBase }         from './BridgeBase.sol';
import { IBridge }            from './interfaces/IBridge.sol';
import { ICommissionManager } from './interfaces/ICommissionManager.sol';
import { IRouteRegistry }     from './interfaces/IRouteRegistry.sol';
import { FundsInContext, FundsOutContext } from './interfaces/RouteTypes.sol';
import { OutflowRateLimiter } from './libraries/OutflowRateLimiter.sol';

/// @title Bridge
/// @notice Production bridge for locking USDT0 on Arbitrum and unlocking it
///         back. Extends BridgeBase with full event data for the UTEXO
///         backend and routes commission to a standalone CommissionManager so
///         protocol fees are held separately from bridge liquidity.
///
/// @dev - Owner is `MultisigProxy`. `fundsOut` is called via
///        `MultisigProxy.execute()` (TEE M-of-N).
///      - Route-specific finality verification and per-route settlement
///        accounting (RGB `fundsInRecords` etc.) live behind the
///        `RouteRegistry` dispatcher in dedicated plugin contracts. Bridge
///        only owns: token custody, the common derived `burnId` replay guard,
///        and commission routing.
///      - `fundsIn` has two overloads:
///        • Public 5-arg: any EVM user on this chain can lock tokens; the
///          source chain id is filled with `block.chainid`.
///        • Adapter-only 6-arg: callable only by the trusted `lzAdapter`,
///          which forwards a non-spoofable `sourceChainId` carried in
///          `composeMsg` from the source chain. Both overloads share the
///          same private body via `_fundsIn`.
///      - `lzAdapter` is mutable so federation governance can rotate adapter
///        deployments without redeploying the Bridge.
contract Bridge is BridgeBase, IBridge, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using OutflowRateLimiter for OutflowRateLimiter.Bucket;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Upper bound on the `destinationAddress` (fundsIn) and
    ///         `sourceAddress` (fundsOut) byte length. These strings are echoed
    ///         into event logs, so an unbounded value would let a caller inflate
    ///         log-storage and indexer cost. 512 bytes covers every supported
    ///         destination representation (RGB invoices and other chains) with
    ///         ample headroom.
    uint256 public constant MAX_ADDRESS_LENGTH = 512;

    /// @notice Upper bound on the `fundsOut` `proof` byte length. `proof` is
    ///         forwarded to the route verifier, so an unbounded blob would let a
    ///         release inflate calldata + verifier gas. 1024 bytes comfortably
    ///         fits the verifier formats (RGB is 64 bytes today; a future SPV
    ///         inclusion proof stays well under this).
    uint256 public constant MAX_PROOF_LENGTH = 1024;

    /// @notice Domain-separated type hash for the on-chain `operationId`
    ///         derivation. Binds the id to this contract, the deposit context
    ///         and a formula version, so ids cannot collide across deployments
    ///         or a future formula revision. Not an EIP-712 signing digest —
    ///         it is an internal, unsigned domain separator for the id hash.
    bytes32 public constant FUNDS_IN_OPERATION_TYPEHASH = keccak256(
        'UtexoFundsInOperation(address bridge,uint256 sourceChainId,bytes32 sourceSender,uint256 senderNonce,address token,uint256 grossAmount,uint256 destinationChainId,bytes32 destinationAddressHash,bytes32 settlementDataHash,uint256 chainId)'
    );

    /// @notice Domain-separated type hash for the `fundsOut` replay key.
    ///         Binds common release intent fields to this Bridge deployment and
    ///         formula version, including the exact verifier proof the enclave
    ///         signed for the release.
    bytes32 public constant FUNDS_OUT_BURN_ID_TYPEHASH = keccak256(
        'UtexoFundsOutBurnId(address bridge,uint256 chainId,address token,address recipient,uint256 amount,uint256 sourceChainId,uint256 destinationChainId,bytes32 sourceAddressHash,bytes32 proofHash,bytes32 settlementDataHash)'
    );

    /// @notice CommissionManager that receives and custodies protocol fees.
    ICommissionManager public immutable commissionManager;

    /// @inheritdoc IBridge
    /// @dev Mutable so federation can rotate registry deployments via
    ///      `UpdateRouteRegistry` governance op without redeploying the
    ///      Bridge.
    address public override routeRegistry;

    /// @inheritdoc IBridge
    address public override lzAdapter;

    /// @notice Set of Bridge-derived burn identifiers already consumed by a
    ///         successful `fundsOut`.
    mapping(uint256 burnId => bool consumed) public consumedBurnIds;

    /// @notice Per-`(sourceChainId, sourceSender)` monotonic nonce. Folded into
    ///         `operationId` so two otherwise-identical deposits from the same
    ///         sender still produce distinct ids. Incremented once per successful
    ///         `fundsIn`; a downstream revert rolls the increment back.
    mapping(uint256 sourceChainId => mapping(bytes32 sourceSender => uint256 nonce))
        public sourceSenderNonces;

    /// @notice Isolated liquidity per non-Arbitrum chain. Tracks the
    ///         net token amount locked on this chain on behalf of a given
    ///         remote chain: `fundsIn` credits the deposit's `destinationChainId`
    ///         bucket, `fundsOut` debits the release's `sourceChainId` bucket.
    ///         A release can therefore never draw more than was actually
    ///         bridged toward that chain.
    mapping(uint256 chainId => uint256 locked) public lockedLiquidity;

    /// @notice Per-source-chain outflow rate limiter. Bounds
    ///         how fast `fundsOut` can drain a single chain's liquidity.
    mapping(uint256 chainId => OutflowRateLimiter.Bucket) public chainBuckets;

    /// @notice Global (aggregate) outflow rate limiter. Bounds
    ///         total `fundsOut` across all source chains, since a compromised
    ///         shared TEE could otherwise drain every chain's per-chain bucket
    ///         in the same window (aggregate = sum of per-chain caps).
    OutflowRateLimiter.Bucket public globalBucket;

    /// @inheritdoc IBridge
    /// @dev Always non-zero (validated at the constructor and setter). Mutable
    ///      so federation can retune the dust floor via the `MultisigProxy`
    ///      propose -> timelock -> execute flow without redeploying the Bridge.
    uint256 public override minFundsInAmount;

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

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param usdt0_             USDT0 token address on this chain.
    /// @param routeRegistry_     `RouteRegistry` deployment paired with this
    ///                           Bridge.
    /// @param commissionManager_ CommissionManager that receives protocol fees.
    /// @param lzAdapter_         Initial trusted LayerZero adapter; pass
    ///                           `address(0)` if it has not been deployed yet
    ///                           (federation can wire it up later via
    ///                           `setLZAdapter`).
    /// @param minFundsInAmount_  Initial minimum accepted `fundsIn` deposit in
    ///                           token smallest units. Must be non-zero; it can
    ///                           be retuned later via `setMinFundsInAmount`.
    constructor(
        address          usdt0_,
        address          routeRegistry_,
        address payable  commissionManager_,
        address          lzAdapter_,
        uint256          minFundsInAmount_
    ) BridgeBase(usdt0_) {
        if (routeRegistry_     == address(0)) revert InvalidRouteRegistryAddress();
        if (commissionManager_ == address(0)) revert InvalidCommissionManagerAddress();
        if (minFundsInAmount_  == 0)          revert InvalidMinFundsInAmount();

        routeRegistry     = routeRegistry_;
        commissionManager = ICommissionManager(commissionManager_);
        lzAdapter         = lzAdapter_;
        minFundsInAmount  = minFundsInAmount_;
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
        if (newRouteRegistry == address(0)) revert InvalidRouteRegistryAddress();
        address old = routeRegistry;
        routeRegistry = newRouteRegistry;
        emit RouteRegistryUpdated(old, newRouteRegistry);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its M-of-N
    ///      timelock flow (generic `proposeAdminExecute` -> execute). Must be
    ///      non-zero: a non-zero floor is what rejects zero-amount and dust
    ///      deposits on the inbound path.
    function setMinFundsInAmount(uint256 newMinimum) external override onlyOwner {
        if (newMinimum == 0) revert InvalidMinFundsInAmount();
        uint256 old = minFundsInAmount;
        minFundsInAmount = newMinimum;
        emit MinFundsInAmountUpdated(old, newMinimum);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its timelock flow.
    function setOutflowLimit(uint256 chainId, uint256 capacity, uint256 refillRate)
        external
        override
        onlyOwner
    {
        if (chainId == 0) revert InvalidOutflowLimit();
        OutflowRateLimiter.Settings memory cfg = _buildOutflowConfig(capacity, refillRate);
        OutflowRateLimiter.validate(cfg, false);
        chainBuckets[chainId].configurePrimed(cfg);
        emit OutflowLimitUpdated(chainId, capacity, refillRate, chainBuckets[chainId].tokens);
    }

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation gates this on its timelock flow.
    function setGlobalOutflowLimit(uint256 capacity, uint256 refillRate)
        external
        override
        onlyOwner
    {
        OutflowRateLimiter.Settings memory cfg = _buildOutflowConfig(capacity, refillRate);
        OutflowRateLimiter.validate(cfg, false);
        globalBucket.configurePrimed(cfg);
        emit GlobalOutflowLimitUpdated(capacity, refillRate, globalBucket.tokens);
    }

    /// @inheritdoc IBridge
    function availableOutflow(uint256 chainId) external view override returns (uint256) {
        return OutflowRateLimiter.currentState(chainBuckets[chainId]).tokens;
    }

    /// @inheritdoc IBridge
    function availableGlobalOutflow() external view override returns (uint256) {
        return OutflowRateLimiter.currentState(globalBucket).tokens;
    }

    // =========================================================================
    // External — user-facing
    // =========================================================================

    /// @inheritdoc IBridge
    function fundsIn(
        uint256 amount,
        uint256 destinationChainId,
        string  calldata destinationAddress,
        bytes   calldata settlementData
    ) external payable override whenNotPaused nonReentrant returns (bytes32 operationId) {
        // Direct EVM deposit: the source sender IS the caller.
        address caller = _msgSender();
        operationId = _fundsIn(
            caller,
            _toSourceSender(caller),
            amount,
            block.chainid,
            destinationChainId,
            destinationAddress,
            settlementData
        );
    }

    /// @inheritdoc IBridge
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string  calldata destinationAddress,
        bytes   calldata settlementData
    ) external payable override whenNotPaused nonReentrant onlyLZAdapter returns (bytes32 operationId) {
        // LZ deposit: tokens are pulled from the adapter (`_msgSender()`), but
        // the identity bound into `operationId` is the authenticated
        // `sourceSender` forwarded from the source-chain entrypoint.
        operationId = _fundsIn(
            _msgSender(),
            sourceSender,
            amount,
            sourceChainId,
            destinationChainId,
            destinationAddress,
            settlementData
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

        // Common replay guard. Set the flag before any external interaction
        // so a revert anywhere downstream rolls the mark back with the rest
        // of the call.
        if (consumedBurnIds[fundsOutParams.burnId]) revert BurnIdAlreadyConsumed(fundsOutParams.burnId);
        consumedBurnIds[fundsOutParams.burnId] = true;

        // Isolated liquidity: a release may only draw from the liquidity
        // locked for its source chain. Debit before any external interaction so
        // a downstream revert rolls the debit back with the rest of the call.
        // `amount` (gross) matches what was minted on the source side, i.e. the
        // `netAmount` that `_fundsIn` credited to this bucket.
        uint256 srcLiquidity = lockedLiquidity[fundsOutParams.sourceChainId];
        if (fundsOutParams.amount > srcLiquidity) {
            revert InsufficientChainLiquidity(fundsOutParams.sourceChainId, fundsOutParams.amount, srcLiquidity);
        }
        lockedLiquidity[fundsOutParams.sourceChainId] = srcLiquidity - fundsOutParams.amount;

        // Outflow rate limit. Consume both the per-source-chain
        // bucket and the global aggregate bucket; either being short reverts the
        // whole call (and rolls back the consume above). Both are debited before
        // any external interaction, so a downstream revert restores them too.
        // Per-source-chain bucket (token-scoped errors), then the global
        // aggregate bucket (aggregate-scoped errors via the address(0) sentinel).
        // The limiter is fail-closed: an unconfigured chain/global bucket
        // rejects the release instead of falling back to unlimited outflow.
        chainBuckets[fundsOutParams.sourceChainId].spend(fundsOutParams.amount, TOKEN);
        globalBucket.spend(fundsOutParams.amount, address(0));

        // Quote commission. NATIVE on fundsOut is unrepresentable: the
        // CommissionManager setters reject a (NATIVE, FUNDS_OUT) rule at config,
        // so `nativeCommission` is always 0 on this path. The value is ignored here.
        (
            uint256 tokenCommission,
            ,
            uint256 netAmount
        ) = commissionManager.calculateFundsOutCommission(
            fundsOutParams.sourceChainId,
            fundsOutParams.destinationChainId,
            TOKEN,
            fundsOutParams.amount
        );

        // Delegate route-specific finality verification + settlement-state
        // mutation to the configured plugins. The registry runs the verifier
        // (view-only) first; if it reverts, no settlement-module write happens.
        IRouteRegistry(routeRegistry).beforeFundsOut(
            FundsOutContext({
                token:         TOKEN,
                recipient:     fundsOutParams.recipient,
                amount:        fundsOutParams.amount,
                burnId:        fundsOutParams.burnId,
                sourceChainId: fundsOutParams.sourceChainId,
                destChainId:   fundsOutParams.destinationChainId,
                sourceAddress: fundsOutParams.sourceAddress
            }),
            fundsOutParams.proof,
            fundsOutParams.settlementData
        );

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
            fundsOutParams.sourceAddress
        );
    }

    /// @inheritdoc IBridge
    function renounceOwnership()
        public
        view
        override(BridgeBase, IBridge)
        onlyOwner
    {
        revert RenounceOwnershipBlocked();
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _validateFundsOutParams(FundsOutParams calldata params) private view {
        if (params.amount             == 0)          revert ZeroAmount();
        if (params.recipient          == address(0)) revert InvalidRecipientAddress();
        if (params.sourceChainId      == 0)          revert InvalidSourceChainId();
        if (params.destinationChainId == 0)          revert InvalidDestinationChainId();

        uint256 sourceAddressLength = bytes(params.sourceAddress).length;
        if (sourceAddressLength > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(sourceAddressLength, MAX_ADDRESS_LENGTH);
        }
        if (params.proof.length > MAX_PROOF_LENGTH) revert ProofTooLong(params.proof.length, MAX_PROOF_LENGTH);
        if (params.amount > IERC20(TOKEN).balanceOf(address(this))) revert AmountExceedBridgePool();

        uint256 expectedBurnId = _deriveBurnId(params);
        if (params.burnId != expectedBurnId) revert InvalidBurnId(params.burnId, expectedBurnId);
    }

    /// @dev Build an enabled outflow-limit config from uint256 inputs, safely
    ///      narrowing to the library's uint128 fields. USDT0 amounts fit in
    ///      uint128; a value above that is a misconfiguration and reverts.
    ///      `OutflowRateLimiter.validate` then enforces `0 < rate < capacity`.
    function _buildOutflowConfig(uint256 capacity, uint256 refillRate)
        private
        pure
        returns (OutflowRateLimiter.Settings memory)
    {
        if (capacity > type(uint128).max || refillRate > type(uint128).max) revert InvalidOutflowLimit();
        return OutflowRateLimiter.Settings({
            isEnabled: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            capacity:  uint128(capacity),
            // forge-lint: disable-next-line(unsafe-typecast)
            rate:      uint128(refillRate)
        });
    }

    /// @dev Shared body for both `fundsIn` overloads. Derives the canonical
    ///      `operationId` on-chain (never caller-supplied) and returns it.
    /// @param from         EVM caller tokens are pulled from (user, or adapter).
    /// @param sourceSender Original source-chain sender bound into `operationId`.
    function _fundsIn(
        address          from,
        bytes32          sourceSender,
        uint256          amount,
        uint256          sourceChainId,
        uint256          destinationChainId,
        string  memory   destinationAddress,
        bytes   calldata settlementData
    ) private returns (bytes32 operationId) {
        if (amount < minFundsInAmount)             revert AmountBelowMinimum(amount, minFundsInAmount);
        if (bytes(destinationAddress).length == 0) revert InvalidDestinationAddress();
        if (bytes(destinationAddress).length > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(bytes(destinationAddress).length, MAX_ADDRESS_LENGTH);
        }
        if (sourceChainId      == 0)               revert InvalidSourceChainId();
        if (destinationChainId == 0)               revert InvalidDestinationChainId();

        // Commission is quoted from the nominal `amount` so the native-commission
        // quote (and the lower-bound `msg.value` check below) stays predictable
        // for the caller. The nominal net is intentionally discarded — the
        // credited net is derived from the ACTUAL received amount after the transfer.
        (uint256 tokenCommission, uint256 nativeCommission, ) =
            commissionManager.calculateFundsInCommission(
                sourceChainId,
                destinationChainId,
                TOKEN,
                amount
            );

        // Native payment: require at least the freshly-quoted commission
        // — an oracle move up between quote and execution reverts here. Any
        // overpayment from a favorable move is collected as commission below
        // (not refunded), so the rule is uniform for direct and LZ deposits.
        // TOKEN-commission routes (nativeCommission == 0) accept no native.
        if (msg.value < nativeCommission) revert NativeValueMismatch();
        if (nativeCommission == 0 && msg.value != 0) revert NativeValueMismatch();

        // Build the canonical context. The per-`(sourceChainId, sourceSender)`
        // nonce is consumed here — before any external call, so a downstream
        // revert rolls it back — and folded, with the deposit context, into the
        // on-chain-derived operationId. Because the id binds the authenticated
        // `sourceSender` and an incrementing nonce, a third party cannot predict
        // or pre-empt it. Held in memory to keep the stack shallow.
        FundsInContext memory ctx = FundsInContext({
            token:         TOKEN,
            sender:        from,
            sourceSender:  sourceSender,
            grossAmount:   amount,
            netAmount:     0, // set below from the ACTUAL received amount
            operationId:   bytes32(0), // filled in on the next line
            senderNonce:   sourceSenderNonces[sourceChainId][sourceSender]++,
            sourceChainId: sourceChainId,
            destChainId:   destinationChainId,
            destAddress:   destinationAddress
        });
        // operationId binds grossAmount (not netAmount), so it is stable
        // regardless of any token transfer fee.
        ctx.operationId = _deriveOperationId(ctx, settlementData);

        // Pull the gross amount and measure what ACTUALLY arrived. A
        // fee-on-transfer token can deliver less than `amount`; crediting the
        // nominal amount would overstate custody and could brick release of the
        // recorded balance. Everything downstream — records, isolated
        // liquidity, event — is built from `received`, never from `amount`.
        uint256 balanceBefore = IERC20(TOKEN).balanceOf(address(this));
        IERC20(TOKEN).safeTransferFrom(from, address(this), amount);
        uint256 received = IERC20(TOKEN).balanceOf(address(this)) - balanceBefore;

        // The token commission is forwarded out of `received`; guard the
        // subtraction so a token fee that eats more than the commission reverts
        // cleanly instead of underflowing. A zero net (received == commission) is
        // left to the existing zero-amount / dust handling, unchanged here.
        if (received < tokenCommission) revert InsufficientReceived(received, tokenCommission);
        ctx.netAmount = received - tokenCommission;

        // Forward token commission BEFORE the settlement hook so that any
        // external call the hook makes (or a contract reading `getContractBalance`
        // during it) observes only the net amount the Bridge actually retains,
        // never the in-flight commission about to leave. `netAmount` is
        // already fixed above, so the hook does not depend on the tokens still
        // being held here.
        if (tokenCommission != 0) _forwardTokenCommission(tokenCommission);

        // Delegate per-route inbound bookkeeping. The module returns an optional
        // correlation id (the RGB OpId for the RGB route; 0 otherwise) to surface
        // in the RGB-only `FundsIn` event below.
        uint256 rgbOpId = IRouteRegistry(routeRegistry).onFundsIn(ctx, settlementData);

        // Isolated liquidity: credit the net deposit to its destination
        // chain's bucket. A later `fundsOut` from that chain can release at most
        // the accumulated locked liquidity. Credited from the ACTUAL received
        // amount so the ledger can never exceed real custody.
        lockedLiquidity[destinationChainId] += ctx.netAmount;

        // Forward the FULL native value to the CommissionManager pool. Any
        // surplus over the quoted `nativeCommission` (favorable oracle drift) is
        // collected as commission rather than refunded, so no native is
        // ever left stranded in the Bridge.
        if (msg.value != 0) {
            (bool ok, ) = address(commissionManager).call{ value: msg.value }('');
            if (!ok) revert NativeValueMismatch();
        }

        // RGB-only correlation event: emitted only when the route module
        // returned a non-zero external id (the RGB OpId). Other routes skip it.
        if (rgbOpId != 0) emit FundsIn(ctx.sender, rgbOpId, ctx.netAmount);
        emit BridgeFundsIn(
            ctx.operationId,
            ctx.sourceSender,
            ctx.sender,
            ctx.senderNonce,
            ctx.grossAmount,
            ctx.netAmount,
            tokenCommission,
            msg.value, // actual native collected (== nativeCommission + any drift surplus)
            ctx.sourceChainId,
            ctx.destChainId,
            ctx.destAddress
        );

        operationId = ctx.operationId;
    }

    /// @dev Left-pads an EVM address into the `bytes32` source-sender encoding
    ///      used by `operationId` derivation and the LZ overload.
    function _toSourceSender(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    /// @dev Transfer `amount` of TOKEN to the CommissionManager and credit the
    ///      commission pool by the ACTUAL balance increase this transfer caused.
    ///      Measuring the delta here (rather than in CM from `balanceOf - pool`)
    ///      keeps the credit fee-on-transfer safe and prevents any pre-existing /
    ///      unsolicited direct transfer to CM from being absorbed as commission.
    function _forwardTokenCommission(uint256 amount) private {
        address cm = address(commissionManager);
        uint256 balBefore = IERC20(TOKEN).balanceOf(cm);
        IERC20(TOKEN).safeTransfer(cm, amount);
        uint256 credited = IERC20(TOKEN).balanceOf(cm) - balBefore;
        commissionManager.receiveTokenCommission(TOKEN, credited);
    }

    /// @dev Canonical `operationId` = domain-separated hash of the deposit
    ///      context. Binds the id to sender/gross-amount/route/destination so it
    ///      is both unpredictable (via the authenticated `sourceSender` + nonce)
    ///      and provably tied to this deposit. Uses `grossAmount` (the user's
    ///      submitted amount, known before execution) rather than the
    ///      commission-derived `netAmount`, so a backend can best-effort
    ///      pre-compute the id; the canonical value is still the one in the
    ///      `BridgeFundsIn` event. `ctx.operationId` is ignored (zero when called).
    function _deriveOperationId(FundsInContext memory ctx, bytes calldata settlementData)
        private
        view
        returns (bytes32)
    {
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

    /// @dev Canonical `burnId` = domain-separated hash of the release intent.
    ///      Route-specific burn identity should be placed in `settlementData`
    ///      when a route has one; Bridge commits to it via `settlementDataHash`.
    function _deriveBurnId(FundsOutParams calldata params) private view returns (uint256) {
        return _deriveBurnIdFromFields(
            params.recipient,
            params.amount,
            params.sourceChainId,
            params.destinationChainId,
            params.sourceAddress,
            params.proof,
            params.settlementData
        );
    }

    function _deriveBurnIdFromFields(
        address recipient,
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string calldata sourceAddress,
        bytes calldata proof,
        bytes calldata settlementData
    ) private view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    FUNDS_OUT_BURN_ID_TYPEHASH,
                    address(this),
                    block.chainid,
                    TOKEN,
                    recipient,
                    amount,
                    sourceChainId,
                    destinationChainId,
                    _hashCalldataString(sourceAddress),
                    _hashCalldataBytes(proof),
                    _hashCalldataBytes(settlementData)
                )
            )
        );
    }

    function _hashCalldataString(string calldata value) private pure returns (bytes32 result) {
        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, value.offset, value.length)
            result := keccak256(ptr, value.length)
            mstore(0x40, add(ptr, and(add(value.length, 0x3f), not(0x1f))))
        }
    }

    function _hashCalldataBytes(bytes calldata value) private pure returns (bytes32 result) {
        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, value.offset, value.length)
            result := keccak256(ptr, value.length)
            mstore(0x40, add(ptr, and(add(value.length, 0x3f), not(0x1f))))
        }
    }
}
