// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test }                from 'forge-std/Test.sol';
import { RgbSettlementModule } from '../src/settlement/RgbSettlementModule.sol';
import { FundsInContext, FundsOutContext } from '../src/interfaces/RouteTypes.sol';

/// @title RgbSettlementModuleTest
/// @notice Unit tests for the standalone settlement module. The module is
///         driven via `vm.prank(routeRegistry)` — no actual `RouteRegistry`.
///
/// @dev    Release semantics under test (post R-C-01 rework): `beforeFundsOut`
///         is a pure (view) proof-of-mint check. It decodes
///         `(uint256[] operationIds, uint256[] amounts)` and asserts every id
///         EXISTS in `fundsInRecords` with an EXACTLY matching amount. It does
///         NOT consume/delete records, does NOT sum them, and does NOT compare
///         against `ctx.amount` — solvency and replay are owned by the Bridge
///         (`lockedLiquidity` / `consumedBurnIds`).
contract RgbSettlementModuleTest is Test {
    RgbSettlementModule module;

    address routeRegistry = makeAddr('routeRegistry');
    address attacker      = makeAddr('attacker');
    address user          = makeAddr('user');
    address recipient     = makeAddr('recipient');
    address token         = makeAddr('token');

    uint256 constant SOURCE_CHAIN_ID = 1_000_001;  // RGB
    uint256 constant DEST_CHAIN_ID   = 42161;      // arbitrum

    bytes32 constant TX_ID_1 = bytes32(uint256(100));
    bytes32 constant TX_ID_2 = bytes32(uint256(101));
    bytes32 constant TX_ID_3 = bytes32(uint256(102));

    uint256 constant AMOUNT      = 100e18;
    uint256 constant BURN_ID     = 9_001;

    /// @dev Non-zero RGB OpId threaded through `onFundsIn`'s settlementData.
    uint256 constant RGB_OP_ID = 0xABCDEF;

    function setUp() public {
        module = new RgbSettlementModule(routeRegistry);
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    function _fundsInCtx(bytes32 operationId, uint256 netAmount)
        internal
        view
        returns (FundsInContext memory)
    {
        return FundsInContext({
            token:         token,
            sender:        user,
            sourceSender:  bytes32(uint256(uint160(user))),
            grossAmount:   netAmount,           // gross == net for these tests
            netAmount:     netAmount,
            operationId:   operationId,
            senderNonce:   0,
            sourceChainId: SOURCE_CHAIN_ID,
            destChainId:   DEST_CHAIN_ID,
            destAddress:   'rgb:asset/utxo1abc'
        });
    }

    /// @dev `ctx.amount` is irrelevant to the reworked module — it never
    ///      compares the release amount against the mint records. We still
    ///      supply a context so the signature matches.
    function _fundsOutCtx() internal view returns (FundsOutContext memory) {
        return FundsOutContext({
            token:         token,
            recipient:     recipient,
            amount:        AMOUNT,
            burnId:        BURN_ID,
            sourceChainId: SOURCE_CHAIN_ID,
            destChainId:   DEST_CHAIN_ID,
            sourceAddress: 'rgb:sender/utxo1src'
        });
    }

    /// @dev Encodes the two parallel arrays the reworked module expects
    ///      (`(bytes32[] operationIds, uint256[] amounts)`).
    function _settlementData(bytes32[] memory ids, uint256[] memory amounts)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(ids, amounts);
    }

    function _single(bytes32 value) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = value;
    }

    function _amt(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _amtPair(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    /// @dev `onFundsIn` settlementData must decode to a non-zero RGB OpId.
    function _record(bytes32 operationId, uint256 netAmount) internal {
        vm.prank(routeRegistry);
        module.onFundsIn(_fundsInCtx(operationId, netAmount), abi.encode(RGB_OP_ID));
    }

    // ========================================================================
    // Constructor
    // ========================================================================

    function test_constructor_setsRouteRegistry() public view {
        assertEq(module.routeRegistry(), routeRegistry);
    }

    function test_constructor_revertsOnZeroRouteRegistry() public {
        vm.expectRevert(RgbSettlementModule.InvalidRouteRegistry.selector);
        new RgbSettlementModule(address(0));
    }

    // ========================================================================
    // onFundsIn
    // ========================================================================

    function test_onFundsIn_recordsNetAmount() public {
        _record(TX_ID_1, AMOUNT);
        assertEq(module.fundsInRecords(TX_ID_1), AMOUNT);
    }

    function test_onFundsIn_returnsRgbOpId() public {
        vm.prank(routeRegistry);
        uint256 returned = module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), abi.encode(RGB_OP_ID));
        assertEq(returned, RGB_OP_ID, 'returns decoded rgb op id');
    }

    function test_onFundsIn_revertsOnZeroRgbOpId() public {
        vm.prank(routeRegistry);
        vm.expectRevert(RgbSettlementModule.InvalidRgbOpId.selector);
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), abi.encode(uint256(0)));
    }

    function test_onFundsIn_revertsOnDuplicateOperationId() public {
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), abi.encode(RGB_OP_ID));
    }

    function test_onFundsIn_revertsIfNotRouteRegistry() public {
        vm.prank(attacker);
        vm.expectRevert(RgbSettlementModule.NotRouteRegistry.selector);
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), abi.encode(RGB_OP_ID));
    }

    // ========================================================================
    // beforeFundsOut — happy paths (existence + exact-amount, no consumption)
    // ========================================================================

    function test_beforeFundsOut_passesOnSingleExactMatch() public {
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1), _amt(AMOUNT)));

        // Proof-of-mint ledger is permanent: the check must not mutate it.
        assertEq(module.fundsInRecords(TX_ID_1), AMOUNT, 'record left intact (no consumption)');
    }

    function test_beforeFundsOut_passesOnMultipleExactMatches() public {
        uint256 amount1 = 60e18;
        uint256 amount2 = 40e18;
        _record(TX_ID_1, amount1);
        _record(TX_ID_2, amount2);

        vm.prank(routeRegistry);
        module.beforeFundsOut(
            _fundsOutCtx(),
            _settlementData(_pair(TX_ID_1, TX_ID_2), _amtPair(amount1, amount2))
        );

        assertEq(module.fundsInRecords(TX_ID_1), amount1, 'record 1 intact');
        assertEq(module.fundsInRecords(TX_ID_2), amount2, 'record 2 intact');
    }

    function test_beforeFundsOut_passesOnEmptyArrays() public {
        // Degenerate input: nothing to verify, nothing to revert on.
        vm.prank(routeRegistry);
        module.beforeFundsOut(
            _fundsOutCtx(),
            _settlementData(new bytes32[](0), new uint256[](0))
        );
    }

    function test_beforeFundsOut_duplicateIdsAreHarmless() public {
        // The check is a pure read, so referencing the same id twice with the
        // same (correct) amount simply passes both times — no double-spend
        // here; solvency is the Bridge's concern.
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        module.beforeFundsOut(
            _fundsOutCtx(),
            _settlementData(_pair(TX_ID_1, TX_ID_1), _amtPair(AMOUNT, AMOUNT))
        );

        assertEq(module.fundsInRecords(TX_ID_1), AMOUNT, 'record intact');
    }

    function test_beforeFundsOut_isViewAcrossManyCalls() public {
        // Repeated verification of the same record never depletes it.
        _record(TX_ID_1, AMOUNT);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(routeRegistry);
            module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1), _amt(AMOUNT)));
        }

        assertEq(module.fundsInRecords(TX_ID_1), AMOUNT, 'record never consumed');
    }

    // ========================================================================
    // beforeFundsOut — reverts
    // ========================================================================

    function test_beforeFundsOut_revertsOnUnknownFundsInId() public {
        // No record ever made for TX_ID_1.
        vm.prank(routeRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(RgbSettlementModule.FundsInNotFound.selector, TX_ID_1)
        );
        module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1), _amt(AMOUNT)));
    }

    function test_beforeFundsOut_revertsWhenAmountAboveRecord() public {
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbSettlementModule.AmountMismatch.selector, TX_ID_1, AMOUNT + 1, AMOUNT
            )
        );
        module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1), _amt(AMOUNT + 1)));
    }

    function test_beforeFundsOut_revertsWhenAmountBelowRecord() public {
        // RGB binds an operationId to an EXACT mint amount, so even an
        // under-claim is rejected — the supplied amount must equal the record.
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbSettlementModule.AmountMismatch.selector, TX_ID_1, AMOUNT - 1, AMOUNT
            )
        );
        module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1), _amt(AMOUNT - 1)));
    }

    function test_beforeFundsOut_revertsOnLengthMismatch() public {
        _record(TX_ID_1, AMOUNT);

        // Two ids but one amount.
        vm.prank(routeRegistry);
        vm.expectRevert(RgbSettlementModule.SettlementDataLengthMismatch.selector);
        module.beforeFundsOut(
            _fundsOutCtx(),
            _settlementData(_pair(TX_ID_1, TX_ID_2), _amt(AMOUNT))
        );
    }

    function test_beforeFundsOut_revertsOnSecondIdMismatch() public {
        // First id matches, second does not — the loop must still catch it.
        _record(TX_ID_1, AMOUNT);
        _record(TX_ID_2, AMOUNT);

        vm.prank(routeRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbSettlementModule.AmountMismatch.selector, TX_ID_2, AMOUNT + 5, AMOUNT
            )
        );
        module.beforeFundsOut(
            _fundsOutCtx(),
            _settlementData(_pair(TX_ID_1, TX_ID_2), _amtPair(AMOUNT, AMOUNT + 5))
        );
    }

    function test_beforeFundsOut_revertsIfNotRouteRegistry() public {
        _record(TX_ID_1, AMOUNT);

        vm.prank(attacker);
        vm.expectRevert(RgbSettlementModule.NotRouteRegistry.selector);
        module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1), _amt(AMOUNT)));
    }

    // ========================================================================
    // beforeFundsOut — fuzz
    // ========================================================================

    /// @dev Any amount that differs from the record must revert; the exact
    ///      record amount must pass. Record is never mutated either way.
    function testFuzz_beforeFundsOut_exactMatchOnly(uint256 recorded, uint256 provided) public {
        recorded = bound(recorded, 1, type(uint128).max);
        provided = bound(provided, 0, type(uint128).max);
        _record(TX_ID_1, recorded);

        if (provided == recorded) {
            vm.prank(routeRegistry);
            module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1), _amt(provided)));
        } else {
            vm.prank(routeRegistry);
            vm.expectRevert(
                abi.encodeWithSelector(
                    RgbSettlementModule.AmountMismatch.selector, TX_ID_1, provided, recorded
                )
            );
            module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1), _amt(provided)));
        }

        assertEq(module.fundsInRecords(TX_ID_1), recorded, 'record never mutated');
    }

}
