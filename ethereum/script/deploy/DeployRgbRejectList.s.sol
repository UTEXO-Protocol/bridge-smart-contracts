// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {RgbRejectList} from "../../src/RgbRejectList.sol";

/// @title DeployRgbRejectList
/// @notice Deploys the standalone `RgbRejectList` read by RGB client-side
///         validation. It is independent of the bridge stack: no bridge
///         contract references it, so it is not part of `DeployAll`.
///
///         Deploy once per network. The RGB contract references this address at
///         issuance and it cannot be changed afterwards, so record the deployed
///         address before issuing, and choose a long-lived owner — ownership is
///         two-step and cannot be renounced.
///
/// Env:
///   PRIVATE_KEY          — deployer private key
///   REJECT_LIST_OWNER    — initial owner: the cold key that appoints and
///                          rotates the appender. A dedicated variable so a
///                          shared `.env.deploy` cannot silently reuse the
///                          bridge governance owner.
///   REJECT_LIST_APPENDER — initial appender: the hot key of the tool that
///                          publishes entries. Must differ from the owner, so a
///                          leaked tool key cannot take over the registry.
///
/// Usage:
///   forge script script/deploy/DeployRgbRejectList.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployRgbRejectList is Script {
    function run() external returns (RgbRejectList list) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("REJECT_LIST_OWNER");
        address appender = vm.envAddress("REJECT_LIST_APPENDER");
        require(owner != appender, "REJECT_LIST_APPENDER must differ from REJECT_LIST_OWNER");

        vm.startBroadcast(pk);
        list = new RgbRejectList(owner, appender);
        vm.stopBroadcast();

        console2.log("RgbRejectList deployed at:", address(list));
        console2.log("Owner:                    ", list.owner());
        console2.log("Appender:                 ", list.appender());
        console2.log("Entries:                  ", list.length());
    }
}
