// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {OutflowRateLimiter} from "../../src/libraries/OutflowRateLimiter.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice Signed releases cannot bypass immutable outflow allowances.
contract MultisigOutflowSafetyTest is MultisigProxyTestBase {
    /// @dev Everything a signed release needs, resolved up front. Kept separate
    ///      from submission so `vm.expectRevert` can sit immediately before the
    ///      single `fundsOutCall` — the preparation itself makes external calls
    ///      and would otherwise absorb the expectation.
    function _prepareRelease(address to, uint256 amount, bytes32 sourceBurnTxId)
        private
        view
        returns (
            IBridge.FundsOutParams memory params,
            uint256 nonce,
            uint256 deadline,
            uint256 bitmap,
            bytes[] memory sigs
        )
    {
        params = _fundsOutParams(to, amount, sourceBurnTxId);
        nonce = proxy.teeNonce(RGB_CHAIN_ID);
        deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks;
        (pks, bitmap) = _encSigSet2of3();
        sigs = MultisigHelper.signAll(vm, digest, pks);
    }

    /// @dev Sign and submit a `fundsOut` through the enclave 2-of-3 quorum.
    function _signedRelease(address to, uint256 amount, bytes32 sourceBurnTxId) private {
        (IBridge.FundsOutParams memory params, uint256 nonce, uint256 deadline, uint256 bitmap, bytes[] memory sigs) =
            _prepareRelease(to, amount, sourceBurnTxId);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    function _adminExecuteBridge(bytes memory callData) private {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeAdminExecute(
            domainSep, address(bridge), bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id =
            proxy.proposeAdminExecute(callData, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks));
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(id, callData);
    }

    /// @notice A valid enclave quorum cannot release the full pool when the
    ///         maximum-total bucket policy permits only a 10% burst.
    function test_fundsOutCall_revertsOnFullPoolDrainWithMaximumBuckets() public {
        address drainRecipient = makeAddr("drainRecipient");

        uint256 bridgeBefore = token.balanceOf(address(bridge));
        uint256 recordBefore = rgbModule.fundsInRecords(seedOpId);
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();

        assertEq(bridgeBefore, AMOUNT * 10, "pre bridge pool");
        assertEq(recordBefore, bridgeBefore, "pre record backs full pool");
        assertLt(bridge.availableOutflow(RGB_CHAIN_ID), bridgeBefore, "chain bucket cannot cover TVL");
        assertLt(bridge.availableGlobalOutflow(), bridgeBefore, "global bucket cannot cover TVL");
        assertEq(
            bridge.effectiveAvailableOutflow(RGB_CHAIN_ID),
            bridgeBefore * MAX_BURST_BPS / bridge.BPS_DENOMINATOR(),
            "at most the configured burst can leave, well under TVL"
        );

        IBridge.FundsOutParams memory params = _fundsOutParams(drainRecipient, bridgeBefore, SRC_BURN_TX_ID);
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // The whole pool is 10_000 bps of the reference; the bucket's burst is
        // MAX_BURST_BPS. Requesting 100% therefore exceeds capacity outright.
        uint256 shareUnit = bridge.SHARE_UNIT();
        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.TokenRequestAboveCapacity.selector,
                MAX_BURST_BPS * shareUnit / bridge.BPS_DENOMINATOR(),
                shareUnit, // the full pool is exactly one SHARE_UNIT of reference
                address(token)
            )
        );
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce, "reverted release does not consume nonce");
        assertFalse(bridge.consumedBurnIds(params.burnId), "reverted release does not consume burn id");
        assertEq(token.balanceOf(address(bridge)), bridgeBefore, "entire pool remains");
        assertEq(token.balanceOf(drainRecipient), 0, "recipient receives nothing");
        assertEq(
            bridge.availableChainSafetyOutflow(RGB_CHAIN_ID),
            bridgeBefore * maxBps / bridge.BPS_DENOMINATOR(),
            "immutable allowance unchanged"
        );
    }

    /// @dev Signed releases cannot bypass the rolling cap through policy changes or splitting.
    function test_fundsOutCall_splitReleasesCannotExceedRollingLimit() public {
        bytes memory policy = abi.encodeCall(IBridge.setOutflowLimit, (RGB_CHAIN_ID, uint256(1_900), uint256(100)));
        _adminExecuteBridge(policy);
        _adminExecuteBridge(abi.encodeCall(IBridge.setGlobalOutflowLimit, (uint256(1_900), uint256(100))));
        // Reconfiguration preserves available shares; allow the larger bucket to refill before spending.
        vm.warp(vm.getBlockTimestamp() + 10 days);
        uint256 start = (vm.getBlockTimestamp() / 1 hours + 1) * 1 hours;
        vm.warp(start);
        _signedRelease(recipient, AMOUNT * 19 / 10, keccak256("signed-first-burn"));
        _adminExecuteBridge(abi.encodeCall(IBridge.setOutflowLimit, (RGB_CHAIN_ID, uint256(100), uint256(1_900))));
        _adminExecuteBridge(abi.encodeCall(IBridge.setGlobalOutflowLimit, (uint256(100), uint256(1_900))));
        // Two governance executions advance time; refill remains inside the first rolling window.
        vm.warp(start + 4 hours);
        _signedRelease(recipient, AMOUNT * 81 / 1_000, keccak256("signed-second-burn"));
        vm.warp(start + 5 hours);
        uint256 request = AMOUNT * 19 / 1_000 + 1;
        assertGt(bridge.availableOutflow(RGB_CHAIN_ID), request, "chain bucket permits the request");
        assertGt(bridge.availableGlobalOutflow(), request, "global bucket permits the request");
        (IBridge.FundsOutParams memory params, uint256 nonce, uint256 deadline, uint256 bitmap, bytes[] memory sigs) =
            _prepareRelease(recipient, request, keccak256("signed-third-burn"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IBridge.ChainSafetyLimitExceeded.selector, RGB_CHAIN_ID, request, AMOUNT * 1_981 / 1_000, AMOUNT * 2
            )
        );
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce, "rejected release preserves TEE nonce");
        assertFalse(bridge.consumedBurnIds(params.burnId), "rejected burn remains unconsumed");
        assertEq(
            bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT * 8_019 / 1_000, "only successful releases debit liquidity"
        );
    }

    /// @dev A full-TVL bucket is not merely rejected against current liquidity;
    ///      it is unrepresentable.
    ///      The policy is a percentage, and `burstBps + refillBpsPerWindow` is
    ///      bounded by the immutable `MAX_CHAIN_OUTFLOW_BPS`, so there is no
    ///      liquidity level at which this proposal would ever succeed.
    function test_proposeAdminExecute_rejectsFullPoolBucketPolicyAtExecution() public {
        uint256 fullTvlBps = bridge.BPS_DENOMINATOR(); // 10_000 bps == 100% of TVL
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();
        uint256 availableBefore = bridge.availableOutflow(RGB_CHAIN_ID);

        bytes memory callData = abi.encodeCall(IBridge.setOutflowLimit, (RGB_CHAIN_ID, fullTvlBps, uint256(1)));
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecute(
            domainSep, proxy.bridge(), bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 proposalId =
            proxy.proposeAdminExecute(callData, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks));

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, fullTvlBps, uint256(1), maxBps));
        proxy.executeProposal(proposalId, callData);

        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), availableBefore, "safe bucket configuration unchanged");
    }
}
