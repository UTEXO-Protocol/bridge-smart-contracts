// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {RouteRegistry} from "../../src/RouteRegistry.sol";

/// @notice Models an authorized route rotation during commission forwarding.
contract RouteRotatingCommissionManager {
    address private immutable _bridge;

    RouteRegistry private immutable _registry;

    address private immutable _verifier;

    address private immutable _module;

    uint256 private immutable _sourceChainId;

    uint256 private immutable _destinationChainId;

    constructor(
        address bridge_,
        RouteRegistry registry_,
        address verifier_,
        address module_,
        uint256 src,
        uint256 dst
    ) {
        _bridge = bridge_;
        _registry = registry_;
        _verifier = verifier_;
        _module = module_;
        _sourceChainId = src;
        _destinationChainId = dst;
    }

    function acceptRegistryOwnership() external {
        _registry.acceptOwnership();
    }

    function bridgeAddress() external view returns (address) {
        return _bridge;
    }

    function calculateFundsInCommission(uint256, uint256, address, uint256 amount)
        external
        pure
        returns (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount)
    {
        return (amount / 10, 0, amount - amount / 10);
    }

    function receiveTokenCommission(address, uint256) external {
        require(msg.sender == _bridge, "only bridge");
        _registry.setRoute(_sourceChainId, _destinationChainId, true, _verifier, _module);
    }
}
