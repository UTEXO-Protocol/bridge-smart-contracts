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
    // debits lockedLiquidity[sourceChainId] by gross amount. A release can never
    // draw more than was bridged toward that chain, and one chain's bucket can
    // never be drained from another chain's release.
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

    function test_isolatedLiquidity_revertsRollsBackDebit() public {
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
        // Bound to the user's funded balance and above the dust floor; no
        // commission in setUp so net == gross.
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
            _settlementWithAmounts(_ids(opId), _one(amount)),
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
            _settlementWithAmounts(_ids(opId), _one(amount)),
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
            _settlementWithAmounts(_ids(opId), _one(amount)),
            SRC_BURN_TX_ID
        );
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), amount - bucketLimit, "configured 10% burst debited");
    }
}
