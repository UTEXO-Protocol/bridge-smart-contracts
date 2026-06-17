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
    ) external override onlyOwner nonReentrant whenOutflowNotPaused {
        if (amount             == 0)                         revert ZeroAmount();
        if (recipient          == address(0))                revert InvalidRecipientAddress();
        if (sourceChainId      == 0)                         revert InvalidSourceChainId();
        if (destinationChainId == 0)                         revert InvalidDestinationChainId();
        if (bytes(sourceAddress).length > MAX_ADDRESS_LENGTH) {
            revert AddressTooLong(bytes(sourceAddress).length, MAX_ADDRESS_LENGTH);
        }
        if (proof.length > MAX_PROOF_LENGTH) revert ProofTooLong(proof.length, MAX_PROOF_LENGTH);
        if (amount > IERC20(TOKEN).balanceOf(address(this))) revert AmountExceedBridgePool();

        // Common replay guard. Set the flag before any external interaction
        // so a revert anywhere downstream rolls the mark back with the rest
        // of the call.
        if (consumedBurnIds[burnId]) revert BurnIdAlreadyConsumed(burnId);
        consumedBurnIds[burnId] = true;

        // Quote commission. NATIVE on fundsOut is unrepresentable: the
        // CommissionManager setters reject a (NATIVE, FUNDS_OUT) rule at config,
        // so `nativeCommission` is always 0 on this path. The
        // value is ignored here.
        (
            uint256 tokenCommission,
            ,
            uint256 netAmount
        ) = commissionManager.calculateFundsOutCommission(
            sourceChainId,
            destinationChainId,
            TOKEN,
            amount
        );

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
