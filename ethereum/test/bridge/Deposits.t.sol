// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Direct deposit accounting, events and route validation.
contract BridgeDepositsTest is BridgeTestBase {
    function test_fundsIn_transfersTokens() public {
        uint256 userBefore = usdt0.balanceOf(user);

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
        assertEq(usdt0.balanceOf(user), userBefore - AMOUNT);
    }

    function test_fundsIn_anyUserCanCall() public {
        address stranger = makeAddr("stranger");
        usdt0.mint(stranger, AMOUNT);
        vm.prank(stranger);
        usdt0.approve(address(bridge), AMOUNT);

        vm.prank(stranger);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
    }

    function test_fundsIn_rgbAcceptsEmptyDestinationAddressAndEmitsNonce() public {
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        bytes32 expectedOpId = _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, AMOUNT);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(user, RGB_OP_ID, uint64(AMOUNT));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit IBridge.BridgeFundsIn(
            expectedOpId, sourceSender, user, 0, AMOUNT, AMOUNT, 0, 0, SOURCE_CHAIN_ID, RGB_CHAIN_ID, "", _rgbData()
        );

        vm.prank(user);
        bytes32 operationId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, "", _rgbData());

        assertEq(operationId, expectedOpId, "canonical RGB mint id");
        assertEq(rgbModule.fundsInRecords(operationId), AMOUNT, "RGB settlement record created");
    }

    function test_fundsIn_revertsOnZeroDestinationChain() public {
        vm.expectRevert(IBridge.InvalidDestinationChainId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, 0, DST_ADDR, _rgbData());
    }

    function test_fundsIn_revertsWhenPaused() public {
        vm.prank(multisig);
        bridge.pauseInflow();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_repeatedRgbMintReverts() public {
        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 balanceBefore = usdt0.balanceOf(user);
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID, RGB_BEFORE_BLOCK + 1));

        assertEq(opId1, _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, AMOUNT));
        assertEq(rgbModule.fundsInRecords(opId1), AMOUNT, "original record unchanged");
        assertEq(usdt0.balanceOf(user), balanceBefore, "duplicate token pull rolled back");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT, "only one liquidity credit");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, bytes32(uint256(uint160(user)))), 1);
    }

    function test_fundsIn_expiredRgbMintRollsBackDeposit() public {
        uint64 beforeBlock = RGB_BEFORE_BLOCK;
        _setArbitrumL2Block(beforeBlock);
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        bytes32 operationId = _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, AMOUNT);
        uint256 userBalance = usdt0.balanceOf(user);

        vm.expectRevert(
            abi.encodeWithSelector(RgbSettlementModule.LockWindowExpired.selector, beforeBlock, beforeBlock)
        );
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID, beforeBlock));

        assertEq(usdt0.balanceOf(user), userBalance, "token pull rolled back");
        assertEq(usdt0.balanceOf(address(bridge)), 0, "bridge custody unchanged");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 0, "nonce rolled back");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 0, "liquidity unchanged");
        assertEq(bridge.totalLockedLiquidity(), 0, "total liquidity unchanged");
        assertEq(rgbModule.fundsInRecords(operationId), 0, "amount record absent");
        assertEq(rgbModule.fundsInRecordChainIds(operationId), 0, "chain record absent");
    }

    function testFuzz_fundsIn_creditsDepositedAmount(uint64 amount) public {
        amount = uint64(bound(uint256(amount), 1, type(uint64).max));
        usdt0.mint(user, amount);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), amount);
        assertEq(rgbModule.fundsInRecords(opId), amount);
    }
}
