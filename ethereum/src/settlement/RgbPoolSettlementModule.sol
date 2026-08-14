// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {FundsInContext, FundsOutContext} from "../interfaces/RouteTypes.sol";
import {RgbSettlementModule} from "./RgbSettlementModule.sol";

/// @title RgbPoolSettlementModule
/// @notice Settlement adapter for an RGB liquidity-pool network whose backing
///         records live in a separate RGB mint/burn network's canonical
///         `RgbSettlementModule` ledger.
///
/// @dev The pool network deliberately has asymmetric settlement semantics:
///
///      - credit (`onFundsIn`, e.g. Arbitrum -> Pool): write no canonical
///        record and return no RGB OpId. Bridge therefore emits only its
///        route-agnostic `BridgeFundsIn` event, not the RGB mint/burn `FundsIn`
///        event;
///      - debit (`beforeFundsOut`, e.g. Pool -> Arbitrum): verify every supplied
///        Bridge operation id against the canonical mint/burn ledger. Records
///        must exist, match the supplied amount exactly, and be tagged with the
///        immutable backing mint/burn chain id.
///
///      Both chain ids are immutable to make an accidental route wiring error
///      fail closed. This module is intended for the physical public-chain <->
///      pool routes. MintBurn -> Pool rebalances use
///      `RgbOutboundSettlementModule` (canonical debit check, no pool credit
///      write); Pool -> MintBurn rebalances use `RgbSettlementModule` so the
///      mint/burn credit leg creates its canonical record.
contract RgbPoolSettlementModule is ISettlementModule {
    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidRouteRegistry();
    error InvalidRgbModule();
    error InvalidPoolChainId();
    error InvalidBackingRecordChainId();
    error IdenticalChainIds();
    error NotRouteRegistry();
    error UnexpectedPoolDestination(uint256 expected, uint256 actual);
    error UnexpectedPoolSource(uint256 expected, uint256 actual);
    error FundsInNotFound(bytes32 operationId);
    error AmountMismatch(bytes32 operationId, uint256 provided, uint256 recorded);
    error FundsInRecordChainMismatch(bytes32 operationId, uint256 expected, uint256 recorded);
    error SettlementDataLengthMismatch();
    error EmptySettlementRecords();

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @notice The only RouteRegistry authorised to invoke either hook.
    address public immutable routeRegistry;

    /// @notice Canonical ledger written by the RGB mint/burn routes.
    RgbSettlementModule public immutable rgbModule;

    /// @notice Backend-assigned chain id of the RGB liquidity-pool network.
    uint256 public immutable poolChainId;

    /// @notice RGB mint/burn chain id whose records back pool withdrawals.
    uint256 public immutable backingRecordChainId;

    modifier onlyRouteRegistry() {
        if (msg.sender != routeRegistry) revert NotRouteRegistry();
        _;
    }

    constructor(address routeRegistry_, address rgbModule_, uint256 poolChainId_, uint256 backingRecordChainId_) {
        if (routeRegistry_ == address(0)) revert InvalidRouteRegistry();
        if (rgbModule_ == address(0)) revert InvalidRgbModule();
        if (poolChainId_ == 0) revert InvalidPoolChainId();
        if (backingRecordChainId_ == 0) revert InvalidBackingRecordChainId();
        if (poolChainId_ == backingRecordChainId_) revert IdenticalChainIds();

        routeRegistry = routeRegistry_;
        rgbModule = RgbSettlementModule(rgbModule_);
        poolChainId = poolChainId_;
        backingRecordChainId = backingRecordChainId_;
    }

    /// @inheritdoc ISettlementModule
    /// @dev Pool credits have no mint/burn bookkeeping. Returning zero is what
    ///      suppresses Bridge's RGB-specific `FundsIn` event.
    function onFundsIn(FundsInContext calldata ctx, bytes calldata)
        external
        view
        override
        onlyRouteRegistry
        returns (uint256)
    {
        if (ctx.destChainId != poolChainId) {
            revert UnexpectedPoolDestination(poolChainId, ctx.destChainId);
        }
        return 0;
    }

    /// @inheritdoc ISettlementModule
    /// @dev `settlementData = abi.encode(bytes32[] operationIds, uint256[] amounts)`.
    ///      The operation ids are the canonical Bridge ids, not RGB OpIds.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata settlementData)
        external
        view
        override
        onlyRouteRegistry
    {
        if (ctx.sourceChainId != poolChainId) {
            revert UnexpectedPoolSource(poolChainId, ctx.sourceChainId);
        }

        (bytes32[] memory operationIds, uint256[] memory amounts) = abi.decode(settlementData, (bytes32[], uint256[]));

        if (operationIds.length != amounts.length) revert SettlementDataLengthMismatch();
        if (operationIds.length == 0) revert EmptySettlementRecords();

        for (uint256 i = 0; i < operationIds.length; i++) {
            uint256 recorded = rgbModule.fundsInRecords(operationIds[i]);
            if (recorded == 0) revert FundsInNotFound(operationIds[i]);
            if (recorded != amounts[i]) revert AmountMismatch(operationIds[i], amounts[i], recorded);

            uint256 recordChainId = rgbModule.fundsInRecordChainIds(operationIds[i]);
            if (recordChainId != backingRecordChainId) {
                revert FundsInRecordChainMismatch(operationIds[i], backingRecordChainId, recordChainId);
            }
        }
    }
}
