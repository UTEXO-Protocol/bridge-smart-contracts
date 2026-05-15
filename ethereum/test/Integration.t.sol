// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test } from 'forge-std/Test.sol';

import { Bridge } from '../src/Bridge.sol';
import { CommissionManager } from '../src/CommissionManager.sol';
import { MultisigProxy } from '../src/MultisigProxy.sol';
import { IMultisigProxy } from '../src/interfaces/IMultisigProxy.sol';
import {
    CommissionConfig,
    CommissionSide,
    CommissionCurrency,
    ICommissionManager
} from '../src/interfaces/ICommissionManager.sol';

import { MockERC20 }        from './helpers/MockERC20.sol';
import { MockBtcRelay }     from './helpers/MockBtcRelay.sol';
import { MockAggregatorV3 } from './helpers/MockAggregatorV3.sol';
import { MultisigHelper } from './helpers/MultisigHelper.sol';

/// @title IntegrationTest
/// @notice End-to-end lifecycle:
///           deploy (DeployAll-style via predicted Bridge address)
///           → federation configures commission routes on CM
///           → user fundsIn (TOKEN commission on the source side)
///           → TEE signs + multisig executes fundsOut (TOKEN commission on the outbound side)
///           → federation withdraws accumulated commissions from CM
///         Verifies token accounting across every step and event emission for
///         the fundsOut → commission → withdrawal trail.
contract IntegrationTest is Test {
    // =========================================================================
    // Actors
    // =========================================================================

    address deployer           = makeAddr('deployer');
    address user               = makeAddr('user');
    address recipient          = makeAddr('recipient');
    address commissionReceiver = makeAddr('commissionReceiver');

    uint256 encPk1 = 0xE1;
    uint256 encPk2 = 0xE2;
    uint256 encPk3 = 0xE3;
    uint256 fedPk1 = 0xF1;
    uint256 fedPk2 = 0xF2;
    uint256 fedPk3 = 0xF3;
    address encA1; address encA2; address encA3;
    address fedA1; address fedA2; address fedA3;

    // =========================================================================
    // System
    // =========================================================================

    MockERC20         token;
    MockBtcRelay      btcRelay;
    MockAggregatorV3  ethUsdFeed;
    CommissionManager cm;
    Bridge            bridge;
    MultisigProxy     proxy;
    bytes32           domainSep;

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 constant SOURCE_CHAIN_ID = 31337;     // foundry default block.chainid
    uint256 constant RGB_CHAIN_ID    = 1_000_001; // backend-assigned for RGB

    uint256 constant USER_DEPOSIT = 100 ether; // 100 tokens gross
    // FUNDS_IN route: 2% token commission (stablePercent = 200, multiplier = 100 → 200/100/100 = 2%).
    uint256 constant FUNDS_IN_PERCENT  = 200;
    uint8   constant FUNDS_IN_MULT     = 100;
    // FUNDS_OUT route: 1% token commission (stablePercent = 100, multiplier = 100 → 1%).
    uint256 constant FUNDS_OUT_PERCENT = 100;
    uint8   constant FUNDS_OUT_MULT    = 100;

    uint256 constant TX_ID_IN   = 42;
    uint256 constant TX_ID_OUT  = 43;
    uint256 constant BURN_ID    = 9_001;

    uint256 constant BLOCK_HEIGHT      = 850_000;
    bytes32 constant COMMITMENT_HASH   = keccak256('integration-btc-block');
    uint256 constant BTC_CONFIRMATIONS = 6;

    uint256 constant TIMELOCK = 1 hours;

    bytes4 constant FUNDS_OUT_SELECTOR = bytes4(keccak256(
        'fundsOut(address,uint256,uint256,uint256,uint256,uint256,string,uint256,bytes32,uint256[])'
    ));

    // =========================================================================
    // Re-declared events for vm.expectEmit
    // =========================================================================

    event BridgeFundsOut(
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 operationId,
        uint256 burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  sourceAddress,
        uint256 blockHeight,
        bytes32 commitmentHash
    );

    event CommissionWithdrawn(address indexed token, uint256 amount, address indexed recipient);

    // =========================================================================
    // Setup — DeployAll-style
    // =========================================================================

    function setUp() public {
        encA1 = vm.addr(encPk1); encA2 = vm.addr(encPk2); encA3 = vm.addr(encPk3);
        fedA1 = vm.addr(fedPk1); fedA2 = vm.addr(fedPk2); fedA3 = vm.addr(fedPk3);

        token    = new MockERC20('Mock USDT0', 'USDT0');
        btcRelay = new MockBtcRelay();
        btcRelay.setBlock(BLOCK_HEIGHT, COMMITMENT_HASH, BTC_CONFIRMATIONS);

        // --- DeployAll-style deployment: predict Bridge address from deployer nonce.
        vm.startPrank(deployer);
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 1);

        cm     = new CommissionManager(predictedBridge);
        bridge = new Bridge(address(token), address(btcRelay), payable(address(cm)), address(0));

        address[] memory enc = new address[](3);
        enc[0] = encA1; enc[1] = encA2; enc[2] = encA3;
        address[] memory fed = new address[](3);
        fed[0] = fedA1; fed[1] = fedA2; fed[2] = fedA3;

        proxy = new MultisigProxy(
            address(bridge),
            address(cm),
            enc, 2,
            fed, 2,
            commissionReceiver,
            TIMELOCK
        );

        cm.transferOwnership(address(proxy));
        bridge.transferOwnership(address(proxy));
        vm.stopPrank();

        // Invariants from deployment
        assertEq(address(bridge),          predictedBridge,   'bridge prediction');
        assertEq(cm.bridgeAddress(),       address(bridge),   'CM.bridgeAddress');
        assertEq(address(bridge.commissionManager()), address(cm), 'bridge.commissionManager');
        assertEq(bridge.owner(),           address(proxy),    'bridge owner');
        assertEq(cm.owner(),               address(proxy),    'cm owner');
        assertEq(proxy.bridge(),           address(bridge),   'proxy.bridge');
        assertEq(proxy.commissionManager(),address(cm),       'proxy.commissionManager');

        domainSep = proxy.DOMAIN_SEPARATOR();

        // Fund the user
        token.mint(user, USER_DEPOSIT * 10);
        vm.prank(user);
        token.approve(address(bridge), type(uint256).max);
    }

    // =========================================================================
    // Main e2e test — TOKEN commission on both sides
    // =========================================================================

    function test_endToEnd_tokenCommission_inboundAndOutbound() public {
        // -------------------------------------------------------------------------
        // 1. Federation configures commission routes on CommissionManager via two
        //    AdminExecuteCommissionManager proposals.
        // -------------------------------------------------------------------------
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(
                ICommissionManager.setCommissionRule.selector,
                SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(token),
                CommissionConfig({
                    stablePercent: FUNDS_IN_PERCENT,
                    multiplier:    FUNDS_IN_MULT,
                    side:          CommissionSide.FUNDS_IN,
                    currency:      CommissionCurrency.TOKEN,
                    isSet:         true
                })
            )
        );

        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(
                ICommissionManager.setCommissionRule.selector,
                RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token),
                CommissionConfig({
                    stablePercent: FUNDS_OUT_PERCENT,
                    multiplier:    FUNDS_OUT_MULT,
                    side:          CommissionSide.FUNDS_OUT,
                    currency:      CommissionCurrency.TOKEN,
                    isSet:         true
                })
            )
        );

        // Sanity: CM now quotes commission for both routes.
        (uint256 tInQuote,, uint256 netIn) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(token), USER_DEPOSIT);
        assertEq(tInQuote, USER_DEPOSIT * FUNDS_IN_PERCENT / FUNDS_IN_MULT / FUNDS_IN_MULT, 'quote in');
        assertEq(netIn,    USER_DEPOSIT - tInQuote, 'net in');

        // -------------------------------------------------------------------------
        // 2. User fundsIn — TOKEN commission routed to CM.
        // -------------------------------------------------------------------------
        uint256 userBefore = token.balanceOf(user);

        vm.prank(user);
        bridge.fundsIn(
            USER_DEPOSIT,
            RGB_CHAIN_ID,
            'rgb:asset1qp0y3mq/utxo1abc',
            TX_ID_IN
        );

        uint256 tokenCommissionIn = tInQuote;
        uint256 netBridgedIn      = netIn;

        assertEq(token.balanceOf(user),           userBefore - USER_DEPOSIT, 'user debited gross');
        assertEq(token.balanceOf(address(bridge)), netBridgedIn,             'bridge keeps net');
        assertEq(token.balanceOf(address(cm)),    tokenCommissionIn,         'cm got commission');
        assertEq(cm.tokenCommissionPool(address(token)), tokenCommissionIn,  'cm pool mirrors balance');
        assertEq(bridge.fundsInRecords(TX_ID_IN), netBridgedIn,              'record stores net');

        // -------------------------------------------------------------------------
        // 3. TEE-signed fundsOut — releases `netBridgedIn` from the pool; 1%
        //    outbound commission to CM, remaining net to recipient.
        // -------------------------------------------------------------------------
        uint256[] memory fundsInIds = new uint256[](1);
        fundsInIds[0] = TX_ID_IN;

        bytes memory callData = abi.encodeWithSelector(
            FUNDS_OUT_SELECTOR,
            recipient,
            netBridgedIn,          // amount = full bridged pool from this deposit
            TX_ID_OUT,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            'rgb:sender/utxo1src',
            BLOCK_HEIGHT,
            COMMITMENT_HASH,
            fundsInIds
        );

        uint256 outNonce    = proxy.getNonce(FUNDS_OUT_SELECTOR);
        uint256 outDeadline = block.timestamp + 1 hours;
        bytes32 outDigest   = MultisigHelper.digestBridgeOp(
            domainSep, FUNDS_OUT_SELECTOR, callData, outNonce, outDeadline
        );
        bytes[] memory teeSigs = _signEnclave2of3(outDigest); // signers 0 and 1

        uint256 tokenCommissionOut = netBridgedIn * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT;
        uint256 netOut             = netBridgedIn - tokenCommissionOut;

        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeFundsOut(
            recipient,
            netBridgedIn,
            netOut,
            tokenCommissionOut,
            TX_ID_OUT,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            'rgb:sender/utxo1src',
            BLOCK_HEIGHT,
            COMMITMENT_HASH
        );

        proxy.execute(callData, outNonce, outDeadline, 3, teeSigs);

        assertEq(token.balanceOf(address(bridge)), 0,                       'bridge drained');
        assertEq(token.balanceOf(recipient),       netOut,                  'recipient got net');
        assertEq(token.balanceOf(address(cm)),     tokenCommissionIn + tokenCommissionOut, 'cm accrued both fees');
        assertEq(cm.tokenCommissionPool(address(token)), tokenCommissionIn + tokenCommissionOut, 'cm pool mirrors');
        assertEq(bridge.fundsInRecords(TX_ID_IN),  0,                       'fundsIn record consumed');

        // -------------------------------------------------------------------------
        // 4. Federation withdraws ERC-20 commission from CM to commissionReceiver.
        // -------------------------------------------------------------------------
        uint256 totalCommission = tokenCommissionIn + tokenCommissionOut;

        uint256 wdNonce    = proxy.proposalNonce();
        uint256 wdDeadline = block.timestamp + 7 days;
        bytes32 wdDigest   = MultisigHelper.digestProposeWithdrawTokenCommissionCM(
            domainSep, address(token), totalCommission, wdNonce, wdDeadline
        );
        bytes[] memory fedSigs = _signFed2of3(wdDigest);

        bytes32 proposalId = proxy.proposeWithdrawTokenCommissionCM(
            address(token), totalCommission, wdNonce, wdDeadline, 3, fedSigs
        );

        // Move past the timelock.
        vm.warp(block.timestamp + TIMELOCK + 1);

        bytes memory opData = abi.encode(address(token), totalCommission);

        vm.expectEmit(true, false, true, true, address(proxy));
        emit CommissionWithdrawn(address(token), totalCommission, commissionReceiver);

        proxy.executeProposal(proposalId, opData);

        // -------------------------------------------------------------------------
        // 5. Final invariants: bridge empty, CM empty, recipient holds netOut,
        //    commissionReceiver holds the full aggregated commission.
        // -------------------------------------------------------------------------
        assertEq(token.balanceOf(address(bridge)),         0,                   'bridge still empty');
        assertEq(token.balanceOf(address(cm)),             0,                   'cm drained');
        assertEq(cm.tokenCommissionPool(address(token)),   0,                   'cm pool drained');
        assertEq(token.balanceOf(recipient),               netOut,              'recipient unchanged');
        assertEq(token.balanceOf(commissionReceiver),      totalCommission,     'commissionReceiver paid');
        // Token conservation: user-deducted == everything distributed.
        assertEq(
            token.balanceOf(recipient) + token.balanceOf(commissionReceiver),
            USER_DEPOSIT,
            'token conservation'
        );
    }

    // =========================================================================
    // Secondary e2e — NATIVE commission on fundsIn, native withdrawal via proxy
    // =========================================================================

    function test_endToEnd_nativeCommission_inboundAndWithdraw() public {
        // Configure a NATIVE FUNDS_IN route (2% on token amount, paid in wei).
        // Wire up a Chainlink ETH/USD feed ($2000 / ETH, 8 decimals, fresh)
        // via federation governance — the same path production will use.
        // Heartbeat is 1 day so the two federation timelock warps below (2 x
        // TIMELOCK) don't push `updatedAt` past the staleness window. Real
        // Chainlink feeds keep updating; the mock holds `updatedAt` fixed at
        // its deploy block timestamp.
        ethUsdFeed = new MockAggregatorV3(8, 2_000e8, block.timestamp);
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(
                ICommissionManager.setEthUsdFeed.selector,
                address(ethUsdFeed),
                uint256(1 days)
            )
        );
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(
                ICommissionManager.setCommissionRule.selector,
                SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(token),
                CommissionConfig({
                    stablePercent: FUNDS_IN_PERCENT,
                    multiplier:    FUNDS_IN_MULT,
                    side:          CommissionSide.FUNDS_IN,
                    currency:      CommissionCurrency.NATIVE,
                    isSet:         true
                })
            )
        );

        (, uint256 nativeQuote, uint256 netQuote) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(token), USER_DEPOSIT);
        assertEq(netQuote, USER_DEPOSIT, 'NATIVE: full amount bridges');
        // 2% of USER_DEPOSIT in token units, converted to wei via the feed.
        uint256 stableFee = USER_DEPOSIT * FUNDS_IN_PERCENT / FUNDS_IN_MULT / FUNDS_IN_MULT;
        assertEq(nativeQuote, cm.convertTokenFeeToNative(stableFee, 18), 'native quote matches feed');

        vm.deal(user, nativeQuote);

        vm.prank(user);
        bridge.fundsIn{ value: nativeQuote }(
            USER_DEPOSIT,
            RGB_CHAIN_ID,
            'rgb:asset1qp0y3mq/utxo1abc',
            TX_ID_IN
        );

        assertEq(token.balanceOf(address(bridge)), USER_DEPOSIT,         'bridge got full token amount');
        assertEq(token.balanceOf(address(cm)),     0,                    'cm no token commission');
        assertEq(address(cm).balance,              nativeQuote,          'cm got native commission');
        assertEq(cm.nativeCommissionPool(),        nativeQuote,          'cm native pool');
        assertEq(bridge.fundsInRecords(TX_ID_IN),  USER_DEPOSIT,         'record stores full amount');

        // Federation withdraws native commission.
        uint256 wdNonce    = proxy.proposalNonce();
        uint256 wdDeadline = block.timestamp + 7 days;
        bytes32 wdDigest   = MultisigHelper.digestProposeWithdrawNativeCommissionCM(
            domainSep, nativeQuote, wdNonce, wdDeadline
        );
        bytes[] memory fedSigs = _signFed2of3(wdDigest);

        bytes32 proposalId = proxy.proposeWithdrawNativeCommissionCM(
            nativeQuote, wdNonce, wdDeadline, 3, fedSigs
        );

        vm.warp(block.timestamp + TIMELOCK + 1);

        uint256 receiverBefore = commissionReceiver.balance;
        proxy.executeProposal(proposalId, abi.encode(nativeQuote));

        assertEq(address(cm).balance,                         0,             'cm native drained');
        assertEq(cm.nativeCommissionPool(),                   0,             'cm pool drained');
        assertEq(commissionReceiver.balance - receiverBefore, nativeQuote,   'receiver paid in native');
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Proposes `callData` as an AdminExecuteCommissionManager op, waits out
    ///      the timelock, and executes. Used by tests to configure the CM.
    function _proposeAndExecuteCmAdminCall(bytes memory callData) internal {
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 7 days;

        bytes4 selector;
        assembly { selector := mload(add(callData, 32)) }

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteCM(
            domainSep, selector, callData, nonce, deadline
        );
        bytes[] memory sigs = _signFed2of3(digest);

        bytes32 proposalId = proxy.proposeAdminExecuteCommissionManager(
            callData, nonce, deadline, 3, sigs
        );

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(proposalId, callData);
    }

    function _signEnclave2of3(bytes32 digest) internal view returns (bytes[] memory sigs) {
        uint256[] memory pks = new uint256[](2);
        pks[0] = encPk1; pks[1] = encPk2;
        sigs = MultisigHelper.signAll(vm, digest, pks);
    }

    function _signFed2of3(bytes32 digest) internal view returns (bytes[] memory sigs) {
        uint256[] memory pks = new uint256[](2);
        pks[0] = fedPk1; pks[1] = fedPk2;
        sigs = MultisigHelper.signAll(vm, digest, pks);
    }
}
