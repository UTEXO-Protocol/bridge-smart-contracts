// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {FundsInContext, FundsOutContext} from "../interfaces/RouteTypes.sol";
import {RgbSettlementModule} from "./RgbSettlementModule.sol";

/// @title RgbOutboundSettlementModule
/// @notice Checks RGB backing records for routes with a non-RGB credit leg.
/// @dev A route has one module slot: this wrapper reads the canonical ledger instead
///      of duplicating its history. Debit checks do not consume records.
///      Debits require non-empty record references with exact amounts and network tags.
///      Credits create no record or RGB event.
///      Both hooks accept calls only from the paired registry.
contract RgbOutboundSettlementModule is ISettlementModule {
    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Constructor was called with a zero `routeRegistry_`.
    error InvalidRouteRegistry();

    /// @notice Constructor was called with a zero `rgbModule_`.
    error InvalidRgbModule();

    /// @notice Caller is not the configured `RouteRegistry`.
    error NotRouteRegistry();

    /// @notice A `beforeFundsOut` call referenced an `operationId` that has no
    ///         record in the wrapped module's ledger.
    error FundsInNotFound(bytes32 operationId);

    /// @notice A referenced operation id exists, but the supplied amount does
    ///         not match the recorded mint amount exactly.
    error AmountMismatch(bytes32 operationId, uint256 provided, uint256 recorded);

    /// @notice A referenced operation id exists in the wrapped ledger, but it was
    ///         minted to a different RGB network than the one this release burns
    ///         from. Mirrors `RgbSettlementModule`'s same-network scope check.
    error FundsInRecordChainMismatch(bytes32 operationId, uint256 expected, uint256 recorded);

    /// @notice `beforeFundsOut` `settlementData` decoded to `operationIds` and
    ///         `amounts` arrays of different lengths.
    error SettlementDataLengthMismatch();

    /// @notice The outbound RGB debit supplied no FundsIn accounting record.
    error EmptySettlementRecords();

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice The `RouteRegistry` instance authorized to drive this module.
    address public immutable routeRegistry;

    /// @notice Canonical `RgbSettlementModule` of the RGB network on the debit
    ///         side. Its public `fundsInRecords` ledger is the source of truth
    ///         this module verifies against.
    RgbSettlementModule public immutable rgbModule;

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
    /// @param rgbModule_             Canonical `RgbSettlementModule` whose ledger the
    ///                               debit-side check reads. Must be non-zero.
    constructor(address routeRegistry_, address rgbModule_) {
        if (routeRegistry_ == address(0)) revert InvalidRouteRegistry();
        if (rgbModule_ == address(0)) revert InvalidRgbModule();
        routeRegistry = routeRegistry_;
        rgbModule = RgbSettlementModule(rgbModule_);
    }

    // =========================================================================
    // ISettlementModule
    // =========================================================================

    /// @inheritdoc ISettlementModule
    function usesRgbMintDepositId() external pure override returns (bool) {
        return false;
    }

    /// @inheritdoc ISettlementModule
    /// @dev Credit side needs no RGB bookkeeping: no record, no correlation id,
    ///      hence no `FundsIn` event from Bridge for this leg.
    function onFundsIn(FundsInContext calldata, bytes calldata)
        external
        view
        override
        onlyRouteRegistry
        returns (uint256)
    {
        return 0;
    }

    /// @inheritdoc ISettlementModule
    /// @dev Reads `(bytes32[] operationIds, uint256[] amounts)` from settlementData.
    ///      Requires at least one pair even for rebalances. Every record must exist in
    ///      the wrapped ledger with an exact amount and the source RGB network tag.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata settlementData)
        external
        view
        override
        onlyRouteRegistry
    {
        (bytes32[] memory operationIds, uint256[] memory amounts) = abi.decode(settlementData, (bytes32[], uint256[]));

        if (operationIds.length != amounts.length) revert SettlementDataLengthMismatch();
        if (operationIds.length == 0) revert EmptySettlementRecords();

        for (uint256 i = 0; i < operationIds.length; i++) {
            uint256 recorded = rgbModule.fundsInRecords(operationIds[i]);
            if (recorded == 0) revert FundsInNotFound(operationIds[i]);
            if (recorded != amounts[i]) revert AmountMismatch(operationIds[i], amounts[i], recorded);
            uint256 recordChainId = rgbModule.fundsInRecordChainIds(operationIds[i]);
            if (recordChainId != ctx.sourceChainId) {
                revert FundsInRecordChainMismatch(operationIds[i], ctx.sourceChainId, recordChainId);
            }
        }
    }
}
