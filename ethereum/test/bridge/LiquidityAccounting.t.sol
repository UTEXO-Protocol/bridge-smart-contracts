// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {OutflowRateLimiter} from "../../src/libraries/OutflowRateLimiter.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Per-chain liquidity isolation and atomic debit rollback.
contract BridgeLiquidityAccountingTest is BridgeTestBase {
    // ========================================================================
    // Isolated liquidity
    // fundsIn credits lockedLiquidity[destinationChainId] by netAmount; fundsOut
    // debits lockedLiquidity[sourceChainId] by gross amount. A release cannot
    // exceed its source bucket's current allocation or debit another bucket.
    // ========================================================================

    function test_isolatedLiquidity_fundsInCreditsNetAmount() public {
        // No commission in setUp → net == gross.
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT, "bucket credited net amount");
    }

    function test_isolatedLiquidity_tokenCommissionCreditsNetNotGross() public {
        _setFundsInTokenRule(400); // 4%
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 fee = cm.calculateStableFee(AMOUNT, 400, 100);
        assertGt(fee, 0, "sanity: positive fee");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT - fee, "bucket credits net, not gross");
    }

    function test_isolatedLiquidity_fundsOutDebitsGrossAmount() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 release = AMOUNT * 2 / 5;
        _ensureRgbSafetyCapacity(release);
        _setFundsOutTokenRule(500); // 5% fee makes gross debit differ from payout
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        vm.prank(multisig);
        // The settlement amount matches the original mint record.
        _fundsOut(
            recipient,
            release,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore - release, "bucket debited by gross release");
        assertEq(bridge.totalLockedLiquidity(), liquidityBefore - release, "total debited by gross release");
        assertEq(usdt0.balanceOf(recipient), release * 95 / 100, "recipient receives net after 5% fee");
        assertEq(cm.tokenCommissionPool(address(usdt0)), release * 5 / 100, "commission receives remaining gross debit");
    }

    function test_isolatedLiquidity_chainCannotConsumeAnotherChainsLiquidity() public {
        // Fund only the RGB bucket.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // A different source chain has no isolated liquidity. This guard runs
        // before its bucket, so the missing liquidity is the precise blocker.
        uint256 otherChain = 777;
        vm.prank(deployer);
        routeRegistry.setRoute(otherChain, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // Bridge holds AMOUNT (from the RGB deposit), but it is locked for RGB,
        // not for `otherChain`. The release must fail on isolated liquidity.
        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT, "pool has balance");
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.InsufficientChainLiquidity.selector, otherChain, AMOUNT, uint256(0))
        );
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, otherChain, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId)), SRC_BURN_TX_ID
        );
    }

    function test_fundsOut_verifierRevertRestoresLiquidityDebit() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        _ensureRgbSafetyCapacity(AMOUNT);
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        // A well-formed proof reaches the verifier after the liquidity debit.
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown"), LATEST_HEIGHT, LATEST_COMMIT);
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
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore, "debit rolled back on verifier revert");
    }

    /// @dev Overdrawing the chain ledger fails before bucket consumption.
    ///      Releasing its whole balance exceeds the configured burst capacity;
    ///      a tranche inside that capacity succeeds.
    function testFuzz_fundsOut_enforcesChainLiquidityAndBucketCapacity(uint256 amount) public {
        amount = bound(amount, 1e6, AMOUNT * 10);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), amount, "credited");

        // Mint an unlocked buffer so the pool balance exceeds the locked amount;
        // this isolates the per-chain liquidity guard from the raw balance guard
        // (a direct mint does not credit lockedLiquidity).
        usdt0.mint(address(bridge), amount + 1);

        // One unit over the locked amount reverts on the per-chain liquidity guard.
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.InsufficientChainLiquidity.selector, RGB_CHAIN_ID, amount + 1, amount)
        );
        vm.prank(multisig);
        _fundsOut(
            recipient,
            amount + 1,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );

        // Releasing the whole chain balance is 100% of the reference, i.e. one
        // full SHARE_UNIT, against the configured 10% burst capacity.
        _configureMaxSafeBuckets();
        uint256 shareUnit = bridge.SHARE_UNIT();
        uint256 bucketLimit = amount * MAX_BURST_BPS / bridge.BPS_DENOMINATOR();
        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.TokenRequestAboveCapacity.selector,
                MAX_BURST_BPS * shareUnit / bridge.BPS_DENOMINATOR(),
                shareUnit,
                address(usdt0)
            )
        );
        vm.prank(multisig);
        _fundsOut(
            recipient,
            amount,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );

        vm.prank(multisig);
        _fundsOut(
            recipient,
            bucketLimit,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), amount - bucketLimit, "configured 10% burst debited");
    }

    /// @dev A plain ERC20 transfer increases custody without crediting either
    ///      liquidity ledger. Only fundsIn creates the accounted credit.
    function test_fundsIn_directTokenTransferDoesNotCreditLiquidity() public {
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
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 0, "direct transfer creates no chain liquidity");
        assertEq(bridge.totalLockedLiquidity(), 0, "direct transfer creates no total liquidity");

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
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT, "only fundsIn credits chain liquidity");
        assertEq(bridge.totalLockedLiquidity(), AMOUNT, "only fundsIn credits total liquidity");
    }
}
