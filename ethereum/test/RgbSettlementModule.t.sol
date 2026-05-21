// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test }                from 'forge-std/Test.sol';
import { RgbSettlementModule } from '../src/settlement/RgbSettlementModule.sol';
import { FundsInContext, FundsOutContext } from '../src/interfaces/RouteTypes.sol';

/// @title RgbSettlementModuleTest
/// @notice Unit tests for the standalone settlement module. The module is
///         driven via `vm.prank(routeRegistry)` — no actual `RouteRegistry`
contract RgbSettlementModuleTest is Test {
    RgbSettlementModule module;

    address routeRegistry = makeAddr('routeRegistry');
    address attacker      = makeAddr('attacker');
    address user          = makeAddr('user');
    address recipient     = makeAddr('recipient');
    address token         = makeAddr('token');

    uint256 constant SOURCE_CHAIN_ID = 1_000_001;  // RGB
    uint256 constant DEST_CHAIN_ID   = 42161;      // arbitrum

    uint256 constant TX_ID_1 = 100;
    uint256 constant TX_ID_2 = 101;
    uint256 constant TX_ID_3 = 102;

    uint256 constant AMOUNT      = 100e18;
    uint256 constant BURN_ID     = 9_001;

    function setUp() public {
        module = new RgbSettlementModule(routeRegistry);
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    function _fundsInCtx(uint256 operationId, uint256 netAmount)
        internal
        view
        returns (FundsInContext memory)
    {
        return FundsInContext({
            token:         token,
            sender:        user,
            grossAmount:   netAmount,           // gross == net for these tests
            netAmount:     netAmount,
            operationId:   operationId,
            sourceChainId: SOURCE_CHAIN_ID,
            destChainId:   DEST_CHAIN_ID,
            destAddress:   'rgb:asset/utxo1abc'
        });
    }

    function _fundsOutCtx(uint256 amount) internal view returns (FundsOutContext memory) {
        return FundsOutContext({
            token:         token,
            recipient:     recipient,
            amount:        amount,
            burnId:        BURN_ID,
            sourceChainId: SOURCE_CHAIN_ID,
            destChainId:   DEST_CHAIN_ID,
            sourceAddress: 'rgb:sender/utxo1src'
        });
    }

    function _settlementData(uint256[] memory ids) internal pure returns (bytes memory) {
        return abi.encode(ids);
    }

    function _single(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _record(uint256 operationId, uint256 netAmount) internal {
        vm.prank(routeRegistry);
        module.onFundsIn(_fundsInCtx(operationId, netAmount), '');
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

    function test_onFundsIn_revertsOnDuplicateOperationId() public {
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), '');
    }

    function test_onFundsIn_revertsIfNotRouteRegistry() public {
        vm.prank(attacker);
        vm.expectRevert(RgbSettlementModule.NotRouteRegistry.selector);
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), '');
    }

    // ========================================================================
    // beforeFundsOut — happy paths
    // ========================================================================

    function test_beforeFundsOut_consumesFullSingleRecord() public {
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        module.beforeFundsOut(_fundsOutCtx(AMOUNT), _settlementData(_single(TX_ID_1)));

        assertEq(module.fundsInRecords(TX_ID_1), 0, 'record fully consumed');
    }

    function test_beforeFundsOut_consumesSequentiallyMultipleIds() public {
        uint256 amount1 = 60e18;
        uint256 amount2 = 40e18;
        _record(TX_ID_1, amount1);
        _record(TX_ID_2, amount2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = TX_ID_1;
        ids[1] = TX_ID_2;

        vm.prank(routeRegistry);
        module.beforeFundsOut(_fundsOutCtx(amount1 + amount2), _settlementData(ids));

        assertEq(module.fundsInRecords(TX_ID_1), 0);
        assertEq(module.fundsInRecords(TX_ID_2), 0);
    }

    function test_beforeFundsOut_partialConsume_preservesResidual() public {
        _record(TX_ID_1, AMOUNT);
        uint256 partialAmount = 60e18;

        vm.prank(routeRegistry);
        module.beforeFundsOut(
            _fundsOutCtx(partialAmount),
            _settlementData(_single(TX_ID_1))
        );

        assertEq(
            module.fundsInRecords(TX_ID_1),
            AMOUNT - partialAmount,
            'residual preserved on same operationId'
        );
    }

    function test_beforeFundsOut_consumesPartiallyAcrossIds() public {
        // Two records of 100 each. fundsOut for 150 fully consumes the
        // first and partially consumes the second (leaving 50).
        _record(TX_ID_1, AMOUNT);
        _record(TX_ID_2, AMOUNT);

        uint256[] memory ids = new uint256[](2);
        ids[0] = TX_ID_1;
        ids[1] = TX_ID_2;

        vm.prank(routeRegistry);
        module.beforeFundsOut(_fundsOutCtx(150e18), _settlementData(ids));

        assertEq(module.fundsInRecords(TX_ID_1), 0,    'first fully consumed');
        assertEq(module.fundsInRecords(TX_ID_2), 50e18, 'second partially consumed');
    }

    function test_beforeFundsOut_breaksAfterAmountSatisfied() public {
        // Three records, but the request is satisfied by the first one. The
        // remaining two records must remain untouched (loop early-terminates).
        _record(TX_ID_1, AMOUNT);
        _record(TX_ID_2, AMOUNT);
        _record(TX_ID_3, AMOUNT);

        uint256[] memory ids = new uint256[](3);
        ids[0] = TX_ID_1;
        ids[1] = TX_ID_2;
        ids[2] = TX_ID_3;

        vm.prank(routeRegistry);
        module.beforeFundsOut(_fundsOutCtx(AMOUNT), _settlementData(ids));

        assertEq(module.fundsInRecords(TX_ID_1), 0);
        assertEq(module.fundsInRecords(TX_ID_2), AMOUNT, 'second untouched');
        assertEq(module.fundsInRecords(TX_ID_3), AMOUNT, 'third untouched');
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
        module.beforeFundsOut(_fundsOutCtx(AMOUNT), _settlementData(_single(TX_ID_1)));
    }

    function test_beforeFundsOut_revertsOnAmountExceedsFundsIn() public {
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        vm.expectRevert(RgbSettlementModule.FundsOutAmountExceedsFundsIn.selector);
        module.beforeFundsOut(
            _fundsOutCtx(AMOUNT + 1),
            _settlementData(_single(TX_ID_1))
        );
    }

    function test_beforeFundsOut_revertsOnDoubleSpendConsumedRecord() public {
        // Record + fully consume + try to consume the same id again.
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        module.beforeFundsOut(_fundsOutCtx(AMOUNT), _settlementData(_single(TX_ID_1)));

        // Second redemption against the same id reverts with FundsInNotFound
        // (slot is back to 0 after `delete`).
        vm.prank(routeRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(RgbSettlementModule.FundsInNotFound.selector, TX_ID_1)
        );
        module.beforeFundsOut(_fundsOutCtx(AMOUNT), _settlementData(_single(TX_ID_1)));
    }

    function test_beforeFundsOut_revertsIfNotRouteRegistry() public {
        _record(TX_ID_1, AMOUNT);

        vm.prank(attacker);
        vm.expectRevert(RgbSettlementModule.NotRouteRegistry.selector);
        module.beforeFundsOut(_fundsOutCtx(AMOUNT), _settlementData(_single(TX_ID_1)));
    }
}
