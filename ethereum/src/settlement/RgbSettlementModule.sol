// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {FundsInContext, FundsOutContext} from "../interfaces/RouteTypes.sol";

/// @title RgbSettlementModule
/// @notice Permanent RGB backing records for deposits and rebalance credits.
/// @dev Only the paired registry may invoke hooks. Records store net amounts and
///      destination network ids. Release checks match each reference without
///      consuming records or equating their sum to the release amount.
///      One instance may serve several RGB networks, distinguished by record tags.
///      Bridge enforces liquidity and burn replay checks; enclaves validate consignments.
contract RgbSettlementModule is ISettlementModule {
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

    /// @notice `ctx.destAddress` was non-empty; RGB destinations are carried in consignments.
    error UnexpectedDestinationAddress();

    /// @notice A `beforeFundsOut` call referenced an `operationId` that has no
    ///         `fundsInRecords` entry (never recorded on-chain).
    error FundsInNotFound(bytes32 operationId);

    /// @notice A `beforeFundsOut` operation id exists, but the amount supplied
    ///         in `settlementData` does not match the on-chain mint record.
    ///         RGB binds an operationId to an exact mint amount, so the match
    ///         must be exact.
    error AmountMismatch(bytes32 operationId, uint256 provided, uint256 recorded);

    /// @notice A `beforeFundsOut` operation id exists, but it was minted to a
    ///         different RGB network than the one this release burns from. Blocks
    ///         a burn on one RGB network from proving its backing with a mint
    ///         recorded for another RGB mint/burn network.
    error FundsInRecordChainMismatch(bytes32 operationId, uint256 expected, uint256 recorded);

    /// @notice `beforeFundsOut` `settlementData` decoded to `operationIds` and
    ///         `amounts` arrays of different lengths.
    error SettlementDataLengthMismatch();

    /// @notice A physical `beforeFundsOut` release supplied no FundsIn
    ///         accounting record. It must reference at least one
    ///         `(operationId, amount)` pair from the proof-of-mint ledger.
    error EmptySettlementRecords();

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice The `RouteRegistry` instance authorised to drive this module.
    ///         The pairing is fixed at deploy time.
    address public immutable routeRegistry;

    /// @notice Net token amount backing each RGB mint id; zero means unrecorded.
    /// @dev Records are permanent and are not consumed by release checks.
    mapping(bytes32 operationId => uint256 netAmount) public fundsInRecords;

    /// @notice Destination RGB network for each recorded mint id.
    mapping(bytes32 operationId => uint256 chainId) public fundsInRecordChainIds;

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
    /// @dev Records `netAmount` and the destination network once per `operationId`.
    ///      Bridge ids bind (network, mint OpId, net amount), excluding sender and nonce;
    ///      deposits and rebalance credits for the same tuple hit the duplicate guard.
    ///      settlementData is abi.encode(uint256 rgbOpId). destAddress must be empty:
    ///      the RGB destination is carried in the consignment, not this argument.
    function onFundsIn(FundsInContext calldata ctx, bytes calldata settlementData)
        external
        override
        onlyRouteRegistry
        returns (uint256 rgbOpId)
    {
        if (bytes(ctx.destAddress).length != 0) revert UnexpectedDestinationAddress();
        if (fundsInRecords[ctx.operationId] != 0) revert DuplicateOperationId();
        fundsInRecords[ctx.operationId] = ctx.netAmount;
        // Tag the record with the RGB network it was minted to, so a release
        // can only cite it when burning from that same network.
        fundsInRecordChainIds[ctx.operationId] = ctx.destChainId;

        rgbOpId = abi.decode(settlementData, (uint256));
        if (rgbOpId == 0) revert InvalidRgbOpId();
    }

    /// @inheritdoc ISettlementModule
    /// @dev Decodes `settlementData` as `(bytes32[] operationIds, uint256[] amounts)`
    ///      and requires at least one pair for a physical release before
    ///      verifying every referenced mint. An authenticated accounting-only
    ///      rebalance may intentionally carry no debit-side record.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata settlementData)
        external
        view
        override
        onlyRouteRegistry
    {
        (bytes32[] memory operationIds, uint256[] memory amounts) = abi.decode(settlementData, (bytes32[], uint256[]));

        if (operationIds.length != amounts.length) revert SettlementDataLengthMismatch();
        if (operationIds.length == 0 && !ctx.isRebalance) revert EmptySettlementRecords();

        for (uint256 i = 0; i < operationIds.length; i++) {
            uint256 recorded = fundsInRecords[operationIds[i]];
            if (recorded == 0) revert FundsInNotFound(operationIds[i]);
            if (recorded != amounts[i]) revert AmountMismatch(operationIds[i], amounts[i], recorded);
            uint256 recordChainId = fundsInRecordChainIds[operationIds[i]];
            if (recordChainId != ctx.sourceChainId) {
                revert FundsInRecordChainMismatch(operationIds[i], ctx.sourceChainId, recordChainId);
            }
        }
    }
}
