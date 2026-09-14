// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Bridge} from "../../src/Bridge.sol";
import {BridgeProxy} from "../../src/BridgeProxy.sol";

abstract contract BridgeProxyTestUtils {
    function _deployBridge(
        address token,
        address routeRegistry,
        address payable commissionManager,
        address lzAdapter,
        uint256 minFundsInAmount,
        uint256 minFundsOutAmount,
        address initialOwner
    ) internal returns (Bridge bridge) {
        (bridge,,) = _deployBridgeWithImplementation(
            token, routeRegistry, commissionManager, lzAdapter, minFundsInAmount, minFundsOutAmount, initialOwner
        );
    }

    function _deployBridgeWithImplementation(
        address token,
        address routeRegistry,
        address payable commissionManager,
        address lzAdapter,
        uint256 minFundsInAmount,
        uint256 minFundsOutAmount,
        address initialOwner
    ) internal returns (Bridge bridge, Bridge implementation, BridgeProxy proxy) {
        implementation = new Bridge();
        (bridge, proxy) = _deployBridgeFromImplementation(
            implementation,
            token,
            routeRegistry,
            commissionManager,
            lzAdapter,
            minFundsInAmount,
            minFundsOutAmount,
            initialOwner
        );
    }

    function _deployBridgeFromImplementation(
        Bridge implementation,
        address token,
        address routeRegistry,
        address payable commissionManager,
        address lzAdapter,
        uint256 minFundsInAmount,
        uint256 minFundsOutAmount,
        address initialOwner
    ) internal returns (Bridge bridge, BridgeProxy proxy) {
        bytes memory initializationData = abi.encodeCall(
            Bridge.initialize,
            (token, routeRegistry, commissionManager, lzAdapter, minFundsInAmount, minFundsOutAmount, initialOwner)
        );
        proxy = new BridgeProxy(address(implementation), initializationData);
        bridge = Bridge(address(proxy));
    }
}
