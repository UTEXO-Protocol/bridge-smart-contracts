// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test } from 'forge-std/Test.sol';
import { Bridge }    from '../src/Bridge.sol';
import { IBridge }   from '../src/interfaces/IBridge.sol';
import { BridgeBase } from '../src/BridgeBase.sol';
import { CommissionManager } from '../src/CommissionManager.sol';
import {
    CommissionConfig,
    CommissionSide,
    CommissionCurrency,
    ICommissionManager
} from '../src/interfaces/ICommissionManager.sol';
import { MockERC20 } from './helpers/MockERC20.sol';
import { MockBtcRelay } from './helpers/MockBtcRelay.sol';
import { Ownable }   from '@openzeppelin/contracts/access/Ownable.sol';
import { Pausable }  from '@openzeppelin/contracts/utils/Pausable.sol';

contract BridgeTest is Test {
    // Events re-declared locally for vm.expectEmit
    event FundsIn(address indexed sender, uint256 operationId, uint256 amount);
    event BridgeFundsIn(
        address indexed sender,
        uint256 operationId,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 nativeCommission,
        string  destinationChain,
        string  destinationAddress
    );
    event BridgeFundsOut(
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 operationId,
        uint256 burnId,
        string  sourceChain,
        string  destChain,
        string  sourceAddress,
        uint256 blockHeight,
        bytes32 commitmentHash
    );

    Bridge            bridge;
    MockERC20         usdt0;
    MockBtcRelay      btcRelay;
    CommissionManager cm;

    address deployer  = makeAddr('deployer');
    address user      = makeAddr('user');
    address recipient = makeAddr('recipient');
    address multisig  = makeAddr('multisig');

    string  constant SOURCE_CHAIN = 'arbitrum';
    string  constant DST_CHAIN    = 'rgb';
    string  constant DST_ADDR     = 'rgb:asset1qp0y3mq6h5k8d9f2e4j7n6c3w/utxo1abc123';
    // For outbound, source is "rgb" coming to "arbitrum" (this chain).
    string  constant SRC_CHAIN    = 'rgb';
    string  constant DST_CHAIN_OUT = 'arbitrum';
    string  constant SRC_ADDR     = 'rgb:sender/utxo1src';
    uint256 constant AMOUNT       = 100e18;
    uint256 constant TX_ID        = 42;
    uint256 constant BURN_ID      = 9_001;

    // BtcRelay test data
    uint256 constant BLOCK_HEIGHT     = 850_000;
    bytes32 constant COMMITMENT_HASH  = keccak256('test-btc-block-commitment');
    uint256 constant CONFIRMATIONS    = 6;

    function setUp() public {
        usdt0    = new MockERC20('Mock USDT0', 'USDT0');
        btcRelay = new MockBtcRelay();

        // Register a valid block in the mock relay
        btcRelay.setBlock(BLOCK_HEIGHT, COMMITMENT_HASH, CONFIRMATIONS);

        // Deploy CommissionManager with deployer as placeholder bridge address.
        vm.prank(deployer);
        cm = new CommissionManager(deployer);

        vm.prank(deployer);
        bridge = new Bridge(address(usdt0), address(btcRelay), payable(address(cm)), address(0));

        // Point the CM to the real bridge.
        vm.prank(deployer);
        cm.setBridgeAddress(address(bridge));

        // deployer transfers ownership to multisig (production flow)
        vm.prank(deployer);
        bridge.transferOwnership(multisig);

        // fund user and approve bridge
        usdt0.mint(user, AMOUNT * 10);
        vm.prank(user);
        usdt0.approve(address(bridge), type(uint256).max);
    }

    // ========================================================================
    // helpers
    // ========================================================================

    function _singleFundsInId() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = TX_ID;
    }

    function _setFundsInTokenRule(uint256 percent) internal {
        vm.prank(deployer);
        cm.setCommissionRule(
            uint256(keccak256(bytes(SOURCE_CHAIN))), uint256(keccak256(bytes(DST_CHAIN))), address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );
    }

    function _setFundsInNativeRule(uint256 percent) internal {
        vm.prank(deployer);
        cm.setCommissionRule(
            uint256(keccak256(bytes(SOURCE_CHAIN))), uint256(keccak256(bytes(DST_CHAIN))), address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.NATIVE,
                isSet: true
            })
        );
    }

    function _setFundsOutTokenRule(uint256 percent) internal {
        vm.prank(deployer);
        cm.setCommissionRule(
            uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );
    }

    function _setFundsOutNativeRule(uint256 percent) internal {
        vm.prank(deployer);
        cm.setCommissionRule(
            uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.NATIVE,
                isSet: true
            })
        );
    }

    // ========================================================================
    // Constructor
    // ========================================================================

    function test_constructor_setsTokenOwnerAndBtcRelay() public view {
        assertEq(bridge.TOKEN(), address(usdt0));
        assertEq(bridge.owner(), multisig);
        assertEq(bridge.btcRelay(), address(btcRelay));
        assertEq(address(bridge.commissionManager()), address(cm));        
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(BridgeBase.InvalidTokenAddress.selector);
        new Bridge(address(0), address(btcRelay), payable(address(cm)), address(0));
    }

    function test_constructor_revertsOnZeroBtcRelay() public {
        vm.expectRevert(IBridge.InvalidBtcRelayAddress.selector);
        new Bridge(address(usdt0), address(0), payable(address(cm)), address(0));
    }

    function test_constructor_revertsOnZeroCommissionManager() public {
        vm.expectRevert(IBridge.InvalidCommissionManagerAddress.selector);
        new Bridge(address(usdt0), address(btcRelay), payable(address(0)), address(0));
    }    

    // ========================================================================
    // fundsIn — happy path (zero commission default)
    // ========================================================================

    function test_fundsIn_transfersTokens() public {
        uint256 userBefore = usdt0.balanceOf(user);

        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
        assertEq(usdt0.balanceOf(user),            userBefore - AMOUNT);
    }

    function test_fundsIn_storesRecord() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        assertEq(bridge.fundsInRecords(TX_ID), AMOUNT);
    }

    function test_fundsIn_emitsBothEvents() public {
        vm.expectEmit(true, false, false, true);
        emit FundsIn(user, TX_ID, AMOUNT);
        vm.expectEmit(true, false, false, true);
        emit BridgeFundsIn(user, TX_ID, AMOUNT, AMOUNT, 0, 0, DST_CHAIN, DST_ADDR);

        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);
    }

    function test_fundsIn_anyUserCanCall() public {
        address stranger = makeAddr('stranger');
        usdt0.mint(stranger, AMOUNT);
        vm.prank(stranger);
        usdt0.approve(address(bridge), AMOUNT);

        vm.prank(stranger);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
    }

    // ========================================================================
    // fundsIn — reverts
    // ========================================================================

    function test_fundsIn_revertsOnEmptyDestinationAddress() public {
        vm.expectRevert(IBridge.InvalidDestinationAddress.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), '', TX_ID);
    }

    function test_fundsIn_revertsOnEmptyDestinationChain() public {
        vm.expectRevert(IBridge.InvalidDestinationChainId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, 0, DST_ADDR, TX_ID);
    }

    function test_fundsIn_revertsWhenPaused() public {
        vm.prank(multisig);
        bridge.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);
    }

    function test_fundsIn_revertsOnDuplicateOperationId() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        vm.expectRevert(IBridge.DuplicateOperationId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);
    }

    // ========================================================================
    // fundsOut — happy path
    // ========================================================================

    function test_fundsOut_transfersAndEmits() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        vm.expectEmit(true, false, false, true);
        emit BridgeFundsOut(
            recipient, AMOUNT, AMOUNT, 0, TX_ID, BURN_ID,
            SRC_CHAIN, DST_CHAIN_OUT, SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH
        );

        vm.prank(multisig);
        bridge.fundsOut(recipient, AMOUNT, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, _singleFundsInId());

        assertEq(usdt0.balanceOf(recipient),       AMOUNT);
        assertEq(usdt0.balanceOf(address(bridge)), 0);
    }

    function test_fundsOut_consumesFundsInRecord() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        vm.prank(multisig);
        bridge.fundsOut(recipient, AMOUNT, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, _singleFundsInId());

        assertEq(bridge.fundsInRecords(TX_ID), 0);
    }

    function test_fundsOut_multipleFundsInIds() public {
        uint256 txId1 = 100;
        uint256 txId2 = 101;
        uint256 amount1 = 60e18;
        uint256 amount2 = 40e18;

        vm.prank(user);
        bridge.fundsIn(amount1, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, txId1);
        vm.prank(user);
        bridge.fundsIn(amount2, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, txId2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = txId1;
        ids[1] = txId2;

        vm.prank(multisig);
        bridge.fundsOut(recipient, amount1 + amount2, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, ids);

        assertEq(usdt0.balanceOf(recipient), amount1 + amount2);
        assertEq(bridge.fundsInRecords(txId1), 0);
        assertEq(bridge.fundsInRecords(txId2), 0);
    }

    function test_fundsOut_partialAmount_decrementsRecord() public {
        // Single fundsIn of 100. fundsOut for 60 should decrement the record to 40
        // (not delete it), preserving the residual liquidity for future fundsOut.
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        uint256 partialAmount = 60e18;

        vm.prank(multisig);
        bridge.fundsOut(recipient, partialAmount, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, _singleFundsInId());

        assertEq(usdt0.balanceOf(recipient), partialAmount);
        assertEq(bridge.fundsInRecords(TX_ID), AMOUNT - partialAmount, 'residual preserved');
    }

    function test_fundsOut_consumesPartiallyAcrossIds() public {
        // Two records of 100 each. fundsOut for 150 should fully consume the first
        // and partially consume the second (leaving 50).
        uint256 txId1 = 100;
        uint256 txId2 = 101;

        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, txId1);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, txId2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = txId1;
        ids[1] = txId2;

        vm.prank(multisig);
        bridge.fundsOut(recipient, 150e18, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, ids);

        assertEq(usdt0.balanceOf(recipient), 150e18);
        assertEq(bridge.fundsInRecords(txId1), 0,    'first id fully consumed');
        assertEq(bridge.fundsInRecords(txId2), 50e18, 'second id partially consumed');
    }

    function test_fundsOut_breaksAfterAmountSatisfied() public {
        // If TEE supplies more ids than needed, the loop must stop after the
        // amount is satisfied — extra ids are NOT touched.
        uint256 txId1 = 100;
        uint256 txId2 = 101;

        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, txId1);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, txId2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = txId1;
        ids[1] = txId2;

        // Amount of 50 < first record; second id should remain untouched.
        vm.prank(multisig);
        bridge.fundsOut(recipient, 50e18, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, ids);

        assertEq(bridge.fundsInRecords(txId1), 50e18,  'first decremented');
        assertEq(bridge.fundsInRecords(txId2), AMOUNT, 'second untouched');
    }

    // ========================================================================
    // fundsOut — BtcRelay verification
    // ========================================================================

    function test_fundsOut_revertsOnUnverifiedBlock() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        uint256 unknownHeight = 999_999;
        bytes32 unknownHash = keccak256('unknown-block');

        vm.expectRevert('verify: block commitment');
        vm.prank(multisig);
        bridge.fundsOut(recipient, AMOUNT, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, unknownHeight, unknownHash, _singleFundsInId());
    }

    // ========================================================================
    // fundsOut — fundsIn verification reverts
    // ========================================================================

    function test_fundsOut_revertsOnUnknownFundsInId() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;

        vm.expectRevert(abi.encodeWithSelector(IBridge.FundsInNotFound.selector, 999));
        vm.prank(multisig);
        bridge.fundsOut(recipient, AMOUNT, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, ids);
    }

    function test_fundsOut_revertsOnAmountExceedsFundsIn() public {
        uint256 txId1 = 100;
        uint256 txId2 = 101;
        vm.prank(user);
        bridge.fundsIn(50e18, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, txId1);
        vm.prank(user);
        bridge.fundsIn(50e18, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, txId2);

        uint256[] memory ids = new uint256[](1);
        ids[0] = txId1;

        vm.expectRevert(IBridge.FundsOutAmountExceedsFundsIn.selector);
        vm.prank(multisig);
        bridge.fundsOut(recipient, 60e18, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, ids);
    }

    function test_fundsOut_revertsOnReplayedBurnId() public {
        // Two independent fundsIn deposits give us enough liquidity for two
        // separate fundsOut calls that share the same burnId.
        uint256 txId1 = 200;
        uint256 txId2 = 201;
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, txId1);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, txId2);

        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = txId1;
        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = txId2;

        // First fundsOut consumes BURN_ID.
        vm.prank(multisig);
        bridge.fundsOut(recipient, AMOUNT, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, ids1);
        assertTrue(bridge.consumedBurnIds(BURN_ID), 'burnId recorded');

        // Second fundsOut uses fresh fundsIn record but the same burnId — must revert.
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, BURN_ID));
        vm.prank(multisig);
        bridge.fundsOut(recipient, AMOUNT, TX_ID + 100, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, ids2);

        // Ensure the second call did not consume the underlying fundsIn record.
        assertEq(bridge.fundsInRecords(txId2), AMOUNT, 'fundsIn record preserved');
    }

    function test_fundsOut_revertsOnDoubleSpendsConsumedFundsIn() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        vm.prank(multisig);
        bridge.fundsOut(recipient, AMOUNT, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, _singleFundsInId());

        usdt0.mint(address(bridge), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IBridge.FundsInNotFound.selector, TX_ID));
        vm.prank(multisig);
        bridge.fundsOut(recipient, AMOUNT, TX_ID + 1, BURN_ID + 1, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, _singleFundsInId());
    }

    // ========================================================================
    // fundsOut — other reverts
    // ========================================================================

    function test_fundsOut_revertsIfNotOwner() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.fundsOut(recipient, AMOUNT, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, _singleFundsInId());
    }

    function test_fundsOut_revertsOnZeroRecipient() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        vm.expectRevert(BridgeBase.InvalidRecipientAddress.selector);
        vm.prank(multisig);
        bridge.fundsOut(address(0), AMOUNT, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, _singleFundsInId());
    }

    function test_fundsOut_revertsIfAmountExceedsPool() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        vm.expectRevert(BridgeBase.AmountExceedBridgePool.selector);
        vm.prank(multisig);
        bridge.fundsOut(recipient, AMOUNT + 1, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, _singleFundsInId());
    }

    // ========================================================================
    // Commission — fundsIn TOKEN
    // ========================================================================

    function test_fundsIn_tokenCommission_routesToCM() public {
        // 4% token commission
        uint256 percent = 400; // 400 / 100 / 100 = 4%
        _setFundsInTokenRule(percent);

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100;
        uint256 expectedNet        = AMOUNT - expectedCommission;

        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        assertEq(usdt0.balanceOf(address(bridge)), expectedNet, 'bridge net');
        assertEq(usdt0.balanceOf(address(cm)),     expectedCommission, 'cm pool');
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, 'cm recorded');
        assertEq(bridge.fundsInRecords(TX_ID),     expectedNet, 'record = net');
    }

    // ========================================================================
    // Commission — fundsIn NATIVE
    // ========================================================================

    function test_fundsIn_nativeCommission_routesToCM() public {
        // 1% native-currency commission
        uint256 percent = 100; // 1%
        _setFundsInNativeRule(percent);

        // Set mock rate: 1 token unit = 1e12 wei (so 100e18 tokens * 1% = 1e18 tokens -> 1e6 * 1e12 = 1e18 wei? Let's compute)
        // stableFee = AMOUNT * 100 / 100 / 100 = AMOUNT/100 = 1e18 token units
        // decimals 18, rate wei per 1e18 token units. Pick rate=1e15 => nativeFee = 1e18*1e15/1e18 = 1e15 wei.
        uint256 rate = 1e15;
        vm.prank(deployer);
        cm.setMockTokenToNativeRate(rate);

        (uint256 tokenC, uint256 nativeC, uint256 net) =
            cm.calculateFundsInCommission(uint256(keccak256(bytes(SOURCE_CHAIN))), uint256(keccak256(bytes(DST_CHAIN))), address(usdt0), AMOUNT);
        assertEq(tokenC, 0);
        assertGt(nativeC, 0);
        assertEq(net, AMOUNT);

        vm.deal(user, nativeC);
        vm.prank(user);
        bridge.fundsIn{ value: nativeC }(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        // Bridge received full amount in token (no token commission).
        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
        // CM received native commission.
        assertEq(address(cm).balance, nativeC);
        assertEq(cm.nativeCommissionPool(), nativeC);
        // Record tracks net (= full amount for NATIVE).
        assertEq(bridge.fundsInRecords(TX_ID), AMOUNT);
    }

    // ========================================================================
    // Commission — fundsOut TOKEN
    // ========================================================================

    function test_fundsOut_tokenCommission_routesToCM() public {
        // Deposit at zero commission first.
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        uint256 percent = 500; // 5%
        _setFundsOutTokenRule(percent);

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100;
        uint256 expectedNet        = AMOUNT - expectedCommission;

        vm.prank(multisig);
        bridge.fundsOut(recipient, AMOUNT, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, _singleFundsInId());

        assertEq(usdt0.balanceOf(recipient), expectedNet, 'recipient net');
        assertEq(usdt0.balanceOf(address(cm)), expectedCommission, 'cm pool');
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, 'cm recorded');
    }

    // ========================================================================
    // Commission — fundsOut NATIVE reverts
    // ========================================================================

    function test_fundsOut_nativeCommission_reverts() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        _setFundsOutNativeRule(100);
        vm.prank(deployer);
        cm.setMockTokenToNativeRate(1e12);

        vm.expectRevert(IBridge.NativeCommissionNotAllowedOnFundsOut.selector);
        vm.prank(multisig);
        bridge.fundsOut(recipient, AMOUNT, TX_ID, BURN_ID, uint256(keccak256(bytes(SRC_CHAIN))), uint256(keccak256(bytes(DST_CHAIN_OUT))), SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, _singleFundsInId());
    }

    // ========================================================================
    // Commission — NativeValueMismatch
    // ========================================================================

    function test_fundsIn_revertsOnNativeValueMismatch_zeroRuleButValueSent() public {
        // No rule; commission is zero. Sending msg.value should revert.
        vm.deal(user, 1 ether);
        vm.expectRevert(IBridge.NativeValueMismatch.selector);
        vm.prank(user);
        bridge.fundsIn{ value: 1 ether }(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);
    }

    function test_fundsIn_revertsOnNativeValueMismatch_nativeRuleButNoValue() public {
        _setFundsInNativeRule(100);
        vm.prank(deployer);
        cm.setMockTokenToNativeRate(1e15);

        vm.expectRevert(IBridge.NativeValueMismatch.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);
    }

    // ========================================================================
    // pause / unpause / renounceOwnership
    // ========================================================================

    function test_pause_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(multisig);
        bridge.pause();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.unpause();
    }

    function test_renounceOwnership_alwaysReverts() public {
        vm.expectRevert(BridgeBase.RenounceOwnershipBlocked.selector);
        vm.prank(multisig);
        bridge.renounceOwnership();
    }

    // ========================================================================
    // views
    // ========================================================================

    function test_getContractBalance() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        assertEq(bridge.getContractBalance(), AMOUNT);
    }

    function test_getChainId() public view {
        assertEq(bridge.getChainId(), block.chainid);
    }

    // ========================================================================
    // Fuzz
    // ========================================================================

    function testFuzz_fundsIn_validAmount(uint128 amount) public {
        vm.assume(amount > 0);
        usdt0.mint(user, amount);

        vm.prank(user);
        bridge.fundsIn(amount, uint256(keccak256(bytes(DST_CHAIN))), DST_ADDR, TX_ID);

        assertEq(usdt0.balanceOf(address(bridge)), amount);
        assertEq(bridge.fundsInRecords(TX_ID), amount);
    }
}
