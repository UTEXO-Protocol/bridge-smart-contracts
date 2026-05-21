// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script, console2 } from 'forge-std/Script.sol';
import { MultisigProxy } from '../../src/MultisigProxy.sol';
import { MultisigHelper } from '../../test/mocks/MultisigHelper.sol';

/// @title MultisigExecuteFundsOut
/// @notice Signs a Bridge.fundsOut() call locally with enclave private keys
///         and submits it via MultisigProxy.execute(). For manual end-to-end
///         testing before the backend is wired up.
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
///   BURN_ID                  — burn consignment id (single-use replay guard)
///   SOURCE_CHAIN_ID (uint)   — source chain id (RGB-side for inbound releases)
///   DESTINATION_CHAIN_ID     — destination chain id (this chain)
///   SOURCE_ADDRESS (string)  — source-side sender address
///   BLOCK_HEIGHT             — Bitcoin block height (consumed by RGBVerifier)
///   COMMITMENT_HASH (bytes32)— Bitcoin block commitment hash
///   FUNDS_IN_IDS             — comma-separated fundsIn op ids referenced by
///                              RgbSettlementModule
///   ENCLAVE_PKS              — comma-separated hex private keys (ordered by
///                              signer index)
///   ENCLAVE_BITMAP           — bitmap of participating signers (hex/decimal)
///   DEADLINE_OFFSET          — seconds from now (e.g. 3600)
contract MultisigExecuteFundsOut is Script {
    /// @dev 8-arg fundsOut selector — must match the TEE allowlist entry
    ///      seeded by `MultisigProxy`'s constructor.
    bytes4 constant FUNDS_OUT_SELECTOR = bytes4(keccak256(
        'fundsOut(address,uint256,uint256,uint256,uint256,string,bytes,bytes)'
    ));

    struct Params {
        address recipient;
        uint256 amount;
        uint256 burnId;
        uint256 sourceChainId;
        uint256 destChainId;
        string  sourceAddress;
        bytes   proof;
        bytes   settlementData;
    }

    function _loadParams() internal view returns (Params memory p) {
        p.recipient     = vm.envAddress('RECIPIENT');
        p.amount        = vm.envUint('AMOUNT');
        p.burnId        = vm.envUint('BURN_ID');
        p.sourceChainId = vm.envUint('SOURCE_CHAIN_ID');
        p.destChainId   = vm.envUint('DESTINATION_CHAIN_ID');
        p.sourceAddress = vm.envString('SOURCE_ADDRESS');

        // proof = abi.encode(blockHeight, commitmentHash) — RGBVerifier layout.
        p.proof = abi.encode(
            vm.envUint('BLOCK_HEIGHT'),
            vm.envBytes32('COMMITMENT_HASH')
        );

        // settlementData = abi.encode(uint256[] fundsInIds) — RgbSettlementModule layout.
        p.settlementData = abi.encode(vm.envUint('FUNDS_IN_IDS', ','));
    }

    function _buildCallData(Params memory p) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            FUNDS_OUT_SELECTOR,
            p.recipient,
            p.amount,
            p.burnId,
            p.sourceChainId,
            p.destChainId,
            p.sourceAddress,
            p.proof,
            p.settlementData
        );
    }

    function run() external {
        MultisigProxy proxy = MultisigProxy(vm.envAddress('PROXY_ADDRESS'));

        bytes memory callData = _buildCallData(_loadParams());

        uint256 nonce    = proxy.getNonce(FUNDS_OUT_SELECTOR);
        uint256 deadline = block.timestamp + vm.envUint('DEADLINE_OFFSET');
        uint256 bitmap   = vm.envUint('ENCLAVE_BITMAP');

        bytes32 digest = MultisigHelper.digestBridgeOp(
            proxy.DOMAIN_SEPARATOR(), FUNDS_OUT_SELECTOR, callData, nonce, deadline
        );
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, vm.envUint('ENCLAVE_PKS', ','));

        console2.log('Submitting execute() with nonce:', nonce);
        console2.log('Deadline:                       ', deadline);
        console2.log('Bitmap:                         ', bitmap);

        vm.startBroadcast(vm.envUint('PRIVATE_KEY'));
        proxy.execute(callData, nonce, deadline, bitmap, sigs);
        vm.stopBroadcast();

        console2.log('execute() succeeded. New nonce:', proxy.getNonce(FUNDS_OUT_SELECTOR));
    }
}
