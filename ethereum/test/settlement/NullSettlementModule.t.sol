// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {FundsInContext, FundsOutContext} from "../../src/interfaces/RouteTypes.sol";
import {NullSettlementModule} from "../../src/settlement/NullSettlementModule.sol";

/// @notice Opting out of settlement creates no RGB identity, correlation ID or module state.
contract NullSettlementModuleTest is Test {
    NullSettlementModule private module;

    function setUp() public {
        module = new NullSettlementModule();
    }

    function test_onFundsIn_returnsNoCorrelationIdAndUsesLegacyIdentity() public view {
        FundsInContext memory context;
        context.token = address(0xBEEF);
        context.grossAmount = 100;
        context.netAmount = 90;
        assertFalse(module.usesRgbMintDepositId(), "null module opts out of RGB identity");
        assertEq(module.onFundsIn(context, hex"deadbeef"), 0, "null module produces no correlation ID");
    }

    function test_beforeFundsOut_acceptsPayloadWithoutStateOrEvents() public {
        FundsOutContext memory context;
        context.token = address(0xBEEF);
        context.amount = 100;
        vm.record();
        vm.recordLogs();
        module.beforeFundsOut(context, hex"deadbeef");
        (, bytes32[] memory writes) = vm.accesses(address(module));
        assertEq(writes.length, 0, "null module stores no release state");
        assertEq(vm.getRecordedLogs().length, 0, "null module emits no release events");
    }
}
