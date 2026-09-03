// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {FundsInContext, FundsOutContext} from "../src/interfaces/RouteTypes.sol";
import {RgbPoolSettlementModule} from "../src/settlement/RgbPoolSettlementModule.sol";
import {RgbSettlementModule} from "../src/settlement/RgbSettlementModule.sol";

contract RgbPoolSettlementModuleTest is Test {
    address private routeRegistry = makeAddr("routeRegistry");
    address private attacker = makeAddr("attacker");
    address private token = makeAddr("token");
    address private user = makeAddr("user");
    address private recipient = makeAddr("recipient");

    uint256 private constant ARBITRUM_CHAIN_ID = 42161;
    uint256 private constant RGB_MINT_BURN_CHAIN_ID = 96;
    uint256 private constant RGB_POOL_CHAIN_ID = 97;
    uint256 private constant OTHER_RGB_CHAIN_ID = 98;
    uint256 private constant AMOUNT = 100e6;
    uint256 private constant RGB_OP_ID = 0xABCDEF;
    bytes32 private constant OPERATION_ID = keccak256("canonical bridge operation");

    RgbSettlementModule private rgbModule;
    RgbPoolSettlementModule private poolModule;

    function setUp() public {
        rgbModule = new RgbSettlementModule(routeRegistry);
        poolModule =
            new RgbPoolSettlementModule(routeRegistry, address(rgbModule), RGB_POOL_CHAIN_ID, RGB_MINT_BURN_CHAIN_ID);
    }

    function _fundsInContext(uint256 destinationChainId, bytes32 operationId, uint256 amount)
        private
        view
        returns (FundsInContext memory)
    {
        return FundsInContext({
            token: token,
            sender: user,
            sourceSender: bytes32(uint256(uint160(user))),
            grossAmount: amount,
            netAmount: amount,
            operationId: operationId,
            senderNonce: 0,
            sourceChainId: ARBITRUM_CHAIN_ID,
            destChainId: destinationChainId,
            destAddress: "rgb:destination"
        });
    }

    function _fundsOutContext(uint256 sourceChainId) private view returns (FundsOutContext memory) {
        return FundsOutContext({
            token: token,
            recipient: recipient,
            amount: AMOUNT,
            burnId: 1,
            sourceChainId: sourceChainId,
            destChainId: ARBITRUM_CHAIN_ID,
            sourceAddress: "rgb:source",
            isRebalance: false
        });
    }

    function _singleSettlement(bytes32 operationId, uint256 amount) private pure returns (bytes memory) {
        bytes32[] memory operationIds = new bytes32[](1);
        operationIds[0] = operationId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        return abi.encode(operationIds, amounts);
    }

    function _recordCanonical(bytes32 operationId, uint256 amount, uint256 chainId) private {
        vm.prank(routeRegistry);
        rgbModule.onFundsIn(_fundsInContext(chainId, operationId, amount), abi.encode(RGB_OP_ID));
    }

    function test_constructor_setsImmutablePairing() public view {
        assertEq(poolModule.routeRegistry(), routeRegistry);
        assertEq(address(poolModule.rgbModule()), address(rgbModule));
        assertEq(poolModule.poolChainId(), RGB_POOL_CHAIN_ID);
        assertEq(poolModule.backingRecordChainId(), RGB_MINT_BURN_CHAIN_ID);
    }

    function test_constructor_rejectsInvalidArguments() public {
        vm.expectRevert(RgbPoolSettlementModule.InvalidRouteRegistry.selector);
        new RgbPoolSettlementModule(address(0), address(rgbModule), RGB_POOL_CHAIN_ID, RGB_MINT_BURN_CHAIN_ID);

        vm.expectRevert(RgbPoolSettlementModule.InvalidRgbModule.selector);
        new RgbPoolSettlementModule(routeRegistry, address(0), RGB_POOL_CHAIN_ID, RGB_MINT_BURN_CHAIN_ID);

        vm.expectRevert(RgbPoolSettlementModule.InvalidPoolChainId.selector);
        new RgbPoolSettlementModule(routeRegistry, address(rgbModule), 0, RGB_MINT_BURN_CHAIN_ID);

        vm.expectRevert(RgbPoolSettlementModule.InvalidBackingRecordChainId.selector);
        new RgbPoolSettlementModule(routeRegistry, address(rgbModule), RGB_POOL_CHAIN_ID, 0);

        vm.expectRevert(RgbPoolSettlementModule.IdenticalChainIds.selector);
        new RgbPoolSettlementModule(routeRegistry, address(rgbModule), RGB_POOL_CHAIN_ID, RGB_POOL_CHAIN_ID);
    }

    function test_onFundsIn_returnsZeroAndWritesNoCanonicalRecord() public {
        FundsInContext memory ctx = _fundsInContext(RGB_POOL_CHAIN_ID, OPERATION_ID, AMOUNT);

        vm.prank(routeRegistry);
        uint256 externalId = poolModule.onFundsIn(ctx, abi.encode(RGB_OP_ID));

        assertEq(externalId, 0, "pool credit suppresses RGB FundsIn event");
        assertEq(rgbModule.fundsInRecords(OPERATION_ID), 0, "pool credit does not write canonical ledger");
        assertEq(rgbModule.fundsInRecordChainIds(OPERATION_ID), 0, "no pool network tag is created");
    }

    function test_onFundsIn_ignoresSettlementData() public {
        vm.prank(routeRegistry);
        uint256 externalId = poolModule.onFundsIn(_fundsInContext(RGB_POOL_CHAIN_ID, OPERATION_ID, AMOUNT), "");
        assertEq(externalId, 0);
    }

    function test_onFundsIn_revertsForWrongDestination() public {
        vm.prank(routeRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbPoolSettlementModule.UnexpectedPoolDestination.selector, RGB_POOL_CHAIN_ID, RGB_MINT_BURN_CHAIN_ID
            )
        );
        poolModule.onFundsIn(_fundsInContext(RGB_MINT_BURN_CHAIN_ID, OPERATION_ID, AMOUNT), "");
    }

    function test_onFundsIn_revertsForUnauthorizedCaller() public {
        vm.prank(attacker);
        vm.expectRevert(RgbPoolSettlementModule.NotRouteRegistry.selector);
        poolModule.onFundsIn(_fundsInContext(RGB_POOL_CHAIN_ID, OPERATION_ID, AMOUNT), "");
    }

    function test_beforeFundsOut_acceptsMintBurnBackingRecord() public {
        _recordCanonical(OPERATION_ID, AMOUNT, RGB_MINT_BURN_CHAIN_ID);

        vm.prank(routeRegistry);
        poolModule.beforeFundsOut(_fundsOutContext(RGB_POOL_CHAIN_ID), _singleSettlement(OPERATION_ID, AMOUNT));

        assertEq(rgbModule.fundsInRecords(OPERATION_ID), AMOUNT, "canonical record remains permanent");
    }

    function test_beforeFundsOut_revertsForWrongSource() public {
        _recordCanonical(OPERATION_ID, AMOUNT, RGB_MINT_BURN_CHAIN_ID);

        vm.prank(routeRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbPoolSettlementModule.UnexpectedPoolSource.selector, RGB_POOL_CHAIN_ID, RGB_MINT_BURN_CHAIN_ID
            )
        );
        poolModule.beforeFundsOut(_fundsOutContext(RGB_MINT_BURN_CHAIN_ID), _singleSettlement(OPERATION_ID, AMOUNT));
    }

    function test_beforeFundsOut_revertsForUnknownRecord() public {
        vm.prank(routeRegistry);
        vm.expectRevert(abi.encodeWithSelector(RgbPoolSettlementModule.FundsInNotFound.selector, OPERATION_ID));
        poolModule.beforeFundsOut(_fundsOutContext(RGB_POOL_CHAIN_ID), _singleSettlement(OPERATION_ID, AMOUNT));
    }

    function test_beforeFundsOut_revertsForAmountMismatch() public {
        _recordCanonical(OPERATION_ID, AMOUNT, RGB_MINT_BURN_CHAIN_ID);

        vm.prank(routeRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(RgbPoolSettlementModule.AmountMismatch.selector, OPERATION_ID, AMOUNT - 1, AMOUNT)
        );
        poolModule.beforeFundsOut(_fundsOutContext(RGB_POOL_CHAIN_ID), _singleSettlement(OPERATION_ID, AMOUNT - 1));
    }

    function test_beforeFundsOut_revertsForRecordFromWrongNetwork() public {
        _recordCanonical(OPERATION_ID, AMOUNT, OTHER_RGB_CHAIN_ID);

        vm.prank(routeRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbPoolSettlementModule.FundsInRecordChainMismatch.selector,
                OPERATION_ID,
                RGB_MINT_BURN_CHAIN_ID,
                OTHER_RGB_CHAIN_ID
            )
        );
        poolModule.beforeFundsOut(_fundsOutContext(RGB_POOL_CHAIN_ID), _singleSettlement(OPERATION_ID, AMOUNT));
    }

    function test_beforeFundsOut_revertsForEmptyRecords() public {
        vm.prank(routeRegistry);
        vm.expectRevert(RgbPoolSettlementModule.EmptySettlementRecords.selector);
        poolModule.beforeFundsOut(_fundsOutContext(RGB_POOL_CHAIN_ID), abi.encode(new bytes32[](0), new uint256[](0)));
    }

    function test_beforeFundsOut_revertsForLengthMismatch() public {
        bytes32[] memory operationIds = new bytes32[](1);
        operationIds[0] = OPERATION_ID;

        vm.prank(routeRegistry);
        vm.expectRevert(RgbPoolSettlementModule.SettlementDataLengthMismatch.selector);
        poolModule.beforeFundsOut(_fundsOutContext(RGB_POOL_CHAIN_ID), abi.encode(operationIds, new uint256[](0)));
    }

    function test_beforeFundsOut_revertsForUnauthorizedCaller() public {
        vm.prank(attacker);
        vm.expectRevert(RgbPoolSettlementModule.NotRouteRegistry.selector);
        poolModule.beforeFundsOut(_fundsOutContext(RGB_POOL_CHAIN_ID), _singleSettlement(OPERATION_ID, AMOUNT));
    }
}
