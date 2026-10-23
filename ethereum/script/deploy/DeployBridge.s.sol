// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {Bridge} from "../../src/Bridge.sol";
import {BridgeProxy} from "../../src/BridgeProxy.sol";

/// @title DeployBridge
/// @notice Deploys a Bridge implementation and initialized proxy owned by the deployer.
/// @dev CM and registry must bind to the proxy's predicted CREATE address: use
///      `cast compute-address <deployer> --nonce <N+1>`, where N is the deployer's
///      next nonce before this script; it creates the implementation at N first.
///      Keep that nonce unchanged between prediction and broadcast. Use DeployAll
///      for a fresh stack; upgrades use DeployBridgeImplementation and governance.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `USDT0_ADDRESS`, `ROUTE_REGISTRY_ADDRESS`, `COMMISSION_MANAGER`,
///      `LZ_ADAPTER`, `MIN_FUNDS_IN_AMOUNT`, `MIN_FUNDS_OUT_AMOUNT`.
contract DeployBridge is Script {
    function run() external returns (Bridge bridge) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address usdt0 = vm.envAddress("USDT0_ADDRESS");
        address routeRegistry = vm.envAddress("ROUTE_REGISTRY_ADDRESS");
        address commissionManager = vm.envAddress("COMMISSION_MANAGER");
        address lzAdapter = vm.envOr("LZ_ADAPTER", address(0));
        uint256 minFundsInAmount = vm.envUint("MIN_FUNDS_IN_AMOUNT");
        uint256 minFundsOutAmount = vm.envUint("MIN_FUNDS_OUT_AMOUNT");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        Bridge implementation = new Bridge();
        BridgeProxy proxy = new BridgeProxy(
            address(implementation),
            abi.encodeCall(
                Bridge.initialize,
                (
                    usdt0,
                    routeRegistry,
                    payable(commissionManager),
                    lzAdapter,
                    minFundsInAmount,
                    minFundsOutAmount,
                    deployer
                )
            )
        );
        bridge = Bridge(address(proxy));
        vm.stopBroadcast();

        console2.log("Bridge proxy deployed at:       ", address(bridge));
        console2.log("Bridge implementation deployed:", address(implementation));
        console2.log("Owner (deployer):    ", bridge.owner());
        console2.log("Token:               ", bridge.TOKEN());
        console2.log("RouteRegistry:       ", address(bridge.routeRegistry()));
        console2.log("CommissionManager:   ", address(bridge.commissionManager()));
        console2.log("LZ adapter:          ", bridge.lzAdapter());
        console2.log("Min fundsIn amount:  ", bridge.minFundsInAmount());
    }
}
