// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 }            from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 }         from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { ReentrancyGuard }   from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import { BridgeBase }         from './BridgeBase.sol';
import { IBridge }            from './interfaces/IBridge.sol';
import { ICommissionManager } from './interfaces/ICommissionManager.sol';
import { IRouteRegistry }     from './interfaces/IRouteRegistry.sol';
import { FundsInContext, FundsOutContext } from './interfaces/RouteTypes.sol';

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

    // =========================================================================
    // State
    // =========================================================================

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
    constructor(
        address          usdt0_,
        address          routeRegistry_,
        address payable  commissionManager_,
        address          lzAdapter_
    ) BridgeBase(usdt0_) {
        if (routeRegistry_     == address(0)) revert InvalidRouteRegistryAddress();
        if (commissionManager_ == address(0)) revert InvalidCommissionManagerAddress();

        routeRegistry     = routeRegistry_;
        commissionManager = ICommissionManager(commissionManager_);
        lzAdapter         = lzAdapter_;
    }

    // =========================================================================
    // External — admin
    // =========================================================================

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation governance gates this call
    ///      on its M-of-N timelock flow.
    function setLZAdapter(address newAdapter) external override onlyOwner {
        address old = lzAdapter;
        lzAdapter = newAdapter;
        emit LZAdapterUpdated(old, newAdapter);
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
    // External — owner-only (called via MultisigProxy.execute)
    // =========================================================================

    /// @inheritdoc IBridge
    function fundsOut(
        address recipient,
        uint256 amount,
        uint256 burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  calldata sourceAddress,
        bytes   calldata proof,
        bytes   calldata settlementData
    ) external override onlyOwner nonReentrant {
        if (recipient          == address(0))                revert InvalidRecipientAddress();
        if (sourceChainId      == 0)                         revert InvalidSourceChainId();
        if (destinationChainId == 0)                         revert InvalidDestinationChainId();
        if (amount > IERC20(TOKEN).balanceOf(address(this))) revert AmountExceedBridgePool();

        // Common replay guard. Set the flag before any external interaction
        // so a revert anywhere downstream rolls the mark back with the rest
        // of the call.
        if (consumedBurnIds[burnId]) revert BurnIdAlreadyConsumed(burnId);
        consumedBurnIds[burnId] = true;

        // Quote commission. NATIVE on fundsOut is disallowed — the caller is
        // the multisig, there is no user to fund a native payment.
        (
            uint256 tokenCommission,
            uint256 nativeCommission,
            uint256 netAmount
        ) = commissionManager.calculateFundsOutCommission(
            sourceChainId,
            destinationChainId,
            TOKEN,
            amount
        );
        if (nativeCommission != 0) revert NativeCommissionNotAllowedOnFundsOut();

        // Delegate route-specific finality verification + settlement-state
        // mutation to the configured plugins. The registry runs the verifier
        // (view-only) first; if it reverts, no settlement-module write happens.
        IRouteRegistry(routeRegistry).beforeFundsOut(
            FundsOutContext({
                token:         TOKEN,
                recipient:     recipient,
                amount:        amount,
                burnId:        burnId,
                sourceChainId: sourceChainId,
                destChainId:   destinationChainId,
                sourceAddress: sourceAddress
            }),
            proof,
            settlementData
        );

        // Forward token commission to the CommissionManager pool.
        if (tokenCommission != 0) {
            IERC20(TOKEN).safeTransfer(address(commissionManager), tokenCommission);
            commissionManager.receiveTokenCommission(TOKEN);
        }

        // Deliver the net amount to the recipient.
        IERC20(TOKEN).safeTransfer(recipient, netAmount);

        emit BridgeFundsOut(
            recipient,
            amount,
            netAmount,
            tokenCommission,
            burnId,
            sourceChainId,
            destinationChainId,
            sourceAddress
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
        if (bytes(destinationAddress).length == 0) revert InvalidDestinationAddress();
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
