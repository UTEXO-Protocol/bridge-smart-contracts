// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {BtcRelay} from "../src/btc_relay/BtcRelay.sol";
import {BtcRelayTestnet} from "../src/btc_relay/BtcRelayTestnet.sol";
import {StoredBlockHeader as MainnetStoredBlockHeader} from "../src/btc_relay/structs/StoredBlockHeader.sol";
import {StoredBlockHeader as TestnetStoredBlockHeader} from "../src/btc_relay/structs/StoredBlockHeaderTestnet.sol";
import {RGBVerifier} from "../src/verifiers/RGBVerifier.sol";
import {MockBtcRelay} from "./mocks/MockBtcRelay.sol";
import {FundsOutContext} from "../src/interfaces/RouteTypes.sol";

contract BtcRelayCheckpointTest is Test {
    uint32 internal constant CHECKPOINT_HEIGHT = 850_000;
    uint32 internal constant BELOW_CHECKPOINT_HEIGHT = 849_000;

    BtcRelay internal relay;
    RGBVerifier internal verifier;
    bytes32 internal checkpointCommitment;

    function setUp() public {
        relay = new BtcRelay(_headerAtHeight(CHECKPOINT_HEIGHT), true);
        checkpointCommitment = relay.getTipCommitHash();
        verifier = new RGBVerifier(address(relay), 6, 1, 5);
    }

    function test_verifyBlockheaderHash_rejectsZeroCommitmentBelowCheckpoint() public {
        assertEq(relay.getCommitHash(BELOW_CHECKPOINT_HEIGHT), bytes32(0));

        vm.expectRevert(bytes("verify: before checkpoint"));
        relay.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, bytes32(0));
    }

    function test_verifyBlockheaderHash_rejectsNonZeroCommitmentBelowCheckpoint() public {
        vm.expectRevert(bytes("verify: before checkpoint"));
        relay.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, keccak256("phantom-block"));
    }

    function test_verifyBlockheaderHash_rejectsZeroCommitmentAtCheckpoint() public {
        vm.expectRevert(bytes("verify: zero commitment"));
        relay.verifyBlockheaderHash(CHECKPOINT_HEIGHT, bytes32(0));
    }

    function test_verifyBlockheaderHash_acceptsStoredCheckpointCommitment() public view {
        assertTrue(checkpointCommitment != bytes32(0));
        assertEq(relay.verifyBlockheaderHash(CHECKPOINT_HEIGHT, checkpointCommitment), 1);
    }

    function test_verifyBlockheaderHash_preservesFutureHeightRevert() public {
        vm.expectRevert(bytes("verify: future block"));
        relay.verifyBlockheaderHash(CHECKPOINT_HEIGHT + 1, bytes32(0));
    }

    function test_rgbVerifier_rejectsPhantomSourceBelowCheckpoint() public {
        bytes memory proof = abi.encode(BELOW_CHECKPOINT_HEIGHT, bytes32(0), CHECKPOINT_HEIGHT, checkpointCommitment);
        FundsOutContext memory context;

        vm.expectRevert(bytes("verify: before checkpoint"));
        verifier.verify(context, proof);
    }

    function _headerAtHeight(uint32 height) private pure returns (MainnetStoredBlockHeader memory header) {
        // blockHeight() reads a big-endian uint32 at byte offset 112, i.e.
        // bytes 16..19 of data[3].
        header.data[3] = bytes32(uint256(height) << 96);
    }
}

contract BtcRelayTestnetCheckpointTest is Test {
    uint32 internal constant CHECKPOINT_HEIGHT = 2_500_000;
    uint32 internal constant BELOW_CHECKPOINT_HEIGHT = 2_499_000;

    BtcRelayTestnet internal relay;
    bytes32 internal checkpointCommitment;

    function setUp() public {
        relay = new BtcRelayTestnet(_headerAtHeight(CHECKPOINT_HEIGHT), true);
        checkpointCommitment = relay.getTipCommitHash();
    }

    function test_verifyBlockheaderHash_rejectsZeroCommitmentBelowCheckpoint() public {
        assertEq(relay.getCommitHash(BELOW_CHECKPOINT_HEIGHT), bytes32(0));

        vm.expectRevert(bytes("verify: before checkpoint"));
        relay.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, bytes32(0));
    }

    function test_verifyBlockheaderHash_rejectsZeroCommitmentAtCheckpoint() public {
        vm.expectRevert(bytes("verify: zero commitment"));
        relay.verifyBlockheaderHash(CHECKPOINT_HEIGHT, bytes32(0));
    }

    function test_verifyBlockheaderHash_acceptsStoredCheckpointCommitment() public view {
        assertTrue(checkpointCommitment != bytes32(0));
        assertEq(relay.verifyBlockheaderHash(CHECKPOINT_HEIGHT, checkpointCommitment), 1);
    }

    function test_verifyBlockheaderHash_preservesFutureHeightRevert() public {
        vm.expectRevert(bytes("verify: future block"));
        relay.verifyBlockheaderHash(CHECKPOINT_HEIGHT + 1, bytes32(0));
    }

    function _headerAtHeight(uint32 height) private pure returns (TestnetStoredBlockHeader memory header) {
        header.data[3] = bytes32(uint256(height) << 96);
    }
}

/// @notice `MockBtcRelay` stands in for the relay across the Bridge, MultisigProxy
///         and RGBVerifier suites. It must reject exactly what the real relay
///         rejects, otherwise an integration test could accept a proof the
///         deployed relay would refuse.
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

    /// Contrast: with no checkpoint configured (the previous mock behaviour) a
    /// block registered below the real relay's checkpoint is served happily.
    /// Setting the checkpoint is what closes that divergence.
    function test_withoutCheckpointBelowHeightIsServed() public {
        MockBtcRelay fresh = new MockBtcRelay();
        assertEq(fresh.checkpointHeight(), 0, "default keeps the pre-existing behaviour");

        bytes32 belowCommit = keccak256("registered-below-checkpoint");
        fresh.setBlock(BELOW_CHECKPOINT_HEIGHT, belowCommit, 1000);
        assertEq(
            fresh.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, belowCommit),
            1000,
            "un-checkpointed mock serves a height the real relay rejects"
        );

        fresh.setCheckpointHeight(CHECKPOINT_HEIGHT);
        vm.expectRevert(bytes("verify: before checkpoint"));
        fresh.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, belowCommit);
    }

    function test_rejectsZeroCommitmentBelowCheckpoint() public {
        vm.expectRevert(bytes("verify: before checkpoint"));
        relay.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, bytes32(0));
    }

    /// The divergence that actually mattered: before the checkpoint existed the
    /// mock happily served a block registered below it, which the real relay
    /// rejects outright. A suite could therefore green-light a proof the
    /// deployed relay would refuse.
    function test_rejectsRegisteredBlockBelowCheckpoint() public {
        bytes32 belowCommit = keccak256("registered-below-checkpoint");
        relay.setBlock(BELOW_CHECKPOINT_HEIGHT, belowCommit, 1000);

        vm.expectRevert(bytes("verify: before checkpoint"));
        relay.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, belowCommit);
    }

    function test_rejectsUnregisteredCommitmentBelowCheckpoint() public {
        vm.expectRevert(bytes("verify: before checkpoint"));
        relay.verifyBlockheaderHash(BELOW_CHECKPOINT_HEIGHT, keccak256("phantom-block"));
    }

    function test_rejectsZeroCommitmentAtRegisteredHeight() public {
        vm.expectRevert(bytes("verify: zero commitment"));
        relay.verifyBlockheaderHash(CHECKPOINT_HEIGHT, bytes32(0));
    }

    function test_preservesUnknownBlockRevert() public {
        vm.expectRevert(bytes("verify: block commitment"));
        relay.verifyBlockheaderHash(LATEST_HEIGHT + 999, keccak256("unknown"));
    }

    function test_acceptsRegisteredBlock() public view {
        assertEq(relay.verifyBlockheaderHash(CHECKPOINT_HEIGHT, SOURCE_COMMIT), 6);
    }

    /// The exact proof shape from the audit finding, driven through the mock the
    /// integration suites use.
    function test_rgbVerifier_rejectsPhantomSourceOverMock() public {
        bytes memory proof = abi.encode(BELOW_CHECKPOINT_HEIGHT, bytes32(0), LATEST_HEIGHT, LATEST_COMMIT);
        FundsOutContext memory context;

        vm.expectRevert(bytes("verify: before checkpoint"));
        verifier.verify(context, proof);
    }
}
