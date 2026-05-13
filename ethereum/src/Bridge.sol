// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 }            from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 }         from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { ReentrancyGuard }   from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import { BridgeBase }         from './BridgeBase.sol';
import { IBridge }            from './interfaces/IBridge.sol';
import { IBtcRelayView }      from './interfaces/IBtcRelayView.sol';
import { ICommissionManager } from './interfaces/ICommissionManager.sol';

/// @title Bridge
/// @notice Production bridge for locking USDT0 on Arbitrum and unlocking it back.
///         Extends BridgeBase with full event data for the UTEXO backend and routes
///         commission to a standalone CommissionManager so protocol fees are held
///         separately from bridge liquidity.
///
/// @dev - Owner is `MultisigProxy`. `fundsOut` is called via
///        `MultisigProxy.execute()` (TEE M-of-N).
///      - `fundsIn` has two overloads:
///        • Public 4-arg: any EVM user on this chain can lock tokens; the
///          source chain id is filled with `block.chainid`.
///        • Adapter-only 5-arg: callable only by the trusted `lzAdapter`,
///          which forwards a non-spoofable `sourceChainId` carried in
///          `composeMsg` from the source chain. Both overloads share the same
///          private body via `_fundsIn`.
///      - `fundsOut` verifies the Bitcoin block header via BtcRelay and the
///        referenced `fundsIn` records before releasing funds.
///      - Commission routing keys on `(sourceChainId, destinationChainId,
///        TOKEN)` for both directions. NATIVE currency is only supported on
///        `fundsIn`; `fundsOut` reverts if a NATIVE rule is configured.
///      - `lzAdapter` is mutable so federation governance can rotate adapter
///        deployments without redeploying the Bridge (the adapter itself
///        immutably points back at the Bridge, so a swap is a one-way
///        Bridge → Adapter pointer update).
contract Bridge is BridgeBase, IBridge, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice BtcRelay contract used to verify Bitcoin block headers.
    address public immutable btcRelay;

    /// @notice CommissionManager that receives and custodies protocol fees.
    ICommissionManager public immutable commissionManager;

    /// @inheritdoc IBridge
    address public override lzAdapter;

    /// @notice On-chain record of fundsIn operations: operationId => netAmount.
    ///         Stores the amount actually bridged after token commission is deducted;
    ///         used by fundsOut to verify that referenced deposits actually happened.
    ///         Records may be partially consumed by fundsOut — the residual stays
    ///         under the same `operationId` until fully drained.
    mapping(uint256 => uint256) public fundsInRecords;

    /// @notice Set of burn identifiers already consumed by a successful `fundsOut`.
    ///         This mapping enforces single-use semantics on-chain.
    mapping(uint256 => bool) public consumedBurnIds;

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev Restricts a function to the configured `lzAdapter`. Until federation
    ///      sets a non-zero adapter, the modifier closes the function for every
    ///      caller (no EOA or contract has `address(0)` as its `msg.sender`).
    modifier onlyLZAdapter() {
        if (msg.sender != lzAdapter) revert NotLZAdapter();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param usdt0_             USDT0 token address on this chain.
    /// @param btcRelay_          BtcRelay contract for Bitcoin header verification.
    /// @param commissionManager_ CommissionManager that receives protocol fees.
    /// @param lzAdapter_         Initial trusted LayerZero adapter; pass
    ///                           `address(0)` if it has not been deployed yet
    ///                           (federation can wire it up later via
    ///                           `setLZAdapter`).
    constructor(
        address usdt0_,
        address btcRelay_,
        address payable commissionManager_,
        address lzAdapter_
    ) BridgeBase(usdt0_) {
        if (btcRelay_ == address(0))          revert InvalidBtcRelayAddress();
        if (commissionManager_ == address(0)) revert InvalidCommissionManagerAddress();

        btcRelay          = btcRelay_;
        commissionManager = ICommissionManager(commissionManager_);
        lzAdapter         = lzAdapter_;
    }

    // =========================================================================
    // External — admin
    // =========================================================================

    /// @inheritdoc IBridge
    /// @dev Owner is `MultisigProxy`; federation governance gates this call on
    ///      its M-of-N timelock flow.
    function setLZAdapter(address newAdapter) external override onlyOwner {
        address old = lzAdapter;
        lzAdapter = newAdapter;
        emit LZAdapterUpdated(old, newAdapter);
    }

    // =========================================================================
    // External — user-facing
    // =========================================================================

    /// @inheritdoc IBridge
    function fundsIn(
        uint256 amount,
        uint256 destinationChainId,
        string  calldata destinationAddress,
        uint256 operationId
    ) external payable override whenNotPaused nonReentrant {
        _fundsIn(
            _msgSender(),
            amount,
            block.chainid,
            destinationChainId,
            destinationAddress,
            operationId
        );
    }

    /// @inheritdoc IBridge
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  calldata destinationAddress,
        uint256 operationId
    ) external payable override whenNotPaused nonReentrant onlyLZAdapter {
        _fundsIn(
            _msgSender(),
            amount,
            sourceChainId,
            destinationChainId,
            destinationAddress,
            operationId
        );
    }

    // =========================================================================
    // External — owner-only (called via MultisigProxy.execute)
    // =========================================================================

    /// @inheritdoc IBridge
    function fundsOut(
        address recipient,
        uint256 amount,
        uint256 operationId,
        uint256 burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  calldata sourceAddress,
        uint256 blockHeight,
        bytes32 commitmentHash,
        uint256[] calldata fundsInIds
    ) external override onlyOwner nonReentrant {
        if (recipient == address(0))               revert InvalidRecipientAddress();
        if (sourceChainId == 0)                    revert InvalidSourceChainId();
        if (destinationChainId == 0)               revert InvalidDestinationChainId();
        if (amount > IERC20(TOKEN).balanceOf(address(this))) revert AmountExceedBridgePool();

        // Set the flag before any external interaction so a revert
        // anywhere downstream rolls back the mark together with the rest of the call.
        if (consumedBurnIds[burnId]) revert BurnIdAlreadyConsumed(burnId);
        consumedBurnIds[burnId] = true;

        // Verify referenced fundsIn operations exist and consume them — sequentially,
        // partially when needed. Each record is either:
        //   • fully consumed (deleted) if it is smaller than the remaining amount, or
        //   • partially consumed (decremented) if it covers the remainder, leaving
        //     a residual liquidity available for future fundsOut calls under the
        //     same operationId.
        uint256 remaining = amount;
        for (uint256 i = 0; i < fundsInIds.length; i++) {
            uint256 recorded = fundsInRecords[fundsInIds[i]];
            if (recorded == 0) revert FundsInNotFound(fundsInIds[i]);

            if (recorded > remaining) {
                fundsInRecords[fundsInIds[i]] = recorded - remaining;
                remaining = 0;
                break;
            }

            // recorded <= remaining — consume the record fully.
            delete fundsInRecords[fundsInIds[i]];
            remaining -= recorded;

            if (remaining == 0) break;
        }
        if (remaining != 0) revert FundsOutAmountExceedsFundsIn();

        // Verify Bitcoin block header is known to BtcRelay (reverts if unknown).
        IBtcRelayView(btcRelay).verifyBlockheaderHash(blockHeight, commitmentHash);

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

        // NATIVE currency on fundsOut is disallowed: the caller is the multisig,
        // there is no user to fund native payment. Routes must use TOKEN currency.
        if (nativeCommission != 0) revert NativeCommissionNotAllowedOnFundsOut();

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
            operationId,
            burnId,
            sourceChainId,
            destinationChainId,
            sourceAddress,
            blockHeight,
            commitmentHash
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
        address from,
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory destinationAddress,
        uint256 operationId
    ) private {
        if (bytes(destinationAddress).length == 0) revert InvalidDestinationAddress();
        if (sourceChainId == 0)                    revert InvalidSourceChainId();
        if (destinationChainId == 0)               revert InvalidDestinationChainId();
        if (fundsInRecords[operationId] != 0)      revert DuplicateOperationId();

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

        // Record the net amount as the bridged liquidity for this operation.
        fundsInRecords[operationId] = netAmount;

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
