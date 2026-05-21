// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { ISettlementModule } from '../../src/interfaces/ISettlementModule.sol';
import { FundsInContext, FundsOutContext } from '../../src/interfaces/RouteTypes.sol';

/// @title MockSettlementModule
/// @notice Test stub for `ISettlementModule`. Records call counts and the
///         relevant fields from the most recent invocation so the test
///         harness can assert (a) the registry dispatcher invoked the
///         module, (b) the canonical `ctx` / `settlementData` were
///         forwarded byte-for-byte, and (c) a reverting verifier
///         short-circuits the module call (counters stay at 0).
contract MockSettlementModule is ISettlementModule {
    error MockModuleForcedRevert();

    bool public shouldRevertOnFundsIn;
    bool public shouldRevertOnBeforeFundsOut;

    uint256 public onFundsInCount;
    uint256 public beforeFundsOutCount;

    // Last-call recordings — kept minimal; we don't need every field.
    address public lastSender;
    uint256 public lastOperationId;
    uint256 public lastNetAmount;
    address public lastRecipient;
    uint256 public lastAmount;
    uint256 public lastBurnId;
    bytes   public lastSettlementData;

    function setShouldRevertOnFundsIn(bool v) external {
        shouldRevertOnFundsIn = v;
    }

    function setShouldRevertOnBeforeFundsOut(bool v) external {
        shouldRevertOnBeforeFundsOut = v;
    }

    /// @inheritdoc ISettlementModule
    function onFundsIn(FundsInContext calldata ctx, bytes calldata settlementData)
        external
        override
    {
        if (shouldRevertOnFundsIn) revert MockModuleForcedRevert();
        onFundsInCount     += 1;
        lastSender          = ctx.sender;
        lastOperationId     = ctx.operationId;
        lastNetAmount       = ctx.netAmount;
        lastSettlementData  = settlementData;
    }

    /// @inheritdoc ISettlementModule
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata settlementData)
        external
        override
    {
        if (shouldRevertOnBeforeFundsOut) revert MockModuleForcedRevert();
        beforeFundsOutCount += 1;
        lastRecipient        = ctx.recipient;
        lastAmount           = ctx.amount;
        lastBurnId           = ctx.burnId;
        lastSettlementData   = settlementData;
    }
}
