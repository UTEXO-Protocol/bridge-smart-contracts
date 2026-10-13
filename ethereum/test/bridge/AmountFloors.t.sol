// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {ICommissionManager} from "../../src/interfaces/ICommissionManager.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Deposit and release minima, ordering constraints and commission dust.
contract BridgeAmountFloorsTest is BridgeTestBase {
    function test_setMinFundsInAmount_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(bridge));
        emit IBridge.MinFundsInAmountUpdated(1, 1000);

        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);
        assertEq(bridge.minFundsInAmount(), 1000);
    }

    function test_setMinFundsInAmount_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidMinFundsInAmount.selector);
        bridge.setMinFundsInAmount(0);
    }

    function test_setMinFundsInAmount_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setMinFundsInAmount(1000);
    }

    function test_setMinFundsOutAmount_updatesAndEmits() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(2000);
        vm.expectEmit(false, false, false, true, address(bridge));
        emit IBridge.MinFundsOutAmountUpdated(1, 2000);

        vm.prank(multisig);
        bridge.setMinFundsOutAmount(2000);
        assertEq(bridge.minFundsOutAmount(), 2000);
    }

    function test_setMinFundsOutAmount_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidMinFundsOutAmount.selector);
        bridge.setMinFundsOutAmount(0);
    }

    function test_setMinFundsOutAmount_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setMinFundsOutAmount(2000);
    }

    function test_setMinFundsInAmount_revertsBelowOutflowMinimum() public {
        vm.startPrank(multisig);
        bridge.setMinFundsInAmount(100);
        bridge.setMinFundsOutAmount(80);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidAmountFloors.selector, uint256(79), uint256(80)));
        bridge.setMinFundsInAmount(79);
        vm.stopPrank();
        assertEq(bridge.minFundsInAmount(), 100);
        assertEq(bridge.minFundsOutAmount(), 80);
    }

    function test_setMinFundsOutAmount_revertsAboveInflowMinimum() public {
        vm.startPrank(multisig);
        bridge.setMinFundsInAmount(100);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidAmountFloors.selector, uint256(100), uint256(101)));
        bridge.setMinFundsOutAmount(101);
        vm.stopPrank();
        assertEq(bridge.minFundsInAmount(), 100);
        assertEq(bridge.minFundsOutAmount(), 1);
    }

    function testFuzz_amountFloors_acceptOrderedMinimumsIncludingEquality(uint256 inMinimum, uint256 outMinimum)
        public
    {
        inMinimum = bound(inMinimum, 1, type(uint256).max);
        outMinimum = bound(outMinimum, 1, inMinimum);
        vm.startPrank(multisig);
        bridge.setMinFundsInAmount(inMinimum);
        bridge.setMinFundsOutAmount(outMinimum);
        assertEq(bridge.minFundsInAmount(), inMinimum);
        assertEq(bridge.minFundsOutAmount(), outMinimum);

        // Raising the outbound minimum up to equality is valid.
        bridge.setMinFundsOutAmount(inMinimum);
        assertEq(bridge.minFundsInAmount(), bridge.minFundsOutAmount());

        // Lower outbound first, then lower inbound down to equality.
        bridge.setMinFundsOutAmount(outMinimum);
        bridge.setMinFundsInAmount(outMinimum);
        vm.stopPrank();
        assertEq(bridge.minFundsInAmount(), outMinimum);
        assertEq(bridge.minFundsOutAmount(), outMinimum);
    }

    /// @dev The floor is an on-chain backstop for a limit the TEE is not known
    ///      to enforce: a dust release costs the bridge more to settle than it
    ///      moves.
    function test_fundsOut_revertsBelowMinFundsOutAmount() public {
        _seedRGB(1000e6);

        vm.prank(multisig);
        bridge.setMinFundsInAmount(1e6);
        vm.prank(multisig);
        bridge.setMinFundsOutAmount(1e6);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, 1e6 - 1, 1e6));
        _releaseRGB(1e6 - 1, keccak256("AmountFloors.t-burn-2"));
    }

    function test_fundsOut_acceptsExactlyMinFundsOutAmount() public {
        _seedRGB(1000e6);

        vm.prank(multisig);
        bridge.setMinFundsInAmount(1e6);
        vm.prank(multisig);
        bridge.setMinFundsOutAmount(1e6);

        uint256 before = usdt0.balanceOf(recipient);
        _releaseRGB(1e6, keccak256("AmountFloors.t-burn-1"));
        assertEq(usdt0.balanceOf(recipient) - before, 1e6, "release at the floor goes through");
    }

    function test_fundsIn_revertsOnZeroAmount() public {
        // Floor is 1 (setUp), so a zero deposit is below the minimum.
        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(0), uint256(1)));
        vm.prank(user);
        bridge.fundsIn(0, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsOut_revertsOnZeroAmount() public {
        // The fixture's outbound floor is one; zero is rejected before
        // burn-id derivation or liquidity checks.
        vm.expectRevert(IBridge.ZeroAmount.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            0,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(new bytes32[](0)),
            SRC_BURN_TX_ID
        );
    }

    function test_fundsIn_revertsBelowMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(999), uint256(1000)));
        vm.prank(user);
        bridge.fundsIn(999, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_acceptsExactlyAtMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(1000, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), 1000, "deposit at the floor is accepted");
    }

    function test_fundsIn_acceptsAboveMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(1001, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), 1001, "deposit above the floor is accepted");
    }

    function test_fundsIn_dustThatRoundsCommissionToZeroIsRejected() public {
        // 4% token commission. Below 25 units the fee floors to zero
        // (24 * 400 / 100 / 100 == 0). The effective fee policy itself rejects
        // that dust, independently
        // of the separately configurable global minimum.
        _setFundsInTokenRule(400);

        assertEq(cm.calculateStableFee(24, 400, 100), 0, "sanity: 24 pays zero commission");

        vm.expectRevert(
            abi.encodeWithSelector(
                ICommissionManager.CommissionRoundsToZero.selector, uint256(24), uint256(400), uint8(100)
            )
        );
        vm.prank(user);
        bridge.fundsIn(24, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // The smallest amount that produces one fee unit is accepted.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(25, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), 24, "net = 25 - 1 commission");
    }

    function test_fundsOut_dustThatRoundsCommissionToZeroIsRejected() public {
        uint256 dustAmount = 24;
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(dustAmount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(dustAmount);
        _setFundsOutTokenRule(400);

        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(_ids(opId), _one(dustAmount));
        uint256 burnId = _deriveBurnId(dustAmount, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICommissionManager.CommissionRoundsToZero.selector, dustAmount, uint256(400), uint8(100)
            )
        );
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, dustAmount, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData
        );

        assertFalse(bridge.consumedBurnIds(burnId), "reverted release does not consume burn id");
    }

    function test_fundsInFromAdapter_revertsBelowMinimum() public {
        // The adapter overload shares `_fundsIn`, so the floor applies there too.
        address mockAdapter = makeAddr("mock-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(mockAdapter);
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        usdt0.mint(mockAdapter, 999);
        vm.prank(mockAdapter);
        usdt0.approve(address(bridge), 999);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(999), uint256(1000)));
        vm.prank(mockAdapter);
        bridge.fundsIn(999, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }
}
