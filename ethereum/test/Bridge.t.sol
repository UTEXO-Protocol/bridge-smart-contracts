// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, Vm} from "forge-std/Test.sol";

import {Bridge} from "../src/Bridge.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {BridgeBaseUpgradeable} from "../src/BridgeBaseUpgradeable.sol";
import {CommissionManager} from "../src/CommissionManager.sol";
import {RouteRegistry} from "../src/RouteRegistry.sol";
import {IRouteRegistry} from "../src/interfaces/IRouteRegistry.sol";
import {RGBVerifier} from "../src/verifiers/RGBVerifier.sol";
import {RgbSettlementModule} from "../src/settlement/RgbSettlementModule.sol";
import {OutflowRateLimiter} from "../src/libraries/OutflowRateLimiter.sol";
import {
    CommissionConfig,
    CommissionSide,
    CommissionCurrency,
    ICommissionManager
} from "../src/interfaces/ICommissionManager.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {MockBtcRelay} from "./mocks/MockBtcRelay.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockSettlementModule} from "./mocks/MockSettlementModule.sol";
import {MockDepositFloor} from "./mocks/MockDepositFloor.sol";
import {BridgeProxyTestUtils} from "./mocks/BridgeProxyTestUtils.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BridgeTestBase, ZeroNetCommissionManager, NonPayableDepositor} from "./BridgeTestBase.sol";

/// @notice Construction, configuration, deposits and the release path.
contract BridgeTest is BridgeTestBase {
    // ========================================================================
    // Constructor
    // ========================================================================

    function test_constructor_setsTokenOwnerAndRouteRegistry() public view {
        assertEq(bridge.TOKEN(), address(usdt0));
        assertEq(bridge.owner(), multisig);
        assertEq(bridge.routeRegistry(), address(routeRegistry));
        assertEq(address(bridge.commissionManager()), address(cm));
    }

    function test_constructor_revertsOnZeroToken() public {
        Bridge implementation = new Bridge();
        vm.expectRevert(BridgeBaseUpgradeable.InvalidTokenAddress.selector);
        _deployBridgeFromImplementation(
            implementation, address(0), address(routeRegistry), payable(address(cm)), address(0), 1, 1, deployer
        );
    }

    function test_constructor_revertsOnZeroRouteRegistry() public {
        Bridge implementation = new Bridge();
        vm.expectRevert(IBridge.InvalidRouteRegistryAddress.selector);
        _deployBridgeFromImplementation(
            implementation, address(usdt0), address(0), payable(address(cm)), address(0), 1, 1, deployer
        );
    }

    function test_constructor_revertsOnZeroCommissionManager() public {
        Bridge implementation = new Bridge();
        vm.expectRevert(IBridge.InvalidCommissionManagerAddress.selector);
        _deployBridgeFromImplementation(
            implementation, address(usdt0), address(routeRegistry), payable(address(0)), address(0), 1, 1, deployer
        );
    }

    function test_constructor_storesInitialLZAdapter() public {
        address initialAdapter = makeAddr("initial-adapter");
        vm.prank(deployer);
        Bridge b =
            _deployBridge(address(usdt0), address(routeRegistry), payable(address(cm)), initialAdapter, 1, 1, deployer);
        assertEq(b.lzAdapter(), initialAdapter, "lzAdapter set in constructor");
    }

    // ========================================================================
    // setLZAdapter
    // ========================================================================

    function test_setLZAdapter_rotatesToNonZero() public {
        address adapter = makeAddr("adapter");

        vm.expectEmit(true, true, false, true, address(bridge));
        emit LZAdapterUpdated(address(0), adapter);

        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        assertEq(bridge.lzAdapter(), adapter, "rotated");
    }

    function test_setLZAdapter_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidLZAdapter.selector);
        bridge.setLZAdapter(address(0));
    }

    function test_disableLZAdapter_clearsAndEmits() public {
        address adapter = makeAddr("adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);

        vm.expectEmit(true, false, false, false, address(bridge));
        emit LZAdapterDisabled(adapter);

        vm.prank(multisig);
        bridge.disableLZAdapter();
        assertEq(bridge.lzAdapter(), address(0), "disabled");
    }

    function test_disableLZAdapter_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.disableLZAdapter();
    }

    function test_setLZAdapter_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setLZAdapter(makeAddr("adapter"));
    }

    // ========================================================================
    // setRouteRegistry (new in PR6)
    // ========================================================================

    function test_setRouteRegistry_ownerCanRotate() public {
        // Deploy a NEW registry paired with the same Bridge (the documented
        // invariant). In production the new registry must already be wired
        // with this Bridge as its `bridge_` immutable.
        RouteRegistry newReg = new RouteRegistry(address(bridge), multisig);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit RouteRegistryUpdated(address(routeRegistry), address(newReg));

        vm.prank(multisig);
        bridge.setRouteRegistry(address(newReg));
        assertEq(bridge.routeRegistry(), address(newReg));
    }

    function test_setRouteRegistry_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidRouteRegistryAddress.selector);
        bridge.setRouteRegistry(address(0));
    }

    function test_setRouteRegistry_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setRouteRegistry(makeAddr("newReg"));
    }

    // ========================================================================
    // setCommissionManager
    // ========================================================================

    function test_setCommissionManager_ownerCanRotate() public {
        CommissionManager newCm = new CommissionManager(address(bridge), recipient);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit CommissionManagerUpdated(address(cm), address(newCm));

        vm.prank(multisig);
        bridge.setCommissionManager(address(newCm));
        assertEq(address(bridge.commissionManager()), address(newCm));
    }

    function test_setCommissionManager_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidCommissionManagerAddress.selector);
        bridge.setCommissionManager(address(0));
    }

    function test_setCommissionManager_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setCommissionManager(makeAddr("newCm"));
    }

    function test_setCommissionManager_routesNewFeesToReplacement() public {
        CommissionManager newCm = new CommissionManager(address(bridge), recipient);
        uint256 percent = 400; // 4%
        newCm.setCommissionRule(
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        vm.prank(multisig);
        bridge.setCommissionManager(address(newCm));

        uint256 oldPoolBefore = cm.tokenCommissionPool(address(usdt0));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 expectedCommission = AMOUNT * percent / 100 / 100;
        assertEq(newCm.tokenCommissionPool(address(usdt0)), expectedCommission, "replacement receives fees");
        assertEq(cm.tokenCommissionPool(address(usdt0)), oldPoolBefore, "old manager receives nothing");
    }

    // ========================================================================
    // Minimum fundsIn amount + zero-amount guards
    //
    // `minFundsInAmount` is a non-zero floor enforced on the inbound path: it
    // rejects zero-amount deposits and dust whose commission would round to
    // zero. `fundsOut` is an authorized release and only rejects amount == 0.
    // The harness deploys with the smallest floor (1), so
    // tests that need a higher floor raise it via `setMinFundsInAmount`.
    // ========================================================================

    function test_constructor_storesMinFundsInAmount() public {
        vm.prank(deployer);
        Bridge b =
            _deployBridge(address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1234, 1, deployer);
        assertEq(b.minFundsInAmount(), 1234, "minFundsInAmount stored from constructor");
    }

    function test_constructor_revertsOnZeroMinFundsInAmount() public {
        Bridge implementation = new Bridge();
        vm.expectRevert(IBridge.InvalidMinFundsInAmount.selector);
        _deployBridgeFromImplementation(
            implementation, address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 0, 1, deployer
        );
    }

    function test_setMinFundsInAmount_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(bridge));
        emit MinFundsInAmountUpdated(1, 1000);

        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);
        assertEq(bridge.minFundsInAmount(), 1000);
    }

    function test_setMinFundsInAmount_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidMinFundsInAmount.selector);
        bridge.setMinFundsInAmount(0);
    }

    function test_setMinFundsInAmount_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setMinFundsInAmount(1000);
    }

    // --- Minimum fundsOut amount (outbound mirror) ---

    function test_constructor_storesMinFundsOutAmount() public {
        vm.prank(deployer);
        Bridge b =
            _deployBridge(address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1, 4321, deployer);
        assertEq(b.minFundsOutAmount(), 4321, "minFundsOutAmount stored from constructor");
    }

    function test_constructor_revertsOnZeroMinFundsOutAmount() public {
        Bridge implementation = new Bridge();
        vm.expectRevert(IBridge.InvalidMinFundsOutAmount.selector);
        _deployBridgeFromImplementation(
            implementation, address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1, 0, deployer
        );
    }

    function test_setMinFundsOutAmount_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(bridge));
        emit MinFundsOutAmountUpdated(1, 2000);

        vm.prank(multisig);
        bridge.setMinFundsOutAmount(2000);
        assertEq(bridge.minFundsOutAmount(), 2000);
    }

    function test_setMinFundsOutAmount_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidMinFundsOutAmount.selector);
        bridge.setMinFundsOutAmount(0);
    }

    function test_setMinFundsOutAmount_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setMinFundsOutAmount(2000);
    }

    /// @dev The floor is an on-chain backstop for a limit the TEE is not known
    ///      to enforce: a dust release costs the bridge more to settle than it
    ///      moves.
    function test_fundsOut_revertsBelowMinFundsOutAmount() public {
        _seedRGB(1000e6);

        vm.prank(multisig);
        bridge.setMinFundsOutAmount(1e6);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, 1e6 - 1, 1e6));
        _releaseRGB(1e6 - 1, BURN_ID);
    }

    function test_fundsOut_acceptsExactlyMinFundsOutAmount() public {
        _seedRGB(1000e6);

        vm.prank(multisig);
        bridge.setMinFundsOutAmount(1e6);

        uint256 before = usdt0.balanceOf(recipient);
        _releaseRGB(1e6, BURN_ID);
        assertEq(usdt0.balanceOf(recipient) - before, 1e6, "release at the floor goes through");
    }

    /// @dev End-to-end mirror of the inbound flat-fee case: a `FUNDS_OUT` rule
    ///      with a `baseFee` deducts percentage + flat from the release and
    ///      forwards both to the CommissionManager pool.
    function test_fundsOut_baseFeeRoutesToCMOnTopOfPercentage() public {
        _seedRGB(1000e6);

        uint256 percent = 400; // 4%
        uint256 baseFee = 1e6;

        // The flat fee must fit under the release floor.
        vm.prank(multisig);
        bridge.setMinFundsOutAmount(10e6);

        vm.prank(deployer);
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                baseFee: baseFee,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        uint256 release = 100e6;
        uint256 expectedCommission = (release * percent) / 100 / 100 + baseFee;

        uint256 recipientBefore = usdt0.balanceOf(recipient);
        uint256 poolBefore = cm.tokenCommissionPool(address(usdt0));

        _releaseRGB(release, BURN_ID);

        assertEq(usdt0.balanceOf(recipient) - recipientBefore, release - expectedCommission, "recipient gets net");
        assertEq(
            cm.tokenCommissionPool(address(usdt0)) - poolBefore, expectedCommission, "pool holds percentage + flat"
        );
    }

    // --- Zero amount ---

    function test_fundsIn_revertsOnZeroAmount() public {
        // Floor is 1 (setUp), so a zero deposit is below the minimum.
        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(0), uint256(1)));
        vm.prank(user);
        bridge.fundsIn(0, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsOut_revertsOnZeroAmount() public {
        // fundsOut has no minimum — only the zero-amount no-op guard, which
        // fires before the burn-id and balance checks.
        vm.expectRevert(IBridge.ZeroAmount.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient, 0, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(new bytes32[](0))
        );
    }

    // --- Dust / below-minimum on the inbound path ---

    function test_fundsIn_revertsBelowMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(999), uint256(1000)));
        vm.prank(user);
        bridge.fundsIn(999, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_acceptsExactlyAtMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(1000, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), 1000, "deposit at the floor is accepted");
    }

    function test_fundsIn_acceptsAboveMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(1001, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), 1001, "deposit above the floor is accepted");
    }

    function test_fundsIn_dustThatRoundsCommissionToZeroIsRejected() public {
        // 4% token commission. Below 25 units the fee floors to zero
        // (24 * 400 / 100 / 100 == 0). The effective fee policy itself rejects
        // that dust, independently
        // of the separately configurable global minimum.
        _setFundsInTokenRule(400);

        assertEq(cm.calculateStableFee(24, 400, 100), 0, "sanity: 24 pays zero commission");

        vm.expectRevert(
            abi.encodeWithSelector(
                ICommissionManager.CommissionRoundsToZero.selector, uint256(24), uint256(400), uint8(100)
            )
        );
        vm.prank(user);
        bridge.fundsIn(24, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // The smallest amount that produces one fee unit is accepted.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(25, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), 24, "net = 25 - 1 commission");
    }

    function test_fundsOutDustThatRoundsCommissionToZeroIsRejected() public {
        uint256 dustAmount = 24;
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(dustAmount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(dustAmount);
        _setFundsOutTokenRule(400);

        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(_ids(opId), _one(dustAmount));
        uint256 burnId =
            _deriveBurnId(recipient, dustAmount, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICommissionManager.CommissionRoundsToZero.selector, dustAmount, uint256(400), uint8(100)
            )
        );
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, dustAmount, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData
        );

        assertFalse(bridge.consumedBurnIds(burnId), "reverted release does not consume burn id");
    }

    function test_fundsInFromAdapter_revertsBelowMinimum() public {
        // The adapter overload shares `_fundsIn`, so the floor applies there too.
        address mockAdapter = makeAddr("mock-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(mockAdapter);
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        usdt0.mint(mockAdapter, 999);
        vm.prank(mockAdapter);
        usdt0.approve(address(bridge), 999);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(999), uint256(1000)));
        vm.prank(mockAdapter);
        bridge.fundsIn(999, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_revertsOnDestinationAddressTooLong() public {
        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        string memory tooLong = _str(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AddressTooLong.selector, max + 1, max));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, tooLong, _rgbData());
    }

    function test_fundsIn_acceptsDestinationAddressAtMaxLength() public {
        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        MockSettlementModule permissiveModule = new MockSettlementModule();
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(permissiveModule));

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, _str(max), _rgbData());
        assertEq(permissiveModule.onFundsInCount(), 1, "generic route accepts the address-length cap");
    }

    function test_fundsIn_revertsOnSettlementDataTooLong() public {
        uint256 max = bridge.MAX_SETTLEMENT_DATA_LENGTH();
        bytes memory tooLong = _bytesOfLength(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.SettlementDataTooLong.selector, max + 1, max));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, tooLong);
    }

    function test_fundsIn_acceptsSettlementDataAtMaxLength() public {
        // The length guard lives in Bridge, ahead of the route module. A
        // maximal-length blob still decodes as a non-zero RGB OpId (the first
        // 32 bytes read as uint256), so the deposit clears the guard and
        // records normally under the bridge-derived operationId.
        uint256 max = bridge.MAX_SETTLEMENT_DATA_LENGTH();
        bytes memory atMax = _bytesOfLength(max);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, atMax);
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "deposit at the settlement-data cap is accepted");
    }

    function test_fundsOut_revertsOnSettlementDataTooLong() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 max = bridge.MAX_SETTLEMENT_DATA_LENGTH();
        bytes memory tooLong = _bytesOfLength(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.SettlementDataTooLong.selector, max + 1, max));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), tooLong);
    }

    function test_fundsOut_acceptsSettlementDataAtMaxLength() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // settlementData at the exact cap clears the length guard. The arbitrary
        // blob does not decode as a valid (bytes32[], uint256[]) settlement
        // encoding, so it reverts later (or on the unrelated burnId check) — the
        // guard is isolated by asserting the revert is NOT SettlementDataTooLong.
        uint256 max = bridge.MAX_SETTLEMENT_DATA_LENGTH();
        bytes memory atMax = _bytesOfLength(max);

        IBridge.FundsOutParams memory params = IBridge.FundsOutParams(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), atMax, SRC_BURN_TX_ID
        );

        vm.prank(multisig);
        try bridge.fundsOut(params) {
        // a valid settlement blob would succeed; this one won't, but if it
        // did the length guard still passed — which is what we assert.
        }
        catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel != IBridge.SettlementDataTooLong.selector, "max-length settlementData must clear the length guard"
            );
        }
    }

    function test_fundsOut_revertsOnSourceAddressTooLong() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        string memory tooLong = _str(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AddressTooLong.selector, max + 1, max));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, tooLong, _proof(), _settlement(_ids(opId)));
    }

    function test_fundsOut_sourceAddressAtMaxLengthPassesBridgeLengthGuard() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        // Bridge accepts the exact generic address-length cap. The configured
        // RGB verifier then rejects the non-empty value for the separate,
        // route-specific reason that RGB has no source-address concept.
        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        vm.expectRevert(RGBVerifier.UnexpectedSourceAddress.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, _str(max), _proof(), _settlement(_ids(opId))
        );
    }

    /// @dev RGB has no source-address concept, so the RGB verifier rejects any
    ///      non-empty value. This keeps `sourceAddress` canonical on RGB routes —
    ///      it is hashed into `burnId`, so a free-form value would let the same
    ///      burn derive a different replay key. Bridge's own length cap is still
    ///      exercised by `test_fundsOut_revertsOnSourceAddressTooLong`.
    function test_fundsOut_rgbRouteRejectsNonEmptySourceAddress() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        vm.expectRevert(RGBVerifier.UnexpectedSourceAddress.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, "rgb:sender", _proof(), _settlement(_ids(opId))
        );
    }

    function test_fundsOut_revertsOnProofTooLong() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 max = bridge.MAX_PROOF_LENGTH();
        bytes memory tooLong = _bytesOfLength(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.ProofTooLong.selector, max + 1, max));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, tooLong, _settlement(_ids(opId)));
    }

    function test_fundsOut_acceptsProofAtMaxLength() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // A proof at the exact cap passes the length guard. It then reverts in
        // the verifier (the blob is not a valid (height, commitment) pair), so
        // the cap check is isolated by asserting it is NOT ProofTooLong: the
        // call reaches the verifier instead.
        uint256 max = bridge.MAX_PROOF_LENGTH();
        bytes memory atMax = _bytesOfLength(max);
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, atMax, settlementData);

        IBridge.FundsOutParams memory params = IBridge.FundsOutParams(
            recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, atMax, settlementData, SRC_BURN_TX_ID
        );

        vm.prank(multisig);
        try bridge.fundsOut(params) {
        // a decodable proof would succeed; this blob won't, so we don't
        // expect to land here — but if a future verifier accepts it, the
        // length guard still passed, which is what this test asserts.
        }
        catch (bytes memory reason) {
            // Must NOT be the length guard — proving max-length passes it.
            bytes4 sel = bytes4(reason);
            assertTrue(sel != IBridge.ProofTooLong.selector, "max-length proof must clear the length guard");
        }
    }

    function test_fundsOut_acceptsRealProofUnderCap() public {
        // The production-shaped 64-byte RGB proof is well under the cap and the
        // happy path still succeeds.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        assertLt(_proof().length, bridge.MAX_PROOF_LENGTH(), "sanity: real proof under cap");

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );
        assertEq(usdt0.balanceOf(recipient), AMOUNT, "release with a normal proof succeeds");
    }

    // ========================================================================
    // fundsIn — adapter overload (`onlyLZAdapter`)
    // ========================================================================

    function test_fundsInFromAdapter_revertsIfCallerIsNotLZAdapter() public {
        // No adapter set in setUp — caller is `user`.
        vm.prank(user);
        vm.expectRevert(IBridge.NotLZAdapter.selector);
        bridge.fundsIn(AMOUNT, 1, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsInFromAdapter_acceptsCustomSourceChainId() public {
        address mockAdapter = makeAddr("mock-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(mockAdapter);

        usdt0.mint(mockAdapter, AMOUNT);
        vm.prank(mockAdapter);
        usdt0.approve(address(bridge), AMOUNT);

        uint256 customSrc = 137; // pretend Polygon
        bytes32 sourceSender = bytes32(uint256(uint160(user))); // authenticated far-chain sender

        // Register a route for the custom (Polygon, RGB) pair — the adapter
        // overload simply forwards whatever sourceChainId the composeMsg
        // carries; both directions need real routes wired in the registry.
        vm.prank(deployer);
        routeRegistry.setRoute(customSrc, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // The nonce for this (sourceChainId, sourceSender) starts at 0.
        bytes32 expectedOpId = _deriveOpId(customSrc, sourceSender, 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // Drop the emitter filter so Forge's expectEmit scans past the token's
        // Transfer event (emitter = usdt0) and matches BridgeFundsIn by topic0.
        // FundsIn (RGB route) carries the rgbOpId; sender = the adapter.
        vm.expectEmit(true, false, false, true);
        emit FundsIn(mockAdapter, RGB_OP_ID, uint64(AMOUNT));
        vm.expectEmit(true, true, true, true);
        emit BridgeFundsIn(
            expectedOpId,
            sourceSender,
            mockAdapter,
            0,
            AMOUNT,
            AMOUNT,
            0,
            0,
            customSrc,
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData()
        );

        vm.prank(mockAdapter);
        bytes32 opId = bridge.fundsIn(AMOUNT, customSrc, sourceSender, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(opId, expectedOpId, "returned id matches derivation");
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "record stored on module");
    }

    // ========================================================================
    // fundsIn — happy path (zero commission default)
    // ========================================================================

    function test_fundsIn_transfersTokens() public {
        uint256 userBefore = usdt0.balanceOf(user);

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
        assertEq(usdt0.balanceOf(user), userBefore - AMOUNT);
    }

    function test_fundsIn_storesRecordOnModule() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(rgbModule.fundsInRecords(opId), AMOUNT);
    }

    function test_fundsIn_emitsBothEvents() public {
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        bytes32 expectedOpId = _deriveOpId(SOURCE_CHAIN_ID, sourceSender, 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.expectEmit(true, false, false, true);
        emit FundsIn(user, RGB_OP_ID, uint64(AMOUNT));
        vm.expectEmit(true, true, true, true);
        emit BridgeFundsIn(
            expectedOpId,
            sourceSender,
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
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_anyUserCanCall() public {
        address stranger = makeAddr("stranger");
        usdt0.mint(stranger, AMOUNT);
        vm.prank(stranger);
        usdt0.approve(address(bridge), AMOUNT);

        vm.prank(stranger);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
    }

    function test_fundsIn_rgbAcceptsEmptyDestinationAddressAndEmitsNonce() public {
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        bytes32 expectedOpId = _deriveOpId(SOURCE_CHAIN_ID, sourceSender, 0, AMOUNT, RGB_CHAIN_ID, "", _rgbData());

        vm.expectEmit(true, false, false, true);
        emit FundsIn(user, RGB_OP_ID, uint64(AMOUNT));
        vm.expectEmit(true, true, true, true);
        emit BridgeFundsIn(
            expectedOpId, sourceSender, user, 0, AMOUNT, AMOUNT, 0, 0, SOURCE_CHAIN_ID, RGB_CHAIN_ID, "", _rgbData()
        );

        vm.prank(user);
        bytes32 operationId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, "", _rgbData());

        assertEq(operationId, expectedOpId, "empty address is part of the canonical operation id");
        assertEq(rgbModule.fundsInRecords(operationId), AMOUNT, "RGB settlement record created");
    }

    // ========================================================================
    // fundsIn — reverts
    // ========================================================================

    function test_fundsIn_revertsOnEmptyDestinationChain() public {
        vm.expectRevert(IBridge.InvalidDestinationChainId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, 0, DST_ADDR, _rgbData());
    }

    function test_fundsIn_revertsWhenPaused() public {
        vm.prank(multisig);
        bridge.pauseInflow();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    // The operationId is derived on-chain with a per-sender nonce, so two
    // identical deposits from the same sender get DISTINCT ids and
    // both succeed — the caller can no longer force a DuplicateOperationId by
    // replaying params. The duplicate guard is exercised directly at the module
    // level (RgbSettlementModule.t.sol) instead.
    function test_fundsIn_repeatedDepositsDoNotCollide() public {
        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(opId1 != opId2, "nonce makes identical deposits distinct");
        assertEq(rgbModule.fundsInRecords(opId1), AMOUNT, "first record");
        assertEq(rgbModule.fundsInRecords(opId2), AMOUNT, "second record");
    }

    // ========================================================================
    // fundsOut — happy path
    // ========================================================================

    function test_fundsOut_transfersAndEmits() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        vm.expectEmit(true, true, false, true);
        emit BridgeFundsOut(
            recipient, AMOUNT, AMOUNT, 0, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, settlementData
        );

        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertEq(usdt0.balanceOf(recipient), AMOUNT);
        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT * 9, "90% configured bucket reserve remains");
    }

    function test_fundsOut_keepsRecordAfterRelease() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );

        // The mint ledger is permanent (proof-of-mint), not a consumable balance.
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "record unchanged after release");
    }

    function test_fundsOut_revertsAndRollsBackWhenCommissionManagerReturnsZeroNetAmount() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        ZeroNetCommissionManager zeroNetManager = new ZeroNetCommissionManager();
        vm.prank(multisig);
        bridge.setCommissionManager(address(zeroNetManager));

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 totalLiquidityBefore = bridge.totalLockedLiquidity();

        vm.expectRevert(IBridge.ZeroNetAmount.selector);
        vm.prank(multisig);
        _fundsOutWithBurnId(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "reverted release does not consume burn id");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore, "reverted release restores liquidity");
        assertEq(bridge.totalLockedLiquidity(), totalLiquidityBefore, "reverted release restores total liquidity");
        assertEq(usdt0.balanceOf(recipient), 0, "reverted release transfers no tokens");
    }

    function test_fundsOut_multipleFundsInIds() public {
        uint256 amount1 = AMOUNT * 3 / 5;
        uint256 amount2 = AMOUNT * 2 / 5;

        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(amount1, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(amount2, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));
        _ensureRgbSafetyCapacity(amount1 + amount2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = opId1;
        ids[1] = opId2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount1;
        amounts[1] = amount2;

        vm.prank(multisig);
        _fundsOut(
            recipient,
            amount1 + amount2,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(ids, amounts)
        );

        assertEq(usdt0.balanceOf(recipient), amount1 + amount2);
        // Records are a permanent proof-of-mint ledger — not consumed on release.
        assertEq(rgbModule.fundsInRecords(opId1), amount1, "record 1 unchanged");
        assertEq(rgbModule.fundsInRecords(opId2), amount2, "record 2 unchanged");
    }

    // ========================================================================
    // fundsOut — verifier reverts
    // ========================================================================

    function test_fundsOut_revertsOnUnverifiedBlock() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        // Well-formed two-pair proof, but the source block is unknown to the relay.
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown-block"), LATEST_HEIGHT, LATEST_COMMIT);

        // RGBVerifier → BtcRelay reverts with the relay's string message.
        vm.expectRevert("verify: block commitment");
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, badProof, _settlement(_ids(opId))
        );
    }

    // ========================================================================
    // fundsOut — settlement-module reverts (delegated to RgbSettlementModule
    // but surfaced through Bridge)
    // ========================================================================

    function test_fundsOutRejectsEmptySettlementRecords() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(new bytes32[](0), new uint256[](0));
        uint256 burnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);

        vm.expectRevert(RgbSettlementModule.EmptySettlementRecords.selector);
        vm.prank(multisig);
        _fundsOutWithBurnId(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "reverted release does not consume burn id");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore, "reverted release does not debit liquidity");
        assertEq(usdt0.balanceOf(recipient), 0, "reverted release transfers no tokens");
    }

    function test_fundsOut_revertsOnUnknownFundsInId() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes32 unknown = bytes32(uint256(999));
        bytes32[] memory ids = _ids(unknown);

        vm.expectRevert(abi.encodeWithSelector(RgbSettlementModule.FundsInNotFound.selector, unknown));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(ids));
    }

    function test_fundsOut_revertsOnAmountMismatch() public {
        // Record one amount, then claim a different amount in
        // settlementData. The module binds operationId → exact mint amount, so
        // the mismatch must revert (surfaced through the Bridge).
        vm.prank(user);
        uint256 recordedAmount = AMOUNT / 2;
        uint256 claimedAmount = AMOUNT * 3 / 5;
        bytes32 opId = bridge.fundsIn(recordedAmount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(recordedAmount);

        bytes32[] memory ids = _ids(opId);
        uint256[] memory amounts = _one(claimedAmount);

        vm.expectRevert(
            abi.encodeWithSelector(RgbSettlementModule.AmountMismatch.selector, opId, claimedAmount, recordedAmount)
        );
        vm.prank(multisig);
        _fundsOut(
            recipient,
            recordedAmount,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(ids, amounts)
        );
    }

    function test_fundsOut_revertsOnReplayedBurnId() public {
        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes32[] memory ids1 = _ids(opId1);
        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(ids1);
        uint256 burnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        assertTrue(bridge.consumedBurnIds(burnId), "burnId recorded");

        // Second fundsOut with the same burnId — must revert before any
        // module mutation, leaving the second record untouched.
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, burnId));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        assertEq(rgbModule.fundsInRecords(opId2), AMOUNT, "second fundsIn record preserved");
    }

    function test_fundsOut_revertsOnInvalidDerivedBurnId() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 expectedBurnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        uint256 invalidBurnId = expectedBurnId ^ 1;

        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, invalidBurnId, expectedBurnId));
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, invalidBurnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData
        );

        assertFalse(bridge.consumedBurnIds(expectedBurnId), "expected burn id unchanged");
        assertFalse(bridge.consumedBurnIds(invalidBurnId), "invalid burn id unchanged");
    }

    /// @dev `proof` is deliberately NOT part of `burnId`: it carries the relay
    ///      head pair, which moves as the relay advances, so including it would
    ///      let one settlement derive different ids over time. Swapping the proof
    ///      therefore keeps the same id — integrity of the proof is carried by the
    ///      enclave's EIP-712 signature, not by the replay key.
    function test_fundsOut_burnIdIsIndependentOfProof() public {
        bytes memory settlementData = _settlement(_ids(keccak256("op")));
        bytes memory proofA = _proof();
        bytes memory proofB = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, keccak256("changed-proof"));

        assertEq(
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proofA, settlementData),
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proofB, settlementData),
            "burnId ignores proof"
        );
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
        uint256 burnId =
            _deriveBurnIdWithTx(AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, settlementData, bytes32(0));

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

        uint256 signedBurnId =
            _deriveBurnIdWithTx(AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, settlementData, otherBurnTx);
        uint256 expectedBurnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        assertTrue(signedBurnId != expectedBurnId, "a different burn derives a different id");

        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, signedBurnId, expectedBurnId));
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, signedBurnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData
        );

        assertFalse(bridge.consumedBurnIds(signedBurnId), "signed burn id unchanged");
    }

    function test_fundsOut_revertsWhenSettlementDataChangesAfterBurnIdDerivation() public {
        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));

        bytes memory proof = _proof();
        bytes memory signedSettlementData = _settlement(_ids(opId1));
        bytes memory changedSettlementData = _settlement(_ids(opId2));
        uint256 signedBurnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, signedSettlementData);
        uint256 expectedBurnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, changedSettlementData);

        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, signedBurnId, expectedBurnId));
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, signedBurnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, changedSettlementData
        );

        assertFalse(bridge.consumedBurnIds(signedBurnId), "signed burn id unchanged");
        assertEq(rgbModule.fundsInRecords(opId1), AMOUNT, "first record unchanged");
        assertEq(rgbModule.fundsInRecords(opId2), AMOUNT, "second record unchanged");
    }

    function test_fundsOut_reusedPermanentRecordCannotExceedRollingLimit() public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );

        // The settlement module no longer consumes records (the mint proof is
        // permanent and may back another distinct burn intent), so let the
        // configurable bucket refill while the first spend remains inside the
        // rolling window.
        bytes32 altLatestCommit = keccak256("test-btc-alt-latest-commitment");
        btcRelay.setBlock(LATEST_HEIGHT + 1, altLatestCommit, LATEST_CONFIRMATIONS);
        bytes memory altProof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT + 1, altLatestCommit);

        vm.warp(block.timestamp + bridge.BUCKET_REFILL_WINDOW() + 1);
        uint256 secondAmount = AMOUNT * 9 / 10; // 10% of the current post-release liquidity
        vm.prank(multisig);
        _fundsOut(
            recipient,
            secondAmount,
            BURN_ID + 1,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            altProof,
            _settlement(_ids(opId))
        );

        // The bucket reprices the second burst against current liquidity, while
        // the immutable limiter still counts both releases against the original
        // 1,000 reference. No split can exceed its remaining 10-token allowance.
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), AMOUNT / 10);
        assertEq(bridge.availableGlobalSafetyOutflow(), AMOUNT / 10);
        vm.warp(block.timestamp + 1);
        assertLe(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), AMOUNT / 10, "rolling ceiling remains authoritative");
        vm.expectPartialRevert(OutflowRateLimiter.TokenOutflowThrottled.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            AMOUNT / 10 + 1,
            BURN_ID + 2,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            altProof,
            _settlement(_ids(opId))
        );
    }

    // ========================================================================
    // Isolated liquidity
    //
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
        _fundsOut(
            recipient,
            release,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)) // settlement amount = recorded AMOUNT
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
        _fundsOut(recipient, AMOUNT, BURN_ID, otherChain, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId)));
    }

    function test_isolatedLiquidity_revertRollsBackDebit() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // Bad proof → verifier reverts downstream of the liquidity debit.
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown"));
        vm.expectRevert();
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, badProof, _settlement(_ids(opId))
        );
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT, "debit rolled back on revert");
    }

    /// @dev Fuzz the interaction between isolated liquidity and the immutable
    ///      rolling ceiling: overdraw still fails on isolated liquidity, while
    ///      a full-bucket release fails and a release inside both limits
    ///      succeeds.
    function testFuzz_isolatedLiquidity_andSafetyLimit(uint256 amount) public {
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
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(_ids(opId), _one(amount))
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
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(_ids(opId), _one(amount))
        );

        vm.prank(multisig);
        _fundsOut(
            recipient,
            bucketLimit,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(_ids(opId), _one(amount))
        );
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), amount - bucketLimit, "configured 10% burst debited");
    }

    function test_outflow_fullBucketAllowsCapacityRejectsOverByOne() public {
        _seedRGB(1000e6);
        uint256 cap = 100e6;
        _setRGBBucket(cap, cap); // reconfig down → available == cap

        _releaseRGB(cap, BURN_ID);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "capacity fully spent");

        // One unit over the (now empty) bucket but still within capacity → rate-limited.
        vm.expectPartialRevert(OutflowRateLimiter.TokenOutflowThrottled.selector);
        _releaseRGB(1, BURN_ID + 1);
    }

    function test_outflow_releaseAboveCapacityReverts() public {
        _seedRGB(1000e6);
        uint256 cap = 100e6;
        _setRGBBucket(cap, cap);

        // Full bucket, but the request exceeds capacity entirely → a different,
        // more-specific error than the rate-limit one.
        vm.expectPartialRevert(OutflowRateLimiter.TokenRequestAboveCapacity.selector);
        _releaseRGB(cap + 1, BURN_ID);
    }

    function test_outflow_refillAccruesOverTime() public {
        _seedRGB(1000e6);
        uint256 cap = 100e6;
        _setRGBBucket(cap, cap);

        _releaseRGB(cap, BURN_ID);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "drained");

        // Half the share capacity is restored. Its token value is calculated
        // against the current 9,900 liquidity after the first release.
        vm.warp(block.timestamp + 12 hours);
        uint256 refilled = bridge.availableOutflow(RGB_CHAIN_ID);
        uint256 expectedRefill = bridge.lockedLiquidity(RGB_CHAIN_ID) * 50 / bridge.BPS_DENOMINATOR();
        assertApproxEqRel(refilled, expectedRefill, 1e12, "partial linear refill"); // 1e-6 relative

        _releaseRGB(refilled - 1, BURN_ID + 1); // the refilled allowance is spendable
    }

    function test_outflow_noDoubleCapBurstOverShortGap() public {
        _seedRGB(1000e6);
        uint256 cap = 100e6;
        _setRGBBucket(cap, cap);

        _releaseRGB(cap, BURN_ID);
        vm.warp(block.timestamp + 1); // one second later

        uint256 accrued = bridge.availableOutflow(RGB_CHAIN_ID);
        uint256 expectedAccrued = bridge.lockedLiquidity(RGB_CHAIN_ID) * 100 / bridge.BPS_DENOMINATOR() / (24 hours);
        assertApproxEqRel(accrued, expectedAccrued, 1e12, "only one second of refill accrued");
        assertLt(accrued, cap, "not a fresh cap");
        bytes32 altLatestCommit = keccak256("test-btc-short-gap-latest-commitment");
        btcRelay.setBlock(LATEST_HEIGHT + 1, altLatestCommit, LATEST_CONFIRMATIONS);
        bytes memory altProof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT + 1, altLatestCommit);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = _seedOpId;

        uint256 currentCapacity = bridge.lockedLiquidity(RGB_CHAIN_ID) * 100 / bridge.BPS_DENOMINATOR();
        vm.expectPartialRevert(OutflowRateLimiter.TokenOutflowThrottled.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            currentCapacity,
            BURN_ID + 1,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            altProof,
            _settlementWithAmounts(ids, _one(_seedAmt))
        );
    }

    function test_outflow_perChainIsolation() public {
        uint256 other = 888;
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, other, true, address(rgbVerifier), address(rgbModule));
        vm.prank(deployer);
        routeRegistry.setRoute(other, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        usdt0.mint(user, 500e6);
        vm.prank(user);
        bridge.fundsIn(500e6, other, DST_ADDR, _rgbData(RGB_OP_ID + 888));

        uint256 otherBps = _bpsOfChain(other, 50e6);
        vm.prank(multisig);
        bridge.setOutflowLimit(other, otherBps, otherBps);

        _seedRGB(1000e6);
        _setRGBBucket(100e6, 100e6);
        _releaseRGB(100e6, BURN_ID); // drain RGB bucket to 0

        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "RGB drained");
        assertEq(bridge.availableOutflow(other), 50e6, "other chain bucket untouched");
    }

    function test_outflow_globalBucketBoundsAggregate() public {
        _seedRGB(1000e6);
        // Keep the per-chain bucket large; tighten only the global bucket.
        uint256 globalBps = _bpsOfGlobal(100e6);
        vm.prank(multisig);
        bridge.setGlobalOutflowLimit(globalBps, globalBps);

        _releaseRGB(100e6, BURN_ID); // consumes the whole global allowance
        assertEq(bridge.availableGlobalOutflow(), 0, "global drained");

        // The per-chain bucket still has room, but the global aggregate trips.
        vm.expectPartialRevert(OutflowRateLimiter.AggregateOutflowThrottled.selector);
        _releaseRGB(1, BURN_ID + 1);
    }

    function test_outflow_reconfigPreservesAvailableNoGift() public {
        _seedRGB(1000e6);
        _setRGBBucket(100e6, 100e6);
        _releaseRGB(60e6, BURN_ID); // 4,000 bps of shares remain
        uint256 availableBefore = bridge.availableOutflow(RGB_CHAIN_ID);
        assertEq(availableBefore, 39.76e6, "pre");

        // Raising capacity must NOT gift a fresh full bucket.
        _setRGBBucket(200e6, 200e6);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), availableBefore, "available preserved, not gifted");
    }
}
