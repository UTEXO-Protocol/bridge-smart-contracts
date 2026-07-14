// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {FundsInContext, FundsOutContext} from "../interfaces/RouteTypes.sol";

/// @title RgbSettlementModule
/// @notice `ISettlementModule` for the RGB → Arbitrum route. Records the
///         on-chain RGB-mint ledger (`operationId → netAmount`) and, on
///         release, verifies that the operation ids a burn consignment
///         references were actually minted on-chain for the claimed amounts.
///
/// @dev Storage layout:
///        `fundsInRecords[operationId] = netAmount` — the post-commission
///        amount minted on the RGB side for that deposit. RGB binds an
///        `operationId` to an exact mint amount, so the record is the
///        canonical on-chain proof of "this mint happened, for this amount".
///
///      Release semantics (existence + exact-amount check, no consumption):
///        On `beforeFundsOut` the TEE supplies the `(operationId, amount)`
///        pairs extracted from the burn consignment. The module checks that
///        every operation id EXISTS in `fundsInRecords` and that its recorded
///        amount EQUALS the supplied amount. It does NOT consume/delete the
///        records, does NOT sum them, and does NOT tie them to the
///        `fundsOut` amount — it only proves the referenced mints are real.
///        This delegates to the contract the check a TEE would otherwise need
///        an ETH light node for ("does the EVM mint event exist?").
///
///        Solvency (no release beyond bridged liquidity) and replay protection
///        are owned elsewhere: `Bridge.lockedLiquidity` caps total outflow per
///        source chain, and `Bridge.consumedBurnIds` blocks burn replays. That
///        is why per-record consumption is unnecessary here, and why duplicate
///        operation ids in `settlementData` are harmless (the checks are pure
///        reads).
///
///      Auth: `onFundsIn` / `beforeFundsOut` are gated on the immutable
///      `routeRegistry` address. Re-pointing at a different registry =
///      redeploy the module + rotate the route under federation governance.
///
///      `settlementData` layout:
///        - `onFundsIn`:  `abi.encode(uint256 rgbOpId)` — the RGB OpId, decoded
///                        and returned for Bridge's `FundsIn` event. The record
///                        is keyed by the bridge-derived `ctx.operationId`, not
///                        by this value.
///        - `beforeFundsOut`: `abi.encode(bytes32[] operationIds, uint256[] amounts)`
///                        (equal-length parallel arrays).
///
///      This contract owns no tokens and mutates
///      no state on release — `beforeFundsOut` is a pure validation. Reverts
///      here roll back the surrounding `Bridge.fundsOut` call atomically.
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

    /// @notice A `beforeFundsOut` call referenced an `operationId` that has no
    ///         `fundsInRecords` entry (never recorded on-chain).
    error FundsInNotFound(bytes32 operationId);

    /// @notice A `beforeFundsOut` operation id exists, but the amount supplied
    ///         in `settlementData` does not match the on-chain mint record.
    ///         RGB binds an operationId to an exact mint amount, so the match
    ///         must be exact.
    error AmountMismatch(bytes32 operationId, uint256 provided, uint256 recorded);

    /// @notice `beforeFundsOut` `settlementData` decoded to `operationIds` and
    ///         `amounts` arrays of different lengths.
    error SettlementDataLengthMismatch();

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice The `RouteRegistry` instance authorised to drive this module.
    ///         The pairing is fixed at deploy time.
    address public immutable routeRegistry;

    /// @notice `operationId → netAmount` ledger of on-chain RGB mints. A zero
    ///         value means "never recorded under this id". Records are written
    ///         once at `onFundsIn` and never cleared — they are a permanent
    ///         proof-of-mint ledger, not a consumable balance.
    mapping(bytes32 operationId => uint256 netAmount) public fundsInRecords;

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
    constructor(address routeRegistry_) {
        if (routeRegistry_ == address(0)) revert InvalidRouteRegistry();
        routeRegistry = routeRegistry_;
    }

    // =========================================================================
    // ISettlementModule
    // =========================================================================

    /// @inheritdoc ISettlementModule
    /// @dev Records the post-commission `netAmount` under the canonical
    ///      `ctx.operationId` (the bridge-derived, unpredictable key). Reverts
    ///      `DuplicateOperationId` if a non-zero record already exists under
    ///      that key. `settlementData` carries the RGB OpId as `abi.encode(uint256
    ///      rgbOpId)`; it is decoded and returned so Bridge can surface it in the
    ///      RGB-only `FundsIn` event. The RGB OpId is NOT the dedup key — it is a
    ///      pass-through correlation id (a mempool copy of it cannot pre-empt a
    ///      deposit, since dedup is on `ctx.operationId`).
    function onFundsIn(FundsInContext calldata ctx, bytes calldata settlementData)
        external
        override
        onlyRouteRegistry
        returns (uint256 rgbOpId)
    {
        if (fundsInRecords[ctx.operationId] != 0) revert DuplicateOperationId();
        fundsInRecords[ctx.operationId] = ctx.netAmount;

        rgbOpId = abi.decode(settlementData, (uint256));
        if (rgbOpId == 0) revert InvalidRgbOpId();
    }

    /// @inheritdoc ISettlementModule
    /// @dev Decodes `settlementData` as `(bytes32[] operationIds, uint256[] amounts)`
    ///      and verifies every referenced mint: each `operationId` must exist
    ///      and its recorded amount must equal the supplied amount.
    function beforeFundsOut(
        FundsOutContext calldata,
        /* ctx */
        bytes calldata settlementData
    )
        external
        view
        override
        onlyRouteRegistry
    {
        (bytes32[] memory operationIds, uint256[] memory amounts) = abi.decode(settlementData, (bytes32[], uint256[]));

        if (operationIds.length != amounts.length) revert SettlementDataLengthMismatch();

        for (uint256 i = 0; i < operationIds.length; i++) {
            uint256 recorded = fundsInRecords[operationIds[i]];
            if (recorded == 0) revert FundsInNotFound(operationIds[i]);
            if (recorded != amounts[i]) revert AmountMismatch(operationIds[i], amounts[i], recorded);
        }
    }
}
