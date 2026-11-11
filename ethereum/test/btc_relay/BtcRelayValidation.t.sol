// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {BtcRelay} from "../../src/btc_relay/BtcRelay.sol";
import {BtcRelayTestnet} from "../../src/btc_relay/BtcRelayTestnet.sol";
import {StoredBlockHeader as MainnetStoredBlockHeader} from "../../src/btc_relay/structs/StoredBlockHeader.sol";
import {StoredBlockHeader as TestnetStoredBlockHeader} from "../../src/btc_relay/structs/StoredBlockHeaderTestnet.sol";
import {Endianness} from "../../src/btc_relay/btc_utils/Endianness.sol";
import {Difficulty} from "../../src/btc_relay/utils/Difficulty.sol";
import {TARGET_TIMESPAN_DIV_4} from "../../src/btc_relay/Constants.sol";

contract DifficultyHarness {
    function computeNewTarget(uint32 prevTimestamp, uint32 startTimestamp, uint32 prevNbitsLE)
        external
        pure
        returns (uint256 newTarget, uint32 newNbitsLE)
    {
        return Difficulty.computeNewTarget(prevTimestamp, startTimestamp, prevNbitsLE, false);
    }
}

contract BtcRelayValidationTest is Test {
    BtcRelay internal mainnetRelay;
    BtcRelayTestnet internal testnetRelay;
    DifficultyHarness internal difficultyHarness;

    function setUp() public {
        MainnetStoredBlockHeader memory mainnetHeader;
        TestnetStoredBlockHeader memory testnetHeader;
        mainnetRelay = new BtcRelay(mainnetHeader, true);
        testnetRelay = new BtcRelayTestnet(testnetHeader, true);
        difficultyHarness = new DifficultyHarness();
    }

    function test_mainnetRejectsPartialMainBatch() public {
        vm.expectRevert(bytes("submitMain: bad length"));
        mainnetRelay.submitMainBlockheaders(new bytes(209));
    }

    function test_mainnetRejectsPartialShortForkBatch() public {
        vm.expectRevert(bytes("shortFork: bad length"));
        mainnetRelay.submitShortForkBlockheaders(new bytes(209));
    }

    function test_mainnetRejectsPartialForkBatch() public {
        vm.expectRevert(bytes("fork: bad length"));
        mainnetRelay.submitForkBlockheaders(1, new bytes(209));
    }

    function test_testnetRejectsPartialMainBatch() public {
        vm.expectRevert(bytes("submitMain: bad length"));
        testnetRelay.submitMainBlockheaders(new bytes(209));
    }

    function test_testnetRejectsPartialShortForkBatch() public {
        vm.expectRevert(bytes("shortFork: bad length"));
        testnetRelay.submitShortForkBlockheaders(new bytes(209));
    }

    function test_testnetRejectsPartialForkBatch() public {
        vm.expectRevert(bytes("fork: bad length"));
        testnetRelay.submitForkBlockheaders(1, new bytes(209));
    }

    function test_negativeRetargetTimespanUsesMinimumTimespan() public view {
        uint32 prevNbitsLE = 0xffff7f20;
        (uint256 negativeTarget, uint32 negativeNbits) = difficultyHarness.computeNewTarget(100, 101, prevNbitsLE);
        (uint256 minimumTarget, uint32 minimumNbits) =
            difficultyHarness.computeNewTarget(uint32(TARGET_TIMESPAN_DIV_4 + 100), 100, prevNbitsLE);

        assertEq(negativeTarget, minimumTarget);
        assertEq(negativeNbits, minimumNbits);
    }
}

contract BtcRelayPoWBoundaryTest is Test {
    uint256 internal constant TARGET = 0x00000000FFFF0000000000000000000000000000000000000000000000000000;
    uint32 internal constant CHECKPOINT_HEIGHT = 850_000;
    uint32 internal constant CHECKPOINT_TIME = 1_700_000_000;
    uint32 internal constant NEW_BLOCK_TIME = 1_700_005_000;

    BtcRelay internal relay;

    function setUp() public {
        relay = new BtcRelay(_checkpoint(), true);
        vm.warp(NEW_BLOCK_TIME + 1);
    }

    function test_acceptsHashEqualToTarget() public {
        bytes32 digest = Endianness.reverseBytes32(bytes32(TARGET));
        vm.mockCall(address(0x02), bytes(""), abi.encode(digest));

        relay.submitMainBlockheaders(_submission());

        assertEq(relay.getBlockheight(), CHECKPOINT_HEIGHT + 1);
    }

    function test_rejectsHashAboveTarget() public {
        bytes32 digest = Endianness.reverseBytes32(bytes32(TARGET + 1));
        vm.mockCall(address(0x02), bytes(""), abi.encode(digest));
        vm.expectRevert(bytes("updateChain: invalid PoW"));

        relay.submitMainBlockheaders(_submission());
    }

    function _checkpoint() private pure returns (MainnetStoredBlockHeader memory checkpoint) {
        bytes memory stored = _storedBlob();
        assembly ("memory-safe") {
            let dst := mload(checkpoint)
            for { let i := 0 } lt(i, 5) { i := add(i, 1) } {
                mstore(add(dst, mul(i, 32)), mload(add(add(stored, 32), mul(i, 32))))
            }
        }
    }

    function _submission() private pure returns (bytes memory) {
        bytes memory compact = abi.encodePacked(
            _le32(0x20000000), bytes32(uint256(0x3333)), _le32(NEW_BLOCK_TIME), bytes4(hex"ffff001d"), _le32(7)
        );
        assert(compact.length == 48);
        return abi.encodePacked(_storedBlob(), compact);
    }

    function _storedBlob() private pure returns (bytes memory stored) {
        bytes memory header = abi.encodePacked(
            _le32(0x20000000),
            bytes32(uint256(0x1111)),
            bytes32(uint256(0x2222)),
            _le32(CHECKPOINT_TIME),
            bytes4(hex"ffff001d"),
            _le32(42)
        );
        stored = abi.encodePacked(
            header, bytes32(0), bytes4(CHECKPOINT_HEIGHT), bytes4(uint32(1_699_000_000)), bytes32(0), bytes8(0)
        );
        assert(stored.length == 160);
    }

    function _le32(uint32 value) private pure returns (bytes4) {
        return bytes4(Endianness.reverseUint32(value));
    }
}
