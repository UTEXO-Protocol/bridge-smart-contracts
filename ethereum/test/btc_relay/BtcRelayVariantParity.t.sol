// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {BtcRelay} from "../../src/btc_relay/BtcRelay.sol";
import {BtcRelayTestnet} from "../../src/btc_relay/BtcRelayTestnet.sol";
import {StoredBlockHeader as MainnetStoredBlockHeader} from "../../src/btc_relay/structs/StoredBlockHeader.sol";
import {StoredBlockHeader as TestnetStoredBlockHeader} from "../../src/btc_relay/structs/StoredBlockHeaderTestnet.sol";
import {Endianness} from "../../src/btc_relay/btc_utils/Endianness.sol";

library RelayFixture {
    uint32 internal constant CHECKPOINT_TIME = 1_700_000_000;

    function storedBlob(uint32 height, uint256 chainWork) internal pure returns (bytes memory stored) {
        bytes memory header = abi.encodePacked(
            le32(0x20000000),
            bytes32(uint256(0x1111)),
            bytes32(uint256(0x2222)),
            le32(CHECKPOINT_TIME),
            bytes4(hex"ffff001d"),
            le32(42)
        );
        stored = abi.encodePacked(
            header, bytes32(chainWork), bytes4(height), bytes4(uint32(1_699_000_000)), bytes32(0), bytes8(0)
        );
        assert(stored.length == 160);
    }

    function compact(uint32 timestamp) internal pure returns (bytes memory result) {
        result = abi.encodePacked(
            le32(0x20000000), bytes32(uint256(0x3333)), le32(timestamp), bytes4(hex"ffff001d"), le32(7)
        );
        assert(result.length == 48);
    }

    function mainnetHeader(bytes memory stored) internal pure returns (MainnetStoredBlockHeader memory checkpoint) {
        assembly ("memory-safe") {
            let dst := mload(checkpoint)
            for { let i := 0 } lt(i, 5) { i := add(i, 1) } {
                mstore(add(dst, mul(i, 32)), mload(add(add(stored, 32), mul(i, 32))))
            }
        }
    }

    function testnetHeader(bytes memory stored) internal pure returns (TestnetStoredBlockHeader memory checkpoint) {
        assembly ("memory-safe") {
            let dst := mload(checkpoint)
            for { let i := 0 } lt(i, 5) { i := add(i, 1) } {
                mstore(add(dst, mul(i, 32)), mload(add(add(stored, 32), mul(i, 32))))
            }
        }
    }

    function le32(uint32 value) internal pure returns (bytes4) {
        return bytes4(Endianness.reverseUint32(value));
    }
}

contract BtcRelayHarness is BtcRelay {
    constructor(MainnetStoredBlockHeader memory checkpoint) BtcRelay(checkpoint, true) {}

    function seedMainState(uint32 tipHeight, uint224 chainWork, uint256 staleHeight, bytes32 staleCommit) external {
        _relayState.blockHeight = tipHeight;
        _relayState.chainWork = chainWork;
        _mainChain[staleHeight] = staleCommit;
    }

    function seedFork(
        address owner,
        uint256 forkId,
        uint32 startHeight,
        uint32 tipHeight,
        bytes32 rootCommit,
        bytes32 tipCommit
    ) external {
        _forks[owner][forkId].startHeight = startHeight;
        _forks[owner][forkId].tipHeight = tipHeight;
        _forks[owner][forkId].chain[uint256(startHeight) - 1] = rootCommit;
        _forks[owner][forkId].chain[tipHeight] = tipCommit;
    }
}

contract BtcRelayMainnetStateGuardTest is Test {
    uint256 internal constant TARGET = 0x00000000FFFF0000000000000000000000000000000000000000000000000000;
    uint32 internal constant NEW_BLOCK_TIME = RelayFixture.CHECKPOINT_TIME + 60;
    address internal constant FORK_SUBMITTER = address(0xA77ACC);

    BtcRelayHarness internal relay;

    function setUp() public {
        relay = new BtcRelayHarness(RelayFixture.mainnetHeader(RelayFixture.storedBlob(1000, 0)));
        vm.warp(NEW_BLOCK_TIME + 1);
    }

    function test_getCommitHashHidesStaleMainnetCommitmentAboveTip() public {
        bytes32 staleCommit = keccak256("stale-mainnet-commit");
        relay.seedMainState(1001, 100, 1002, staleCommit);

        assertEq(relay.getCommitHash(1002), bytes32(0));
    }

    function test_rejectsMainnetForkPromotionWhenRootIsAboveTip() public {
        bytes memory storedTip = RelayFixture.storedBlob(1003, 101);
        bytes32 rootCommit = keccak256("stale-mainnet-root");
        relay.seedMainState(1001, 100, 1002, rootCommit);
        relay.seedFork(FORK_SUBMITTER, 1, 1003, 1003, rootCommit, keccak256(storedTip));

        bytes32 digest = Endianness.reverseBytes32(bytes32(TARGET - 1));
        vm.mockCall(address(0x02), bytes(""), abi.encode(digest));
        vm.expectRevert(bytes("fork: root above tip"));
        vm.prank(FORK_SUBMITTER);
        relay.submitForkBlockheaders(1, abi.encodePacked(storedTip, RelayFixture.compact(NEW_BLOCK_TIME)));

        assertEq(relay.getBlockheight(), 1001);
        assertEq(relay.getChainwork(), 100);
    }
}

contract BtcRelayTestnetPoWBoundaryTest is Test {
    uint256 internal constant TARGET = 0x00000000FFFF0000000000000000000000000000000000000000000000000000;
    uint32 internal constant CHECKPOINT_HEIGHT = 850_000;
    uint32 internal constant NEW_BLOCK_TIME = RelayFixture.CHECKPOINT_TIME + 60;

    BtcRelayTestnet internal relay;
    bytes internal storedCheckpoint;

    function setUp() public {
        storedCheckpoint = RelayFixture.storedBlob(CHECKPOINT_HEIGHT, 0);
        relay = new BtcRelayTestnet(RelayFixture.testnetHeader(storedCheckpoint), true);
        vm.warp(NEW_BLOCK_TIME + 1);
    }

    function test_testnetAcceptsHashEqualToTarget() public {
        bytes32 digest = Endianness.reverseBytes32(bytes32(TARGET));
        vm.mockCall(address(0x02), bytes(""), abi.encode(digest));

        relay.submitMainBlockheaders(abi.encodePacked(storedCheckpoint, RelayFixture.compact(NEW_BLOCK_TIME)));

        assertEq(relay.getBlockheight(), CHECKPOINT_HEIGHT + 1);
    }

    function test_testnetRejectsHashAboveTarget() public {
        bytes32 digest = Endianness.reverseBytes32(bytes32(TARGET + 1));
        vm.mockCall(address(0x02), bytes(""), abi.encode(digest));
        vm.expectRevert(bytes("updateChain: invalid PoW"));

        relay.submitMainBlockheaders(abi.encodePacked(storedCheckpoint, RelayFixture.compact(NEW_BLOCK_TIME)));
    }
}
