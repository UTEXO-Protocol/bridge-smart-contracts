// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    FlatFeeType,
    ICommissionManager,
    PayerTier,
    WitnessFeeConfig
} from "../../src/interfaces/ICommissionManager.sol";
import {MockDepositFloor} from "../mocks/MockDepositFloor.sol";
import {CommissionManagerTestBase} from "./CommissionManagerTestBase.sol";

contract CommissionManagerWitnessFeesTest is CommissionManagerTestBase {
    bytes32 private constant CLIENT = bytes32(uint256(uint160(address(0xC11E17))));

    function _setRule(uint256 stablePercent, uint256 baseFee, CommissionCurrency currency) private {
        vm.prank(owner);
        cm.setCommissionRule(
            SRC_CHAIN_ID,
            DST_CHAIN_ID,
            address(token),
            CommissionConfig(stablePercent, baseFee, 100, CommissionSide.FUNDS_IN, currency, true)
        );
    }

    function _setWitness(uint256 witnessFee, bool isSet) private {
        vm.prank(owner);
        cm.setWitnessFee(
            SRC_CHAIN_ID, DST_CHAIN_ID, address(token), WitnessFeeConfig({witnessFee: witnessFee, isSet: isSet})
        );
    }

    function test_baseAndWitnessSelectDifferentFlatComponents() public {
        _setRule(100, 125, CommissionCurrency.TOKEN);
        _setWitness(1_500, true);

        (uint256 baseFee,,) = cm.calculateFundsInCommission(
            SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 500_000, bytes32(0), FlatFeeType.BASE
        );
        (uint256 witnessFee,, uint256 net) = cm.calculateFundsInCommission(
            SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 500_000, bytes32(0), FlatFeeType.WITNESS
        );

        assertEq(baseFee, 5_125);
        assertEq(witnessFee, 6_500);
        assertEq(net, 493_500);
    }

    function test_witnessFeePreservedWhenClientTierWaivesPercentage() public {
        _setRule(100, 125, CommissionCurrency.TOKEN);
        _setWitness(1_500, true);
        vm.prank(owner);
        cm.setPayerTier(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), CLIENT, PayerTier({stablePercent: 0, isSet: true}));

        (uint256 fee,,) = cm.calculateFundsInCommission(
            SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 500_000, CLIENT, FlatFeeType.WITNESS
        );
        assertEq(fee, 1_500);
    }

    function test_unconfiguredWitnessFeeFailsClosed() public {
        _setRule(100, 125, CommissionCurrency.TOKEN);
        bytes32 routeKey = cm.buildRouteKey(SRC_CHAIN_ID, DST_CHAIN_ID, address(token));
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.WitnessFeeNotConfigured.selector, routeKey));
        cm.calculateFundsInCommission(
            SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 500_000, bytes32(0), FlatFeeType.WITNESS
        );
    }

    function test_explicitZeroWitnessFeeIsConfiguredAndClearIsNormalized() public {
        _setRule(100, 125, CommissionCurrency.TOKEN);
        _setWitness(0, true);
        (uint256 fee,,) = cm.calculateFundsInCommission(
            SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 500_000, bytes32(0), FlatFeeType.WITNESS
        );
        assertEq(fee, 5_000);

        WitnessFeeConfig memory cleared = WitnessFeeConfig({witnessFee: 0, isSet: false});
        vm.expectEmit(true, true, true, true, address(cm));
        emit ICommissionManager.WitnessFeeUpdated(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), cleared);
        _setWitness(type(uint256).max, false);
        WitnessFeeConfig memory stored = cm.getWitnessFee(SRC_CHAIN_ID, DST_CHAIN_ID, address(token));
        assertEq(stored.witnessFee, 0);
        assertFalse(stored.isSet);
    }

    function test_witnessSetterValidatesOwnerSideAndAmountFloor() public {
        _setRule(100, 0, CommissionCurrency.TOKEN);

        vm.expectRevert(
            abi.encodeWithSelector(ICommissionManager.FeeAboveAmountFloor.selector, 1_010_000, DEPOSIT_FLOOR)
        );
        _setWitness(DEPOSIT_FLOOR, true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        cm.setWitnessFee(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), WitnessFeeConfig({witnessFee: 1_500, isSet: true}));

        vm.prank(owner);
        cm.setCommissionRule(
            SRC_CHAIN_ID,
            DST_CHAIN_ID,
            address(token),
            CommissionConfig(100, 0, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN, true)
        );
        vm.expectRevert(ICommissionManager.WitnessFeeOnlyFundsIn.selector);
        _setWitness(1_500, true);
    }

    function test_nativeWitnessTotalUsesExistingOracleConversion() public {
        MockDepositFloor(BRIDGE).setMinFundsInAmount(1 ether);
        _setRule(100, 1e14, CommissionCurrency.NATIVE);
        _setWitness(1e15, true);

        (, uint256 nativeFee, uint256 net) = cm.calculateFundsInCommission(
            SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 0.5 ether, bytes32(0), FlatFeeType.WITNESS
        );
        uint256 tokenDenominatedTotal = 0.5 ether / 100 + 1e15;
        assertEq(nativeFee, cm.convertTokenFeeToNative(tokenDenominatedTotal, token.decimals()));
        assertEq(net, 0.5 ether);
    }

    function test_witnessQuoteRechecksFloorAfterItIsLowered() public {
        _setRule(100, 0, CommissionCurrency.TOKEN);
        _setWitness(500_000, true);
        MockDepositFloor(BRIDGE).setMinFundsInAmount(400_000);

        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.FeeAboveAmountFloor.selector, 504_000, 400_000));
        cm.calculateFundsInCommission(
            SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 600_000, bytes32(0), FlatFeeType.WITNESS
        );
    }

    function test_witnessQuoteFailsClosedAfterRuleClearsToFundsOutGlobals() public {
        _setRule(100, 0, CommissionCurrency.TOKEN);
        _setWitness(1_500, true);
        vm.startPrank(owner);
        cm.setGlobalDefaults(100, 0, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);
        cm.clearCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token));
        vm.stopPrank();

        vm.expectRevert(ICommissionManager.WitnessFeeOnlyFundsIn.selector);
        cm.calculateFundsInCommission(
            SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 500_000, bytes32(0), FlatFeeType.WITNESS
        );
    }
}
