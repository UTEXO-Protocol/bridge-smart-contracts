// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICommissionManager} from "../../src/interfaces/ICommissionManager.sol";
import {CommissionManagerTestBase} from "./CommissionManagerTestBase.sol";

/// @notice Only the Bridge credits pools and withdrawals pay the fixed recipient.
contract CommissionManagerPoolsTest is CommissionManagerTestBase {
    function test_receiveTokenCommission_onlyBridge() public {
        uint256 amt = 100 ether;
        token.mint(address(cm), amt);

        vm.prank(user);
        vm.expectRevert(ICommissionManager.OnlyBridge.selector);
        cm.receiveTokenCommission(address(token), amt);

        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token), amt);
        assertEq(cm.tokenCommissionPool(address(token)), amt);
    }

    function test_receiveTokenCommission_revertsNothingReceived() public {
        vm.prank(BRIDGE);
        vm.expectRevert(ICommissionManager.NothingReceived.selector);
        cm.receiveTokenCommission(address(token), 0);
    }

    // The pool is credited by the passed `credited`, not by balanceOf - pool.
    // Crediting more than the on-chain balance can back reverts
    // BalanceBelowRecordedPool (guards against over-crediting).
    function test_receiveTokenCommission_revertsWhenCreditExceedsBalance() public {
        token.mint(address(cm), 5 ether);
        vm.prank(BRIDGE);
        vm.expectRevert(ICommissionManager.BalanceBelowRecordedPool.selector);
        cm.receiveTokenCommission(address(token), 6 ether);
    }

    // An unsolicited direct transfer already sitting in the CM is NOT folded
    // into the pool. The Bridge measures only its own transfer and
    // passes that as `credited`; the donation stays as a stray balance.
    function test_receiveTokenCommission_doesNotAbsorbUnsolicitedBalance() public {
        uint256 unsolicitedAmount = 3 ether;
        uint256 legitimateAmount = 7 ether;

        token.mint(user, unsolicitedAmount);
        vm.prank(user);
        token.transfer(address(cm), unsolicitedAmount); // donation

        token.mint(BRIDGE, legitimateAmount);
        vm.prank(BRIDGE);
        token.transfer(address(cm), legitimateAmount); // the Bridge's transfer

        assertEq(token.balanceOf(address(cm)), unsolicitedAmount + legitimateAmount, "pre cm token balance");
        assertEq(cm.tokenCommissionPool(address(token)), 0, "pre cm pool");

        // Bridge credits ONLY the amount its transfer actually delivered.
        vm.expectEmit(true, false, false, true, address(cm));
        emit ICommissionManager.TokenCommissionReceived(address(token), legitimateAmount);

        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token), legitimateAmount);

        assertEq(cm.tokenCommissionPool(address(token)), legitimateAmount, "pool credited only the legit commission");
        assertEq(token.balanceOf(address(cm)), unsolicitedAmount + legitimateAmount, "donation stays as stray balance");
    }

    function test_withdrawTokenCommission_transfersAndUpdatesPool() public {
        uint256 amt = 50 ether;
        token.mint(address(cm), amt);
        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token), amt);

        vm.prank(owner);
        cm.withdrawTokenCommission(address(token), amt);

        assertEq(cm.tokenCommissionPool(address(token)), 0);
        assertEq(token.balanceOf(recipient), amt);
    }

    function test_withdrawAllTokenCommission_paysEntirePoolToFixedRecipient() public {
        uint256 amt = 30 ether;
        token.mint(address(cm), amt);
        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token), amt);

        vm.prank(owner);
        cm.withdrawAllTokenCommission(address(token));

        assertEq(cm.tokenCommissionPool(address(token)), 0);
        assertEq(token.balanceOf(recipient), amt);
    }

    function test_withdrawTokenCommission_revertsInsufficient() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.InsufficientBalance.selector);
        cm.withdrawTokenCommission(address(token), 1);
    }

    function test_withdrawCommission_rejectsUnsupportedRecipientOverrideSelectors() public {
        uint256 amount = 10 ether;
        token.mint(address(cm), amount);
        vm.prank(BRIDGE);
        cm.receiveTokenCommission(address(token), amount);

        bytes[] memory legacyCalls = new bytes[](4);
        legacyCalls[0] =
            abi.encodeWithSignature("withdrawTokenCommission(address,address,uint256)", address(token), user, amount);
        legacyCalls[1] = abi.encodeWithSignature("withdrawNativeCommission(address,uint256)", user, amount);
        legacyCalls[2] = abi.encodeWithSignature("withdrawAllTokenCommission(address,address)", address(token), user);
        legacyCalls[3] = abi.encodeWithSignature("withdrawAllNativeCommission(address)", user);

        for (uint256 i = 0; i < legacyCalls.length; i++) {
            vm.prank(owner);
            (bool ok,) = address(cm).call(legacyCalls[i]);
            assertFalse(ok, "legacy free-recipient selector must not exist");
        }

        assertEq(cm.tokenCommissionPool(address(token)), amount, "failed legacy calls preserve pool");
        assertEq(token.balanceOf(user), 0, "arbitrary recipient receives nothing");
        assertEq(token.balanceOf(recipient), 0, "no valid withdrawal executed");
    }

    function test_receive_onlyBridge() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool okUser, bytes memory userError) = address(cm).call{value: 1 ether}("");
        assertFalse(okUser);
        assertEq(
            userError,
            abi.encodeWithSelector(ICommissionManager.OnlyBridge.selector),
            "only Bridge can fund native pool"
        );

        vm.deal(BRIDGE, 1 ether);
        vm.prank(BRIDGE);
        (bool okBridge,) = address(cm).call{value: 1 ether}("");
        assertTrue(okBridge);
        assertEq(cm.nativeCommissionPool(), 1 ether);
    }

    function test_receive_revertsZeroValue() public {
        vm.prank(BRIDGE);
        (bool ok, bytes memory errorData) = address(cm).call{value: 0}("");
        assertFalse(ok);
        assertEq(
            errorData, abi.encodeWithSelector(ICommissionManager.ZeroNativeAmount.selector), "zero funding is rejected"
        );
    }

    function test_withdrawNativeCommission_paysRequestedAmountToFixedRecipient() public {
        vm.deal(BRIDGE, 5 ether);
        vm.prank(BRIDGE);
        (bool ok,) = address(cm).call{value: 2 ether}("");
        assertTrue(ok);

        uint256 before = recipient.balance;
        vm.prank(owner);
        cm.withdrawNativeCommission(2 ether);
        assertEq(cm.nativeCommissionPool(), 0);
        assertEq(recipient.balance, before + 2 ether);
    }

    function test_withdrawAllNativeCommission_paysEntirePoolToFixedRecipient() public {
        vm.deal(BRIDGE, 3 ether);
        vm.prank(BRIDGE);
        (bool ok,) = address(cm).call{value: 3 ether}("");
        assertTrue(ok);

        uint256 before = recipient.balance;
        vm.prank(owner);
        cm.withdrawAllNativeCommission();
        assertEq(cm.nativeCommissionPool(), 0);
        assertEq(recipient.balance, before + 3 ether);
    }

    function test_withdrawNativeCommission_revertsInsufficient() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.InsufficientBalance.selector);
        cm.withdrawNativeCommission(1 wei);
    }
}
