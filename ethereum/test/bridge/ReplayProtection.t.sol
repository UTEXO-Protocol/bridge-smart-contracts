// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Canonical burn identities and release replay rejection.
contract BridgeReplayProtectionTest is BridgeTestBase {
    function test_fundsOut_revertsOnReplayedBurnId() public {
        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes32[] memory ids1 = _ids(opId1);
        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(ids1);
        uint256 burnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);

        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData, SRC_BURN_TX_ID);
        assertTrue(bridge.consumedBurnIds(burnId), "burnId recorded");

        // Second fundsOut with the same burnId — must revert before any
        // module mutation, leaving the second record untouched.
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, burnId));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData, SRC_BURN_TX_ID);
        assertEq(rgbModule.fundsInRecords(opId2), AMOUNT, "second fundsIn record preserved");
    }

    function test_fundsOut_revertsOnInvalidDerivedBurnId() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 expectedBurnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);
        uint256 invalidBurnId = expectedBurnId ^ 1;

        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, invalidBurnId, expectedBurnId));
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, invalidBurnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData
        );

        assertFalse(bridge.consumedBurnIds(expectedBurnId), "expected burn id unchanged");
        assertFalse(bridge.consumedBurnIds(invalidBurnId), "invalid burn id unchanged");
    }

    /// @dev Changing a valid relay head preserves the burn key and cannot bypass replay protection.
    function test_fundsOut_changedProofCannotReplaySameBurn() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);

        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), settlementData
        );
        assertTrue(bridge.consumedBurnIds(burnId), "first release consumes the source burn");

        bytes32 latestCommit = keccak256("advanced-relay-head");
        btcRelay.setBlock(LATEST_HEIGHT + 1, latestCommit, LATEST_CONFIRMATIONS);
        bytes memory changedProof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT + 1, latestCommit);
        uint256 recipientBalance = usdt0.balanceOf(recipient);
        uint256 sourceLiquidity = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 totalLiquidity = bridge.totalLockedLiquidity();
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, burnId));
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, changedProof, settlementData
        );
        assertEq(usdt0.balanceOf(recipient), recipientBalance, "replay pays no additional tokens");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), sourceLiquidity, "replay preserves source liquidity");
        assertEq(bridge.totalLockedLiquidity(), totalLiquidity, "replay preserves total liquidity");
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "backing record remains permanent");
    }

    /// @dev Route-agnostic guard: every chain supplies a burn id, and on routes
    ///      whose `settlementData` is empty it is the only field keeping the key
    ///      distinct. Enforced in Bridge rather than a route plugin so a route
    ///      registering `NullSettlementModule` is covered too.
    function test_fundsOut_revertsOnZeroSourceBurnTxId() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, bytes32(0));

        vm.expectRevert(IBridge.ZeroSourceBurnTxId.selector);
        vm.prank(multisig);
        bridge.fundsOut(
            IBridge.FundsOutParams({
                recipient: recipient,
                amount: AMOUNT,
                burnId: burnId,
                sourceChainId: RGB_CHAIN_ID,
                destinationChainId: SOURCE_CHAIN_ID,
                sourceAddress: SRC_ADDR,
                proof: _proof(),
                settlementData: settlementData,
                sourceBurnTxId: bytes32(0)
            })
        );
    }

    /// @dev The source burn identifier IS part of the key: two settlements of
    ///      different burns can never collide, which is what lets `fundsOut` and
    ///      `rebalanceLiquidity` share one replay namespace.
    function test_fundsOut_revertsWhenSourceBurnTxIdChangesAfterBurnIdDerivation() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        bytes32 otherBurnTx = keccak256("a-different-rgb-burn");

        uint256 signedBurnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, otherBurnTx);
        uint256 expectedBurnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);
        assertTrue(signedBurnId != expectedBurnId, "a different burn derives a different id");

        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, signedBurnId, expectedBurnId));
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, signedBurnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData
        );

        assertFalse(bridge.consumedBurnIds(signedBurnId), "signed burn id unchanged");
    }

    function test_fundsOut_rejectsLegacyBurnIdFormula() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 legacyBurnId = uint256(
            keccak256(
                abi.encode(
                    keccak256(
                        "UtexoBurnId(address bridge,uint256 chainId,address token,uint256 amount,uint256 sourceChainId,bytes32 sourceAddressHash,bytes32 settlementDataHash,bytes32 sourceBurnTxId)"
                    ),
                    address(bridge),
                    block.chainid,
                    address(usdt0),
                    AMOUNT,
                    RGB_CHAIN_ID,
                    keccak256(bytes(SRC_ADDR)),
                    keccak256(settlementData),
                    SRC_BURN_TX_ID
                )
            )
        );
        uint256 expectedBurnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, legacyBurnId, expectedBurnId));
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, legacyBurnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), settlementData
        );
        assertFalse(bridge.consumedBurnIds(legacyBurnId));
        assertFalse(bridge.consumedBurnIds(expectedBurnId));
        assertEq(usdt0.balanceOf(recipient), 0);
    }

    function test_fundsOut_changedBackingRecordsCannotReplaySameBurn() public {
        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes memory proof = _proof();
        bytes memory originalData = _settlement(_ids(opId1));
        bytes memory changedData = _settlement(_ids(opId2));
        uint256 burnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);
        assertEq(
            _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID),
            burnId,
            "backing records do not change burn identity"
        );

        vm.prank(multisig);
        _fundsOutWithBurnId(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, originalData);
        uint256 recipientBalance = usdt0.balanceOf(recipient);
        uint256 liquidity = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 poolBalance = usdt0.balanceOf(address(bridge));

        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, burnId));
        vm.prank(multisig);
        _fundsOutWithBurnId(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, changedData);

        assertTrue(bridge.consumedBurnIds(burnId));
        assertEq(usdt0.balanceOf(recipient), recipientBalance, "no second payout");
        assertEq(usdt0.balanceOf(address(bridge)), poolBalance, "pool unchanged");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidity, "liquidity unchanged");
        assertEq(rgbModule.fundsInRecords(opId1), AMOUNT, "first record unchanged");
        assertEq(rgbModule.fundsInRecords(opId2), AMOUNT, "second record unchanged");
    }

    /// @dev A valid bucket-policy change cannot bypass the cumulative rolling limit.
    function test_fundsOut_reusedPermanentRecordCannotExceedRollingLimit() public {
        uint256 start = (vm.getBlockTimestamp() / 1 hours + 1) * 1 hours;
        vm.warp(start);
        vm.startPrank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, 1_900, 100);
        bridge.setGlobalOutflowLimit(1_900, 100);
        vm.stopPrank();
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT * 10, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        bytes memory settlementData = _settlementWithAmounts(_ids(opId), _one(AMOUNT * 10));

        vm.prank(multisig);
        _fundsOut(
            recipient,
            AMOUNT * 19 / 10,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            settlementData,
            keccak256("rolling-first-burn")
        );
        vm.startPrank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, 100, 1_900);
        bridge.setGlobalOutflowLimit(100, 1_900);
        vm.stopPrank();
        vm.warp(start + 2 hours);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            AMOUNT * 81 / 1_000,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            settlementData,
            keccak256("rolling-second-burn")
        );
        vm.warp(start + 3 hours);

        uint256 remaining = AMOUNT * 19 / 1_000;
        uint256 request = remaining + 1;
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), remaining, "both releases count toward the cap");
        assertEq(bridge.availableGlobalSafetyOutflow(), remaining, "physical outflow counts globally");
        assertGt(bridge.availableOutflow(RGB_CHAIN_ID), request, "chain bucket permits the third request");
        assertGt(bridge.availableGlobalOutflow(), request, "global bucket permits the third request");
        uint256 sourceLiquidity = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 totalLiquidity = bridge.totalLockedLiquidity();
        uint256 recipientBalance = usdt0.balanceOf(recipient);
        bytes32 sourceBurnTxId = keccak256("rolling-third-burn");
        uint256 burnId = _deriveBurnId(request, RGB_CHAIN_ID, SRC_ADDR, sourceBurnTxId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBridge.ChainSafetyLimitExceeded.selector, RGB_CHAIN_ID, request, AMOUNT * 1_981 / 1_000, AMOUNT * 2
            )
        );
        vm.prank(multisig);
        _fundsOut(recipient, request, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), settlementData, sourceBurnTxId);
        assertFalse(bridge.consumedBurnIds(burnId), "rejected third burn remains unconsumed");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), sourceLiquidity, "rejected release preserves liquidity");
        assertEq(bridge.totalLockedLiquidity(), totalLiquidity, "rejected release preserves total liquidity");
        assertEq(usdt0.balanceOf(recipient), recipientBalance, "rejected release pays no tokens");
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT * 10, "reused backing record remains permanent");
    }
}
