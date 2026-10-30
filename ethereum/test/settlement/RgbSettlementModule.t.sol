// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {IArbSys} from "../../src/interfaces/IArbSys.sol";
import {FundsInContext, FundsOutContext} from "../../src/interfaces/RouteTypes.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";

/// @notice RGB settlement requires permanent, network-scoped operation IDs.
/// @dev Records remain permanent. Empty accounting-only settlements are valid;
///      non-empty releases validate each pair without comparing their sum to
///      the release amount. Bridge enforces solvency and burn replay protection.
contract RgbSettlementModuleTest is Test {
    bytes32 internal constant SRC_BURN_TX_ID = keccak256("unit-burn-tx");

    RgbSettlementModule internal module;

    address internal routeRegistry = makeAddr("routeRegistry");

    address internal attacker = makeAddr("attacker");

    address internal user = makeAddr("user");

    address internal recipient = makeAddr("recipient");

    address internal token = makeAddr("token");

    uint256 internal constant RGB_CHAIN_ID = 1_000_001; // RGB network the mint is credited to

    uint256 internal constant EVM_CHAIN_ID = 42161; // arbitrum

    uint256 internal constant OTHER_RGB_CHAIN_ID = 1_000_002; // a second RGB network

    bytes32 internal constant TX_ID_1 = bytes32(uint256(100));

    bytes32 internal constant TX_ID_2 = bytes32(uint256(101));

    uint256 internal constant AMOUNT = 100e18;

    uint256 internal constant BURN_ID = 9_001;

    /// @dev Non-zero RGB OpId threaded through `onFundsIn`'s settlementData.
    uint256 internal constant RGB_OP_ID = 0xABCDEF;

    uint256 internal constant L2_BLOCK = 1_000_000;

    uint64 internal constant BEFORE_BLOCK = 1_100_000;

    function setUp() public {
        vm.mockCall(address(100), abi.encodeCall(IArbSys.arbBlockNumber, ()), abi.encode(L2_BLOCK));
        module = new RgbSettlementModule(routeRegistry);
    }

    /// @dev A deposit toward the RGB network: source = EVM, dest = RGB. The
    ///      record is therefore tagged with `RGB_CHAIN_ID`.
    function _fundsInCtx(bytes32 operationId, uint256 netAmount) private view returns (FundsInContext memory) {
        return _fundsInCtx(operationId, netAmount, RGB_CHAIN_ID);
    }

    /// @dev Deposit toward an explicit RGB network id (its `destChainId`).
    function _fundsInCtx(bytes32 operationId, uint256 netAmount, uint256 rgbChainId)
        private
        view
        returns (FundsInContext memory)
    {
        return FundsInContext({
            token: token,
            sender: user,
            sourceSender: bytes32(uint256(uint160(user))),
            grossAmount: netAmount, // gross == net for these tests
            netAmount: netAmount,
            operationId: operationId,
            senderNonce: 0,
            sourceChainId: EVM_CHAIN_ID,
            destChainId: rgbChainId,
            destAddress: ""
        });
    }

    /// @dev A release burning from the RGB network: source = RGB, dest = EVM.
    ///      Its `sourceChainId` must match the referenced records' network tag.
    ///      `ctx.amount` is irrelevant to the module — it never compares the
    ///      release amount against the mint records.
    function _fundsOutCtx() private view returns (FundsOutContext memory) {
        return _fundsOutCtx(RGB_CHAIN_ID);
    }

    function _fundsOutCtx(uint256 rgbChainId) private view returns (FundsOutContext memory) {
        return FundsOutContext({
            token: token,
            recipient: recipient,
            amount: AMOUNT,
            burnId: BURN_ID,
            sourceChainId: rgbChainId,
            destChainId: EVM_CHAIN_ID,
            sourceAddress: "",
            isRebalance: false,
            sourceBurnTxId: SRC_BURN_TX_ID
        });
    }

    /// @dev Encodes the referenced RGB mint operation ids.
    function _settlementData(bytes32[] memory ids) private pure returns (bytes memory) {
        return abi.encode(ids);
    }

    function _single(bytes32 value) private pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = value;
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32[] memory arr) {
        arr = new bytes32[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _fundsInData(uint256 rgbOpId, uint64 beforeBlock) private pure returns (bytes memory) {
        return abi.encode(rgbOpId, beforeBlock);
    }

    /// @dev `onFundsIn` settlementData must decode to a non-zero RGB OpId.
    function _record(bytes32 operationId, uint256 netAmount) private {
        vm.prank(routeRegistry);
        module.onFundsIn(_fundsInCtx(operationId, netAmount), _fundsInData(RGB_OP_ID, BEFORE_BLOCK));
    }

    function test_constructor_setsRouteRegistry() public view {
        assertEq(module.routeRegistry(), routeRegistry);
    }

    function test_constructor_revertsOnZeroRouteRegistry() public {
        vm.expectRevert(RgbSettlementModule.InvalidRouteRegistry.selector);
        new RgbSettlementModule(address(0));
    }

    function test_onFundsIn_recordsNetAmount() public {
        _record(TX_ID_1, AMOUNT);
        assertEq(module.fundsInRecords(TX_ID_1), AMOUNT);
    }

    function test_onFundsIn_recordsL2BlockPlusOne() public {
        _record(TX_ID_1, AMOUNT);
        assertEq(module.fundsInRecordL2Blocks(TX_ID_1), L2_BLOCK + 1);
    }

    function test_onFundsIn_tagsRecordWithDestChainId() public {
        _record(TX_ID_1, AMOUNT);
        assertEq(module.fundsInRecordChainIds(TX_ID_1), RGB_CHAIN_ID, "record tagged with the RGB network");
    }

    function test_onFundsIn_returnsRgbOpId() public {
        vm.prank(routeRegistry);
        uint256 returned = module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), _fundsInData(RGB_OP_ID, BEFORE_BLOCK));
        assertEq(returned, RGB_OP_ID, "returns decoded rgb op id");
    }

    function test_onFundsIn_acceptsBlockImmediatelyBeforeDeadline() public {
        uint256 lastValidBlock = uint256(BEFORE_BLOCK) - 1;
        _setL2Block(lastValidBlock);

        vm.prank(routeRegistry);
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), _fundsInData(RGB_OP_ID, BEFORE_BLOCK));

        assertEq(module.fundsInRecords(TX_ID_1), AMOUNT);
    }

    function test_onFundsIn_recordsUint64MaxAtBlockBoundary() public {
        uint256 lastUint64Block = type(uint64).max - 1;
        _setL2Block(lastUint64Block);

        vm.prank(routeRegistry);
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), _fundsInData(RGB_OP_ID, type(uint64).max));

        assertEq(module.fundsInRecordL2Blocks(TX_ID_1), type(uint64).max);
    }

    function test_onFundsIn_revertsAtDeadlineWithoutWritingRecord() public {
        _setL2Block(BEFORE_BLOCK);

        vm.prank(routeRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(RgbSettlementModule.LockWindowExpired.selector, BEFORE_BLOCK, BEFORE_BLOCK)
        );
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), _fundsInData(RGB_OP_ID, BEFORE_BLOCK));

        assertEq(module.fundsInRecords(TX_ID_1), 0);
        assertEq(module.fundsInRecordChainIds(TX_ID_1), 0);
        assertEq(module.fundsInRecordL2Blocks(TX_ID_1), 0);
    }

    function test_onFundsIn_revertsAfterDeadlineWithoutWritingRecord() public {
        uint256 lateBlock = uint256(BEFORE_BLOCK) + 1;
        _setL2Block(lateBlock);

        vm.prank(routeRegistry);
        vm.expectRevert(abi.encodeWithSelector(RgbSettlementModule.LockWindowExpired.selector, lateBlock, BEFORE_BLOCK));
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), _fundsInData(RGB_OP_ID, BEFORE_BLOCK));

        assertEq(module.fundsInRecords(TX_ID_1), 0);
        assertEq(module.fundsInRecordChainIds(TX_ID_1), 0);
        assertEq(module.fundsInRecordL2Blocks(TX_ID_1), 0);
    }

    function test_onFundsIn_revertsOnLegacyOneWordPayload() public {
        vm.prank(routeRegistry);
        vm.expectRevert();
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), abi.encode(RGB_OP_ID));
    }

    function test_getFundsInRecords_returnsAmountsInOrderAndZeroForMissing() public {
        _record(TX_ID_1, AMOUNT);
        _record(TX_ID_2, AMOUNT + 1);

        bytes32[] memory ids = new bytes32[](3);
        ids[0] = TX_ID_2;
        ids[1] = keccak256("missing");
        ids[2] = TX_ID_1;

        uint256[] memory amounts = module.getFundsInRecords(ids);
        assertEq(amounts.length, ids.length);
        assertEq(amounts[0], AMOUNT + 1);
        assertEq(amounts[1], 0);
        assertEq(amounts[2], AMOUNT);
    }

    function test_onFundsIn_revertsOnZeroRgbOpId() public {
        vm.prank(routeRegistry);
        vm.expectRevert(RgbSettlementModule.InvalidRgbOpId.selector);
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), _fundsInData(0, BEFORE_BLOCK));
    }

    function _setL2Block(uint256 l2Block) private {
        vm.mockCall(address(100), abi.encodeCall(IArbSys.arbBlockNumber, ()), abi.encode(l2Block));
    }

    function test_onFundsIn_revertsOnNonEmptyDestinationAddress() public {
        FundsInContext memory ctx = _fundsInCtx(TX_ID_1, AMOUNT);
        ctx.destAddress = "rgb:unexpected";

        vm.prank(routeRegistry);
        vm.expectRevert(RgbSettlementModule.UnexpectedDestinationAddress.selector);
        module.onFundsIn(ctx, _fundsInData(RGB_OP_ID, BEFORE_BLOCK));

        assertEq(module.fundsInRecords(TX_ID_1), 0, "record not written");
        assertEq(module.fundsInRecordChainIds(TX_ID_1), 0, "network tag not written");
        assertEq(module.fundsInRecordL2Blocks(TX_ID_1), 0, "block not written");
    }

    function test_onFundsIn_revertsOnDuplicateOperationId() public {
        _record(TX_ID_1, AMOUNT);

        uint64 recordedBlock = module.fundsInRecordL2Blocks(TX_ID_1);
        _setL2Block(L2_BLOCK + 1);

        vm.prank(routeRegistry);
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), _fundsInData(RGB_OP_ID, BEFORE_BLOCK));

        assertEq(module.fundsInRecordL2Blocks(TX_ID_1), recordedBlock, "first block preserved");
    }

    function test_onFundsIn_revertsIfNotRouteRegistry() public {
        vm.prank(attacker);
        vm.expectRevert(RgbSettlementModule.NotRouteRegistry.selector);
        module.onFundsIn(_fundsInCtx(TX_ID_1, AMOUNT), _fundsInData(RGB_OP_ID, BEFORE_BLOCK));
    }

    function test_beforeFundsOut_acceptsOneValidPair() public {
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1)));

        // Proof-of-mint ledger is permanent: the check must not mutate it.
        assertEq(module.fundsInRecords(TX_ID_1), AMOUNT, "record left intact (no consumption)");
    }

    function test_beforeFundsOut_passesOnMultipleExistingRecords() public {
        uint256 amount1 = 60e18;
        uint256 amount2 = 40e18;
        _record(TX_ID_1, amount1);
        _record(TX_ID_2, amount2);

        vm.prank(routeRegistry);
        module.beforeFundsOut(_fundsOutCtx(), _settlementData(_pair(TX_ID_1, TX_ID_2)));

        assertEq(module.fundsInRecords(TX_ID_1), amount1, "record 1 intact");
        assertEq(module.fundsInRecords(TX_ID_2), amount2, "record 2 intact");
    }

    function test_beforeFundsOut_revertsOnEmptyArrays() public {
        vm.prank(routeRegistry);
        vm.expectRevert(RgbSettlementModule.EmptySettlementRecords.selector);
        module.beforeFundsOut(_fundsOutCtx(), _settlementData(new bytes32[](0)));
    }

    function test_beforeFundsOut_allowsEmptyArraysForAccountingOnlyRebalance() public {
        FundsOutContext memory ctx = _fundsOutCtx();
        ctx.isRebalance = true;

        vm.prank(routeRegistry);
        module.beforeFundsOut(ctx, _settlementData(new bytes32[](0)));
    }

    function test_beforeFundsOut_duplicateIdsAreHarmless() public {
        // The check is a pure read, so referencing the same id twice simply
        // passes both times — no double-spend here; solvency is the Bridge's concern.
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        module.beforeFundsOut(_fundsOutCtx(), _settlementData(_pair(TX_ID_1, TX_ID_1)));

        assertEq(module.fundsInRecords(TX_ID_1), AMOUNT, "record intact");
    }

    function test_beforeFundsOut_isViewAcrossManyCalls() public {
        // Repeated verification of the same record never depletes it.
        _record(TX_ID_1, AMOUNT);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(routeRegistry);
            module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1)));
        }

        assertEq(module.fundsInRecords(TX_ID_1), AMOUNT, "record never consumed");
    }

    function test_beforeFundsOut_revertsOnUnknownFundsInId() public {
        // No record ever made for TX_ID_1.
        vm.prank(routeRegistry);
        vm.expectRevert(abi.encodeWithSelector(RgbSettlementModule.FundsInNotFound.selector, TX_ID_1));
        module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1)));
    }

    function test_beforeFundsOut_revertsIfNotRouteRegistry() public {
        _record(TX_ID_1, AMOUNT);

        vm.prank(attacker);
        vm.expectRevert(RgbSettlementModule.NotRouteRegistry.selector);
        module.beforeFundsOut(_fundsOutCtx(), _settlementData(_single(TX_ID_1)));
    }

    function test_beforeFundsOut_revertsOnCrossNetworkRecord() public {
        // Record minted to RGB_CHAIN_ID; a release burning from OTHER_RGB_CHAIN_ID
        // must not be able to cite it as proof-of-mint.
        _record(TX_ID_1, AMOUNT);

        vm.prank(routeRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbSettlementModule.FundsInRecordChainMismatch.selector, TX_ID_1, OTHER_RGB_CHAIN_ID, RGB_CHAIN_ID
            )
        );
        module.beforeFundsOut(_fundsOutCtx(OTHER_RGB_CHAIN_ID), _settlementData(_single(TX_ID_1)));
    }

    function test_beforeFundsOut_passesWhenNetworksMatch() public {
        // A single module instance serving two RGB networks: a record minted to
        // OTHER_RGB_CHAIN_ID is citable by a burn from OTHER_RGB_CHAIN_ID.
        vm.prank(routeRegistry);
        module.onFundsIn(_fundsInCtx(TX_ID_2, AMOUNT, OTHER_RGB_CHAIN_ID), _fundsInData(RGB_OP_ID, BEFORE_BLOCK));

        vm.prank(routeRegistry);
        module.beforeFundsOut(_fundsOutCtx(OTHER_RGB_CHAIN_ID), _settlementData(_single(TX_ID_2)));

        assertEq(module.fundsInRecordChainIds(TX_ID_2), OTHER_RGB_CHAIN_ID, "second network record tagged correctly");
    }
}
