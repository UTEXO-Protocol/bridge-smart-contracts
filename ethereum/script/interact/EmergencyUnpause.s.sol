// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {MultisigHelper} from "../../test/mocks/MultisigHelper.sol";

/// @title EmergencyUnpause
/// @notice Locally signs and submits MultisigProxy.emergencyUnpause().
///
/// Env: same as EmergencyPause.
contract EmergencyUnpause is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address proxyAddr = vm.envAddress("PROXY_ADDRESS");
        uint256[] memory ks = vm.envUint("FED_PKS", ",");
        uint256 bitmap = vm.envUint("FED_BITMAP");
        uint256 offset = vm.envUint("DEADLINE_OFFSET");

        MultisigProxy proxy = MultisigProxy(proxyAddr);
        uint256 deadline = block.timestamp + offset;
        (uint256 nonce, bytes32 digest) = _prepareEmergencyUnpause(proxy, deadline);
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, ks);

        vm.startBroadcast(pk);
        proxy.emergencyUnpause(nonce, deadline, bitmap, sigs);
        vm.stopBroadcast();

        console2.log("emergencyUnpause submitted. New emergencyNonce:", proxy.emergencyNonce());
    }

    /// @dev Emergency actions have an independent nonce lane. Keeping nonce
    ///      lookup and digest construction together prevents the production
    ///      script from accidentally signing with the regular proposal nonce.
    function _prepareEmergencyUnpause(MultisigProxy proxy, uint256 deadline)
        internal
        view
        returns (uint256 nonce, bytes32 digest)
    {
        nonce = proxy.emergencyNonce();
        digest = MultisigHelper.digestEmergencyUnpause(proxy.DOMAIN_SEPARATOR(), nonce, deadline);
    }
}
