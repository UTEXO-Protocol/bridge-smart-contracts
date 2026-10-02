// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {IBridge} from "./interfaces/IBridge.sol";
import {IBridgeProxy} from "./interfaces/IBridgeProxy.sol";

/// @title BridgeProxy
/// @notice Owner-controlled ERC-1967 proxy for the canonical Bridge.
/// @dev Upgrade authorization lives exclusively here; Bridge implementations
///      do not expose UUPS upgrade functions. The stored OpenZeppelin Ownable
///      owner is the sole upgrade authority. Future implementations must preserve
///      the Ownable namespace and owner field at offset zero; upgrade checks read
///      this slot directly and do not depend on the implementation's owner() getter.
///      implementation() and upgradeToAndCall(address,bytes) selectors are
///      reserved by this proxy and must not appear in an implementation ABI.
contract BridgeProxy is ERC1967Proxy, IBridgeProxy {
    /// @dev Maximum upgrade initialization bytes, including the selector.
    ///      Keep aligned with MultisigProxy's proposal/execution limit.
    uint256 private constant _MAX_UPGRADE_CALLDATA_LENGTH = 4096;

    /// @dev ERC-7201 openzeppelin.storage.Ownable namespace, with address _owner
    ///      in its first field. Must match the deployed OwnableUpgradeable layout.
    bytes32 private constant _OWNABLE_OWNER_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    error UnauthorizedBridgeOwner(address caller);
    error IncompatibleBridgeImplementation(address implementation);
    error UpgradeCallDataTooLong(uint256 length, uint256 maxLength);

    constructor(address implementation_, bytes memory initializationData_)
        payable
        ERC1967Proxy(implementation_, initializationData_)
    {
        _requireCompatibleImplementation(implementation_);
    }

    modifier onlyBridgeOwner() {
        if (msg.sender != _storedOwner()) revert UnauthorizedBridgeOwner(msg.sender);
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
        if (data.length > _MAX_UPGRADE_CALLDATA_LENGTH) {
            revert UpgradeCallDataTooLong(data.length, _MAX_UPGRADE_CALLDATA_LENGTH);
        }
        _requireCompatibleImplementation(newImplementation);
        ERC1967Utils.upgradeToAndCall(newImplementation, data);
        // Read the owner slot after the reinitializer, independently of the
        // new implementation's getter. Any failure rolls
        // back both the implementation slot and all initialization writes.
        if (_storedOwner() != msg.sender) {
            revert IncompatibleBridgeImplementation(newImplementation);
        }
    }

    function _storedOwner() private view returns (address storedOwner) {
        // Only the low 160 bits belong to the address field.
        assembly { storedOwner := and(sload(_OWNABLE_OWNER_SLOT), 0xffffffffffffffffffffffffffffffffffffffff) }
    }

    function _requireCompatibleImplementation(address candidate) private view {
        // Pointing the implementation slot at this proxy would make every
        // fallback recurse into itself and permanently brick the Bridge.
        if (candidate == address(this)) revert IncompatibleBridgeImplementation(candidate);

        // Implementations must expose a direct-call-only compatibility marker.
        // Bridge's immutable identity guard rejects proxy-mediated calls to it.
        (bool ok, bytes memory result) = candidate.staticcall(abi.encodeCall(IBridge.bridgeProxyCompatibilityUUID, ()));
        if (
            !ok || result.length != 32
                || abi.decode(result, (bytes32)) != keccak256("utexo.bridge.proxy.compatibility.v1")
        ) {
            revert IncompatibleBridgeImplementation(candidate);
        }
    }
}
