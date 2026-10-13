// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {BtcRelayTestnet} from "../../src/btc_relay/BtcRelayTestnet.sol";
import {StoredBlockHeader as TestnetStoredBlockHeader} from "../../src/btc_relay/structs/StoredBlockHeaderTestnet.sol";

/// @notice Testnet relay applies the same below-checkpoint query rejection.
contract BtcRelayTestnetCheckpointTest is Test {
    uint32 internal constant CHECKPOINT_HEIGHT = 2_500_000;

    uint32 internal constant BELOW_CHECKPOINT_HEIGHT = 2_499_000;

    BtcRelayTestnet internal relay;

    bytes32 internal checkpointCommitment;

    function setUp() public {
        relay = new BtcRelayTestnet(_headerAtHeight(CHECKPOINT_HEIGHT), true);
        checkpointCommitment = relay.getTipCommitHash();
    }

    function _headerAtHeight(uint32 height) private pure returns (TestnetStoredBlockHeader memory header) {
        header.data[3] = bytes32(uint256(height) << 96);
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
}
