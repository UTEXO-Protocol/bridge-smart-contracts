// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, Vm} from "forge-std/Test.sol";
import {BaseBridge} from "../src/BaseBridge.sol";
import {BridgeBase} from "../src/BridgeBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract BaseBridgeTest is Test {
    // Events re-declared locally for vm.expectEmit
    event FundsIn(address indexed sender, uint256 operationId, uint64 amount);
    event FundsOut(address indexed recipient, uint256 amount, uint256 indexed operationId, string sourceAddress);

    BaseBridge bridge;
    MockERC20 token;

    address deployer = makeAddr("deployer");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address owner = makeAddr("owner");

    string constant SRC_ADDR = "rgb:sender/utxo1src";
    uint256 constant AMOUNT = 1e18;
    uint256 constant OPERATION_ID = 42;

    function setUp() public {
        token = new MockERC20("Mock Token", "MOCK");

        vm.prank(deployer);
        bridge = new BaseBridge(address(token));

        // deployer hands ownership over to the integrator multisig
        vm.prank(deployer);
        bridge.transferOwnership(owner);

        // Ownable2Step: the new owner must accept before it takes effect.
        vm.prank(owner);
        bridge.acceptOwnership();

        token.mint(user, AMOUNT * 10);
        vm.prank(user);
        token.approve(address(bridge), type(uint256).max);
    }

    // ========================================================================
    // Constructor
    // ========================================================================

    function test_constructor_setsTokenAndOwner() public view {
        assertEq(bridge.TOKEN(), address(token));
        assertEq(bridge.owner(), owner);
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(BridgeBase.InvalidTokenAddress.selector);
        new BaseBridge(address(0));
    }

    // ========================================================================
    // fundsIn
    // ========================================================================

    function test_fundsIn_transfersTokens() public {
        uint256 userBefore = token.balanceOf(user);

        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);

        assertEq(token.balanceOf(address(bridge)), AMOUNT);
        assertEq(token.balanceOf(user), userBefore - AMOUNT);
    }

    function test_fundsIn_emitsFundsIn() public {
        vm.expectEmit(true, false, false, true);
        emit FundsIn(user, OPERATION_ID, uint64(AMOUNT));

        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);
    }

    function test_fundsIn_operationIdIsNonIndexedEventData() public {
        bytes32 fundsInTopic = keccak256("FundsIn(address,uint256,uint64)");
        vm.recordLogs();
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(bridge) && logs[i].topics[0] == fundsInTopic) {
                assertEq(logs[i].topics.length, 2, "only signature and sender are indexed");
                assertEq(address(uint160(uint256(logs[i].topics[1]))), user, "sender topic");
                (uint256 operationId, uint64 amount) = abi.decode(logs[i].data, (uint256, uint64));
                assertEq(operationId, OPERATION_ID, "operation id is event data");
                assertEq(amount, AMOUNT, "amount is event data");
                return;
            }
        }
        fail("FundsIn event not found");
    }

    function test_fundsIn_acceptsUint64Maximum() public {
        uint256 amount = type(uint64).max;
        token.mint(user, amount);

        vm.expectEmit(true, false, false, true);
        emit FundsIn(user, OPERATION_ID, type(uint64).max);

        vm.prank(user);
        bridge.fundsIn(amount, OPERATION_ID);
    }

    function test_fundsIn_revertsAboveUint64WithoutPullingTokens() public {
        uint256 amount = uint256(type(uint64).max) + 1;
        token.mint(user, amount);
        uint256 userBefore = token.balanceOf(user);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.AmountExceedsUint64.selector, amount));
        vm.prank(user);
        bridge.fundsIn(amount, OPERATION_ID);

        assertEq(token.balanceOf(user), userBefore);
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    function test_fundsIn_anyUserCanCall() public {
        address stranger = makeAddr("stranger");
        token.mint(stranger, AMOUNT);
        vm.prank(stranger);
        token.approve(address(bridge), AMOUNT);

        vm.prank(stranger);
        bridge.fundsIn(AMOUNT, OPERATION_ID);

        assertEq(token.balanceOf(address(bridge)), AMOUNT);
    }

    function test_fundsIn_revertsWhenPaused() public {
        vm.prank(owner);
        bridge.pauseInflow();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);
    }

    // ========================================================================
    // fundsOut
    // ========================================================================

    function test_fundsOut_transfersAndEmits() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);

        vm.expectEmit(true, true, false, true);
        emit FundsOut(recipient, AMOUNT, OPERATION_ID, SRC_ADDR);

        vm.prank(owner);
        bridge.fundsOut(recipient, AMOUNT, OPERATION_ID, SRC_ADDR);

        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    function test_fundsOut_revertsIfNotOwner() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.fundsOut(recipient, AMOUNT, OPERATION_ID, SRC_ADDR);
    }

    function test_fundsOut_revertsOnZeroRecipient() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);

        vm.expectRevert(BridgeBase.InvalidRecipientAddress.selector);
        vm.prank(owner);
        bridge.fundsOut(address(0), AMOUNT, OPERATION_ID, SRC_ADDR);
    }

    function test_fundsOut_revertsIfAmountExceedsPool() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);

        vm.expectRevert(BridgeBase.AmountExceedBridgePool.selector);
        vm.prank(owner);
        bridge.fundsOut(recipient, AMOUNT + 1, OPERATION_ID, SRC_ADDR);
    }

    // ========================================================================
    // pause / unpause / renounceOwnership
    // ========================================================================

    function test_pause_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.pauseInflow();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(owner);
        bridge.pauseInflow();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.unpauseInflow();
    }

    function test_unpause_ownerCanUnpause() public {
        vm.prank(owner);
        bridge.pauseInflow();
        vm.prank(owner);
        bridge.unpauseInflow();

        // fundsIn works again
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);
        assertEq(token.balanceOf(address(bridge)), AMOUNT);
    }

    function test_renounceOwnership_alwaysReverts() public {
        vm.expectRevert(BridgeBase.RenounceOwnershipBlocked.selector);
        vm.prank(owner);
        bridge.renounceOwnership();
    }

    // ========================================================================
    // Two-tier pause (inflow vs outflow / emergency)
    // ========================================================================

    /// @dev With outflow frozen, fundsOut reverts. The whenOutflowNotPaused
    ///      modifier runs before the body, so a dummy
    ///      release is enough to exercise the gate.
    function test_fundsOut_revertsWhenOutflowPaused() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID); // seed the pool

        vm.prank(owner);
        bridge.emergencyPauseAll();

        vm.expectRevert(BridgeBase.OutflowEnforcedPause.selector);
        vm.prank(owner);
        bridge.fundsOut(recipient, AMOUNT, OPERATION_ID, SRC_ADDR);
    }

    /// @dev The planned inflow-only pause blocks deposits but leaves
    ///      withdrawals open — the core two-tier distinction (liquidity can be
    ///      migrated out while new deposits are frozen).
    function test_fundsOut_worksWhenOnlyInflowPaused() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID); // seed before freezing inflow

        vm.prank(owner);
        bridge.pauseInflow();

        // Deposits are frozen...
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);

        // ...but withdrawals still work.
        vm.prank(owner);
        bridge.fundsOut(recipient, AMOUNT, OPERATION_ID, SRC_ADDR);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    /// @dev Emergency pause freezes BOTH paths.
    function test_emergencyPauseAll_freezesBothPaths() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID); // seed the pool

        vm.prank(owner);
        bridge.emergencyPauseAll();

        assertTrue(bridge.paused(), "inflow frozen");
        assertTrue(bridge.outflowPaused(), "outflow frozen");

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);

        vm.expectRevert(BridgeBase.OutflowEnforcedPause.selector);
        vm.prank(owner);
        bridge.fundsOut(recipient, AMOUNT, OPERATION_ID, SRC_ADDR);
    }

    /// @dev Emergency unpause lifts BOTH freezes.
    function test_emergencyUnpauseAll_liftsBoth() public {
        vm.startPrank(owner);
        bridge.emergencyPauseAll();
        bridge.emergencyUnpauseAll();
        vm.stopPrank();

        assertFalse(bridge.paused(), "inflow resumed");
        assertFalse(bridge.outflowPaused(), "outflow resumed");

        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);
        assertEq(token.balanceOf(address(bridge)), AMOUNT);
    }

    /// @dev emergencyPauseAll must be idempotent per flag: it must not revert
    ///      if inflow is already frozen via the planned path.
    function test_emergencyPauseAll_idempotentWhenInflowAlreadyPaused() public {
        vm.startPrank(owner);
        bridge.pauseInflow(); // inflow already frozen
        bridge.emergencyPauseAll(); // must not revert on the already-set inflow flag
        vm.stopPrank();

        assertTrue(bridge.paused(), "inflow still frozen");
        assertTrue(bridge.outflowPaused(), "outflow now frozen");
    }

    function test_pauseInflow_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.pauseInflow();
    }

    function test_emergencyPauseAll_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.emergencyPauseAll();
    }

    function test_emergencyUnpauseAll_onlyOwner() public {
        vm.prank(owner);
        bridge.emergencyPauseAll();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.emergencyUnpauseAll();
    }

    function test_outflowPaused_defaultsFalse() public view {
        assertFalse(bridge.outflowPaused());
    }

    // ========================================================================
    // views
    // ========================================================================

    function test_getContractBalance() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID);

        assertEq(bridge.getContractBalance(), AMOUNT);
    }

    function test_getChainId() public view {
        assertEq(bridge.getChainId(), block.chainid);
    }

    // ========================================================================
    // Fuzz
    // ========================================================================

    function testFuzz_fundsIn_validAmount(uint64 amount) public {
        vm.assume(amount > 0);
        token.mint(user, amount);

        vm.prank(user);
        bridge.fundsIn(amount, OPERATION_ID);

        assertEq(token.balanceOf(address(bridge)), uint256(amount));
    }

    function testFuzz_fundsOut_anyAmountUpToPool(uint64 lockAmount, uint64 releaseAmount) public {
        vm.assume(lockAmount > 0);
        vm.assume(releaseAmount <= lockAmount);
        token.mint(user, lockAmount);

        vm.prank(user);
        bridge.fundsIn(lockAmount, OPERATION_ID);

        vm.prank(owner);
        bridge.fundsOut(recipient, releaseAmount, OPERATION_ID, SRC_ADDR);

        assertEq(token.balanceOf(recipient), uint256(releaseAmount));
        assertEq(token.balanceOf(address(bridge)), uint256(lockAmount) - uint256(releaseAmount));
    }
}
