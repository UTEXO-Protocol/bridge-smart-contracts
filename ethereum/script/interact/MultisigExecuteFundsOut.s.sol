// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {MultisigHelper} from "../../test/mocks/MultisigHelper.sol";

/// @notice Minimal Bridge view used to derive the canonical funds-out replay
///         key from the same domain fields as `Bridge._deriveBurnId`.
interface IBridgeFundsOutView {
    function TOKEN() external view returns (address);
    function FUNDS_OUT_BURN_ID_TYPEHASH() external view returns (bytes32);
}

/// @title MultisigExecuteFundsOut
/// @notice Signs a Bridge.fundsOut() release locally with enclave private keys
///         and submits it via MultisigProxy.fundsOutCall(). For manual
///         end-to-end testing before the backend is wired up.
///
/// @dev RGB-route specific: `proof` and `settlementData` are packed for the
///      Atomiq BtcRelay + RgbSettlementModule plugins. Other routes will
///      need different blob layouts.
///
/// Env:
///   PRIVATE_KEY              — tx submitter (anyone)
///   PROXY_ADDRESS            — MultisigProxy address
///   RECIPIENT                — release recipient on this chain
///   AMOUNT (wei)             — gross amount to release (pre-commission)
///   SOURCE_CHAIN_ID (uint)   — source chain id (RGB-side for inbound releases)
///   DESTINATION_CHAIN_ID     — destination chain id (this chain)
///   SOURCE_ADDRESS (string)  — source-side sender address
///   SOURCE_BLOCK_HEIGHT      — Bitcoin block containing the RGB burn/lock
///   SOURCE_COMMITMENT_HASH   — source Bitcoin block commitment hash
///   LATEST_BLOCK_HEIGHT      — fresh Bitcoin block at the relay head
///   LATEST_COMMITMENT_HASH   — latest Bitcoin block commitment hash
///   FUNDS_IN_IDS             — comma-separated bytes32 Bridge operation ids
///                              referenced by the RGB burn consignment
///   FUNDS_IN_AMOUNTS         — comma-separated exact mint amounts parallel to
///                              FUNDS_IN_IDS
///   ENCLAVE_PKS              — comma-separated hex private keys (ordered by
///                              signer index)
///   ENCLAVE_BITMAP           — bitmap of participating signers (hex/decimal)
///   DEADLINE_OFFSET          — seconds from now (e.g. 3600)
contract MultisigExecuteFundsOut is Script {
    function _loadParams(address bridgeAddress) internal view returns (IBridge.FundsOutParams memory p) {
        p.recipient = vm.envAddress("RECIPIENT");
        p.amount = vm.envUint("AMOUNT");
        p.sourceChainId = vm.envUint("SOURCE_CHAIN_ID");
        p.destinationChainId = vm.envUint("DESTINATION_CHAIN_ID");
        p.sourceAddress = vm.envString("SOURCE_ADDRESS");

        // RGBVerifier expects the confirmed source block plus a fresh block at
        // the relay head: (sourceHeight, sourceCommit, latestHeight, latestCommit).
        p.proof = abi.encode(
            vm.envUint("SOURCE_BLOCK_HEIGHT"),
            vm.envBytes32("SOURCE_COMMITMENT_HASH"),
            vm.envUint("LATEST_BLOCK_HEIGHT"),
            vm.envBytes32("LATEST_COMMITMENT_HASH")
        );

        // RgbSettlementModule checks exact, network-scoped mint records using
        // equal-length parallel arrays.
        bytes32[] memory operationIds = vm.envBytes32("FUNDS_IN_IDS", ",");
        uint256[] memory amounts = vm.envUint("FUNDS_IN_AMOUNTS", ",");
        require(operationIds.length == amounts.length, "FUNDS_IN_IDS/FUNDS_IN_AMOUNTS length mismatch");
        p.settlementData = abi.encode(operationIds, amounts);

        // This is the Bridge-derived funds-out intent hash/replay key, NOT the
        // RGB consignment's burn id. The Bridge recomputes the same value and
        // rejects the call if any signed release field differs.
        p.burnId = _deriveBurnId(bridgeAddress, p);
    }

    function _deriveBurnId(address bridgeAddress, IBridge.FundsOutParams memory p) internal view returns (uint256) {
        IBridgeFundsOutView bridge = IBridgeFundsOutView(bridgeAddress);
        return uint256(
            keccak256(
                abi.encode(
                    bridge.FUNDS_OUT_BURN_ID_TYPEHASH(),
                    bridgeAddress,
                    block.chainid,
                    bridge.TOKEN(),
                    p.recipient,
                    p.amount,
                    p.sourceChainId,
                    p.destinationChainId,
                    keccak256(bytes(p.sourceAddress)),
                    keccak256(p.proof),
                    keccak256(p.settlementData)
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
