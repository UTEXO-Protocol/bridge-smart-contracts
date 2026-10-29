// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IArbSys} from "../interfaces/IArbSys.sol";
import {IBridge} from "../interfaces/IBridge.sol";
import {IRouteRegistry} from "../interfaces/IRouteRegistry.sol";
import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {FundsInContext, FundsOutContext} from "../interfaces/RouteTypes.sol";

/// @title RgbSettlementModule
/// @notice Permanent RGB backing records for deposits and rebalance credits.
/// @dev Only the paired registry may invoke hooks. Records store net amounts and
///      destination network ids. Release checks validate each reference without
///      consuming records.
///      One instance may serve several RGB networks, distinguished by record tags.
///      Bridge enforces liquidity and burn replay checks; enclaves validate consignments.
contract RgbSettlementModule is ISettlementModule {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Arbitrum system precompile exposing the child-chain block number.
    IArbSys internal constant ARBSYS = IArbSys(address(100));

    /// @notice Canonical RGB network used by the two-argument rgb-lib lookup ABI.
    uint256 public constant RGB_NETWORK = 827166;

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Constructor was called with `address(0)`.
    error InvalidRouteRegistry();

    /// @notice Caller is not the configured `RouteRegistry`.
    error NotRouteRegistry();

    /// @notice An `onFundsIn` call referenced an `operationId` that already
    ///         has a non-zero record. Re-using an `operationId` would
    ///         silently overwrite the previous net amount and is rejected.
    error DuplicateOperationId();

    /// @notice `onFundsIn` `settlementData` decoded to a zero RGB OpId. The RGB
    ///         route requires a non-zero OpId (it is threaded to the RGB side).
    error InvalidRgbOpId();

    /// @notice The lock was submitted at or after its exclusive maximum L2 block.
    error LockWindowExpired(uint256 l2Block, uint64 beforeBlock);

    /// @notice `ctx.destAddress` was non-empty; RGB destinations are carried in consignments.
    error UnexpectedDestinationAddress();

    /// @notice A `beforeFundsOut` call referenced an `operationId` that has no
    ///         `fundsInRecords` entry (never recorded on-chain).
    error FundsInNotFound(bytes32 operationId);

    /// @notice A `beforeFundsOut` operation id exists, but it was minted to a
    ///         different RGB network than the one this release burns from. Blocks
    ///         a burn on one RGB network from proving its backing with a mint
    ///         recorded for another RGB mint/burn network.
    error FundsInRecordChainMismatch(bytes32 operationId, uint256 expected, uint256 recorded);

    /// @notice A physical `beforeFundsOut` release supplied no FundsIn
    ///         accounting record. It must reference at least one operation id
    ///         from the proof-of-mint ledger.
    error EmptySettlementRecords();

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice The `RouteRegistry` instance authorized to drive this module.
    ///         The pairing is fixed at deploy time.
    address public immutable routeRegistry;

    /// @notice Net token amount backing each RGB mint id; zero means unrecorded.
    /// @dev Records are permanent and are not consumed by release checks.
    mapping(bytes32 operationId => uint256 netAmount) public fundsInRecords;

    /// @notice Destination RGB network for each recorded mint id.
    mapping(bytes32 operationId => uint256 chainId) public fundsInRecordChainIds;

    /// @notice Funded Arbitrum L2 height for each RGB mint id, encoded as block + 1.
    /// @dev Zero means absent. Records are permanent and scoped by the full
    ///      Bridge-derived operation id, which includes the RGB network and net amount.
    mapping(bytes32 operationId => uint64 l2BlockPlusOne) public fundsInRecordL2Blocks;

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyRouteRegistry() {
        if (msg.sender != routeRegistry) revert NotRouteRegistry();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param routeRegistry_         The `RouteRegistry` deployment that will drive
    ///                               this module. Must be non-zero.
    constructor(address routeRegistry_) {
        if (routeRegistry_ == address(0)) revert InvalidRouteRegistry();
        routeRegistry = routeRegistry_;
    }

    // =========================================================================
    // ISettlementModule
    // =========================================================================

    /// @inheritdoc ISettlementModule
    function usesRgbMintDepositId() external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc ISettlementModule
    /// @dev Records `netAmount` and destination network once per `operationId`.
    ///      Bridge ids bind (network, mint OpId, net amount), excluding sender and nonce;
    ///      deposits and rebalance credits for the same tuple hit the duplicate guard.
    ///      settlementData is abi.encode(uint256 rgbOpId, uint64 beforeBlock).
    ///      `beforeBlock` is an exclusive maximum Arbitrum L2 block. destAddress must be empty:
    ///      the RGB destination is carried in the consignment, not this argument.
    /// @return rgbOpId Mint OpId decoded from `settlementData`.
    function onFundsIn(FundsInContext calldata ctx, bytes calldata settlementData)
        external
        override
        onlyRouteRegistry
        returns (uint256 rgbOpId)
    {
        if (bytes(ctx.destAddress).length != 0) revert UnexpectedDestinationAddress();

        uint64 beforeBlock;
        (rgbOpId, beforeBlock) = abi.decode(settlementData, (uint256, uint64));
        if (rgbOpId == 0) revert InvalidRgbOpId();

        uint256 l2Block = ARBSYS.arbBlockNumber();
        if (l2Block >= beforeBlock) revert LockWindowExpired(l2Block, beforeBlock);

        if (fundsInRecords[ctx.operationId] != 0) revert DuplicateOperationId();
        fundsInRecords[ctx.operationId] = ctx.netAmount;
        // Tag the record with the RGB network it was minted to, so a release
        // can only cite it when burning from that same network.
        fundsInRecordChainIds[ctx.operationId] = ctx.destChainId;
        // Safe because l2Block < beforeBlock and beforeBlock is uint64.
        // forge-lint: disable-next-line(unsafe-typecast)
        fundsInRecordL2Blocks[ctx.operationId] = uint64(l2Block + 1);
    }

    /// @notice Returns the funded L2 height for one canonical RGB mint claim.
    /// @dev Matches rgb-lib's BFA resolver ABI. `netAmount` is the post-commission
    ///      amount committed by Bridge. Zero means that this module has no record.
    function getFundsInBlock(uint256 rgbOpId, uint256 netAmount) external view returns (uint64 l2BlockPlusOne) {
        address bridge_ = IRouteRegistry(routeRegistry).bridge();
        bytes32 operationId = IBridge(bridge_).rgbMintDepositId(RGB_NETWORK, rgbOpId, netAmount);
        return fundsInRecordL2Blocks[operationId];
    }

    /// @notice Returns RGB mint amounts for operation ids in caller-supplied order.
    /// @dev Missing ids return zero. This batches state-based resolver lookups
    ///      without introducing another persistent mapping.
    function getFundsInRecords(bytes32[] calldata operationIds) external view returns (uint256[] memory netAmounts) {
        netAmounts = new uint256[](operationIds.length);
        for (uint256 i; i < operationIds.length; ++i) {
            netAmounts[i] = fundsInRecords[operationIds[i]];
        }
    }

    /// @inheritdoc ISettlementModule
    /// @dev Decodes `settlementData` as `bytes32[] operationIds` and requires
    ///      at least one id for a physical release before verifying every
    ///      referenced mint. An authenticated accounting-only
    ///      rebalance may intentionally carry no debit-side record.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata settlementData)
        external
        view
        override
        onlyRouteRegistry
    {
        bytes32[] memory operationIds = abi.decode(settlementData, (bytes32[]));

        if (operationIds.length == 0 && !ctx.isRebalance) revert EmptySettlementRecords();

        for (uint256 i = 0; i < operationIds.length; i++) {
            uint256 recorded = fundsInRecords[operationIds[i]];
            if (recorded == 0) revert FundsInNotFound(operationIds[i]);
            uint256 recordChainId = fundsInRecordChainIds[operationIds[i]];
            if (recordChainId != ctx.sourceChainId) {
                revert FundsInRecordChainMismatch(operationIds[i], ctx.sourceChainId, recordChainId);
            }
        }
    }
}
