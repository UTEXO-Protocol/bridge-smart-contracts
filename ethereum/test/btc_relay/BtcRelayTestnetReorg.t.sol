// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {BtcRelayTestnet} from "../../src/btc_relay/BtcRelayTestnet.sol";
import {StoredBlockHeader} from "../../src/btc_relay/structs/StoredBlockHeaderTestnet.sol";
import {Endianness} from "../../src/btc_relay/btc_utils/Endianness.sol";

contract BtcRelayTestnetReorgTest is Test {
    uint256 internal constant LIGHT_TARGET = uint256(0x7fffff) << 232;
    uint256 internal constant HEAVY_TARGET = uint256(0x7fffff) << 224;
    uint256 internal constant LIGHT_WORK = (~LIGHT_TARGET) / (LIGHT_TARGET + 1) + 1;
    uint256 internal constant HEAVY_WORK = (~HEAVY_TARGET) / (HEAVY_TARGET + 1) + 1;
    bytes4 internal constant LIGHT_NBITS = hex"ffff7f20";
    bytes4 internal constant HEAVY_NBITS = hex"ffff7f1f";
    uint32 internal constant T0 = 1_700_000_000;

    address internal constant FORK_SUBMITTER = address(0xA77ACC);

    BtcRelayTestnet internal relay;
    bytes internal checkpointHeader;
    bytes32[5] internal checkpointWords;
    bytes32 internal checkpointHash;

    function setUp() public {
        checkpointHeader = _header(bytes32(uint256(1)), T0, 0, LIGHT_NBITS, bytes32(uint256(0xC0)));
        checkpointWords = _storedWords(checkpointHeader, 0, 1000, T0, _zeroRing());
        StoredBlockHeader memory checkpoint;
        checkpoint.data = checkpointWords;
        relay = new BtcRelayTestnet(checkpoint, true);
        checkpointHash = sha256(abi.encodePacked(sha256(checkpointHeader)));
        vm.warp(T0 + 100_000);
    }

    function test_rejectsForkPromotionWhenRootIsAboveTip() public {
        (bytes memory m1, bytes32 m1Hash) =
            _grind(checkpointHash, T0 + 60, LIGHT_NBITS, LIGHT_TARGET, bytes32(uint256(0xD1)));
        (bytes memory m2, bytes32 m2Hash) = _grind(m1Hash, T0 + 120, LIGHT_NBITS, LIGHT_TARGET, bytes32(uint256(0xD2)));
        (bytes memory m3,) = _grind(m2Hash, T0 + 180, LIGHT_NBITS, LIGHT_TARGET, bytes32(uint256(0xD3)));
        relay.submitMainBlockheaders(abi.encodePacked(_blob(checkpointWords), _compact(m1), _compact(m2), _compact(m3)));

        bytes32[5] memory storedM2 = _storedWords(m2, 2 * LIGHT_WORK, 1002, T0, _ring2(T0, T0 + 60));
        (bytes memory a3, bytes32 a3Hash) = _grind(m2Hash, T0 + 180, LIGHT_NBITS, LIGHT_TARGET, bytes32(uint256(0xA3)));
        vm.prank(FORK_SUBMITTER);
        relay.submitForkBlockheaders(1, abi.encodePacked(_blob(storedM2), _compact(a3)));
        assertEq(relay.getBlockheight(), 1003);

        (bytes memory r1,) = _grind(checkpointHash, T0 + 70, HEAVY_NBITS, HEAVY_TARGET, bytes32(uint256(0xB1)));
        relay.submitShortForkBlockheaders(abi.encodePacked(_blob(checkpointWords), _compact(r1)));
        assertEq(relay.getBlockheight(), 1001);
        assertEq(relay.getChainwork(), uint224(HEAVY_WORK));
        assertEq(relay.getCommitHash(1002), bytes32(0));
        assertEq(relay.getCommitHash(1003), bytes32(0));

        bytes32[5] memory storedA3 = _storedWords(a3, 3 * LIGHT_WORK, 1003, T0, _ring3(T0, T0 + 60, T0 + 120));
        (bytes memory a4,) = _grind(a3Hash, T0 + 240, HEAVY_NBITS, HEAVY_TARGET, bytes32(uint256(0xA4)));

        vm.expectRevert(bytes("fork: root above tip"));
        vm.prank(FORK_SUBMITTER);
        relay.submitForkBlockheaders(1, abi.encodePacked(_blob(storedA3), _compact(a4)));

        assertEq(relay.getBlockheight(), 1001);
        assertEq(relay.getChainwork(), uint224(HEAVY_WORK));
    }

    function _le(uint32 value) private pure returns (bytes4) {
        return bytes4(
            uint32(((value & 0xff) << 24) | ((value & 0xff00) << 8) | ((value >> 8) & 0xff00) | ((value >> 24) & 0xff))
        );
    }

    function _header(bytes32 prev, uint32 timestamp, uint32 nonce, bytes4 nbitsWire, bytes32 merkle)
        private
        pure
        returns (bytes memory header)
    {
        header = abi.encodePacked(bytes4(uint32(1)), prev, merkle, _le(timestamp), nbitsWire, bytes4(nonce));
        assert(header.length == 80);
    }

    function _grind(bytes32 prev, uint32 timestamp, bytes4 nbitsWire, uint256 target, bytes32 merkle)
        private
        pure
        returns (bytes memory header, bytes32 digest)
    {
        for (uint32 nonce = 0; nonce < type(uint32).max; nonce++) {
            header = _header(prev, timestamp, nonce, nbitsWire, merkle);
            digest = sha256(abi.encodePacked(sha256(header)));
            if (uint256(Endianness.reverseBytes32(digest)) < target) return (header, digest);
        }
        revert("no pow");
    }

    function _compact(bytes memory header) private pure returns (bytes memory compact) {
        compact = new bytes(48);
        for (uint256 i = 0; i < 4; i++) {
            compact[i] = header[i];
        }
        for (uint256 i = 0; i < 44; i++) {
            compact[4 + i] = header[36 + i];
        }
    }

    function _zeroRing() private pure returns (uint32[10] memory ring) {}

    function _ring2(uint32 t8, uint32 t9) private pure returns (uint32[10] memory ring) {
        ring[8] = t8;
        ring[9] = t9;
    }

    function _ring3(uint32 t7, uint32 t8, uint32 t9) private pure returns (uint32[10] memory ring) {
        ring[7] = t7;
        ring[8] = t8;
        ring[9] = t9;
    }

    function _storedWords(
        bytes memory header,
        uint256 chainWork,
        uint32 height,
        uint32 lastDiffAdjustment,
        uint32[10] memory ring
    ) private pure returns (bytes32[5] memory words) {
        bytes memory blob = abi.encodePacked(header, bytes32(chainWork), bytes4(height), bytes4(lastDiffAdjustment));
        for (uint256 i = 0; i < 10; i++) {
            blob = abi.encodePacked(blob, bytes4(ring[i]));
        }
        assert(blob.length == 160);

        for (uint256 i = 0; i < 5; i++) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(blob, 32), mul(i, 32)))
            }
            words[i] = word;
        }
    }

    function _blob(bytes32[5] memory words) private pure returns (bytes memory) {
        return abi.encodePacked(words[0], words[1], words[2], words[3], words[4]);
    }
}
