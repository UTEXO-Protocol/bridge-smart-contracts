// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {FundsInContext, FundsOutContext} from "../interfaces/RouteTypes.sol";
import {RgbSettlementModule} from "./RgbSettlementModule.sol";

/// @title RgbOutboundSettlementModule
/// @notice `ISettlementModule` for rebalance routes whose DEBIT side is an RGB
///         network but whose CREDIT side is NOT an RGB network, so no RGB
///         bookkeeping is needed on credit — e.g. `(RGB, Arch)`: liquidity
///         migrates toward Arch, nothing is minted on an RGB network, so the
///         credit writes no record and emits no `FundsIn`.
///
///         Routes where BOTH sides are RGB networks (e.g. mint/burn ↔ pool) do
///         NOT use this module: they use the canonical `RgbSettlementModule`,
///         whose credit hook writes the destination-network record (tagged via
///         `fundsInRecordChainIds`) so a later release from that network can
///         reference it.
///
/// @dev The debit-side check must read the SAME `fundsInRecords` ledger the
///      canonical `RgbSettlementModule` of that RGB network writes — a burn
///      consignment references operation ids recorded there by past deposits
///      and rebalances. A route slot holds exactly one module, so this module
///      wraps the canonical one by reading its public ledger (view-only, no
///      auth needed on the target) instead of duplicating storage.
///
///      Hook semantics:
///        - `beforeFundsOut`: identical existence + exact-amount + same-network
///          verification as `RgbSettlementModule.beforeFundsOut` (same
///          `settlementData` layout, `abi.encode(bytes32[] operationIds,
///          uint256[] amounts)`), evaluated against the wrapped module's ledger,
///          including its `fundsInRecordChainIds` network tag vs
///          `ctx.sourceChainId`. Pure reads — no consumption, matching the
///          canonical release semantics (solvency is owned by
///          `Bridge.lockedLiquidity`, replay by `Bridge.consumedBurnIds`).
///        - `onFundsIn`: returns `0` and writes nothing. No record is created
///          (nothing was minted with a new OpId on the credit side) and Bridge
///          therefore emits no RGB-only `FundsIn` event for this leg.
///
///      Auth mirrors `RgbSettlementModule`: both hooks are gated on the
///      immutable `routeRegistry` pairing, so a foreign registry cannot drive
///      this module even though the hooks mutate nothing.
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

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice The `RouteRegistry` instance authorised to drive this module.
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

    /// @param routeRegistry_ The `RouteRegistry` deployment that will drive
    ///                       this module. Must be non-zero.
    /// @param rgbModule_     Canonical `RgbSettlementModule` whose ledger the
    ///                       debit-side check reads. Must be non-zero.
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
    /// @dev Same decoding and checks as `RgbSettlementModule.beforeFundsOut`,
    ///      but against the wrapped module's ledger: every referenced
    ///      `operationId` must exist there, with an exactly matching amount, and
    ///      recorded for the release's `ctx.sourceChainId` RGB network.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata settlementData)
        external
        view
        override
        onlyRouteRegistry
    {
        (bytes32[] memory operationIds, uint256[] memory amounts) = abi.decode(settlementData, (bytes32[], uint256[]));

        if (operationIds.length != amounts.length) revert SettlementDataLengthMismatch();

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
