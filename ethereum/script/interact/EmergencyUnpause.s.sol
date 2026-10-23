// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {MultisigHelper} from "../../test/helpers/MultisigHelper.sol";

/// @title EmergencyUnpause
/// @notice Locally signs and submits a federation emergency unpause.
/// @dev Uses emergencyNonce. DEADLINE_OFFSET must be at most 86400 seconds.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `PROXY_ADDRESS`, `FED_PKS`, `FED_BITMAP`, `DEADLINE_OFFSET`.
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

    /// @dev Uses emergencyNonce, independent of proposal and enclave nonces.
    function _prepareEmergencyUnpause(MultisigProxy proxy, uint256 deadline)
        internal
        view
        returns (uint256 nonce, bytes32 digest)
    {
        nonce = proxy.emergencyNonce();
        digest = MultisigHelper.digestEmergencyUnpause(proxy.DOMAIN_SEPARATOR(), nonce, deadline);
    }
}
