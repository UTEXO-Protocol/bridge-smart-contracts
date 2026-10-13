// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BridgeBaseUpgradeable} from "../../src/BridgeBaseUpgradeable.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {ICommissionManager} from "../../src/interfaces/ICommissionManager.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {ZeroNetCommissionManager} from "../mocks/ZeroNetCommissionManager.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Release conservation, plugin validation and owner authorization.
contract BridgeWithdrawalsTest is BridgeTestBase {
    struct ReleaseSnapshot {
        uint256 bridgeBalance;
        uint256 recipientBalance;
        uint256 recordAmount;
    }

    function _assertNonconservingQuoteRejected(uint256 fee, uint256 net) private {
        _seedRGB(AMOUNT);
        vm.mockCall(
            address(cm),
            abi.encodeCall(
                ICommissionManager.calculateFundsOutCommission, (RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(usdt0), AMOUNT)
            ),
            abi.encode(fee, uint256(0), net)
        );
        bytes memory settlementData = _settlementWithAmounts(_ids(_seedOpId), _one(_seedAmt));
        uint256 burnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);
        LedgerSnapshot memory beforeState = _snapshotLedger(_seedOpId);
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 totalBefore = bridge.totalLockedLiquidity();
        uint256 chainAllowanceBefore = bridge.availableOutflow(RGB_CHAIN_ID);
        uint256 globalAllowanceBefore = bridge.availableGlobalOutflow();

        vm.expectRevert(IBridge.CommissionConservationBroken.selector);
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), settlementData
        );

        _assertLedgerUnchanged(beforeState, _seedOpId);
        assertEq(usdt0.balanceOf(recipient), 0);
        assertFalse(bridge.consumedBurnIds(burnId));
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore);
        assertEq(bridge.totalLockedLiquidity(), totalBefore);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), chainAllowanceBefore);
        assertEq(bridge.availableGlobalOutflow(), globalAllowanceBefore);
    }

    function test_fundsOut_transfersAndEmits() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeFundsOut(
            recipient, AMOUNT, AMOUNT, 0, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, settlementData
        );

        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData, SRC_BURN_TX_ID);

        assertEq(usdt0.balanceOf(recipient), AMOUNT);
        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT * 9, "nine deposit amounts remain in the Bridge");
    }

    function test_fundsOut_keepsRecordAfterRelease() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        vm.prank(multisig);
        _fundsOut(
            recipient,
            AMOUNT,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );

        // The mint ledger is permanent (proof-of-mint), not a consumable balance.
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "record unchanged after release");
    }

    function test_fundsOut_revertsAndRollsBackWhenCommissionManagerReturnsZeroNetAmount() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        ZeroNetCommissionManager zeroNetManager = new ZeroNetCommissionManager(address(bridge));
        vm.prank(multisig);
        bridge.setCommissionManager(address(zeroNetManager));

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 totalLiquidityBefore = bridge.totalLockedLiquidity();

        vm.expectRevert(IBridge.ZeroNetAmount.selector);
        vm.prank(multisig);
        _fundsOutWithBurnId(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "reverted release does not consume burn id");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore, "reverted release restores liquidity");
        assertEq(bridge.totalLockedLiquidity(), totalLiquidityBefore, "reverted release restores total liquidity");
        assertEq(usdt0.balanceOf(recipient), 0, "reverted release transfers no tokens");
    }

    function test_fundsOut_rejectsInflatedCommissionQuote() public {
        _assertNonconservingQuoteRejected(0, AMOUNT * 2);
    }

    function test_fundsOut_rejectsUnderpayingCommissionQuote() public {
        _assertNonconservingQuoteRejected(0, AMOUNT - 1);
    }

    function test_fundsOut_rejectsOverflowingCommissionQuote() public {
        _assertNonconservingQuoteRejected(type(uint256).max, 1);
    }

    function testFuzz_fundsOut_rejectsNonconservingCommissionQuote(uint256 feeSeed, uint256 netSeed) public {
        uint256 fee;
        uint256 net;
        if (feeSeed % 2 == 0) {
            fee = bound(feeSeed, 0, AMOUNT);
            net = bound(netSeed, 0, AMOUNT * 2);
            if (net == AMOUNT - fee) net += 1;
        } else {
            fee = bound(feeSeed, AMOUNT + 1, type(uint256).max);
            net = netSeed;
        }
        _assertNonconservingQuoteRejected(fee, net);
    }

    function test_fundsOut_multipleFundsInIds() public {
        uint256 amount1 = AMOUNT * 3 / 5;
        uint256 amount2 = AMOUNT * 2 / 5;

        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(amount1, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(amount2, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));
        _ensureRgbSafetyCapacity(amount1 + amount2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = opId1;
        ids[1] = opId2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount1;
        amounts[1] = amount2;

        vm.prank(multisig);
        _fundsOut(
            recipient,
            amount1 + amount2,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(ids, amounts),
            SRC_BURN_TX_ID
        );

        assertEq(usdt0.balanceOf(recipient), amount1 + amount2);
        // Records are a permanent proof-of-mint ledger — not consumed on release.
        assertEq(rgbModule.fundsInRecords(opId1), amount1, "record 1 unchanged");
        assertEq(rgbModule.fundsInRecords(opId2), amount2, "record 2 unchanged");
    }

    function test_fundsOut_revertsOnUnverifiedBlock() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        // Well-formed two-pair proof, but the source block is unknown to the relay.
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown-block"), LATEST_HEIGHT, LATEST_COMMIT);

        // RGBVerifier → BtcRelay reverts with the relay's string message.
        vm.expectRevert("verify: block commitment");
        vm.prank(multisig);
        _fundsOut(
            recipient,
            AMOUNT,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            badProof,
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );
    }

    function test_fundsOut_rejectsEmptySettlementRecords() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(new bytes32[](0), new uint256[](0));
        uint256 burnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);

        vm.expectRevert(RgbSettlementModule.EmptySettlementRecords.selector);
        vm.prank(multisig);
        _fundsOutWithBurnId(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "reverted release does not consume burn id");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore, "reverted release does not debit liquidity");
        assertEq(usdt0.balanceOf(recipient), 0, "reverted release transfers no tokens");
    }

    function test_fundsOut_revertsOnUnknownFundsInId() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes32 unknown = bytes32(uint256(999));
        bytes32[] memory ids = _ids(unknown);

        vm.expectRevert(abi.encodeWithSelector(RgbSettlementModule.FundsInNotFound.selector, unknown));
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(ids), SRC_BURN_TX_ID
        );
    }

    function test_fundsOut_revertsOnAmountMismatch() public {
        // Record one amount, then claim a different amount in
        // settlementData. The module binds operationId → exact mint amount, so
        // the mismatch must revert (surfaced through the Bridge).
        vm.prank(user);
        uint256 recordedAmount = AMOUNT / 2;
        uint256 claimedAmount = AMOUNT * 3 / 5;
        bytes32 opId = bridge.fundsIn(recordedAmount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(recordedAmount);

        bytes32[] memory ids = _ids(opId);
        uint256[] memory amounts = _one(claimedAmount);

        vm.expectRevert(
            abi.encodeWithSelector(RgbSettlementModule.AmountMismatch.selector, opId, claimedAmount, recordedAmount)
        );
        vm.prank(multisig);
        _fundsOut(
            recipient,
            recordedAmount,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(ids, amounts),
            SRC_BURN_TX_ID
        );
    }

    function test_fundsOut_revertsForNonOwner() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        _fundsOut(
            recipient,
            AMOUNT,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );
    }

    function test_fundsOut_revertsOnZeroRecipient() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.expectRevert(BridgeBaseUpgradeable.InvalidRecipientAddress.selector);
        vm.prank(multisig);
        _fundsOut(
            address(0),
            AMOUNT,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );
    }

    function test_fundsOut_revertsIfAmountExceedsPool() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.expectRevert(BridgeBaseUpgradeable.AmountExceedBridgePool.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            AMOUNT + 1,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );
    }

    /// @notice A valid Bitcoin block proof also permits another recipient and
    ///         enabled destination route; it does not encode the release context.
    /// @dev Bridge ownership authorizes this call. Multisig signatures bind the
    ///      complete intent, while RGBVerifier validates block commitments only.
    function test_fundsOut_blockProofAcceptsAlternateRecipientAndDestination() public {
        address alternateRecipient = makeAddr("alternateRecipient");
        uint256 releaseAmount = AMOUNT * 37 / 100;
        uint256 alternateDestinationChainId = SOURCE_CHAIN_ID + 77;
        vm.prank(deployer);
        routeRegistry.setRoute(
            RGB_CHAIN_ID, alternateDestinationChainId, true, address(rgbVerifier), address(rgbModule)
        );
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(releaseAmount);

        ReleaseSnapshot memory beforeState = ReleaseSnapshot({
            bridgeBalance: usdt0.balanceOf(address(bridge)),
            recipientBalance: usdt0.balanceOf(alternateRecipient),
            recordAmount: rgbModule.fundsInRecords(opId)
        });
        assertEq(beforeState.bridgeBalance, releaseAmount * 10, "pre bridge pool satisfies configured 10% burst");
        assertEq(beforeState.recipientBalance, 0, "pre recipient token");
        assertEq(beforeState.recordAmount, AMOUNT, "pre record");
        IBridge.FundsOutParams memory params = IBridge.FundsOutParams({
            recipient: alternateRecipient,
            amount: releaseAmount,
            burnId: _deriveBurnId(releaseAmount, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID),
            sourceChainId: RGB_CHAIN_ID,
            destinationChainId: alternateDestinationChainId,
            sourceAddress: SRC_ADDR,
            proof: _proof(),
            settlementData: _settlement(_ids(opId)),
            sourceBurnTxId: SRC_BURN_TX_ID
        });
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeFundsOut(
            alternateRecipient,
            releaseAmount,
            releaseAmount,
            0,
            params.burnId,
            RGB_CHAIN_ID,
            alternateDestinationChainId,
            SRC_ADDR,
            params.settlementData
        );
        vm.prank(multisig);
        bridge.fundsOut(params);

        assertTrue(bridge.consumedBurnIds(params.burnId), "burn id consumed");
        assertEq(usdt0.balanceOf(address(bridge)), beforeState.bridgeBalance - releaseAmount, "bridge debit");
        assertEq(
            usdt0.balanceOf(alternateRecipient), beforeState.recipientBalance + releaseAmount, "recipient credited"
        );
        assertEq(rgbModule.fundsInRecords(opId), beforeState.recordAmount, "record unchanged (proof-of-mint permanent)");
    }
}
