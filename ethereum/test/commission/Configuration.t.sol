// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {CommissionCurrency, CommissionSide, ICommissionManager} from "../../src/interfaces/ICommissionManager.sol";
import {CommissionManagerTestBase} from "./CommissionManagerTestBase.sol";

/// @notice Commission-manager initialization, defaults and bridge binding.
contract CommissionManagerConfigurationTest is CommissionManagerTestBase {
    function test_constructor_setsBridgeAndOwner() public view {
        assertEq(cm.bridgeAddress(), BRIDGE);
        assertEq(cm.commissionRecipient(), recipient);
        assertEq(cm.owner(), owner);
    }

    function test_constructor_revertsOnZeroBridge() public {
        vm.expectRevert(ICommissionManager.InvalidBridgeAddress.selector);
        new CommissionManager(address(0), recipient);
    }

    function test_constructor_revertsOnZeroCommissionRecipient() public {
        vm.expectRevert(ICommissionManager.InvalidRecipient.selector);
        new CommissionManager(BRIDGE, address(0));
    }

    function test_renounceOwnership_blocked() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.RenounceOwnershipBlocked.selector);
        cm.renounceOwnership();
    }

    function test_buildRouteKey_matchesEncodeHash() public view {
        address t = address(token);
        bytes32 expected = keccak256(abi.encode(SRC_CHAIN_ID, DST_CHAIN_ID, t));
        assertEq(cm.buildRouteKey(SRC_CHAIN_ID, DST_CHAIN_ID, t), expected);
    }

    function test_getGlobalDefaults_initial() public view {
        (uint256 sp, uint256 baseFee, uint8 m, CommissionSide side, CommissionCurrency cur) = cm.getGlobalDefaults();
        assertEq(sp, 0);
        assertEq(baseFee, 0);
        assertEq(m, 100);
        assertEq(uint8(side), uint8(CommissionSide.FUNDS_IN));
        assertEq(uint8(cur), uint8(CommissionCurrency.TOKEN));
    }

    function test_setGlobalDefaults_updatesAndEmits() public {
        // FUNDS_IN + NATIVE is a valid shape (the user funds the native fee on
        // deposit). NATIVE + FUNDS_OUT is rejected by the setter and is covered
        // by a dedicated revert test.
        vm.expectEmit(true, true, true, true, address(cm));
        emit ICommissionManager.GlobalDefaultsUpdated(
            200, 50_000, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE
        );
        vm.prank(owner);
        cm.setGlobalDefaults(200, 50_000, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        (uint256 sp, uint256 baseFee, uint8 m, CommissionSide side, CommissionCurrency cur) = cm.getGlobalDefaults();
        assertEq(sp, 200);
        assertEq(baseFee, 50_000);
        assertEq(m, 100);
        assertEq(uint8(side), uint8(CommissionSide.FUNDS_IN));
        assertEq(uint8(cur), uint8(CommissionCurrency.NATIVE));
    }

    function test_setGlobalDefaults_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    function test_setGlobalDefaults_revertsPercentTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.StablePercentTooHigh.selector);
        cm.setGlobalDefaults(9001, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    function test_setGlobalDefaults_acceptsZeroPercent() public {
        vm.prank(owner);
        cm.setGlobalDefaults(100, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        assertEq(cm.globalStablePercent(), 100);
        vm.prank(owner);
        cm.setGlobalDefaults(0, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        (uint256 sp,,,,) = cm.getGlobalDefaults();
        assertEq(sp, 0);
    }

    function test_setGlobalDefaults_revertsZeroMultiplier() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.MultiplierZero.selector);
        cm.setGlobalDefaults(400, 0, 0, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev setGlobalDefaults rejects the NATIVE + FUNDS_OUT shape.
    function test_setGlobalDefaults_revertsNativeFundsOut() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.NativeCommissionNotAllowedOnFundsOut.selector);
        cm.setGlobalDefaults(100, 0, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.NATIVE);
    }

    /// @dev FUNDS_IN + NATIVE stays valid — the user funds the native fee on deposit.
    function test_setGlobalDefaults_acceptsNativeFundsIn() public {
        vm.prank(owner);
        cm.setGlobalDefaults(100, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        (,,, CommissionSide side, CommissionCurrency cur) = cm.getGlobalDefaults();
        assertEq(uint8(side), uint8(CommissionSide.FUNDS_IN));
        assertEq(uint8(cur), uint8(CommissionCurrency.NATIVE));
    }

    function test_setBridgeAddress_updates() public {
        address newBridge = makeAddr("newBridge");
        vm.expectEmit(true, true, true, true, address(cm));
        emit ICommissionManager.BridgeAddressUpdated(newBridge);
        vm.prank(owner);
        cm.setBridgeAddress(newBridge);
        assertEq(cm.bridgeAddress(), newBridge);
    }

    function test_setBridgeAddress_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.InvalidBridgeAddress.selector);
        cm.setBridgeAddress(address(0));
    }
}
