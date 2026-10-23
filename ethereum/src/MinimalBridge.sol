// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BridgeBase} from "./BridgeBase.sol";
import {IArbSys} from "./interfaces/IArbSys.sol";

/// @title MinimalBridge
/// @notice Minimal single-token bridge for lock/unlock operations.
///
/// @dev - No TEE signature verification.
///      - `fundsOut` is owner-only; the owner is expected to be a multisig or
///        similar access control contract on the integrator's side.
contract MinimalBridge is BridgeBase {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Arbitrum system precompile exposing the child-chain block number.
    IArbSys internal constant ARBSYS = IArbSys(address(100));

    /// @notice Maximum number of Arbitrum L2 blocks after `afterBlock` in
    ///         which an RGB mint may be funded.
    uint64 public constant MAX_LOCK_BLOCKS = 400_000;

    /// @notice Domain-separated type hash for permanent RGB mint records.
    bytes32 public constant RGB_MINT_DEPOSIT_TYPEHASH = keccak256(
        "UtexoRgbMintDeposit(address bridge,uint256 chainId,address token,uint256 rgbOpId,uint256 amount,uint64 afterBlock)"
    );

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice Permanent funded RGB mint heights, keyed by the complete claim.
    /// @dev Zero means absent; otherwise the value is the actual L2 block plus one.
    mapping(bytes32 claimKey => uint64 l2BlockPlusOne) public fundsInRecords;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted on every fundsIn.
    /// @param sender                 Address that deposited the tokens.
    /// @param operationId            Backend-assigned operation identifier (the RGB OpId).
    /// @param amount                 Amount of tokens locked.
    event FundsIn(address indexed sender, uint256 indexed operationId, uint64 amount);

    /// @notice Emitted when tokens are released from the bridge.
    /// @param recipient              Recipient on this chain.
    /// @param amount                 Amount of tokens released.
    /// @param operationId            Backend-assigned operation identifier.
    /// @param sourceAddress          Sender address on the source chain (e.g. RGB address).
    event FundsOut(address indexed recipient, uint256 amount, uint256 indexed operationId, string sourceAddress);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice The RGB operation identifier is zero.
    error InvalidOperationId();

    /// @notice A record already exists for the complete RGB mint claim.
    error DuplicateMintDeposit(bytes32 claimKey);

    /// @notice The lock was submitted before its inclusive minimum L2 block.
    error LockWindowNotStarted(uint256 l2Block, uint64 afterBlock);

    /// @notice The lock was submitted after its allowed L2 block window.
    error LockWindowExpired(uint256 l2Block, uint64 afterBlock);

    /// @notice The Arbitrum L2 block number cannot be encoded in the record.
    error L2BlockNumberExceedsUint64(uint256 l2Block);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param token_                 ERC-20 token address accepted by this bridge (e.g. USDT0).
    constructor(address token_) BridgeBase(token_) {}

    // =========================================================================
    // External — user-facing
    // =========================================================================

    /// @notice Lock tokens in the bridge to initiate a transfer to the destination chain.
    /// @param amount                 Amount of tokens to lock.
    /// @param operationId            RGB mint operation identifier included in the event.
    /// @param afterBlock              Inclusive minimum Arbitrum L2 block for the lock.
    function fundsIn(uint256 amount, uint256 operationId, uint64 afterBlock) external whenNotPaused {
        if (amount > type(uint64).max) revert AmountExceedsUint64(amount);
        if (operationId == 0) revert InvalidOperationId();

        uint256 l2Block = ARBSYS.arbBlockNumber();
        if (l2Block < afterBlock) revert LockWindowNotStarted(l2Block, afterBlock);
        if (l2Block - afterBlock > MAX_LOCK_BLOCKS) revert LockWindowExpired(l2Block, afterBlock);
        if (l2Block >= type(uint64).max) revert L2BlockNumberExceedsUint64(l2Block);

        bytes32 claimKey = rgbMintDepositId(operationId, amount, afterBlock);
        if (fundsInRecords[claimKey] != 0) revert DuplicateMintDeposit(claimKey);

        // Safe after the explicit block-number bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 recordedBlockPlusOne = uint64(l2Block + 1);

        // Write before the token interaction so the same claim cannot be
        // re-entered. A transfer failure reverts this write atomically.
        fundsInRecords[claimKey] = recordedBlockPlusOne;

        IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), amount);

        // forge-lint: disable-next-line(unsafe-typecast)
        emit FundsIn(msg.sender, operationId, uint64(amount));
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Derives the permanent record key for an RGB mint claim.
    function rgbMintDepositId(uint256 operationId, uint256 amount, uint64 afterBlock) public view returns (bytes32) {
        return keccak256(
            abi.encode(RGB_MINT_DEPOSIT_TYPEHASH, address(this), block.chainid, TOKEN, operationId, amount, afterBlock)
        );
    }

    /// @notice Returns the funded L2 height for one RGB mint claim.
    /// @dev Zero means absent; otherwise subtract one to recover the L2 block.
    function getFundsInBlock(uint256 operationId, uint256 amount, uint64 afterBlock)
        external
        view
        returns (uint64 l2BlockPlusOne)
    {
        return fundsInRecords[rgbMintDepositId(operationId, amount, afterBlock)];
    }

    // =========================================================================
    // External — owner-only
    // =========================================================================

    /// @notice Release tokens from the bridge to a recipient. Only callable by owner.
    /// @param recipient              Recipient address on this chain.
    /// @param amount                 Amount of tokens to release.
    /// @param operationId            Backend-assigned operation identifier included in the event.
    /// @param sourceAddress          Sender address on the source chain (e.g. RGB address).
    function fundsOut(address recipient, uint256 amount, uint256 operationId, string calldata sourceAddress)
        external
        onlyOwner
        whenOutflowNotPaused
    {
        if (recipient == address(0)) revert InvalidRecipientAddress();
        if (amount > IERC20(TOKEN).balanceOf(address(this))) revert AmountExceedBridgePool();

        IERC20(TOKEN).safeTransfer(recipient, amount);

        emit FundsOut(recipient, amount, operationId, sourceAddress);
    }
}
