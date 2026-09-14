// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

import {IBridge} from "./interfaces/IBridge.sol";
import {IBridgeProxy} from "./interfaces/IBridgeProxy.sol";

/// @title BridgeProxy
/// @notice Owner-controlled ERC-1967 proxy for the canonical Bridge.
/// @dev Upgrade authorization lives exclusively here; Bridge implementations
///      do not expose UUPS upgrade functions. Bridge.owner() is the sole authority.
///      Future implementations must preserve a working owner() getter: upgrade
///      authorization depends on it and fails closed if the getter reverts.
contract BridgeProxy is ERC1967Proxy, IBridgeProxy {
    error UnauthorizedBridgeOwner(address caller);
    error IncompatibleBridgeImplementation(address implementation);

    constructor(address implementation_, bytes memory initializationData_)
        payable
        ERC1967Proxy(implementation_, initializationData_)
    {
        _requireCompatibleImplementation(implementation_);
    }

    modifier onlyBridgeOwner() {
        // External view call enters fallback and reads owner in proxy storage.
        // owner() must not be declared on this proxy (it belongs to Bridge).
        if (msg.sender != IERC5313(address(this)).owner()) revert UnauthorizedBridgeOwner(msg.sender);
        _;
    }

    function implementation() external view override returns (address) {
        return ERC1967Utils.getImplementation();
    }

    function upgradeToAndCall(address newImplementation, bytes calldata data)
        external
        payable
        override
        onlyBridgeOwner
    {
        _requireCompatibleImplementation(newImplementation);
        ERC1967Utils.upgradeToAndCall(newImplementation, data);
    }

    function _requireCompatibleImplementation(address candidate) private view {
        // Pointing the implementation slot at this proxy would make every
        // fallback recurse into itself and permanently brick the Bridge.
        if (candidate == address(this)) revert IncompatibleBridgeImplementation(candidate);

        // Another ERC-1967 proxy can expose the Bridge marker through its own
        // fallback, but using proxy bytecode as an implementation would make
        // it read this proxy's implementation slot and recurse as well.
        (bool exposesProxyApi, bytes memory proxyResult) =
            candidate.staticcall(abi.encodeCall(IBridgeProxy.implementation, ()));
        if (exposesProxyApi && proxyResult.length == 32) revert IncompatibleBridgeImplementation(candidate);

        (bool ok, bytes memory result) = candidate.staticcall(abi.encodeCall(IBridge.bridgeProxyCompatibilityUUID, ()));
        if (
            !ok || result.length != 32
                || abi.decode(result, (bytes32)) != keccak256("utexo.bridge.proxy.compatibility.v1")
        ) {
            revert IncompatibleBridgeImplementation(candidate);
        }
    }
}
