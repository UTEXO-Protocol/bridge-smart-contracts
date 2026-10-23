// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {RgbRejectList} from "../../src/RgbRejectList.sol";

/// @title DeployRgbRejectList
/// @notice Deploys the standalone RGB reject list with separate owner and appender addresses.
/// @dev Use a cold owner and a hot appender. Record the address before RGB asset issuance;
///      the asset reference is fixed at issuance. Not included in DeployAll.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `REJECT_LIST_OWNER`, `REJECT_LIST_APPENDER`.
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
