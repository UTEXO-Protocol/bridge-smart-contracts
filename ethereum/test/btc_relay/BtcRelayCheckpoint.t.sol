// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {BtcRelay} from "../../src/btc_relay/BtcRelay.sol";
import {StoredBlockHeader as MainnetStoredBlockHeader} from "../../src/btc_relay/structs/StoredBlockHeader.sol";
import {FundsOutContext} from "../../src/interfaces/RouteTypes.sol";
import {RGBVerifier} from "../../src/verifiers/RGBVerifier.sol";

/// @notice Production relay checkpoint and block-header query validation.
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

    function _headerAtHeight(uint32 height) private pure returns (MainnetStoredBlockHeader memory header) {
        // blockHeight() reads a big-endian uint32 at byte offset 112, i.e.
        // bytes 16..19 of data[3].
        header.data[3] = bytes32(uint256(height) << 96);
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
}

