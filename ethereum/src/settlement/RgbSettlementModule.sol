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
///        `fundsInRecordChainIds[operationId] = destChainId` — the RGB network
///        the mint was credited TO. One module instance can serve several RGB
///        networks (e.g. a pool and a mint/burn network) from this one ledger,
///        because every record is tagged with its network. Records are keyed by
///        the globally-unique `operationId`, so no cross-network key collision
///        is possible; the tag exists to enforce network SCOPE at release.
///
///      Release semantics (existence + exact-amount + same-network check, no
///      consumption):
///        On `beforeFundsOut` the TEE supplies the `(operationId, amount)`
///        pairs extracted from the burn consignment. The module checks that
///        every operation id EXISTS in `fundsInRecords`, that its recorded
///        amount EQUALS the supplied amount, and that its recorded network
///        EQUALS the release's `sourceChainId` — so a burn on one RGB network
///        cannot cross-satisfy its proof-of-mint with a record minted on a
///        different RGB network. It does NOT consume/delete the records, does
///        NOT sum them, and does NOT tie them to the `fundsOut` amount — it only
///        proves the referenced mints are real and belong to the burning
///        network. This delegates to the contract the check a TEE would
///        otherwise need an ETH light node for ("does the EVM mint event
///        exist?").
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

    /// @notice A `beforeFundsOut` operation id exists, but it was minted to a
    ///         different RGB network than the one this release burns from. Blocks
    ///         a burn on one RGB network from proving its backing with a mint
    ///         recorded for another (e.g. a pool burn citing a mint/burn record).
    error FundsInRecordChainMismatch(bytes32 operationId, uint256 expected, uint256 recorded);

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

    /// @notice `operationId → RGB network id` the mint was credited to (the
    ///         deposit's `destChainId`). Written alongside `fundsInRecords` and
    ///         checked at release so a burn can only reference mints from its own
    ///         RGB network. Zero for an unrecorded id (which fails the
    ///         `fundsInRecords` existence check first).
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
        // Tag the record with the RGB network it was minted to, so a release
        // can only cite it when burning from that same network.
        fundsInRecordChainIds[ctx.operationId] = ctx.destChainId;

        rgbOpId = abi.decode(settlementData, (uint256));
        if (rgbOpId == 0) revert InvalidRgbOpId();
    }

    /// @inheritdoc ISettlementModule
    /// @dev Decodes `settlementData` as `(bytes32[] operationIds, uint256[] amounts)`
    ///      and verifies every referenced mint: each `operationId` must exist,
    ///      its recorded amount must equal the supplied amount, and its recorded
    ///      RGB network must equal the release's `ctx.sourceChainId`.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata settlementData)
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
            uint256 recordChainId = fundsInRecordChainIds[operationIds[i]];
            if (recordChainId != ctx.sourceChainId) {
                revert FundsInRecordChainMismatch(operationIds[i], ctx.sourceChainId, recordChainId);
            }
        }
    }
}
