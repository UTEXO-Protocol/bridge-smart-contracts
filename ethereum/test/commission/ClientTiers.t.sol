// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager,
    PayerTier
} from "../../src/interfaces/ICommissionManager.sol";
import {CommissionManagerTestBase} from "./CommissionManagerTestBase.sol";

contract CommissionManagerClientTiersTest is CommissionManagerTestBase {
    bytes32 internal constant CLIENT = bytes32(uint256(uint160(address(0xC11E17))));
    bytes32 internal constant OTHER_CLIENT = bytes32(uint256(uint160(address(0xBEEF))));

    function _setRule(
        uint256 sourceChainId,
        uint256 destChainId,
        uint256 stablePercent,
        uint256 baseFee,
        CommissionSide side,
        CommissionCurrency currency
    ) private {
        vm.prank(owner);
        cm.setCommissionRule(
            sourceChainId,
            destChainId,
            address(token),
            CommissionConfig(stablePercent, baseFee, 100, side, currency, true)
        );
    }

    function _setTier(uint256 sourceChainId, uint256 destChainId, bytes32 subject, uint256 stablePercent) private {
        vm.prank(owner);
        cm.setPayerTier(sourceChainId, destChainId, address(token), subject, stablePercent);
    }

    function test_setAndClearRouteScopedTier() public {
        PayerTier memory expected = PayerTier({stablePercent: 70, isSet: true});
        vm.expectEmit(true, true, true, true, address(cm));
        emit ICommissionManager.PayerTierUpdated(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), CLIENT, expected);
        _setTier(SRC_CHAIN_ID, DST_CHAIN_ID, CLIENT, 70);

        PayerTier memory stored = cm.getPayerTier(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), CLIENT);
        assertEq(stored.stablePercent, 70);
        assertTrue(stored.isSet);

        vm.expectEmit(true, true, true, true, address(cm));
        emit ICommissionManager.PayerTierCleared(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), CLIENT);
        vm.prank(owner);
        cm.clearPayerTier(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), CLIENT);
        stored = cm.getPayerTier(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), CLIENT);
        assertEq(stored.stablePercent, 0);
        assertFalse(stored.isSet);
    }

    function test_tierAdministrationRejectsInvalidCalls() public {
        vm.startPrank(owner);
        vm.expectRevert(ICommissionManager.InvalidFeeSubject.selector);
        cm.setPayerTier(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), bytes32(0), 70);
        vm.expectRevert(ICommissionManager.InvalidToken.selector);
        cm.setPayerTier(SRC_CHAIN_ID, DST_CHAIN_ID, address(0), CLIENT, 70);
        vm.expectRevert(ICommissionManager.StablePercentTooHigh.selector);
        cm.setPayerTier(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), CLIENT, 9001);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        cm.setPayerTier(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), CLIENT, 70);
    }

    function test_lowerTierDiscountsOnlySelectedClient() public {
        _setRule(SRC_CHAIN_ID, DST_CHAIN_ID, 100, 0, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        _setTier(SRC_CHAIN_ID, DST_CHAIN_ID, CLIENT, 70);

        (uint256 standardFee,,) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000, OTHER_CLIENT);
        (uint256 clientFee,, uint256 clientNet) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000, CLIENT);
        assertEq(standardFee, 10_000);
        assertEq(clientFee, 7_000);
        assertEq(clientNet, 993_000);
    }

    function test_higherTierCannotIncreaseDefaultFee() public {
        _setRule(SRC_CHAIN_ID, DST_CHAIN_ID, 50, 0, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        _setTier(SRC_CHAIN_ID, DST_CHAIN_ID, CLIENT, 70);
        (uint256 fee,,) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000, CLIENT);
        assertEq(fee, 5_000);
    }

    function test_zeroTierWaivesProportionalFeeButPreservesBaseFee() public {
        _setRule(SRC_CHAIN_ID, DST_CHAIN_ID, 100, 125, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        _setTier(SRC_CHAIN_ID, DST_CHAIN_ID, CLIENT, 0);
        (uint256 fee,, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000, CLIENT);
        assertEq(fee, 125);
        assertEq(net, 999_875);
    }

    function test_nativeRuleIgnoresTier() public {
        _setRule(SRC_CHAIN_ID, DST_CHAIN_ID, 100, 0, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        _setTier(SRC_CHAIN_ID, DST_CHAIN_ID, CLIENT, 0);
        (, uint256 standardNative,) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1 ether, OTHER_CLIENT);
        (, uint256 clientNative,) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1 ether, CLIENT);
        assertEq(clientNative, standardNative);
        assertGt(clientNative, 0);
    }

    function test_tierAppliesOnlyToExactRoute() public {
        uint256 otherDestination = DST_CHAIN_ID + 1;
        _setRule(SRC_CHAIN_ID, DST_CHAIN_ID, 100, 0, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        _setRule(SRC_CHAIN_ID, otherDestination, 100, 0, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        _setTier(SRC_CHAIN_ID, DST_CHAIN_ID, CLIENT, 70);

        (uint256 selectedFee,,) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000, CLIENT);
        (uint256 otherFee,,) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, otherDestination, address(token), 1_000_000, CLIENT);
        assertEq(selectedFee, 7_000);
        assertEq(otherFee, 10_000);
    }

    function test_fundsOutAndTotalFeeUseTier() public {
        _setRule(SRC_CHAIN_ID, DST_CHAIN_ID, 100, 25, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);
        _setTier(SRC_CHAIN_ID, DST_CHAIN_ID, CLIENT, 70);
        (uint256 fee,, uint256 net) =
            cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000, CLIENT);
        assertEq(fee, 7_025);
        assertEq(net, 992_975);
        assertEq(cm.calculateTotalFee(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000, CLIENT), 7_025);
    }
}
