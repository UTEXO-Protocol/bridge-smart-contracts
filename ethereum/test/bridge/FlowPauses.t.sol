// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Vm} from "forge-std/Test.sol";
import {BridgeBase} from "../../src/BridgeBase.sol";
import {MinimalBridge} from "../../src/MinimalBridge.sol";
import {IArbSys} from "../../src/interfaces/IArbSys.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @dev Common public pause ABI implemented by both concrete bridge variants.
interface IFlowPauseControl {
    function pauseInflow() external;
    function unpauseInflow() external;
    function emergencyPauseAll() external;
    function emergencyUnpauseAll() external;
    function renounceOwnership() external view;
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function outflowPaused() external view returns (bool);
}

/// @notice Both real bridge variants preserve independent flow flags and exact transition events.
contract BridgeFlowPausesTest is BridgeTestBase {
    enum PauseState {
        Open,
        InflowOnly,
        OutflowOnly,
        Both
    }

    MinimalBridge private minimalBridge;

    bytes32 private constant INFLOW_PAUSED = keccak256("Paused(address)");
    bytes32 private constant INFLOW_UNPAUSED = keccak256("Unpaused(address)");
    bytes32 private constant OUTFLOW_PAUSED = keccak256("OutflowPaused(address)");
    bytes32 private constant OUTFLOW_UNPAUSED = keccak256("OutflowUnpaused(address)");
    uint256 private constant MINIMAL_L2_BLOCK = 1_000_000;
    uint64 private constant MINIMAL_BEFORE_BLOCK = 1_000_001;

    function setUp() public override {
        super.setUp();
        minimalBridge = new MinimalBridge(address(usdt0));
        minimalBridge.transferOwnership(multisig);
        vm.prank(multisig);
        minimalBridge.acceptOwnership();
        vm.prank(user);
        usdt0.approve(address(minimalBridge), type(uint256).max);
        vm.mockCall(address(100), abi.encodeCall(IArbSys.arbBlockNumber, ()), abi.encode(MINIMAL_L2_BLOCK));
    }

    function _pauseTargets() private view returns (IFlowPauseControl[2] memory) {
        return [IFlowPauseControl(address(bridge)), IFlowPauseControl(address(minimalBridge))];
    }

    function _inflowPaused(PauseState state) private pure returns (bool) {
        return state == PauseState.InflowOnly || state == PauseState.Both;
    }

    function _outflowPaused(PauseState state) private pure returns (bool) {
        return state == PauseState.OutflowOnly || state == PauseState.Both;
    }

    /// @dev All four states are reachable through public owner operations.
    function _setPauseState(IFlowPauseControl target, PauseState state) private {
        vm.startPrank(multisig);
        if (_outflowPaused(state)) {
            target.emergencyPauseAll();
            if (!_inflowPaused(state)) target.unpauseInflow();
        } else if (_inflowPaused(state)) {
            target.pauseInflow();
        }
        vm.stopPrank();
        assertEq(target.paused(), _inflowPaused(state), "inflow precondition");
        assertEq(target.outflowPaused(), _outflowPaused(state), "outflow precondition");
    }

    function _assertTransitionLog(Vm.Log memory entry, address target, bytes32 topic) private view {
        assertEq(entry.emitter, target, "transition comes from the concrete bridge");
        assertEq(entry.topics.length, 1, "pause events have no indexed arguments");
        assertEq(entry.topics[0], topic, "transition event signature");
        assertEq(entry.data, abi.encode(multisig), "transition identifies the owner caller");
    }

    function _assertEmergencyTransition(IFlowPauseControl target, PauseState state, bool pauseBoth) private {
        uint256 snapshot = vm.snapshotState();
        _setPauseState(target, state);
        bool changeInflow = _inflowPaused(state) != pauseBoth;
        bool changeOutflow = _outflowPaused(state) != pauseBoth;
        vm.recordLogs();
        vm.prank(multisig);
        if (pauseBoth) target.emergencyPauseAll();
        else target.emergencyUnpauseAll();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(target.paused(), pauseBoth, "inflow reaches the requested state");
        assertEq(target.outflowPaused(), pauseBoth, "outflow reaches the requested state");
        assertEq(entries.length, (changeInflow ? 1 : 0) + (changeOutflow ? 1 : 0), "only changed flows emit events");
        uint256 index;
        if (changeInflow) {
            _assertTransitionLog(entries[index++], address(target), pauseBoth ? INFLOW_PAUSED : INFLOW_UNPAUSED);
        }
        if (changeOutflow) {
            _assertTransitionLog(entries[index], address(target), pauseBoth ? OUTFLOW_PAUSED : OUTFLOW_UNPAUSED);
        }
        assertTrue(vm.revertToStateAndDelete(snapshot), "pause scenario restored");
    }

    function _assertEmergencyAuthorizationAcrossStates(bool pauseBoth) private {
        IFlowPauseControl[2] memory targets = _pauseTargets();
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 state; state <= uint256(type(PauseState).max); ++state) {
                uint256 snapshot = vm.snapshotState();
                PauseState pauseState = PauseState(state);
                _setPauseState(targets[i], pauseState);
                vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
                vm.prank(user);
                if (pauseBoth) targets[i].emergencyPauseAll();
                else targets[i].emergencyUnpauseAll();
                assertEq(targets[i].paused(), _inflowPaused(pauseState), "stranger preserves inflow");
                assertEq(targets[i].outflowPaused(), _outflowPaused(pauseState), "stranger preserves outflow");
                assertEq(targets[i].owner(), multisig, "stranger preserves owner");
                assertTrue(vm.revertToStateAndDelete(snapshot), "authorization scenario restored");
            }
        }
    }

    function test_emergencyPauseAll_emitsOnlyTransitionsAcrossPauseStates() public {
        IFlowPauseControl[2] memory targets = _pauseTargets();
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 state; state <= uint256(type(PauseState).max); ++state) {
                _assertEmergencyTransition(targets[i], PauseState(state), true);
            }
        }
    }

    function test_emergencyUnpauseAll_emitsOnlyTransitionsAcrossPauseStates() public {
        IFlowPauseControl[2] memory targets = _pauseTargets();
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 state; state <= uint256(type(PauseState).max); ++state) {
                _assertEmergencyTransition(targets[i], PauseState(state), false);
            }
        }
    }

    function test_emergencyPauseAll_revertsForNonOwnerAcrossPauseStates() public {
        _assertEmergencyAuthorizationAcrossStates(true);
    }

    function test_emergencyUnpauseAll_revertsForNonOwnerAcrossPauseStates() public {
        _assertEmergencyAuthorizationAcrossStates(false);
    }

    function test_renounceOwnership_revertsForNonOwnerOnBothVariants() public {
        IFlowPauseControl[2] memory targets = _pauseTargets();
        for (uint256 i; i < targets.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
            vm.prank(user);
            targets[i].renounceOwnership();
            assertEq(targets[i].owner(), multisig, "stranger cannot renounce bridge ownership");
        }
    }

    function test_pauseInflow_revertsWhenAlreadyPausedOnBothVariants() public {
        IFlowPauseControl[2] memory targets = _pauseTargets();
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(multisig);
            targets[i].pauseInflow();
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(multisig);
            targets[i].pauseInflow();
            assertTrue(targets[i].paused(), "inflow remains paused");
            assertFalse(targets[i].outflowPaused(), "planned pause keeps outflow open");
        }
    }

    function test_unpauseInflow_revertsWhenAlreadyOpenOnBothVariants() public {
        IFlowPauseControl[2] memory targets = _pauseTargets();
        for (uint256 i; i < targets.length; ++i) {
            vm.expectRevert(Pausable.ExpectedPause.selector);
            vm.prank(multisig);
            targets[i].unpauseInflow();
            assertFalse(targets[i].paused(), "inflow remains open");
            assertFalse(targets[i].outflowPaused(), "outflow remains open");
        }
    }

    function test_unpauseInflow_keepsMinimalBridgeOutflowFrozen() public {
        vm.startPrank(multisig);
        minimalBridge.emergencyPauseAll();
        minimalBridge.unpauseInflow();
        vm.stopPrank();
        assertFalse(minimalBridge.paused(), "planned resume opens inflow");
        assertTrue(minimalBridge.outflowPaused(), "planned resume preserves emergency outflow freeze");
        vm.prank(user);
        minimalBridge.fundsIn(AMOUNT, RGB_OP_ID, MINIMAL_BEFORE_BLOCK);
        assertEq(usdt0.balanceOf(address(minimalBridge)), AMOUNT, "deposit succeeds with outflow frozen");
        vm.expectRevert(BridgeBase.OutflowEnforcedPause.selector);
        vm.prank(multisig);
        minimalBridge.fundsOut(recipient, AMOUNT, RGB_OP_ID, SRC_ADDR);
        assertEq(usdt0.balanceOf(address(minimalBridge)), AMOUNT, "frozen release preserves custody");
        assertEq(usdt0.balanceOf(recipient), 0, "frozen release pays nothing");
        vm.prank(multisig);
        minimalBridge.emergencyUnpauseAll();
        vm.prank(multisig);
        minimalBridge.fundsOut(recipient, AMOUNT, RGB_OP_ID, SRC_ADDR);
        assertEq(usdt0.balanceOf(recipient), AMOUNT, "same release succeeds after emergency resume");
    }

    function test_unpauseInflow_keepsProxyOutflowFrozen() public {
        _seedRGB(AMOUNT);
        bytes memory settlementData = _settlementWithAmounts(_ids(_seedOpId), _one(_seedAmt));
        vm.startPrank(multisig);
        bridge.emergencyPauseAll();
        bridge.unpauseInflow();
        vm.stopPrank();
        assertFalse(bridge.paused(), "planned resume opens proxy inflow");
        assertTrue(bridge.outflowPaused(), "planned resume preserves proxy outflow freeze");
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 1));
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT * 11, "deposit credits the frozen-outflow chain");
        vm.expectRevert(BridgeBase.OutflowEnforcedPause.selector);
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), settlementData, SRC_BURN_TX_ID);
        assertEq(bridge.getContractBalance(), AMOUNT * 11, "frozen release preserves proxy custody");
        assertEq(bridge.totalLockedLiquidity(), AMOUNT * 11, "frozen release preserves proxy ledger");
        assertEq(usdt0.balanceOf(recipient), 0, "frozen proxy release pays nothing");
        vm.prank(multisig);
        bridge.emergencyUnpauseAll();
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), settlementData, SRC_BURN_TX_ID);
        assertEq(usdt0.balanceOf(recipient), AMOUNT, "same proxy release succeeds after emergency resume");
        assertEq(bridge.totalLockedLiquidity(), AMOUNT * 10, "successful retry debits the ledger once");
    }
}
