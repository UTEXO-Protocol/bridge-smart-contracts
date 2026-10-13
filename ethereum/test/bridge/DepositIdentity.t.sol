// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "forge-std/Test.sol";
import {BridgeBaseUpgradeable} from "../../src/BridgeBaseUpgradeable.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {MockSettlementModule} from "../mocks/MockSettlementModule.sol";
import {RouteRotatingCommissionManager} from "../mocks/RouteRotatingCommissionManager.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice RGB mint ids, legacy sender-bound ids and nonce rollback.
contract BridgeDepositIdentityTest is BridgeTestBase {
    // A different net amount cannot occupy the backing id for the real mint.
    function test_fundsIn_differentAmountCannotBlockVictimDeposit() public {
        address preemptor = makeAddr("operationIdPreemptor");
        uint256 preemptAmount = AMOUNT / 4;

        usdt0.mint(preemptor, preemptAmount);
        vm.prank(preemptor);
        usdt0.approve(address(bridge), preemptAmount);

        // Preemptor deposits first, reusing the SAME rgbOpId the victim will use.
        vm.prank(preemptor);
        bytes32 preemptOpId = bridge.fundsIn(preemptAmount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(preemptOpId), preemptAmount, "preemptor record");

        uint256 victimBefore = usdt0.balanceOf(user);

        // The victim's amount matches a different canonical backing id.
        vm.prank(user);
        bytes32 victimOpId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(victimOpId != preemptOpId, "victim id distinct from preemptor id");
        assertEq(rgbModule.fundsInRecords(victimOpId), AMOUNT, "victim record created");
        assertEq(usdt0.balanceOf(user), victimBefore - AMOUNT, "victim deposit went through");
    }

    // A plain ERC20 transfer can change Bridge's raw balance,
    // but it does not enter the Bridge.fundsIn accounting path.
    function test_liquidity_directTokenTransferDoesNotCreditAccounting() public {
        address donor = makeAddr("directTransferDonor");
        uint256 directAmount = 17e18;
        bytes32 expectedOpId = _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, AMOUNT);

        usdt0.mint(donor, directAmount);

        uint256 donorBefore = usdt0.balanceOf(donor);
        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(donorBefore, directAmount, "pre donor token");
        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(recordBefore, 0, "pre record");

        vm.prank(donor);
        usdt0.transfer(address(bridge), directAmount);

        assertEq(usdt0.balanceOf(donor), donorBefore - directAmount, "donor direct transfer spent");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + directAmount, "bridge raw balance increased");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(expectedOpId), recordBefore, "record not created");

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(user, RGB_OP_ID, uint64(AMOUNT));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit IBridge.BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            AMOUNT,
            0,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData()
        );

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore - AMOUNT, "user fundsIn spent");
        assertEq(
            usdt0.balanceOf(address(bridge)),
            bridgeBefore + directAmount + AMOUNT,
            "bridge includes direct plus fundsIn"
        );
        assertEq(rgbModule.fundsInRecords(opId), recordBefore + AMOUNT, "record created only by fundsIn");
    }

    // Bridge remains route-agnostic, but the RGB settlement module requires
    // the canonical empty destination address.
    function test_fundsIn_rgbRejectsNonEmptyDestinationAddress() public {
        string memory invalidDestination = "not-rgb-destination";
        bytes32 expectedOpId = _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, AMOUNT);

        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(recordBefore, 0, "pre record");

        vm.prank(user);
        vm.expectRevert(RgbSettlementModule.UnexpectedDestinationAddress.selector);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, invalidDestination, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore, "user balance rolled back");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore, "bridge balance rolled back");
        assertEq(rgbModule.fundsInRecords(expectedOpId), recordBefore, "record not created");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, bytes32(uint256(uint160(user)))), 0, "nonce rolled back");
    }

    // A positive-net RGB deposit creates one record for the mint. A duplicate
    // reverts even with a fresh sender nonce and rolls back fees and accounting.
    function testFuzz_fundsIn_positiveNetDepositRejectsDuplicateAndRollsBack(uint128 amountSeed, uint16 percentSeed)
        public
    {
        uint256 amount = bound(uint256(amountSeed), 100, AMOUNT);
        uint256 percent = bound(uint256(percentSeed), 100, 9_000);

        _setFundsInTokenRule(percent);

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), amount);

        assertGt(tokenCommission, 0, "pre positive token fee");
        assertGt(netAmount, 0, "pre positive net");

        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();

        bytes32 expectedOpId = _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, netAmount);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(user, RGB_OP_ID, uint64(netAmount));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit IBridge.BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            amount,
            netAmount,
            tokenCommission,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData()
        );

        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId1, expectedOpId, "returned id matches derivation");

        assertEq(usdt0.balanceOf(user), userBefore - amount, "user spent gross once");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + netAmount, "bridge got net");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, "cm got fee");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, "cm pool recorded fee");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId1), netAmount, "record = net");
        assertEq(
            (usdt0.balanceOf(address(bridge)) - bridgeBefore) + (usdt0.balanceOf(address(cm)) - cmBefore),
            amount,
            "gross token conserved"
        );

        LedgerSnapshot memory afterFirst = _snapshotLedger(opId1);
        uint256 lockedAfterFirst = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 totalAfterFirst = bridge.totalLockedLiquidity();
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        vm.prank(user);
        bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        _assertLedgerUnchanged(afterFirst, opId1);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), lockedAfterFirst);
        assertEq(bridge.totalLockedLiquidity(), totalAfterFirst);
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, bytes32(uint256(uint160(user)))), 1);
    }

    function test_fundsIn_shadowDepositWithDifferentSenderReverts() public {
        vm.prank(user);
        bytes32 original = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        address shadowSender = makeAddr("shadowSender");
        usdt0.mint(shadowSender, AMOUNT);
        vm.prank(shadowSender);
        usdt0.approve(address(bridge), AMOUNT);
        LedgerSnapshot memory beforeShadow = _snapshotLedger(original);

        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        vm.prank(shadowSender);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        _assertLedgerUnchanged(beforeShadow, original);
        assertEq(usdt0.balanceOf(shadowSender), AMOUNT, "shadow funding rolled back");
        assertEq(bridge.totalLockedLiquidity(), AMOUNT, "no shadow liquidity credit");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, bytes32(uint256(uint160(shadowSender)))), 0);
    }

    function test_fundsIn_routeRotationDuringCommissionUsesCurrentIdentityMode() public {
        MockSettlementModule legacyModule = new MockSettlementModule();
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(legacyModule));
        RouteRotatingCommissionManager rotating = new RouteRotatingCommissionManager(
            address(bridge), routeRegistry, address(rgbVerifier), address(rgbModule), SOURCE_CHAIN_ID, RGB_CHAIN_ID
        );
        vm.prank(deployer);
        routeRegistry.transferOwnership(address(rotating));
        rotating.acceptRegistryOwnership();
        vm.prank(multisig);
        bridge.setCommissionManager(address(rotating));

        bytes32 legacyId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        vm.prank(user);
        bytes32 actual = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(actual, _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, AMOUNT * 9 / 10));
        assertEq(rgbModule.fundsInRecords(actual), AMOUNT * 9 / 10);
        assertEq(rgbModule.fundsInRecords(legacyId), 0, "no stale legacy id in the RGB ledger");
        assertEq(legacyModule.onFundsInCount(), 0);
        assertEq(usdt0.balanceOf(address(rotating)), AMOUNT / 10);
    }

    function test_fundsIn_sameMintAndNetWithDifferentGrossReverts() public {
        vm.prank(user);
        bytes32 original = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _setFundsInTokenRule(5_000); // twice the gross, same net
        LedgerSnapshot memory beforeDuplicate = _snapshotLedger(original);
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 2, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _assertLedgerUnchanged(beforeDuplicate, original);
        assertEq(bridge.totalLockedLiquidity(), AMOUNT);
    }

    function test_fundsIn_sameMintWithPaddedSettlementDataReverts() public {
        vm.prank(user);
        bytes32 original = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, abi.encodePacked(_rgbData(), bytes32(uint256(7))));
        assertEq(rgbModule.fundsInRecords(original), AMOUNT);
        assertEq(bridge.totalLockedLiquidity(), AMOUNT);
    }

    function test_fundsIn_sameMintWithDifferentNetAmountsCreatesDifferentIds() public {
        vm.prank(user);
        bytes32 first = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        vm.prank(user);
        bytes32 second = bridge.fundsIn(AMOUNT / 2, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(first, _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, AMOUNT));
        assertEq(second, _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, AMOUNT / 2));
        assertTrue(first != second);
        assertEq(rgbModule.fundsInRecords(first), AMOUNT);
        assertEq(rgbModule.fundsInRecords(second), AMOUNT / 2);
    }

    function test_fundsIn_sameMintAndAmountOnDifferentRgbNetworksCreatesDifferentIds() public {
        uint256 otherNetwork = RGB_CHAIN_ID + 1;
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, otherNetwork, true, address(rgbVerifier), address(rgbModule));
        vm.prank(user);
        bytes32 first = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        vm.prank(user);
        bytes32 second = bridge.fundsIn(AMOUNT, otherNetwork, DST_ADDR, _rgbData());
        assertEq(second, _deriveRgbOpId(otherNetwork, RGB_OP_ID, AMOUNT));
        assertTrue(first != second);
        assertEq(rgbModule.fundsInRecordChainIds(first), RGB_CHAIN_ID);
        assertEq(rgbModule.fundsInRecordChainIds(second), otherNetwork);
    }

    function test_fundsIn_duplicateRgbMintRestoresNativeCommission() public {
        _setFundsInNativeRule(100);
        (, uint256 fee,) = cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        vm.deal(user, fee * 3);
        vm.prank(user);
        bytes32 original = bridge.fundsIn{value: fee}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        LedgerSnapshot memory beforeDuplicate = _snapshotLedger(original);
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        vm.prank(user);
        bridge.fundsIn{value: fee}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _assertLedgerUnchanged(beforeDuplicate, original);
        assertEq(bridge.totalLockedLiquidity(), AMOUNT);
    }

    /// @dev A non-RGB id binds the authenticated sender; two
    ///      different senders with otherwise-identical deposits produce
    ///      different ids, so an attacker cannot reproduce a victim's id.
    function test_fundsIn_legacyRouteDerivesSenderBoundOperationId() public {
        MockSettlementModule legacyModule = new MockSettlementModule();
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(legacyModule));

        address attacker = makeAddr("attacker");
        usdt0.mint(attacker, AMOUNT);
        vm.prank(attacker);
        usdt0.approve(address(bridge), AMOUNT);

        vm.prank(user);
        bytes32 victimId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.prank(attacker);
        bytes32 attackerId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(victimId != attackerId, "ids bound to distinct senders differ");
        // The attacker's id equals the on-chain derivation for the attacker's
        // sender — it cannot be any value the attacker freely chose.
        assertEq(
            attackerId,
            _deriveOpId(
                SOURCE_CHAIN_ID, bytes32(uint256(uint160(attacker))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
            ),
            "attacker id is the derived value"
        );
    }

    /// @dev Non-RGB identical deposits retain distinct ids (nonce), and the
    ///      per-(chain,sender) nonce advances to 2.
    function test_fundsIn_legacyRouteRepeatedDepositsGetDistinctIds() public {
        MockSettlementModule legacyModule = new MockSettlementModule();
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(legacyModule));

        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 0, "nonce starts at 0");

        vm.prank(user);
        bytes32 id1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        vm.prank(user);
        bytes32 id2 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(id1 != id2, "nonce makes identical deposits distinct");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 2, "nonce incremented to 2");
    }

    /// @dev A deposit below the minimum consumes no nonce; the next valid
    ///      deposit increments it once and records its canonical mint id.
    function test_fundsIn_belowMinimumDoesNotConsumeNonce() public {
        bytes32 sourceSender = bytes32(uint256(uint160(user)));

        // Amount below the (raised) minimum reverts before the nonce is consumed.
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(999), uint256(1000)));
        vm.prank(user);
        bridge.fundsIn(999, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 0, "nonce not consumed on revert");

        // A subsequent successful deposit records its canonical RGB id.
        bytes32 expectedId = _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, 1000);
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(1000, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId, expectedId, "first success records the RGB mint");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 1, "nonce now 1");
    }

    /// @dev Bridge rejects a zero RGB operation ID before module dispatch.
    function test_fundsIn_zeroRgbOpIdReverts() public {
        vm.expectRevert(IBridge.InvalidRgbOpId.selector, address(bridge));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(0));
    }

    /// @dev The RGB route emits FundsIn carrying the rgbOpId and net amount.
    function test_fundsIn_rgbRouteEmitsFundsInWithRgbOpId() public {
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(user, RGB_OP_ID, uint64(AMOUNT)); // no commission → net == gross == AMOUNT
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_rgbRouteAcceptsUint64Maximum() public {
        uint256 amount = type(uint64).max;
        usdt0.mint(user, amount);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(user, RGB_OP_ID, type(uint64).max);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(rgbModule.fundsInRecords(opId), amount);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), amount);
    }

    function test_fundsIn_rgbRouteRejectsNetAmountAboveUint64WithoutTruncation() public {
        uint256 amount = uint256(type(uint64).max) + 1;
        usdt0.mint(user, amount);
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        bytes32 expectedOpId = _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, amount);
        uint256 userBefore = usdt0.balanceOf(user);

        vm.expectRevert(abi.encodeWithSelector(BridgeBaseUpgradeable.AmountExceedsUint64.selector, amount));
        vm.prank(user);
        bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore, "token pull rolled back");
        assertEq(usdt0.balanceOf(address(bridge)), 0, "bridge retained no tokens");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 0, "liquidity credit rolled back");
        assertEq(rgbModule.fundsInRecords(expectedOpId), 0, "settlement record rolled back");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 0, "nonce rolled back");
    }

    function test_fundsIn_rgbRangeCheckUsesNetAmountAfterCommission() public {
        uint256 grossAmount = uint256(type(uint64).max) + 1;
        uint256 percent = 400; // 4% makes the RGB net amount fit in uint64
        _setFundsInTokenRule(percent);
        usdt0.mint(user, grossAmount);

        uint256 expectedNet = grossAmount - cm.calculateStableFee(grossAmount, percent, 100);
        assertLe(expectedNet, type(uint64).max, "test setup: net fits RGB u64");

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(user, RGB_OP_ID, uint64(expectedNet));

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(grossAmount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(rgbModule.fundsInRecords(opId), expectedNet);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), expectedNet);
    }

    function test_fundsIn_rgbOpIdIsIndexedTopic() public {
        bytes32 fundsInTopic = keccak256("FundsIn(address,uint256,uint64)");
        vm.recordLogs();
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(bridge) && logs[i].topics[0] == fundsInTopic) {
                assertEq(logs[i].topics.length, 3, "signature, sender and rgb op id are indexed");
                assertEq(address(uint160(uint256(logs[i].topics[1]))), user, "sender topic");
                assertEq(uint256(logs[i].topics[2]), RGB_OP_ID, "rgb op id topic");
                assertEq(logs[i].data.length, 32, "only amount is event data");
                assertEq(abi.decode(logs[i].data, (uint64)), AMOUNT, "amount is event data");
                return;
            }
        }
        fail("FundsIn event not found");
    }

    /// @dev Full deposit → fundsOut happy path using the captured bytes32 in the
    ///      release settlement data.
    function test_fundsOut_referencesDerivedOperationId() public {
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

        assertEq(usdt0.balanceOf(recipient), AMOUNT, "release via derived id succeeds");
    }
}
