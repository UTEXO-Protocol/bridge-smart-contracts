// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script, console2 } from 'forge-std/Script.sol';
import { MultisigProxy } from '../../src/MultisigProxy.sol';

/// @title DeployMultisigProxy
/// @notice Deploys MultisigProxy for an existing Bridge + CommissionManager and
///         optionally transfers ownership of both (call from the current owner otherwise).
///
/// Env:
///   PRIVATE_KEY           — deployer private key
///   BRIDGE_ADDRESS        — existing Bridge deployment
///   COMMISSION_MANAGER    — existing CommissionManager deployment
///   ENCLAVE_SIGNERS       — comma-separated TEE signer addresses
///   ENCLAVE_THRESHOLD     — M for enclave M-of-N
///   FEDERATION_SIGNERS    — comma-separated governance signer addresses
///   FEDERATION_THRESHOLD  — M for federation M-of-N
///   COMMISSION_RECIPIENT  — destination for commission withdrawals
///   TIMELOCK_DURATION     — seconds between propose and execute (e.g. 3600)
///
/// Usage:
///   forge script script/deploy/DeployMultisigProxy.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployMultisigProxy is Script {
    function run() external returns (MultisigProxy proxy) {
        uint256 pk = vm.envUint('PRIVATE_KEY');

        address bridgeAddr         = vm.envAddress('BRIDGE_ADDRESS');
        address commissionManager  = vm.envAddress('COMMISSION_MANAGER');
        address[] memory enc       = vm.envAddress('ENCLAVE_SIGNERS', ',');
        uint256 encThr             = vm.envUint('ENCLAVE_THRESHOLD');
        address[] memory fed       = vm.envAddress('FEDERATION_SIGNERS', ',');
        uint256 fedThr             = vm.envUint('FEDERATION_THRESHOLD');
        address commission         = vm.envAddress('COMMISSION_RECIPIENT');
        uint256 timelock           = vm.envUint('TIMELOCK_DURATION');

        vm.startBroadcast(pk);
        proxy = new MultisigProxy(
            bridgeAddr,
            commissionManager,
            enc, encThr,
            fed, fedThr,
            commission,
            timelock
        );
        vm.stopBroadcast();

        console2.log('MultisigProxy deployed at:', address(proxy));
        console2.log('Bridge:                   ', proxy.bridge());
        console2.log('CommissionManager:        ', proxy.commissionManager());
        console2.log('Enclave threshold:        ', proxy.enclaveThreshold());
        console2.log('Federation threshold:     ', proxy.federationThreshold());
        console2.log('Commission recipient:     ', proxy.commissionRecipient());
        console2.log('Timelock duration (sec):  ', proxy.timelockDuration());
        console2.log('');
        console2.log('lzAdapter (proxy):        ', proxy.lzAdapter());
        console2.log('');
        console2.log('Next steps:');
        console2.log('  1) Transfer Bridge ownership to MultisigProxy.');
        console2.log('  2) Transfer CommissionManager ownership to MultisigProxy.');
        console2.log('  3) Once the LayerZero adapter is deployed:');
        console2.log('     a) propose Bridge.setLZAdapter(adapter) via proposeAdminExecute');
        console2.log('     b) propose MultisigProxy.lzAdapter via proposeUpdateLZAdapter');
    }
}
