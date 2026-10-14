// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {IntegrationTestBase} from "./IntegrationTestBase.sol";

/// @notice Deposits create mint records and credit isolated liquidity.
contract IntegrationDepositsTest is IntegrationTestBase {
    /// @notice A deposit records its mint (operationId -> net) and credits the
    ///         destination chain's bridged liquidity; commission routed to CM.
    function test_fundsIn_mintRecordsDepositAndCreditsLiquidity() public {
        _configTokenCommissionRoutes();
        uint256 netIn = _netIn();
        uint256 fee = USER_DEPOSIT - netIn;

        uint256 userBefore = token.balanceOf(user);
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(RGB_OP_ID));

        assertEq(token.balanceOf(user), userBefore - USER_DEPOSIT, "user debited gross");
        assertEq(token.balanceOf(address(bridge)), netIn, "bridge keeps net");
        assertEq(token.balanceOf(address(cm)), fee, "commission to CM");
        assertEq(cm.tokenCommissionPool(address(token)), fee, "CM recorded inbound fee");
        assertEq(rgbModule.fundsInRecords(opId), netIn, "mint record stores net");
        assertEq(opId, bridge.rgbMintDepositId(RGB_CHAIN_ID, RGB_OP_ID, netIn), "consignment-derived backing id");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), netIn, "destination liquidity credited");
        assertEq(bridge.totalLockedLiquidity(), netIn, "total liquidity credited");
        assertEq(
            bridge.sourceSenderNonces(SOURCE_CHAIN_ID, bytes32(uint256(uint160(user)))), 1, "deposit nonce consumed"
        );
        // Conservation: gross deposit is split between bridge pool and CM, nothing lost.
        assertEq(token.balanceOf(address(bridge)) + token.balanceOf(address(cm)), USER_DEPOSIT, "deposit conserved");
    }

    /// @notice Different RGB mint OpIds remain distinct deposits.
    function test_fundsIn_mintDistinctDepositsGetDistinctOperationIds() public {
        _configTokenCommissionRoutes();
        vm.prank(user);
        bytes32 op1 = bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(RGB_OP_ID));
        vm.prank(user);
        bytes32 op2 = bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(RGB_OP_ID + 1));

        assertTrue(op1 != op2, "operationIds distinct");
        assertEq(rgbModule.fundsInRecords(op1), _netIn(), "first recorded");
        assertEq(rgbModule.fundsInRecords(op2), _netIn(), "second recorded");
        assertEq(bridge.totalLockedLiquidity(), _netIn() * 2, "both deposits accounted");
        assertEq(cm.tokenCommissionPool(address(token)), (USER_DEPOSIT - _netIn()) * 2, "both inbound fees recorded");
        assertEq(
            bridge.sourceSenderNonces(SOURCE_CHAIN_ID, bytes32(uint256(uint160(user)))),
            2,
            "two deposit nonces consumed"
        );
    }

    /// @notice A mint route must carry a non-zero RGB OpId in settlementData.
    function test_fundsIn_mintZeroRgbOpIdReverts() public {
        _configTokenCommissionRoutes();
        ReleaseState memory beforeState = _releaseState(0);
        uint256 userBefore = token.balanceOf(user);
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        uint256 nonceBefore = bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender);
        vm.prank(user);
        vm.expectRevert(IBridge.InvalidRgbOpId.selector, address(bridge));
        bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(uint256(0)));
        _assertReleaseUnchanged(0, beforeState);
        assertEq(token.balanceOf(user), userBefore, "failed deposit does not debit user");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), nonceBefore, "failed deposit restores nonce");
    }

    /// @notice Pausing inflow stops deposits while withdrawals still flow
    ///         (independent pause flags).
    function test_fundsIn_mintInflowPauseStopsDepositsReleasesStillFlow() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        vm.prank(address(proxy));
        bridge.pauseInflow();

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(RGB_OP_ID + 100));

        // Outflow is a separate flag - a withdraw still succeeds.
        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());
        ReleaseState memory beforeState = _releaseState(burnId);
        _submitFundsOut(params);
        uint256 outFee = netIn * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT;
        _assertSuccessfulRelease(params, beforeState, outFee);
        assertTrue(bridge.paused(), "release leaves inflow paused");
    }
}
