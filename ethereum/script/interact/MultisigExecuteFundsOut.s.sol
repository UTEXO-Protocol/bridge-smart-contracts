// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {MultisigHelper} from "../../test/helpers/MultisigHelper.sol";

/// @notice Minimal Bridge view used to derive the canonical funds-out replay
///         key from the same domain fields as `Bridge._deriveBurnId`.
interface IBridgeFundsOutView {
    function TOKEN() external view returns (address);
    function BURN_TYPEHASH() external view returns (bytes32);
}

/// @title MultisigExecuteFundsOut
/// @notice Locally signs an RGB release and submits it through MultisigProxy.
/// @dev Packs proof and settlement data for RGBVerifier and RgbSettlementModule.
///      AMOUNT is in token smallest units; SOURCE_ADDRESS must be empty when source is RGB.
///      DEADLINE_OFFSET is at most 86400 seconds. Use local signing keys only for testing.
///      Inputs (see the matching .env example for values):
///      `RECIPIENT`, `AMOUNT`, `SOURCE_CHAIN_ID`, `DESTINATION_CHAIN_ID`, `SOURCE_ADDRESS`,
///      `SOURCE_BURN_TX_ID`, `SOURCE_BLOCK_HEIGHT`, `SOURCE_COMMITMENT_HASH`,
///      `LATEST_BLOCK_HEIGHT`, `LATEST_COMMITMENT_HASH`, `FUNDS_IN_IDS`,
///      `PROXY_ADDRESS`, `DEADLINE_OFFSET`, `ENCLAVE_BITMAP`, `ENCLAVE_PKS`, `PRIVATE_KEY`.
contract MultisigExecuteFundsOut is Script {
    function _loadParams(address bridgeAddress) internal view returns (IBridge.FundsOutParams memory p) {
        p.recipient = vm.envAddress("RECIPIENT");
        p.amount = vm.envUint("AMOUNT");
        p.sourceChainId = vm.envUint("SOURCE_CHAIN_ID");
        p.destinationChainId = vm.envUint("DESTINATION_CHAIN_ID");
        p.sourceAddress = vm.envString("SOURCE_ADDRESS");
        p.sourceBurnTxId = vm.envBytes32("SOURCE_BURN_TX_ID");

        // RGBVerifier checks the source depth and latest-block depth relative to the relay tip.
        // Proof layout: (sourceHeight, sourceCommit, latestHeight, latestCommit).
        p.proof = abi.encode(
            vm.envUint("SOURCE_BLOCK_HEIGHT"),
            vm.envBytes32("SOURCE_COMMITMENT_HASH"),
            vm.envUint("LATEST_BLOCK_HEIGHT"),
            vm.envBytes32("LATEST_COMMITMENT_HASH")
        );

        // RgbSettlementModule checks that every referenced mint exists on the
        // source RGB network.
        bytes32[] memory operationIds = vm.envBytes32("FUNDS_IN_IDS", ",");
        p.settlementData = abi.encode(operationIds);

        // Shared Bridge settlement replay key. The Bridge recomputes the same
        // canonical value for fundsOut and rebalanceLiquidity. The moving
        // proof, recipient and destination chain id remain signed by the enclave
        // but are not part of this id.
        p.burnId = _deriveBurnId(bridgeAddress, p);
    }

    function _deriveBurnId(address bridgeAddress, IBridge.FundsOutParams memory p) internal view returns (uint256) {
        IBridgeFundsOutView bridge = IBridgeFundsOutView(bridgeAddress);
        return uint256(
            keccak256(
                abi.encode(
                    bridge.BURN_TYPEHASH(),
                    bridgeAddress,
                    block.chainid,
                    bridge.TOKEN(),
                    p.amount,
                    p.sourceChainId,
                    keccak256(bytes(p.sourceAddress)),
                    p.sourceBurnTxId
                )
            )
        );
    }

    function run() external {
        MultisigProxy proxy = MultisigProxy(vm.envAddress("PROXY_ADDRESS"));

        IBridge.FundsOutParams memory params = _loadParams(proxy.bridge());

        uint256 nonce = proxy.teeNonce(params.sourceChainId);
        uint256 deadline = block.timestamp + vm.envUint("DEADLINE_OFFSET");
        uint256 bitmap = vm.envUint("ENCLAVE_BITMAP");

        bytes32 digest = MultisigHelper.digestTeeFundsOut(proxy.DOMAIN_SEPARATOR(), params, nonce, deadline);
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, vm.envUint("ENCLAVE_PKS", ","));

        console2.log("Submitting fundsOutCall() with nonce:", nonce);
        console2.log("Canonical Bridge burnId:              ", params.burnId);
        console2.log("Deadline:                            ", deadline);
        console2.log("Bitmap:                              ", bitmap);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
        vm.stopBroadcast();

        console2.log("fundsOutCall() succeeded. New nonce:", proxy.teeNonce(params.sourceChainId));
    }
}
