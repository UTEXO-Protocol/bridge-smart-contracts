// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager
} from "../../src/interfaces/ICommissionManager.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {IntegrationTestBase} from "./IntegrationTestBase.sol";

/// @notice Signed deposits, releases and withdrawals conserve bridge backing and fees.
contract IntegrationLifecycleTest is IntegrationTestBase {
    MockAggregatorV3 internal ethUsdFeed;

    function test_endToEnd_tokenCommissionInboundAndOutbound() public {
        _configTokenCommissionRoutes(0, 0);

        (uint256 tInQuote,, uint256 netIn) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(token), USER_DEPOSIT);
        assertEq(tInQuote, USER_DEPOSIT * FUNDS_IN_PERCENT / FUNDS_IN_MULT / FUNDS_IN_MULT, "quote in");
        assertEq(netIn, USER_DEPOSIT - tInQuote, "net in");

        // User fundsIn — TOKEN commission routed to CM; the RGB settlement
        //    module records the inbound deposit.

        uint256 userBefore = token.balanceOf(user);

        // Ten equal deposits make the release below exactly 10% of isolated
        // and global TVL — the configured bucket burst.
        bytes32 opId = _depositN(10, RGB_OP_ID);

        uint256 tokenCommissionIn = tInQuote * 10;
        uint256 netBridgedIn = netIn;

        // Balanced maximum-total policy: 10% burst plus 10% refill per window.
        // Ten deposits back a release of one, so the full burst is spendable.
        _openOutflowLimits();

        assertEq(token.balanceOf(user), userBefore - USER_DEPOSIT * 10, "user debited ten gross deposits");
        assertEq(token.balanceOf(address(bridge)), netBridgedIn * 10, "bridge keeps ten net deposits");
        assertEq(token.balanceOf(address(cm)), tokenCommissionIn, "cm got commission");
        assertEq(cm.tokenCommissionPool(address(token)), tokenCommissionIn, "cm pool mirrors balance");
        assertEq(rgbModule.fundsInRecords(opId), netBridgedIn, "record stores net");

        // TEE-signed fundsOut — RGBVerifier checks the BtcRelay header, the
        //    settlement module verifies the referenced mint exists for the exact
        //    amount (no consumption), Bridge releases `netBridgedIn` from the
        //    pool. 1% outbound commission to CM, the rest to recipient.

        (IBridge.FundsOutParams memory params, uint256 burnId) =
            _buildFundsOut(opId, netBridgedIn, netBridgedIn, "", _validProof());

        uint256 tokenCommissionOut = netBridgedIn * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT;
        uint256 netOut = netBridgedIn - tokenCommissionOut;

        FundsOutAuthorization memory authorization = _prepareFundsOut(params);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeFundsOut(
            recipient,
            netBridgedIn,
            netOut,
            tokenCommissionOut,
            burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            params.sourceAddress,
            params.settlementData
        );

        proxy.fundsOutCall(params, authorization.nonce, authorization.deadline, 3, authorization.signatures);

        assertEq(token.balanceOf(address(bridge)), netBridgedIn * 9, "one tenth released; safety reserve remains");
        assertEq(token.balanceOf(recipient), netOut, "recipient got net");
        assertEq(token.balanceOf(address(cm)), tokenCommissionIn + tokenCommissionOut, "cm accrued both fees");
        assertEq(cm.tokenCommissionPool(address(token)), tokenCommissionIn + tokenCommissionOut, "cm pool mirrors");
        assertEq(rgbModule.fundsInRecords(opId), netBridgedIn, "fundsIn record unchanged (permanent)");
        assertTrue(bridge.consumedBurnIds(burnId), "burnId recorded");

        uint256 totalCommission = tokenCommissionIn + tokenCommissionOut;

        uint256 wdNonce = proxy.proposalNonce();
        uint256 wdDeadline = vm.getBlockTimestamp() + 7 days;
        bytes32 wdDigest = MultisigHelper.digestProposeWithdrawTokenCommissionCM(
            domainSep, proxy.commissionManager(), address(token), totalCommission, wdNonce, wdDeadline
        );
        bytes[] memory fedSigs = _signFed2of3(wdDigest);

        bytes32 proposalId =
            proxy.proposeWithdrawTokenCommissionCM(address(token), totalCommission, wdNonce, wdDeadline, 3, fedSigs);

        // Move past the timelock.
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        bytes memory opData = abi.encode(address(token), totalCommission);

        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.CommissionWithdrawn(address(token), totalCommission, commissionReceiver);

        proxy.executeProposal(proposalId, opData);

        // Final invariants: the nine-deposit safety reserve remains in the
        //    bridge, CM is empty, and all commissions reached their receiver.

        assertEq(token.balanceOf(address(bridge)), netBridgedIn * 9, "nine-deposit safety reserve remains");
        assertEq(token.balanceOf(address(cm)), 0, "cm drained");
        assertEq(cm.tokenCommissionPool(address(token)), 0, "cm pool drained");
        assertEq(token.balanceOf(recipient), netOut, "recipient unchanged");
        assertEq(token.balanceOf(commissionReceiver), totalCommission, "commissionReceiver paid");
        // Token conservation: ten gross deposits remain fully accounted for.
        assertEq(
            token.balanceOf(address(bridge)) + token.balanceOf(recipient) + token.balanceOf(commissionReceiver),
            USER_DEPOSIT * 10,
            "token conservation"
        );
    }

    function test_endToEnd_nativeCommissionInboundAndWithdraw() public {
        // Configure a NATIVE FUNDS_IN route (2% on token amount, paid in wei).
        // Wire the complete mandatory oracle config through federation
        // governance — dependencies first, ETH/USD feed last.
        // Establish a healthy round independently of the governance timelocks.
        vm.warp(vm.getBlockTimestamp() + cm.SEQUENCER_GRACE_PERIOD() + 1);
        MockAggregatorV3 sequencerFeed =
            new MockAggregatorV3(0, 0, vm.getBlockTimestamp() - cm.SEQUENCER_GRACE_PERIOD() - 1);
        ethUsdFeed = new MockAggregatorV3(8, 2_000e8, vm.getBlockTimestamp());
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(ICommissionManager.setSequencerUptimeFeed.selector, address(sequencerFeed))
        );
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(ICommissionManager.setEthUsdPriceBounds.selector, uint256(100e8), uint256(100_000e8))
        );
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(ICommissionManager.setEthUsdFeed.selector, address(ethUsdFeed), uint256(1 days))
        );
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(
                ICommissionManager.setCommissionRule.selector,
                SOURCE_CHAIN_ID,
                RGB_CHAIN_ID,
                address(token),
                CommissionConfig({
                    stablePercent: FUNDS_IN_PERCENT,
                    baseFee: 0,
                    multiplier: FUNDS_IN_MULT,
                    side: CommissionSide.FUNDS_IN,
                    currency: CommissionCurrency.NATIVE,
                    isSet: true
                })
            )
        );

        (, uint256 nativeQuote, uint256 netQuote) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(token), USER_DEPOSIT);
        assertEq(netQuote, USER_DEPOSIT, "NATIVE: full amount bridges");
        // 2% of USER_DEPOSIT in token units, converted to wei via the feed.
        assertEq(nativeQuote, 10_000_000_000_000, "0.02 USD at 2000 USD per ETH quotes 1e13 wei");

        vm.deal(user, nativeQuote);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn{value: nativeQuote}(USER_DEPOSIT, RGB_CHAIN_ID, "", abi.encode(RGB_OP_ID));

        assertEq(token.balanceOf(address(bridge)), USER_DEPOSIT, "bridge got full token amount");
        assertEq(token.balanceOf(address(cm)), 0, "cm no token commission");
        assertEq(address(cm).balance, nativeQuote, "cm got native commission");
        assertEq(cm.nativeCommissionPool(), nativeQuote, "cm native pool");
        assertEq(rgbModule.fundsInRecords(opId), USER_DEPOSIT, "record stores full amount");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), USER_DEPOSIT, "native deposit credits full chain liquidity");
        assertEq(bridge.totalLockedLiquidity(), USER_DEPOSIT, "native deposit credits full total liquidity");
        assertEq(address(bridge).balance, 0, "bridge retains no native commission");

        // Federation withdraws native commission.
        uint256 wdNonce = proxy.proposalNonce();
        uint256 wdDeadline = vm.getBlockTimestamp() + 7 days;
        bytes32 wdDigest = MultisigHelper.digestProposeWithdrawNativeCommissionCM(
            domainSep, proxy.commissionManager(), nativeQuote, wdNonce, wdDeadline
        );
        bytes[] memory fedSigs = _signFed2of3(wdDigest);

        bytes32 proposalId = proxy.proposeWithdrawNativeCommissionCM(nativeQuote, wdNonce, wdDeadline, 3, fedSigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        uint256 receiverBefore = commissionReceiver.balance;
        proxy.executeProposal(proposalId, abi.encode(nativeQuote));

        assertEq(address(cm).balance, 0, "cm native drained");
        assertEq(cm.nativeCommissionPool(), 0, "cm pool drained");
        assertEq(commissionReceiver.balance - receiverBefore, nativeQuote, "receiver paid in native");
    }

    /// @notice Percentage plus flat fees are accounted on both legs and paid
    ///         to the pinned recipient through a real timelocked withdrawal.
    function test_endToEnd_tokenCommissionWithBaseFees() public {
        uint256 inBaseFee = 0.01 ether;
        uint256 outBaseFee = 0.005 ether;
        // The flat fee must leave positive net at each side's amount floor.
        _proposeAndExecuteBridgeAdminCall(abi.encodeCall(IBridge.setMinFundsInAmount, (0.1 ether)));
        _proposeAndExecuteBridgeAdminCall(abi.encodeCall(IBridge.setMinFundsOutAmount, (0.1 ether)));
        _configTokenCommissionRoutes(inBaseFee, outBaseFee);
        _openOutflowLimits();

        uint256 inFee = USER_DEPOSIT * FUNDS_IN_PERCENT / FUNDS_IN_MULT / FUNDS_IN_MULT + inBaseFee;
        uint256 netIn = USER_DEPOSIT - inFee;
        bytes32 opId = _depositN(10, RGB_OP_ID);
        assertEq(token.balanceOf(user), 0, "user paid ten gross deposits");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), netIn * 10, "chain credited net after both fee components");
        assertEq(bridge.totalLockedLiquidity(), netIn * 10, "total credited net after both fee components");
        assertEq(token.balanceOf(address(bridge)), netIn * 10, "bridge custody equals net deposits");
        assertEq(cm.tokenCommissionPool(address(token)), inFee * 10, "CM recorded percentage plus inbound base fee");
        assertEq(token.balanceOf(address(cm)), inFee * 10, "CM received percentage plus inbound base fee");
        assertEq(rgbModule.fundsInRecords(opId), netIn, "mint record excludes full inbound fee");

        uint256 outFee = netIn * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT + outBaseFee;
        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());
        ReleaseState memory beforeState = _releaseState(burnId);
        FundsOutAuthorization memory authorization = _prepareFundsOut(params);
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeFundsOut(
            recipient, netIn, netIn - outFee, outFee, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, "", params.settlementData
        );
        proxy.fundsOutCall(params, authorization.nonce, authorization.deadline, 3, authorization.signatures);
        _assertSuccessfulRelease(params, beforeState, outFee);
        assertEq(rgbModule.fundsInRecords(opId), netIn, "release preserves mint record");

        uint256 totalCommission = inFee * 10 + outFee;
        uint256 wdNonce = proxy.proposalNonce();
        uint256 wdDeadline = vm.getBlockTimestamp() + 7 days;
        bytes32 wdDigest = MultisigHelper.digestProposeWithdrawTokenCommissionCM(
            domainSep, proxy.commissionManager(), address(token), totalCommission, wdNonce, wdDeadline
        );
        bytes32 proposalId = proxy.proposeWithdrawTokenCommissionCM(
            address(token), totalCommission, wdNonce, wdDeadline, 3, _signFed2of3(wdDigest)
        );
        uint256 receiverBefore = token.balanceOf(commissionReceiver);
        vm.expectRevert(IMultisigProxy.TimelockActive.selector);
        proxy.executeProposal(proposalId, abi.encode(address(token), totalCommission));
        assertEq(cm.tokenCommissionPool(address(token)), totalCommission, "timelock rejection preserves pool");
        assertEq(token.balanceOf(address(cm)), totalCommission, "timelock rejection preserves custody");
        assertEq(token.balanceOf(commissionReceiver), receiverBefore, "timelock rejection pays nothing");
        assertEq(uint256(proxy.getProposal(proposalId).status), uint256(IMultisigProxy.ProposalStatus.Pending));

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(proposalId, abi.encode(address(token), totalCommission));
        assertEq(cm.tokenCommissionPool(address(token)), 0, "commission pool emptied");
        assertEq(token.balanceOf(address(cm)), 0, "CM custody emptied");
        assertEq(
            token.balanceOf(commissionReceiver), receiverBefore + totalCommission, "pinned recipient received fees"
        );
        assertEq(bridge.totalLockedLiquidity(), netIn * 9, "commission withdrawal preserves remaining liquidity");
        assertEq(
            token.balanceOf(address(bridge)) + token.balanceOf(recipient) + token.balanceOf(commissionReceiver),
            USER_DEPOSIT * 10,
            "percentage and flat fee lifecycle conserves tokens"
        );
    }
}
