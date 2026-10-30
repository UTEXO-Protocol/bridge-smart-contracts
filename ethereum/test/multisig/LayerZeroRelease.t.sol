// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {CommissionConfig, CommissionCurrency, CommissionSide} from "../../src/interfaces/ICommissionManager.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MockOutboundLZAdapter} from "../mocks/MockOutboundLZAdapter.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice LayerZero releases bind recipient, actual delivered tokens and outbound fees.
contract MultisigLayerZeroReleaseTest is MultisigProxyTestBase {
    struct ReleaseSnapshot {
        uint256 adapter;
        uint256 adapterEth;
        uint256 bridge;
        uint256 cm;
        uint256 cmPool;
        uint256 duplicateRecord;
        uint256 nativePool;
        uint256 oft;
        uint256 oftEth;
        uint256 originalRecord;
        uint256 proxyEth;
        uint256 record;
    }

    struct ReleaseQuote {
        uint256 tokenCommission;
        uint256 nativeCommission;
        uint256 netAmount;
    }

    struct ReleaseAuthorization {
        uint256 nonce;
        uint256 deadline;
        uint256 bitmap;
        bytes[] sigs;
    }

    /// @dev Registration executes its signed timelock before a release is prepared.
    function _deployLzAdapter(address oft) private returns (MockOutboundLZAdapter adapter) {
        adapter = new MockOutboundLZAdapter(address(token), oft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));
    }

    function _snapshotRelease(address adapter, address oft) private view returns (ReleaseSnapshot memory state) {
        state.bridge = token.balanceOf(address(bridge));
        state.adapter = token.balanceOf(adapter);
        state.oft = token.balanceOf(oft);
        state.cm = token.balanceOf(address(cm));
        state.cmPool = cm.tokenCommissionPool(address(token));
        state.nativePool = cm.nativeCommissionPool();
        state.record = rgbModule.fundsInRecords(seedOpId);
        state.proxyEth = address(proxy).balance;
        state.adapterEth = adapter.balance;
        state.oftEth = oft.balance;
    }

    function _setTokenCommission(uint256 stablePercent) private {
        vm.prank(address(proxy));
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: stablePercent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );
    }

    function _quoteRelease() private view returns (ReleaseQuote memory quote) {
        (quote.tokenCommission, quote.nativeCommission, quote.netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
    }

    function _authorizeRelease(IMultisigProxy.LzFundsOutParams memory params)
        private
        view
        returns (ReleaseAuthorization memory auth)
    {
        auth.deadline = vm.getBlockTimestamp() + 1 hours;
        (auth.nonce, auth.bitmap, auth.sigs) = _signLzEnclave(params, auth.deadline);
    }

    /// @notice One signed release pays the Bridge net amount through the adapter
    ///         and forwards the native fee, leaving no token or native residue.
    function test_lzFundsOutCall_forwardsNetTokensAndNativeFeeWithoutResidue() public {
        ReleaseSnapshot memory beforeState;
        _setTokenCommission(500); // 5%

        ReleaseQuote memory quote = _quoteRelease();
        assertGt(quote.tokenCommission, 0, "token fee quoted");
        assertEq(quote.nativeCommission, 0, "native fee is zero");
        assertEq(quote.netAmount, AMOUNT - quote.tokenCommission, "net adapter amount");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter = _deployLzAdapter(mockOft);

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());

        ReleaseAuthorization memory auth = _authorizeRelease(params);

        beforeState = _snapshotRelease(address(adapter), mockOft);

        assertEq(beforeState.bridge, AMOUNT * 10, "pre bridge pool");
        assertEq(beforeState.adapter, 0, "pre adapter token");
        assertEq(beforeState.oft, 0, "pre oft token");
        assertEq(beforeState.cm, 0, "pre cm token");
        assertEq(beforeState.cmPool, 0, "pre cm pool");
        assertEq(beforeState.record, AMOUNT * 10, "pre record");
        assertEq(beforeState.adapterEth, 0, "pre adapter native");
        assertEq(beforeState.oftEth, 0, "pre oft native");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        bytes32 sendOutGuid = keccak256(abi.encode("mock-send-out", DST_EID, LZ_RECIPIENT, quote.netAmount));

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeFundsOut(
            address(adapter),
            AMOUNT,
            quote.netAmount,
            quote.tokenCommission,
            params.burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            params.settlementData
        );
        vm.expectEmit(true, false, false, true, address(adapter));
        emit MockOutboundLZAdapter.SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, quote.netAmount);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.LzFundsOutExecuted(
            RGB_CHAIN_ID, auth.nonce, auth.bitmap, DST_EID, LZ_RECIPIENT, quote.netAmount
        );

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, auth.nonce, auth.deadline, auth.bitmap, auth.sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), auth.nonce + 1, "tee nonce incremented");
        assertTrue(bridge.consumedBurnIds(params.burnId), "burn id consumed");
        assertEq(token.balanceOf(address(bridge)), beforeState.bridge - AMOUNT, "bridge gross debit");
        assertEq(token.balanceOf(address(cm)), beforeState.cm + quote.tokenCommission, "cm fee delta");
        assertEq(cm.tokenCommissionPool(address(token)), beforeState.cmPool + quote.tokenCommission, "cm pool delta");
        assertEq(rgbModule.fundsInRecords(seedOpId), beforeState.record, "record unchanged (proof-of-mint permanent)");
        assertEq(token.balanceOf(address(adapter)), beforeState.adapter, "adapter no residue");
        assertEq(token.balanceOf(mockOft), beforeState.oft + quote.netAmount, "oft receives net");
        assertEq(address(proxy).balance, beforeState.proxyEth, "proxy native no residue");
        assertEq(address(adapter).balance, beforeState.adapterEth, "adapter native no residue");
        assertEq(mockOft.balance, beforeState.oftEth + LZ_NATIVE_FEE, "oft receives native fee");
        assertEq(
            (token.balanceOf(mockOft) - beforeState.oft) + (token.balanceOf(address(cm)) - beforeState.cm),
            AMOUNT,
            "gross batch payout conserved"
        );
    }

    // Rollback: an insufficient LayerZero native fee reverts in
    // adapter.sendOut, after Bridge.fundsOut ran in the same lzFundsOutCall, so
    // the whole release rolls back.
    function test_lzFundsOutCall_sendOutInsufficientNativeFeeRollsBackBridgeState() public {
        ReleaseSnapshot memory beforeState;
        _setTokenCommission(500); // 5%

        ReleaseQuote memory quote = _quoteRelease();
        assertGt(quote.tokenCommission, 0, "token fee quoted");
        assertEq(quote.nativeCommission, 0, "native fee is zero");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter = _deployLzAdapter(mockOft);

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());

        ReleaseAuthorization memory auth = _authorizeRelease(params);

        // Snapshot all state touched by the first Bridge leg and the failed adapter leg.
        beforeState = _snapshotRelease(address(adapter), mockOft);

        assertEq(beforeState.bridge, AMOUNT * 10, "pre bridge pool");
        assertEq(beforeState.adapter, 0, "pre adapter token");
        assertEq(beforeState.oft, 0, "pre oft token");
        assertEq(beforeState.cm, 0, "pre cm token");
        assertEq(beforeState.cmPool, 0, "pre cm pool");
        assertEq(beforeState.nativePool, 0, "pre native pool");
        assertEq(beforeState.record, AMOUNT * 10, "pre record");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        // An underfunded native fee reverts in sendOut, after Bridge.fundsOut
        // already ran inside the same lzFundsOutCall transaction.
        vm.deal(address(this), LZ_NATIVE_FEE - 1);
        vm.expectRevert(bytes("native fee"));
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE - 1}(params, auth.nonce, auth.deadline, auth.bitmap, auth.sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), auth.nonce, "tee nonce unchanged");
        assertFalse(bridge.consumedBurnIds(params.burnId), "burn id unchanged");
        assertEq(token.balanceOf(address(bridge)), beforeState.bridge, "bridge token unchanged");
        assertEq(token.balanceOf(address(adapter)), beforeState.adapter, "adapter token unchanged");
        assertEq(token.balanceOf(mockOft), beforeState.oft, "oft token unchanged");
        assertEq(token.balanceOf(address(cm)), beforeState.cm, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(token)), beforeState.cmPool, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), beforeState.nativePool, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(seedOpId), beforeState.record, "record unchanged");
        assertEq(address(proxy).balance, beforeState.proxyEth, "proxy native unchanged");
        assertEq(address(adapter).balance, beforeState.adapterEth, "adapter native unchanged");
        assertEq(mockOft.balance, beforeState.oftEth, "oft native unchanged");
    }

    // Bridge has liquidity and the adapter is configured; verification fails
    // before any transfer or adapter dispatch.
    // Real UtexoLZAdapter call-skipping coverage belongs in a cross-repo integration test.
    function test_lzFundsOutCall_bridgeVerifierFailureDoesNotCallAdapter() public {
        ReleaseSnapshot memory beforeState;
        _setTokenCommission(500); // 5%

        ReleaseQuote memory quote = _quoteRelease();
        assertGt(quote.tokenCommission, 0, "token fee quoted");
        assertEq(quote.nativeCommission, 0, "native fee is zero");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter = _deployLzAdapter(mockOft);

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());
        // Well-formed two-pair proof whose source block is unknown to the relay,
        // so Bridge.fundsOut reverts before the adapter send can run.
        params.proof = abi.encode(uint256(999_999), keccak256("unknown-block"), LATEST_HEIGHT, LATEST_COMMIT);

        ReleaseAuthorization memory auth = _authorizeRelease(params);

        // The Bridge is funded and the adapter is configured; the verifier
        // failure stops dispatch before tokens reach the adapter.
        beforeState = _snapshotRelease(address(adapter), mockOft);

        assertEq(beforeState.bridge, AMOUNT * 10, "pre bridge pool");
        assertEq(beforeState.adapter, 0, "pre adapter token");
        assertEq(beforeState.oft, 0, "pre oft token");
        assertEq(beforeState.cm, 0, "pre cm token");
        assertEq(beforeState.cmPool, 0, "pre cm pool");
        assertEq(beforeState.nativePool, 0, "pre native pool");
        assertEq(beforeState.record, AMOUNT * 10, "pre record");
        assertEq(adapter.sendOutCalls(), 0, "pre adapter calls");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        vm.deal(address(this), LZ_NATIVE_FEE);
        vm.expectRevert(bytes("verify: block commitment"));
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, auth.nonce, auth.deadline, auth.bitmap, auth.sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), auth.nonce, "tee nonce unchanged");
        assertFalse(bridge.consumedBurnIds(params.burnId), "burn id unchanged");
        assertEq(adapter.sendOutCalls(), 0, "adapter not called");
        assertEq(token.balanceOf(address(bridge)), beforeState.bridge, "bridge token unchanged");
        assertEq(token.balanceOf(address(adapter)), beforeState.adapter, "adapter token unchanged");
        assertEq(token.balanceOf(mockOft), beforeState.oft, "oft token unchanged");
        assertEq(token.balanceOf(address(cm)), beforeState.cm, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(token)), beforeState.cmPool, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), beforeState.nativePool, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(seedOpId), beforeState.record, "record unchanged");
        assertEq(address(proxy).balance, beforeState.proxyEth, "proxy native unchanged");
        assertEq(address(adapter).balance, beforeState.adapterEth, "adapter native unchanged");
        assertEq(mockOft.balance, beforeState.oftEth, "oft native unchanged");
    }

    // Duplicate settlement IDs are accepted when the release amount is smaller
    // than the referenced permanent record.
    function test_lzFundsOutCall_acceptsDuplicateSettlementIdsOnPartialRelease() public {
        ReleaseSnapshot memory beforeState;
        _setTokenCommission(500); // 5%

        ReleaseQuote memory quote = _quoteRelease();
        assertGt(quote.tokenCommission, 0, "token fee quoted");
        assertEq(quote.nativeCommission, 0, "native fee is zero");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter = _deployLzAdapter(mockOft);

        bytes32[] memory duplicateIds = new bytes32[](2);
        duplicateIds[0] = seedOpId;
        duplicateIds[1] = seedOpId;

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, duplicateIds);

        ReleaseAuthorization memory auth = _authorizeRelease(params);

        // Duplicate ids are harmless under the permanent-record module: the check is a
        // pure read, so referencing the same id twice with its (correct) amount
        // simply passes both times. Solvency is the Bridge's concern, not the
        // module's.
        beforeState = _snapshotRelease(address(adapter), mockOft);

        assertEq(beforeState.bridge, AMOUNT * 10, "pre bridge pool");
        assertEq(beforeState.adapter, 0, "pre adapter token");
        assertEq(beforeState.oft, 0, "pre oft token");
        assertEq(beforeState.cm, 0, "pre cm token");
        assertEq(beforeState.cmPool, 0, "pre cm pool");
        assertEq(beforeState.nativePool, 0, "pre native pool");
        assertEq(beforeState.record, AMOUNT * 10, "pre record");
        assertEq(adapter.sendOutCalls(), 0, "pre adapter calls");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        bytes32 sendOutGuid = keccak256(abi.encode("mock-send-out", DST_EID, LZ_RECIPIENT, quote.netAmount));

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeFundsOut(
            address(adapter),
            AMOUNT,
            quote.netAmount,
            quote.tokenCommission,
            params.burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            params.settlementData
        );
        vm.expectEmit(true, false, false, true, address(adapter));
        emit MockOutboundLZAdapter.SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, quote.netAmount);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.LzFundsOutExecuted(
            RGB_CHAIN_ID, auth.nonce, auth.bitmap, DST_EID, LZ_RECIPIENT, quote.netAmount
        );

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, auth.nonce, auth.deadline, auth.bitmap, auth.sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), auth.nonce + 1, "tee nonce incremented");
        assertTrue(bridge.consumedBurnIds(params.burnId), "burn id consumed");
        assertEq(adapter.sendOutCalls(), 1, "adapter called once");
        assertEq(token.balanceOf(address(bridge)), beforeState.bridge - AMOUNT, "bridge token debit");
        assertEq(token.balanceOf(address(adapter)), beforeState.adapter, "adapter no residue");
        assertEq(token.balanceOf(mockOft), beforeState.oft + quote.netAmount, "oft token delta");
        assertEq(token.balanceOf(address(cm)), beforeState.cm + quote.tokenCommission, "cm token delta");
        assertEq(cm.tokenCommissionPool(address(token)), beforeState.cmPool + quote.tokenCommission, "cm pool delta");
        assertEq(cm.nativeCommissionPool(), beforeState.nativePool, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(seedOpId), beforeState.record, "record unchanged (proof-of-mint permanent)");
        assertEq(address(proxy).balance, beforeState.proxyEth, "proxy native unchanged");
        assertEq(address(adapter).balance, beforeState.adapterEth, "adapter native unchanged");
        assertEq(mockOft.balance, beforeState.oftEth + LZ_NATIVE_FEE, "oft native fee");
    }

    // Duplicate settlement IDs are also accepted when the release amount equals
    // the referenced permanent record. Each (id, amount) pair is verified by read.
    function test_lzFundsOutCall_acceptsDuplicateSettlementIdsOnFullRelease() public {
        ReleaseSnapshot memory beforeState;
        vm.prank(user);
        bytes32 secondOpId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, abi.encode(RGB_OP_ID, RGB_BEFORE_BLOCK));

        _setTokenCommission(500); // 5%

        ReleaseQuote memory quote = _quoteRelease();
        assertGt(quote.tokenCommission, 0, "token fee quoted");
        assertEq(quote.nativeCommission, 0, "native fee is zero");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter = _deployLzAdapter(mockOft);

        bytes32[] memory duplicateIds = new bytes32[](2);
        duplicateIds[0] = secondOpId;
        duplicateIds[1] = secondOpId;

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, duplicateIds);

        ReleaseAuthorization memory auth = _authorizeRelease(params);

        // The module keeps permanent records, so a duplicated id is just
        // verified twice against the same (intact) record and passes.
        beforeState = _snapshotRelease(address(adapter), mockOft);
        beforeState.originalRecord = beforeState.record;
        beforeState.duplicateRecord = rgbModule.fundsInRecords(secondOpId);

        assertEq(beforeState.bridge, AMOUNT * 11, "pre bridge pool");
        assertEq(beforeState.adapter, 0, "pre adapter token");
        assertEq(beforeState.oft, 0, "pre oft token");
        assertEq(beforeState.cm, 0, "pre cm token");
        assertEq(beforeState.cmPool, 0, "pre cm pool");
        assertEq(beforeState.originalRecord, AMOUNT * 10, "pre original record");
        assertEq(beforeState.duplicateRecord, AMOUNT, "pre duplicate record");
        assertEq(adapter.sendOutCalls(), 0, "pre adapter calls");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        bytes32 sendOutGuid = keccak256(abi.encode("mock-send-out", DST_EID, LZ_RECIPIENT, quote.netAmount));

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeFundsOut(
            address(adapter),
            AMOUNT,
            quote.netAmount,
            quote.tokenCommission,
            params.burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            params.settlementData
        );
        vm.expectEmit(true, false, false, true, address(adapter));
        emit MockOutboundLZAdapter.SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, quote.netAmount);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.LzFundsOutExecuted(
            RGB_CHAIN_ID, auth.nonce, auth.bitmap, DST_EID, LZ_RECIPIENT, quote.netAmount
        );

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, auth.nonce, auth.deadline, auth.bitmap, auth.sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), auth.nonce + 1, "tee nonce incremented");
        assertTrue(bridge.consumedBurnIds(params.burnId), "burn id consumed");
        assertEq(adapter.sendOutCalls(), 1, "adapter called once");
        assertEq(token.balanceOf(address(bridge)), beforeState.bridge - AMOUNT, "bridge token debit");
        assertEq(token.balanceOf(address(adapter)), beforeState.adapter, "adapter no residue");
        assertEq(token.balanceOf(mockOft), beforeState.oft + quote.netAmount, "oft token delta");
        assertEq(token.balanceOf(address(cm)), beforeState.cm + quote.tokenCommission, "cm token delta");
        assertEq(cm.tokenCommissionPool(address(token)), beforeState.cmPool + quote.tokenCommission, "cm pool delta");
        assertEq(rgbModule.fundsInRecords(seedOpId), beforeState.originalRecord, "original record untouched");
        assertEq(rgbModule.fundsInRecords(secondOpId), beforeState.duplicateRecord, "duplicate record unchanged");
        assertEq(address(proxy).balance, beforeState.proxyEth, "proxy native unchanged");
        assertEq(address(adapter).balance, beforeState.adapterEth, "adapter native unchanged");
        assertEq(mockOft.balance, beforeState.oftEth + LZ_NATIVE_FEE, "oft native fee");
    }

    // ========================================================================
    // lzFundsOutCall binds the release and send-out legs
    // The release and cross-chain send are bound on-chain in one signed
    // operation: the Bridge recipient is forced to the adapter (no params field
    // for it), and the amount handed to adapter.sendOut is the balance the
    // adapter ACTUALLY received, measured on-chain — not params.amount. A token
    // commission makes gross != net, which is what distinguishes the bound
    // (net delivered) amount from the signed gross amount.
    // ========================================================================

    function test_lzFundsOutCall_sendsNetDeliveredNotGross() public {
        // 5% FUNDS_OUT token commission so gross (AMOUNT) != net (delivered).
        _setTokenCommission(500); // 5%

        ReleaseQuote memory quote = _quoteRelease();
        assertGt(quote.tokenCommission, 0, "fee makes gross != net");
        assertEq(quote.netAmount, AMOUNT - quote.tokenCommission, "net = gross - fee");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter = _deployLzAdapter(mockOft);

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());
        ReleaseAuthorization memory auth = _authorizeRelease(params);

        // Leg 1: the Bridge recipient is forced to the adapter (not in params).
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeFundsOut(
            address(adapter),
            AMOUNT,
            quote.netAmount,
            quote.tokenCommission,
            params.burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            params.settlementData
        );
        // Leg 2: sendOut carries the NET delivered amount, not the gross AMOUNT.
        bytes32 sendOutGuid = keccak256(abi.encode("mock-send-out", DST_EID, LZ_RECIPIENT, quote.netAmount));
        vm.expectEmit(true, false, false, true, address(adapter));
        emit MockOutboundLZAdapter.SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, quote.netAmount);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, auth.nonce, auth.deadline, auth.bitmap, auth.sigs);

        // The send-out amount is bound to what the adapter received: it forwarded
        // exactly the net (leaving no residue) and that net differs from gross.
        assertEq(token.balanceOf(address(adapter)), 0, "adapter forwarded everything it received");
        assertEq(token.balanceOf(mockOft), quote.netAmount, "oft received exactly the net delivered");
        assertTrue(quote.netAmount != AMOUNT, "bound amount is distinct from signed gross");
    }

    function test_lzFundsOutCall_revertsOnDeadlineTooFar() public {
        address mockOft = makeAddr("mockOft");
        _deployLzAdapter(mockOft);

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + proxy.MAX_TEE_DEADLINE() + 1;

        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.deal(address(this), LZ_NATIVE_FEE);
        vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);
    }

    function test_lzFundsOutCall_revertsIfAdapterUnset() public {
        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.LZAdapterNotSet.selector);
        proxy.lzFundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    function test_lzFundsOutCall_settlementDataRemainsSigned() public {
        MockOutboundLZAdapter adapter = _deployLzAdapter(makeAddr("mockOft"));
        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);
        params.settlementData = bytes.concat(params.settlementData, hex"01");
        vm.deal(address(this), LZ_NATIVE_FEE);
        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce, "invalid settlement signature preserves the nonce");
        assertFalse(bridge.consumedBurnIds(params.burnId), "invalid settlement signature leaves the burn fresh");
        assertEq(adapter.sendOutCalls(), 0, "invalid settlement signature makes no adapter call");
    }

    function test_lzFundsOutCall_changedSettlementCannotReplaySameBurn() public {
        address oft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter = _deployLzAdapter(oft);
        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);
        vm.deal(address(this), LZ_NATIVE_FEE * 2);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);
        uint256 balance = token.balanceOf(oft);

        params.settlementData = bytes.concat(params.settlementData, hex"00");
        // Fresh valid signatures authorize the changed payload and current nonce.
        (nonce, bitmap, sigs) = _signLzEnclave(params, deadline);
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, params.burnId));
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce, "failed release restores nonce");
        assertEq(adapter.sendOutCalls(), 1, "no second send");
        assertEq(token.balanceOf(oft), balance, "no second payout");
    }

    function test_lzFundsOutCall_acceptsDeadlineAtMaxBoundary() public {
        address mockOft = makeAddr("mockOft");
        _deployLzAdapter(mockOft);

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + proxy.MAX_TEE_DEADLINE(); // exact boundary

        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);
        assertEq(token.balanceOf(mockOft), AMOUNT, "lz release executes at the exact deadline ceiling");
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "teeNonce incremented");
    }

    function test_lzFundsOutCall_revertsOnConsumedNonceForDifferentBurn() public {
        address oft = makeAddr("stale-nonce-oft");
        MockOutboundLZAdapter adapter = _deployLzAdapter(oft);
        IMultisigProxy.LzFundsOutParams memory first =
            _lzFundsOutParams(AMOUNT / 4, keccak256("nonce-first-lz-release"), _fundsInIds());
        ReleaseAuthorization memory auth = _authorizeRelease(first);
        vm.deal(address(this), LZ_NATIVE_FEE * 2);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(first, auth.nonce, auth.deadline, auth.bitmap, auth.sigs);
        IMultisigProxy.LzFundsOutParams memory second =
            _lzFundsOutParams(AMOUNT / 4, keccak256("nonce-second-lz-release"), _fundsInIds());
        (uint256[] memory keys,) = _encSigSet2of3();
        auth.sigs = MultisigHelper.signAll(
            vm, MultisigHelper.digestTeeLzFundsOut(domainSep, second, auth.nonce, auth.deadline), keys
        );
        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(second, auth.nonce, auth.deadline, auth.bitmap, auth.sigs);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), auth.nonce + 1, "stale nonce does not change lane");
        assertEq(adapter.sendOutCalls(), 1, "only the first send executes");
        assertEq(token.balanceOf(oft), AMOUNT / 4, "only the first payload pays out");
        assertEq(oft.balance, LZ_NATIVE_FEE, "only the first native fee is forwarded");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT * 10 - AMOUNT / 4, "only the first debit persists");
        assertFalse(bridge.consumedBurnIds(second.burnId), "rejected burn remains fresh");

        ReleaseAuthorization memory fresh = _authorizeRelease(second);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(second, fresh.nonce, fresh.deadline, fresh.bitmap, fresh.sigs);
        assertEq(adapter.sendOutCalls(), 2, "fresh nonce accepts the same second payload");
        assertEq(token.balanceOf(oft), AMOUNT / 2, "fresh nonce pays the second payload");
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), 2, "fresh nonce advances the lane");
    }

    function test_lzFundsOutCall_revertsOnUnknownSourceBeforeNonceCheck() public {
        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());
        params.sourceChainId = 424_242;
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, uint256(424_242)));
        proxy.lzFundsOutCall(params, 1, vm.getBlockTimestamp() + 1 hours, 0, new bytes[](0));
    }
}
