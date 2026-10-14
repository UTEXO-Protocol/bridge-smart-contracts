// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {CommissionCurrency, CommissionSide, ICommissionManager} from "../../src/interfaces/ICommissionManager.sol";
import {CommissionManagerTestBase} from "./CommissionManagerTestBase.sol";

/// @notice Inbound and outbound quotes conserve the charged amount.
contract CommissionManagerCalculationTest is CommissionManagerTestBase {
    function test_calculateStableFee_defaultMultiplier() public view {
        // 10000 amount, 400 (=4%), mult 100 → 10000*400/10000 = 400
        assertEq(cm.calculateStableFee(10000, 400, 100), 400);
    }

    function test_calculateFundsInCommission_tokenDeductsFromAmount() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        address t = address(token);
        uint256 amount = 100_000;
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 4000); // 4% of 100_000
        assertEq(nat, 0);
        assertEq(net, amount - 4000);
    }

    function test_calculateFundsInCommission_zeroStablePercentNoTokenFee() public view {
        address t = address(token);
        uint256 amount = 100_000;
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 0);
        assertEq(nat, 0);
        assertEq(net, amount);
    }

    function test_calculateFundsInCommission_zeroStablePercentNativeSkipsFeedCheck() public {
        vm.prank(owner);
        cm.setGlobalDefaults(0, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        // Make the feed unhealthy: if the contract still hit it the call would
        // revert. A zero stable percent must short-circuit before the read.
        ethUsdFeed.setAnswer(0);
        address t = address(token);
        uint256 amount = 1000 ether;
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 0);
        assertEq(nat, 0);
        assertEq(net, amount);
    }

    function test_calculateFundsInCommission_nativeFullAmountBridged() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        address t = address(token);
        uint256 amount = 100_000 ether;
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        // 4% of 100_000 USD is 4000 USD; at 2000 USD per ETH, the fee is 2 ETH.
        uint256 expectedNat = 2 ether; // 4000 USD at 2000 USD per ETH
        assertEq(tok, 0);
        assertEq(nat, expectedNat);
        assertEq(net, amount);
    }

    function test_calculateFundsInCommission_skipsWhenSideIsFundsOut() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);
        address t = address(token);
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 50_000);
        assertEq(tok, 0);
        assertEq(nat, 0);
        assertEq(net, 50_000);
    }

    function test_calculateFundsInCommission_nativeRevertsWhenFeedUnset() public {
        // Close the NATIVE path explicitly and confirm the calculator surfaces
        // the underlying `EthUsdFeedNotSet` revert (rather than producing a
        // silent zero quote).
        vm.prank(owner);
        cm.setEthUsdFeed(address(0), 0);
        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        address t = address(token);
        vm.expectRevert(ICommissionManager.EthUsdFeedNotSet.selector);
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 1000);
    }

    function test_calculateFundsInCommission_nativeRevertsWhenPriceStale() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp() - HEARTBEAT - 1);
        vm.expectRevert(ICommissionManager.StalePrice.selector);
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1000);
    }

    function test_calculateFundsOutCommission_token() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);
        address t = address(token);
        uint256 amount = 80_000;
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, amount);
        assertEq(tok, 3200);
        assertEq(nat, 0);
        assertEq(net, amount - 3200);
    }

    function test_calculateFundsOutCommission_skipsWhenSideIsFundsIn() public view {
        address t = address(token);
        (uint256 tok, uint256 nat, uint256 net) = cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 40_000);
        assertEq(tok, 0);
        assertEq(nat, 0);
        assertEq(net, 40_000);
    }

    function test_calculateFundsInCommission_revertsWhenFlatFeeConsumesQuotedAmount() public {
        uint256 baseFee = 1000;
        vm.prank(owner);
        cm.setGlobalDefaults(0, baseFee, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.ZeroNetAmount.selector, baseFee, baseFee));
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), baseFee);
    }

    function test_calculateFundsOutCommission_revertsWhenFlatFeeConsumesQuotedAmount() public {
        uint256 baseFee = 1000;
        vm.prank(owner);
        cm.setGlobalDefaults(0, baseFee, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.ZeroNetAmount.selector, baseFee, baseFee));
        cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), baseFee);
    }

    function test_calculateFundsInCommission_revertsWhenNativeConversionRoundsToZero() public {
        vm.prank(owner);
        cm.setGlobalDefaults(1, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICommissionManager.CommissionRoundsToZero.selector, DEPOSIT_FLOOR, uint256(1), uint8(100)
            )
        );
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), DEPOSIT_FLOOR);
    }

    function test_calculateFundsInCommission_revertsWhenTokenDecimalsGetterFails() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);
        vm.mockCallRevert(address(token), abi.encodeWithSignature("decimals()"), bytes("decimals unavailable"));
        vm.expectRevert(ICommissionManager.TokenDecimalsUnavailable.selector);
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1 ether);
    }
}
