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
///        only owns: token custody, the common `burnId` replay guard, and
///        commission routing.
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

    /// @notice CommissionManager that receives and custodies protocol fees.
    ICommissionManager public immutable commissionManager;

    /// @inheritdoc IBridge
    /// @dev Mutable so federation can rotate registry deployments via
    ///      `UpdateRouteRegistry` governance op without redeploying the
    ///      Bridge.
    address public override routeRegistry;

    /// @inheritdoc IBridge
    address public override lzAdapter;

    /// @notice Set of burn identifiers already consumed by a successful
    ///         `fundsOut`.
    mapping(uint256 burnId => bool consumed) public consumedBurnIds;

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
        uint256 operationId,
        bytes   calldata settlementData
    ) external payable override whenNotPaused nonReentrant {
        _fundsIn(
            _msgSender(),
            amount,
            block.chainid,
            destinationChainId,
            destinationAddress,
            operationId,
            settlementData
        );
    }

    /// @inheritdoc IBridge
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  calldata destinationAddress,
        uint256 operationId,
        bytes   calldata settlementData
    ) external payable override whenNotPaused nonReentrant onlyLZAdapter {
        _fundsIn(
            _msgSender(),
            amount,
            sourceChainId,
            destinationChainId,
            destinationAddress,
            operationId,
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
        if (fundsOutParams.amount             == 0)                       revert ZeroAmount();
        if (fundsOutParams.recipient          == address(0))              revert InvalidRecipientAddress();
        if (fundsOutParams.sourceChainId      == 0)                       revert InvalidSourceChainId();
        if (fundsOutParams.destinationChainId == 0)                       revert InvalidDestinationChainId();
        if (bytes(fundsOutParams.sourceAddress).length > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(bytes(fundsOutParams.sourceAddress).length, MAX_ADDRESS_LENGTH);
        }
        if (fundsOutParams.proof.length > MAX_PROOF_LENGTH) revert ProofTooLong(fundsOutParams.proof.length, MAX_PROOF_LENGTH);
        if (fundsOutParams.amount > IERC20(TOKEN).balanceOf(address(this))) revert AmountExceedBridgePool();

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
        if (tokenCommission != 0) {
            IERC20(TOKEN).safeTransfer(address(commissionManager), tokenCommission);
            commissionManager.receiveTokenCommission(TOKEN);
        }

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

    /// @dev Shared body for both `fundsIn` overloads.
    function _fundsIn(
        address          from,
        uint256          amount,
        uint256          sourceChainId,
        uint256          destinationChainId,
        string  memory   destinationAddress,
        uint256          operationId,
        bytes   calldata settlementData
    ) private {
        if (amount < minFundsInAmount)             revert AmountBelowMinimum(amount, minFundsInAmount);
        if (bytes(destinationAddress).length == 0) revert InvalidDestinationAddress();
        if (bytes(destinationAddress).length > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(bytes(destinationAddress).length, MAX_ADDRESS_LENGTH);
        }
        if (sourceChainId      == 0)               revert InvalidSourceChainId();
        if (destinationChainId == 0)               revert InvalidDestinationChainId();

        (
            uint256 tokenCommission,
            uint256 nativeCommission,
            uint256 netAmount
        ) = commissionManager.calculateFundsInCommission(
            sourceChainId,
            destinationChainId,
            TOKEN,
            amount
        );

        // Native payment must match the quote exactly (includes the zero-native case).
        if (msg.value != nativeCommission) revert NativeValueMismatch();

        // Pull the full gross amount from `from` into this contract.
        IERC20(TOKEN).safeTransferFrom(from, address(this), amount);

        // Delegate per-route inbound bookkeeping.
        IRouteRegistry(routeRegistry).onFundsIn(
            FundsInContext({
                token:         TOKEN,
                sender:        from,
                grossAmount:   amount,
                netAmount:     netAmount,
                operationId:   operationId,
                sourceChainId: sourceChainId,
                destChainId:   destinationChainId,
                destAddress:   destinationAddress
            }),
            settlementData
        );

        // Isolated liquidity: credit the net deposit to its destination
        // chain's bucket. A later `fundsOut` from that chain can release at most
        // the accumulated locked liquidity.
        lockedLiquidity[destinationChainId] += netAmount;

        // Forward token commission, if any, to the CommissionManager pool.
        if (tokenCommission != 0) {
            IERC20(TOKEN).safeTransfer(address(commissionManager), tokenCommission);
            commissionManager.receiveTokenCommission(TOKEN);
        }

        // Forward native commission, if any, to the CommissionManager pool.
        if (nativeCommission != 0) {
            (bool ok, ) = address(commissionManager).call{ value: nativeCommission }('');
            if (!ok) revert NativeValueMismatch();
        }

        emit FundsIn(from, operationId, netAmount);
        emit BridgeFundsIn(
            from,
            operationId,
            amount,
            netAmount,
            tokenCommission,
            nativeCommission,
            sourceChainId,
            destinationChainId,
            destinationAddress
        );
    }
}
