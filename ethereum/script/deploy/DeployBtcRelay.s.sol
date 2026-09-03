// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {BtcRelay} from "../../src/btc_relay/BtcRelay.sol";
import {BtcRelayTestnet} from "../../src/btc_relay/BtcRelayTestnet.sol";
import {
    StoredBlockHeader as MainnetHeader,
    StoredBlockHeaderImpl as MainnetHeaderImpl,
    StoredBlockHeaderByteLength as MAINNET_HEADER_BYTES
} from "../../src/btc_relay/structs/StoredBlockHeader.sol";
import {
    StoredBlockHeader as TestnetHeader,
    StoredBlockHeaderByteLength as TESTNET_HEADER_BYTES
} from "../../src/btc_relay/structs/StoredBlockHeaderTestnet.sol";
import {Endianness} from "../../src/btc_relay/btc_utils/Endianness.sol";
import {IBtcRelayView} from "../../src/interfaces/IBtcRelayView.sol";

/// @title DeployBtcRelay
/// @notice Deploys the Atomiq Bitcoin SPV header relay at a fixed, pre-reviewed
///         initialisation checkpoint, then hands its address to
///         `DeployRGBVerifier` / `DeployAll` via `BTC_RELAY_ADDRESS`.
///
///      Choose the checkpoint DEEP. Six blocks is not enough: a reorg deeper
///      than the checkpoint is unrecoverable, because all three header-submit
///      paths can only extend a height already committed in `_mainChain`, so
///      the relay would stay pinned to the orphaned branch forever and the fix
///      is a new relay + a new (immutable) RGBVerifier + a route rotation.
///      Depth is nearly free: catch-up costs 48 bytes of calldata per block, so
///      a full day of margin (~144 blocks) is ~7 KB — one transaction.
///
/// Env (required):
///   PRIVATE_KEY                — deployer private key
///   BTC_CHECKPOINT_HEADER      — the 160-byte `StoredBlockHeader` blob, hex:
///                                  [0..79]    raw 80-byte Bitcoin block header
///                                  [80..111]  cumulative chainWork (big-endian uint256)
///                                  [112..115] block height (uint32)
///                                  [116..119] lastDiffAdjustment (uint32)
///                                  [120..159] uint32[10] previous block timestamps
///   BTC_CHECKPOINT_HEIGHT      — expected height, asserted against the blob
///   BTC_CHECKPOINT_BLOCKHASH   — expected block hash in DISPLAY order, i.e. exactly
///                                as a block explorer or `getblockhash` shows it
///   BTC_CHECKPOINT_CHAINWORK   — expected cumulative chainwork, as the 32-byte
///                                `chainwork` field of `getblockheader`
///
/// Env (optional, defaults in parens):
///   BTC_CLAMP_BLOCK_TARGET (true)  — enforce the maximum PoW target; immutable after deploy
///   BTC_RELAY_TESTNET      (false) — deploy `BtcRelayTestnet` instead of `BtcRelay`
///
/// Usage:
///   forge script script/deploy/DeployBtcRelay.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployBtcRelay is Script {
    using MainnetHeaderImpl for MainnetHeader;

    /// @dev Chainwork is masked to 224 bits by the relay constructor. Bitcoin is
    ///      nowhere near this, so exceeding it means a malformed blob rather
    ///      than a real chain — reject instead of silently truncating.
    uint256 private constant MAX_CHAINWORK = type(uint224).max;

    function run() external returns (address relay) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        bytes memory blob = vm.envBytes("BTC_CHECKPOINT_HEADER");
        uint256 expectedHeight = vm.envUint("BTC_CHECKPOINT_HEIGHT");
        bytes32 expectedBlockhash = vm.envBytes32("BTC_CHECKPOINT_BLOCKHASH");
        uint256 expectedChainwork = uint256(vm.envBytes32("BTC_CHECKPOINT_CHAINWORK"));
        bool clampBlockTarget = vm.envOr("BTC_CLAMP_BLOCK_TARGET", true);
        bool testnet = vm.envOr("BTC_RELAY_TESTNET", false);

        bytes32[5] memory words = _toWords(blob);

        // Mainnet and testnet headers are the same 160-byte layout at the same
        // offsets, so one decoder validates both. Guarded rather than assumed,
        // in case the vendored copies ever diverge upstream.
        require(MAINNET_HEADER_BYTES == TESTNET_HEADER_BYTES, "checkpoint: header layouts diverged");

        MainnetHeader memory header;
        header.data = words;

        _reportAndVerifyHeader(header, expectedHeight, expectedBlockhash, expectedChainwork);

        console2.log("");
        console2.log("clampBlockTarget (immutable):", clampBlockTarget);
        console2.log("network:                     ", testnet ? "testnet" : "mainnet");

        vm.startBroadcast(pk);
        if (testnet) {
            TestnetHeader memory testnetHeader;
            testnetHeader.data = words;
            relay = address(new BtcRelayTestnet(testnetHeader, clampBlockTarget));
        } else {
            relay = address(new BtcRelay(header, clampBlockTarget));
        }
        vm.stopBroadcast();

        _verifyDeployment(relay, expectedHeight, expectedChainwork);
        _reportNextSteps(relay, expectedHeight);
    }

    // =========================================================================
    // Header decoding
    // =========================================================================

    /// @dev Split the 160-byte blob into the five words of `bytes32[5]`. Written
    ///      as plain loads rather than `mcopy` because the project targets the
    ///      shanghai EVM.
    function _toWords(bytes memory blob) private pure returns (bytes32[5] memory words) {
        require(blob.length == MAINNET_HEADER_BYTES, "checkpoint: header must be exactly 160 bytes");

        for (uint256 i = 0; i < 5; i++) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(blob, 32), mul(i, 32)))
            }
            words[i] = word;
        }
    }

    /// @dev Re-derive every field from the blob, print it for a final human
    ///      read, and assert the three independently supplied expectations.
    ///      The three fields NOT asserted here — `lastDiffAdjustment` and the
    ///      ten previous timestamps — cannot be checked from the blob alone;
    ///      they are printed instead, and are the fields most worth verifying
    ///      by hand, because a mistake in them surfaces weeks later in the
    ///      retarget and median-time-past rules rather than at deploy.
    function _reportAndVerifyHeader(
        MainnetHeader memory header,
        uint256 expectedHeight,
        bytes32 expectedBlockhash,
        uint256 expectedChainwork
    ) private view {
        uint256 height = uint256(header.blockHeight());
        uint256 chainWork = header.chainWork();
        // `header_blockhash` returns the raw double-SHA256 in Bitcoin's internal
        // byte order; explorers show it reversed. Compare in display order so the
        // configured value is a straight copy-paste.
        bytes32 displayHash = Endianness.reverseBytes32(header.header_blockhash());

        console2.log("=== Checkpoint header (decoded from BTC_CHECKPOINT_HEADER) ===");
        console2.log("blockHeight:        ", height);
        console2.log("blockhash (display):", vm.toString(displayHash));
        console2.log("chainWork:          ", chainWork);
        console2.log("version:            ", uint256(header.header_version()));
        console2.log("previousBlockhash:  ", vm.toString(Endianness.reverseBytes32(header.header_previousBlockhash())));
        console2.log("merkleRoot:         ", vm.toString(Endianness.reverseBytes32(header.header_merkleRoot())));
        console2.log("timestamp:          ", uint256(header.header_timestamp()));
        console2.log("nBits (LE):         ", uint256(header.header_nBitsLE()));
        console2.log("nonce:              ", uint256(header.header_nonce()));
        console2.log("lastDiffAdjustment: ", uint256(header.lastDiffAdjustment()));

        uint32[10] memory prevTimestamps = header.previousBlockTimestamps();
        console2.log("previousBlockTimestamps (oldest first):");
        for (uint256 i = 0; i < 10; i++) {
            console2.log("  -", uint256(prevTimestamps[i]));
        }

        require(height == expectedHeight, "checkpoint: height does not match BTC_CHECKPOINT_HEIGHT");
        require(height <= type(uint32).max, "checkpoint: height overflows uint32");
        require(displayHash == expectedBlockhash, "checkpoint: blockhash does not match BTC_CHECKPOINT_BLOCKHASH");
        require(chainWork == expectedChainwork, "checkpoint: chainwork does not match BTC_CHECKPOINT_CHAINWORK");
        require(chainWork <= MAX_CHAINWORK, "checkpoint: chainwork exceeds the relay's 224-bit field");
        require(header.header_timestamp() != 0, "checkpoint: zero header timestamp");
        require(header.header_nBitsLE() != 0, "checkpoint: zero nBits");
    }

    // =========================================================================
    // Post-deploy verification
    // =========================================================================

    /// @dev Read the deployed relay back through the same interface `RGBVerifier`
    ///      uses, so a mis-initialised relay fails here rather than silently
    ///      serving a bogus chain.
    function _verifyDeployment(address relay, uint256 expectedHeight, uint256 expectedChainwork) private view {
        IBtcRelayView view_ = IBtcRelayView(relay);

        require(uint256(view_.getBlockheight()) == expectedHeight, "deployed: tip height mismatch");

        bytes32 tipCommit = view_.getTipCommitHash();
        require(tipCommit != bytes32(0), "deployed: zero tip commitment");
        require(view_.getCommitHash(expectedHeight) == tipCommit, "deployed: checkpoint is not the tip");
        require(uint256(view_.getChainwork()) == expectedChainwork, "deployed: chainwork mismatch");

        // End-to-end read on the exact call `RGBVerifier` makes.
        require(view_.verifyBlockheaderHash(expectedHeight, tipCommit) == 1, "deployed: checkpoint does not verify");

        console2.log("");
        console2.log("=== Post-deploy verification ===");
        console2.log("BtcRelay deployed at:", relay);
        console2.log("tip height:          ", uint256(view_.getBlockheight()));
        console2.log("tip commitment:      ", vm.toString(tipCommit));
        console2.log("chainwork:           ", uint256(view_.getChainwork()));
    }

    function _reportNextSteps(address relay, uint256 expectedHeight) private pure {
        console2.log("");
        console2.log("=== Next steps ===");
        console2.log("1. The relay sits at the checkpoint and is NOT usable yet. Submit headers");
        console2.log("   from this height up to the Bitcoin tip via submitMainBlockheaders");
        console2.log("   (160-byte stored header + 48 bytes per block, chunked across txs).");
        console2.log("   RGBVerifier enforces maxLatestConfirmations, so it rejects everything");
        console2.log("   until the relay reaches the chain head - and keeping it there is a");
        console2.log("   standing operational duty, not a one-off.");
        console2.log("2. Export BTC_RELAY_ADDRESS for DeployRGBVerifier / DeployAll:");
        console2.log("   BTC_RELAY_ADDRESS=", relay);
        console2.log("3. Checkpoint height, now the immutable floor of the finality gate:");
        console2.log("   ", expectedHeight);
    }
}
