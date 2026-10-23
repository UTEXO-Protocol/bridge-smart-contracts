// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {BridgeBase} from "../../src/BridgeBase.sol";
import {MinimalBridge} from "../../src/MinimalBridge.sol";
import {IArbSys} from "../../src/interfaces/IArbSys.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Minimal Bridge custody, owner authorization and independent flow pauses.
contract MinimalBridgeTest is Test {
    MinimalBridge internal bridge;

    MockERC20 internal token;

    address internal deployer = makeAddr("deployer");

    address internal user = makeAddr("user");

    address internal recipient = makeAddr("recipient");

    address internal owner = makeAddr("owner");

    string internal constant SRC_ADDR = "rgb:sender/utxo1src";

    uint256 internal constant AMOUNT = 1e18;

    uint256 internal constant OPERATION_ID = 42;

    uint64 internal constant AFTER_BLOCK = 1_000_000;

    uint256 internal constant L2_BLOCK = AFTER_BLOCK + 100_000;

    function setUp() public {
        token = new MockERC20("Mock Token", "MOCK");

        vm.prank(deployer);
        bridge = new MinimalBridge(address(token));

        // deployer hands ownership over to the integrator multisig
        vm.prank(deployer);
        bridge.transferOwnership(owner);

        // Ownable2Step: the new owner must accept before it takes effect.
        vm.prank(owner);
        bridge.acceptOwnership();

        token.mint(user, AMOUNT * 10);
        vm.prank(user);
        token.approve(address(bridge), type(uint256).max);

        _setL2Block(L2_BLOCK);
    }

    function _setL2Block(uint256 l2Block) internal {
        vm.mockCall(address(100), abi.encodeCall(IArbSys.arbBlockNumber, ()), abi.encode(l2Block));
    }

    function test_constructor_setsTokenAndOwner() public view {
        assertEq(bridge.TOKEN(), address(token));
        assertEq(bridge.owner(), owner);
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(BridgeBase.InvalidTokenAddress.selector);
        new MinimalBridge(address(0));
    }

    function test_fundsIn_transfersTokens() public {
        uint256 userBefore = token.balanceOf(user);

        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        assertEq(token.balanceOf(address(bridge)), AMOUNT);
        assertEq(token.balanceOf(user), userBefore - AMOUNT);
    }

    function test_fundsIn_recordsL2Block() public {
        bytes32 claimKey = bridge.rgbMintDepositId(OPERATION_ID, AMOUNT, AFTER_BLOCK);

        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        uint64 l2BlockPlusOne = bridge.fundsInRecords(claimKey);
        assertEq(l2BlockPlusOne, L2_BLOCK + 1);
    }

    function test_rgbMintDepositId_matchesCanonicalFormula() public view {
        bytes32 typehash = keccak256(
            "UtexoRgbMintDeposit(address bridge,uint256 chainId,address token,uint256 rgbOpId,uint256 amount,uint64 afterBlock)"
        );
        assertEq(bridge.RGB_MINT_DEPOSIT_TYPEHASH(), typehash);

        bytes32 expected = keccak256(
            abi.encode(typehash, address(bridge), block.chainid, address(token), OPERATION_ID, AMOUNT, AFTER_BLOCK)
        );

        assertEq(bridge.rgbMintDepositId(OPERATION_ID, AMOUNT, AFTER_BLOCK), expected);
    }

    function test_rgbMintDepositId_bindsAfterBlock() public view {
        bytes32 first = bridge.rgbMintDepositId(OPERATION_ID, AMOUNT, AFTER_BLOCK);
        bytes32 second = bridge.rgbMintDepositId(OPERATION_ID, AMOUNT, AFTER_BLOCK + 1);

        assertNotEq(first, second);
    }

    function test_fundsIn_acceptsWindowBoundaries() public {
        _setL2Block(AFTER_BLOCK);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        uint256 secondOperationId = OPERATION_ID + 1;
        uint256 upperBoundary = uint256(AFTER_BLOCK) + bridge.MAX_LOCK_BLOCKS();
        _setL2Block(upperBoundary);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, secondOperationId, AFTER_BLOCK);

        bytes32 firstKey = bridge.rgbMintDepositId(OPERATION_ID, AMOUNT, AFTER_BLOCK);
        bytes32 secondKey = bridge.rgbMintDepositId(secondOperationId, AMOUNT, AFTER_BLOCK);
        uint64 firstBlockPlusOne = bridge.fundsInRecords(firstKey);
        uint64 secondBlockPlusOne = bridge.fundsInRecords(secondKey);
        assertEq(firstBlockPlusOne, uint256(AFTER_BLOCK) + 1);
        assertEq(secondBlockPlusOne, upperBoundary + 1);
    }

    function test_fundsIn_revertsBeforeAfterBlockWithoutPullingTokens() public {
        uint256 l2Block = uint256(AFTER_BLOCK) - 1;
        _setL2Block(l2Block);

        vm.expectRevert(abi.encodeWithSelector(MinimalBridge.LockWindowNotStarted.selector, l2Block, AFTER_BLOCK));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        assertEq(token.balanceOf(address(bridge)), 0);
    }

    function test_fundsIn_revertsAfterLockWindowWithoutPullingTokens() public {
        uint256 l2Block = uint256(AFTER_BLOCK) + bridge.MAX_LOCK_BLOCKS() + 1;
        _setL2Block(l2Block);

        vm.expectRevert(abi.encodeWithSelector(MinimalBridge.LockWindowExpired.selector, l2Block, AFTER_BLOCK));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        assertEq(token.balanceOf(address(bridge)), 0);
    }

    function test_fundsIn_revertsDuplicateClaimWithoutPullingMoreTokens() public {
        bytes32 claimKey = bridge.rgbMintDepositId(OPERATION_ID, AMOUNT, AFTER_BLOCK);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        uint256 bridgeBalance = token.balanceOf(address(bridge));
        vm.expectRevert(abi.encodeWithSelector(MinimalBridge.DuplicateMintDeposit.selector, claimKey));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        assertEq(token.balanceOf(address(bridge)), bridgeBalance);
    }

    function test_fundsIn_failedTransferRollsBackRecord() public {
        bytes32 claimKey = bridge.rgbMintDepositId(OPERATION_ID, AMOUNT, AFTER_BLOCK);
        vm.prank(user);
        token.approve(address(bridge), 0);

        vm.expectRevert();
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        assertEq(bridge.fundsInRecords(claimKey), 0);
    }

    function test_fundsIn_revertsWhenL2BlockCannotFitRecord() public {
        uint256 l2Block = type(uint64).max;
        uint64 afterBlock = type(uint64).max - 1;
        _setL2Block(l2Block);

        vm.expectRevert(abi.encodeWithSelector(MinimalBridge.L2BlockNumberExceedsUint64.selector, l2Block));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, afterBlock);
    }

    function test_fundsIn_revertsZeroOperationId() public {
        vm.expectRevert(MinimalBridge.InvalidOperationId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, 0, AFTER_BLOCK);
    }

    function test_getFundsInBlock_returnsExistingAndMissingClaims() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        assertEq(bridge.getFundsInBlock(OPERATION_ID, AMOUNT, AFTER_BLOCK), L2_BLOCK + 1);
        assertEq(bridge.getFundsInBlock(OPERATION_ID + 1, AMOUNT, AFTER_BLOCK), 0);
        assertEq(bridge.getFundsInBlock(OPERATION_ID, AMOUNT + 1, AFTER_BLOCK), 0);
        assertEq(bridge.getFundsInBlock(OPERATION_ID, AMOUNT, AFTER_BLOCK + 1), 0);
    }

    function test_fundsIn_emitsFundsIn() public {
        vm.expectEmit(true, true, false, true, address(bridge));
        emit MinimalBridge.FundsIn(user, OPERATION_ID, uint64(AMOUNT));

        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);
    }

    function test_fundsIn_operationIdIsIndexedTopic() public {
        bytes32 fundsInTopic = keccak256("FundsIn(address,uint256,uint64)");
        vm.recordLogs();
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(bridge) && logs[i].topics[0] == fundsInTopic) {
                assertEq(logs[i].topics.length, 3, "signature, sender and operation id are indexed");
                assertEq(address(uint160(uint256(logs[i].topics[1]))), user, "sender topic");
                assertEq(uint256(logs[i].topics[2]), OPERATION_ID, "operation id topic");
                assertEq(logs[i].data.length, 32, "only amount is event data");
                assertEq(abi.decode(logs[i].data, (uint64)), AMOUNT, "amount is event data");
                return;
            }
        }
        fail("FundsIn event not found");
    }

    function test_fundsIn_acceptsUint64Maximum() public {
        uint256 amount = type(uint64).max;
        token.mint(user, amount);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit MinimalBridge.FundsIn(user, OPERATION_ID, type(uint64).max);

        vm.prank(user);
        bridge.fundsIn(amount, OPERATION_ID, AFTER_BLOCK);
    }

    function test_fundsIn_revertsAboveUint64WithoutPullingTokens() public {
        uint256 amount = uint256(type(uint64).max) + 1;
        token.mint(user, amount);
        uint256 userBefore = token.balanceOf(user);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.AmountExceedsUint64.selector, amount));
        vm.prank(user);
        bridge.fundsIn(amount, OPERATION_ID, AFTER_BLOCK);

        assertEq(token.balanceOf(user), userBefore);
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    function test_fundsIn_anyUserCanCall() public {
        address stranger = makeAddr("stranger");
        token.mint(stranger, AMOUNT);
        vm.prank(stranger);
        token.approve(address(bridge), AMOUNT);

        vm.prank(stranger);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        assertEq(token.balanceOf(address(bridge)), AMOUNT);
    }

    function test_fundsIn_revertsWhenPaused() public {
        vm.prank(owner);
        bridge.pauseInflow();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);
    }

    function test_fundsOut_transfersAndEmits() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit MinimalBridge.FundsOut(recipient, AMOUNT, OPERATION_ID, SRC_ADDR);

        vm.prank(owner);
        bridge.fundsOut(recipient, AMOUNT, OPERATION_ID, SRC_ADDR);

        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    function test_fundsOut_revertsForNonOwner() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.fundsOut(recipient, AMOUNT, OPERATION_ID, SRC_ADDR);
    }

    function test_fundsOut_revertsOnZeroRecipient() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        vm.expectRevert(BridgeBase.InvalidRecipientAddress.selector);
        vm.prank(owner);
        bridge.fundsOut(address(0), AMOUNT, OPERATION_ID, SRC_ADDR);
    }

    function test_fundsOut_revertsIfAmountExceedsPool() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        vm.expectRevert(BridgeBase.AmountExceedBridgePool.selector);
        vm.prank(owner);
        bridge.fundsOut(recipient, AMOUNT + 1, OPERATION_ID, SRC_ADDR);
    }

    function test_unpauseInflow_revertsForNonOwner() public {
        vm.prank(owner);
        bridge.pauseInflow();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.unpauseInflow();
    }

    function test_unpauseInflow_resumesDepositsForOwner() public {
        vm.prank(owner);
        bridge.pauseInflow();
        vm.prank(owner);
        bridge.unpauseInflow();

        // fundsIn works again
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);
        assertEq(token.balanceOf(address(bridge)), AMOUNT);
    }

    function test_renounceOwnership_alwaysReverts() public {
        vm.expectRevert(BridgeBase.RenounceOwnershipBlocked.selector);
        vm.prank(owner);
        bridge.renounceOwnership();
    }

    /// @dev A funded, otherwise-valid release is rejected by the outflow
    ///      pause modifier before the release body runs.
    function test_fundsOut_revertsWhenOutflowPaused() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK); // seed the pool

        vm.prank(owner);
        bridge.emergencyPauseAll();

        vm.expectRevert(BridgeBase.OutflowEnforcedPause.selector);
        vm.prank(owner);
        bridge.fundsOut(recipient, AMOUNT, OPERATION_ID, SRC_ADDR);
    }

    /// @dev The planned inflow-only pause blocks deposits but leaves
    ///      withdrawals open — the core two-tier distinction (liquidity can be
    ///      migrated out while new deposits are frozen).
    function test_fundsOut_succeedsWhenOnlyInflowPaused() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK); // seed before freezing inflow

        vm.prank(owner);
        bridge.pauseInflow();

        // Deposits are frozen...
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        // ...but withdrawals still work.
        vm.prank(owner);
        bridge.fundsOut(recipient, AMOUNT, OPERATION_ID, SRC_ADDR);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    /// @dev Emergency pause freezes BOTH paths.
    function test_emergencyPauseAll_freezesBothPaths() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK); // seed the pool

        vm.prank(owner);
        bridge.emergencyPauseAll();

        assertTrue(bridge.paused(), "inflow frozen");
        assertTrue(bridge.outflowPaused(), "outflow frozen");

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

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
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);
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

    function test_pauseInflow_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.pauseInflow();
    }

    function test_emergencyPauseAll_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.emergencyPauseAll();
    }

    function test_emergencyUnpauseAll_revertsForNonOwner() public {
        vm.prank(owner);
        bridge.emergencyPauseAll();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.emergencyUnpauseAll();
    }

    function test_outflowPaused_defaultsFalse() public view {
        assertFalse(bridge.outflowPaused());
    }

    function test_getContractBalance_returnsCustodiedBalance() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, OPERATION_ID, AFTER_BLOCK);

        assertEq(bridge.getContractBalance(), AMOUNT);
    }

    function test_getChainId_returnsCurrentChain() public view {
        assertEq(bridge.getChainId(), block.chainid);
    }

    function testFuzz_fundsIn_creditsDepositedAmount(uint64 amount) public {
        token.mint(user, amount);

        vm.prank(user);
        bridge.fundsIn(amount, OPERATION_ID, AFTER_BLOCK);

        assertEq(token.balanceOf(address(bridge)), uint256(amount));
    }

    function testFuzz_fundsOut_anyAmountUpToPool(uint64 lockAmount, uint64 releaseAmount) public {
        lockAmount = uint64(bound(uint256(lockAmount), 0, type(uint64).max));
        releaseAmount = uint64(bound(uint256(releaseAmount), 0, lockAmount));
        token.mint(user, lockAmount);

        vm.prank(user);
        bridge.fundsIn(lockAmount, OPERATION_ID, AFTER_BLOCK);

        vm.prank(owner);
        bridge.fundsOut(recipient, releaseAmount, OPERATION_ID, SRC_ADDR);

        assertEq(token.balanceOf(recipient), uint256(releaseAmount));
        assertEq(token.balanceOf(address(bridge)), uint256(lockAmount) - uint256(releaseAmount));
    }

    function test_emergencyUnpauseAll_resumesPlannedInflowPauseAndIsIdempotent() public {
        vm.startPrank(owner);
        bridge.pauseInflow();
        assertFalse(bridge.outflowPaused(), "planned pause leaves outflow open");
        bridge.emergencyUnpauseAll();
        assertFalse(bridge.paused(), "emergency unpause resumes inflow");
        assertFalse(bridge.outflowPaused(), "outflow stays open");
        vm.recordLogs();
        bridge.emergencyUnpauseAll();
        assertEq(vm.getRecordedLogs().length, 0, "repeated unpause emits no transitions");
        vm.stopPrank();
    }
}
