// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {FundsOutContext} from "../../src/interfaces/RouteTypes.sol";
import {RGBVerifier} from "../../src/verifiers/RGBVerifier.sol";
import {MockBtcRelay} from "../mocks/MockBtcRelay.sol";

/// @notice Mock checkpoint queries preserve the deployed relay’s below-checkpoint rejection.
contract MockBtcRelayCheckpointTest is Test {
    uint256 internal constant CHECKPOINT_HEIGHT = 850_000;

    uint256 internal constant BELOW_CHECKPOINT_HEIGHT = 849_000;

    uint256 internal constant LATEST_HEIGHT = 850_005;

    bytes32 internal constant SOURCE_COMMIT = keccak256("mock-source-block");

    bytes32 internal constant LATEST_COMMIT = keccak256("mock-latest-block");

    MockBtcRelay internal relay;

    RGBVerifier internal verifier;

    function setUp() public {
        relay = new MockBtcRelay();
        relay.setCheckpointHeight(CHECKPOINT_HEIGHT);
        relay.setBlock(CHECKPOINT_HEIGHT, SOURCE_COMMIT, 6);
        relay.setBlock(LATEST_HEIGHT, LATEST_COMMIT, 1);
        verifier = new RGBVerifier(address(relay), 6, 1, 5);
    }

    /// @notice With no checkpoint, a registered height is accepted; configuring
    ///         a higher checkpoint makes the same query fail.
    function test_verifyBlockheaderHash_acceptsRegisteredHeightUntilCheckpointIsConfigured() public {
        MockBtcRelay fresh = new MockBtcRelay();
        assertEq(fresh.checkpointHeight(), 0, "default checkpoint is zero");

        bytes32 belowCommit = keccak256("registered-below-checkpoint");
        fresh.setBlock(BELOW_CHECKPOINT_HEIGHT, belowCommit, 1000);
        assertEq(
            fresh.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, belowCommit),
            1000,
            "unconfigured checkpoint permits this registered height"
        );

        fresh.setCheckpointHeight(CHECKPOINT_HEIGHT);
        vm.expectRevert(bytes("verify: before checkpoint"));
        fresh.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, belowCommit);
    }

    function test_verifyBlockheaderHash_rejectsZeroCommitmentBelowCheckpoint() public {
        vm.expectRevert(bytes("verify: before checkpoint"));
        relay.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, bytes32(0));
    }

    /// @notice Registered blocks below the checkpoint fail regardless of confirmations.
    function test_verifyBlockheaderHash_rejectsRegisteredBlockBelowCheckpoint() public {
        bytes32 belowCommit = keccak256("registered-below-checkpoint");
        relay.setBlock(BELOW_CHECKPOINT_HEIGHT, belowCommit, 1000);

        vm.expectRevert(bytes("verify: before checkpoint"));
        relay.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, belowCommit);
    }

    function test_verifyBlockheaderHash_rejectsUnregisteredCommitmentBelowCheckpoint() public {
        vm.expectRevert(bytes("verify: before checkpoint"));
        relay.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, keccak256("phantom-block"));
    }

    function test_verifyBlockheaderHash_rejectsZeroCommitmentAtRegisteredHeight() public {
        vm.expectRevert(bytes("verify: zero commitment"));
        relay.verifyBlockheaderHash(CHECKPOINT_HEIGHT, bytes32(0));
    }

    function test_verifyBlockheaderHash_rejectsUnknownCommitment() public {
        vm.expectRevert(bytes("verify: block commitment"));
        relay.verifyBlockheaderHash(LATEST_HEIGHT + 999, keccak256("unknown"));
    }

    function test_verifyBlockheaderHash_acceptsRegisteredBlock() public view {
        assertEq(relay.verifyBlockheaderHash(CHECKPOINT_HEIGHT, SOURCE_COMMIT), 6);
    }

    /// @notice A zero-commitment source below the checkpoint fails relay validation.
    function test_rgbVerifier_rejectsPhantomSourceOverMock() public {
        bytes memory proof = abi.encode(BELOW_CHECKPOINT_HEIGHT, bytes32(0), LATEST_HEIGHT, LATEST_COMMIT);
        FundsOutContext memory context;

        vm.expectRevert(bytes("verify: before checkpoint"));
        verifier.verify(context, proof);
    }
}
