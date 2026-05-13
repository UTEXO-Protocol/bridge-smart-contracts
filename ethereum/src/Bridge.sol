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
/// @dev - Owner must be MultisigProxy. fundsOut is called via MultisigProxy.execute()
///        (TEE M-of-N).
///      - fundsIn is open — any user can lock tokens. Validation of destination
///        address and chain happens on the backend before minting on the other side.
///      - fundsOut verifies the Bitcoin block header via BtcRelay before releasing funds.
///      - Commission routing: fundsIn uses route key
///        `(sourceChainName, destinationChain, TOKEN)`; fundsOut uses
///        `(sourceChain, destChain, TOKEN)`. NATIVE currency is only supported on
///        fundsIn — revert on fundsOut.
contract Bridge is BridgeBase, IBridge, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice BtcRelay contract used to verify Bitcoin block headers.
    address public immutable btcRelay;

    /// @notice CommissionManager that receives and custodies protocol fees.
    ICommissionManager public immutable commissionManager;

    /// @notice Hash of this bridge's chain identifier (the `sourceChain` half of
    ///         the fundsIn route key). The string itself is kept immutable-ish via
    ///         storage + an immutable hash for quick equality checks if ever needed.
    string private _sourceChainName;

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
    // Constructor
    // =========================================================================

    /// @param usdt0_             USDT0 token address on this chain.
    /// @param btcRelay_          BtcRelay contract for Bitcoin header verification.
    /// @param commissionManager_ CommissionManager that receives protocol fees.
    /// @param sourceChainName_   This bridge's chain id as used in CommissionManager
    ///                           route keys (e.g. "arbitrum"). Non-empty, immutable.
    constructor(
        address usdt0_,
        address btcRelay_,
        address payable commissionManager_,
        string memory sourceChainName_
    ) BridgeBase(usdt0_) {
        if (btcRelay_ == address(0))          revert InvalidBtcRelayAddress();
        if (commissionManager_ == address(0)) revert InvalidCommissionManagerAddress();
        if (bytes(sourceChainName_).length == 0) revert InvalidSourceChainName();

        btcRelay          = btcRelay_;
        commissionManager = ICommissionManager(commissionManager_);
        _sourceChainName  = sourceChainName_;
    }

    // =========================================================================
    // View
    // =========================================================================

    /// @notice Returns the source chain identifier used as the origin side of the
    ///         CommissionManager route key for fundsIn.
    function sourceChainName() external view returns (string memory) {
        return _sourceChainName;
    }

    // =========================================================================
    // External — user-facing
    // =========================================================================

    /// @inheritdoc IBridge
    function fundsIn(
        uint256 amount,
        string  calldata destinationChain,
        string  calldata destinationAddress,
        uint256 operationId
    ) external payable whenNotPaused nonReentrant {
        if (bytes(destinationAddress).length == 0) revert InvalidDestinationAddress();
        if (bytes(destinationChain).length == 0)   revert InvalidDestinationChain();
        if (fundsInRecords[operationId] != 0)      revert DuplicateOperationId();

        (
            uint256 tokenCommission,
            uint256 nativeCommission,
            uint256 netAmount
        ) = commissionManager.calculateFundsInCommission(
            block.chainid,
            uint256(keccak256(bytes(destinationChain))),
            TOKEN,
            amount
        );

        // Native payment must match the quote exactly (includes the zero-native case).
        if (msg.value != nativeCommission) revert NativeValueMismatch();

        // Pull the full gross amount from the user into this contract.
        IERC20(TOKEN).safeTransferFrom(_msgSender(), address(this), amount);

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

        emit FundsIn(_msgSender(), operationId, netAmount);
        emit BridgeFundsIn(
            _msgSender(),
            operationId,
            amount,
            netAmount,
            tokenCommission,
            nativeCommission,
            destinationChain,
            destinationAddress
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
        string  calldata sourceChain,
        string  calldata destChain,
        string  calldata sourceAddress,
        uint256 blockHeight,
        bytes32 commitmentHash,
        uint256[] calldata fundsInIds
    ) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert InvalidRecipientAddress();
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
            uint256(keccak256(bytes(sourceChain))),
            uint256(keccak256(bytes(destChain))),
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
            sourceChain,
            destChain,
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
}
