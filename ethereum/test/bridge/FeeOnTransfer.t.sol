// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Bridge} from "../../src/Bridge.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {RouteRegistry} from "../../src/RouteRegistry.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {CommissionConfig, CommissionCurrency, CommissionSide} from "../../src/interfaces/ICommissionManager.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {BurnIdHelper} from "../helpers/BurnIdHelper.sol";
import {FeeOnTransferERC20} from "../mocks/FeeOnTransferERC20.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Liquidity and commission accounting use actual token receipts.
contract BridgeFeeOnTransferTest is BridgeTestBase {
    struct FeeStack {
        Bridge bridge;
        FeeOnTransferERC20 token;
        RgbSettlementModule module;
        CommissionManager cm;
    }

    /// @dev Deploy an independent fee-token stack, reusing the fixture verifier
    ///      and oracle feeds with fresh manager, registry, Bridge and RGB module.
    function _deployFeeStack(uint256 feeBps) private returns (FeeStack memory s) {
        s.token = new FeeOnTransferERC20("Fee USDT0", "fUSDT0", feeBps);

        vm.startPrank(deployer);
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 3);

        s.cm = new CommissionManager(predictedBridge, recipient);
        RouteRegistry feeRouteRegistry = new RouteRegistry(predictedBridge, deployer);
        s.bridge = _deployBridge(
            address(s.token), address(feeRouteRegistry), payable(address(s.cm)), address(0), 1, 1, deployer
        );

        // Reuse the suite's RGB verifier (shares `btcRelay` + `_proof()`); a
        // fresh module is bound to this stack's route registry.
        s.module = new RgbSettlementModule(address(feeRouteRegistry));

        feeRouteRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(s.module));
        feeRouteRegistry.setRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(s.module));

        vm.stopPrank();
        _configureFeeStack(s);
    }

    /// @dev Oracle wiring, ownership handoff and user funding for a `FeeStack`.
    ///      Split out of `_deployFeeStack` so neither frame trips the via-ir
    ///      stack limit once the caller is inlined.
    function _configureFeeStack(FeeStack memory s) private {
        vm.startPrank(deployer);
        s.cm.setSequencerUptimeFeed(address(sequencerUptimeFeed));
        s.cm.setEthUsdPriceBounds(100e8, 100_000e8);
        s.cm.setEthUsdFeed(address(ethUsdFeed), 1 hours);

        s.bridge.transferOwnership(multisig);
        vm.stopPrank();

        vm.prank(multisig);
        s.bridge.acceptOwnership();

        // Fund `user` generously and approve the fee bridge. `mint` is untaxed,
        // so `user` holds exactly the minted amount.
        s.token.mint(user, AMOUNT * 10);
        vm.prank(user);
        s.token.approve(address(s.bridge), type(uint256).max);
    }

    /// @dev Release through a `FeeStack`, isolated in its own frame so the
    ///      fee-token tests stay within via-ir stack limits.
    function _releaseFor(
        FeeStack memory s,
        uint256 amount,
        uint256 burnId,
        bytes memory proof,
        bytes memory settlementData
    ) private {
        vm.prank(multisig);
        s.bridge
            .fundsOut(
                IBridge.FundsOutParams(
                    recipient,
                    amount,
                    burnId,
                    RGB_CHAIN_ID,
                    SOURCE_CHAIN_ID,
                    SRC_ADDR,
                    proof,
                    settlementData,
                    SRC_BURN_TX_ID
                )
            );
    }

    /// @dev Set a FUNDS_IN TOKEN commission rule on a fee stack's CM for the
    ///      (SOURCE_CHAIN_ID → RGB_CHAIN_ID) route.
    function _setFeeStackFundsInTokenRule(FeeStack memory s, uint256 stablePercent, uint8 multiplier) private {
        vm.prank(deployer);
        s.cm
            .setCommissionRule(
                SOURCE_CHAIN_ID,
                RGB_CHAIN_ID,
                address(s.token),
                CommissionConfig({
                    stablePercent: stablePercent,
                    baseFee: 0,
                    multiplier: multiplier,
                    side: CommissionSide.FUNDS_IN,
                    currency: CommissionCurrency.TOKEN,
                    isSet: true
                })
            );
    }

    function _deriveBurnIdFor(
        FeeStack memory s,
        uint256 amount,
        uint256 sourceChainId,
        string memory sourceAddress,
        bytes32 sourceBurnTxId
    ) private view returns (uint256) {
        return BurnIdHelper.derive(
            address(s.bridge), block.chainid, address(s.token), amount, sourceChainId, sourceAddress, sourceBurnTxId
        );
    }

    function test_fundsIn_feeTokenCreditsActualReceivedNotNominal() public {
        FeeStack memory s = _deployFeeStack(100); // 1% fee, no commission rule

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        assertLt(received, AMOUNT, "sanity: fee token delivers less than nominal");

        bytes32 expectedOperationId = keccak256(
            abi.encode(
                keccak256(
                    "UtexoRgbMintDeposit(address bridge,uint256 chainId,address token,uint256 rgbNetwork,uint256 rgbOpId,uint256 netAmount)"
                ),
                address(s.bridge),
                block.chainid,
                address(s.token),
                RGB_CHAIN_ID,
                RGB_OP_ID,
                received
            )
        );
        bytes32 sourceSender = bytes32(uint256(uint160(user)));

        // BridgeFundsIn must carry gross `amount == AMOUNT` and `netAmount == received`.
        vm.expectEmit(true, true, false, true, address(s.bridge));
        emit IBridge.FundsIn(user, RGB_OP_ID, uint64(received));
        vm.expectEmit(true, true, true, true, address(s.bridge));
        emit IBridge.BridgeFundsIn(
            expectedOperationId,
            sourceSender,
            user,
            0,
            AMOUNT,
            received,
            0,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData()
        );

        vm.prank(user);
        bytes32 opId = s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(opId, expectedOperationId, "id uses actual received");
        assertEq(s.module.fundsInRecords(opId), received, "record credits actual received");
        assertEq(s.bridge.lockedLiquidity(RGB_CHAIN_ID), received, "lockedLiquidity credits actual received");
        assertEq(s.token.balanceOf(address(s.bridge)), received, "bridge token balance == received");
    }

    function test_fundsIn_feeTokenLedgerNotOverstatedWithCommission() public {
        FeeStack memory s = _deployFeeStack(100); // 1% transfer fee
        // 4% FUNDS_IN TOKEN commission rule (stablePercent 400, multiplier 100).
        _setFeeStackFundsInTokenRule(s, 400, 100);

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        // Commission is quoted from the NOMINAL amount.
        uint256 tokenCommission = s.cm.calculateStableFee(AMOUNT, 400, 100);
        assertGt(tokenCommission, 0, "sanity: non-zero commission");

        vm.prank(user);
        bytes32 opId = s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(
            opId,
            s.bridge.rgbMintDepositId(RGB_CHAIN_ID, RGB_OP_ID, received - tokenCommission),
            "id uses actual received minus nominal commission"
        );

        // Ledger credited from actual received minus the (nominal-quoted) commission.
        assertEq(
            s.bridge.lockedLiquidity(RGB_CHAIN_ID),
            received - tokenCommission,
            "lockedLiquidity == received - tokenCommission"
        );

        // The Bridge measures the CM receipt delta after the taxed commission
        // transfer and credits that received amount to the CM pool.
        assertEq(
            s.cm.tokenCommissionPool(address(s.token)),
            tokenCommission - s.token.feeOn(tokenCommission),
            "CM pool credits the actual receipt"
        );

        // No overstate: the bridge's retained token balance equals the credited
        // lockedLiquidity exactly (bridge sent `tokenCommission` out to the CM).
        uint256 bridgeRetained = s.token.balanceOf(address(s.bridge));
        assertEq(bridgeRetained, received - tokenCommission, "bridge retained == lockedLiquidity");
        assertEq(
            s.bridge.lockedLiquidity(RGB_CHAIN_ID),
            bridgeRetained,
            "lockedLiquidity + bridge-retained invariant: credited == held"
        );
    }

    function test_fundsOut_feeTokenRecordedAmountIsReleasable() public {
        FeeStack memory s = _deployFeeStack(100); // 1% fee, no commission

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);

        vm.prank(user);
        bytes32 opId = s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(s.module.fundsInRecords(opId), received, "record == actual received");

        // Nine more equal deposits make the first record's amount fit
        // the 10% bucket burst.
        for (uint256 i = 1; i < 10; i++) {
            vm.prank(user);
            s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + i));
        }

        // Ten equal deposits back the release, so `received` is ~10% of chain
        // liquidity and the balanced policy's burst covers it.
        vm.startPrank(multisig);
        s.bridge.setOutflowLimit(RGB_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        s.bridge.setGlobalOutflowLimit(MAX_BURST_BPS, MAX_REFILL_BPS);
        vm.stopPrank();

        // Release exactly the permanent record amount; the remaining deposits
        // provide liquidity for the configured burst.
        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(_ids(opId), _one(received));
        uint256 burnId = _deriveBurnIdFor(s, received, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);

        uint256 recipientBefore = s.token.balanceOf(recipient);

        _releaseFor(s, received, burnId, proof, settlementData);

        // The outbound transfer is also taxed, so the recipient nets
        // `received - feeOn(received)`. The payoff is that the release did NOT
        // revert and value moved.
        uint256 delta = s.token.balanceOf(recipient) - recipientBefore;
        assertGt(delta, 0, "recipient balance increased");
        assertEq(delta, received - s.token.feeOn(received), "recipient nets received minus outbound fee");
        assertEq(s.bridge.lockedLiquidity(RGB_CHAIN_ID), received * 9, "nine deposit amounts remain locked");
    }

    /// @dev A 90% transfer fee leaves AMOUNT / 10 (1e17), while the 90%
    ///      commission quote is AMOUNT * 9 / 10 (9e17), exceeding the receipt.
    function test_fundsIn_revertsWhenCommissionExceedsActualReceipt() public {
        FeeStack memory s = _deployFeeStack(9000); // 90% transfer fee
        _setFeeStackFundsInTokenRule(s, 9000, 100); // 90% commission on nominal — the ceiling

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        uint256 tokenCommission = s.cm.calculateStableFee(AMOUNT, 9000, 100);

        assertEq(received, AMOUNT / 10, "sanity: received == 10% of nominal");
        assertGt(tokenCommission, received, "sanity: commission exceeds actual received");

        vm.expectRevert(abi.encodeWithSelector(IBridge.InsufficientReceived.selector, received, tokenCommission));
        vm.prank(user);
        s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    /// @dev A nominally valid (<100%) commission can still consume the full
    ///      ACTUAL receipt when the token charges a transfer fee. Equality must
    ///      revert rather than recording a zero-net settlement.
    function test_fundsIn_revertsWhenTransferFeeLeavesZeroNetReceipt() public {
        FeeStack memory s = _deployFeeStack(5000); // Bridge receives 50%
        _setFeeStackFundsInTokenRule(s, 5000, 100); // nominal commission is 50%

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        uint256 tokenCommission = s.cm.calculateStableFee(AMOUNT, 5000, 100);
        assertEq(received, tokenCommission, "sanity: actual receipt equals nominal commission");

        vm.expectRevert(abi.encodeWithSelector(IBridge.InsufficientReceived.selector, received, tokenCommission));
        vm.prank(user);
        s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(s.bridge.lockedLiquidity(RGB_CHAIN_ID), 0, "zero-net liquidity was not recorded");
        assertEq(s.cm.tokenCommissionPool(address(s.token)), 0, "commission transfer rolled back");
    }
}
