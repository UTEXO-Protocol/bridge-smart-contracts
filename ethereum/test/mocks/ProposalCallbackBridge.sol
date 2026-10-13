// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {MultisigProxy} from "../../src/MultisigProxy.sol";

/// @notice Models a Bridge target that calls back into proposal execution during rotation.
contract ProposalCallbackBridge {
    MultisigProxy public proxy;

    address public commissionManager;

    uint256 public calls;

    bytes public callbackError;

    bytes32 private _nestedId;

    bytes private _nestedData;

    bool private _callbackEnabled;

    bool private _bubbleFailure;

    constructor(address manager) {
        commissionManager = manager;
    }

    function configure(MultisigProxy proxy_, bytes32 nestedId, bytes calldata nestedData, bool enabled, bool bubble)
        external
    {
        proxy = proxy_;
        _nestedId = nestedId;
        _nestedData = nestedData;
        _callbackEnabled = enabled;
        _bubbleFailure = bubble;
    }

    function setCommissionManager(address manager) external {
        require(msg.sender == address(proxy), "only proxy");
        commissionManager = manager;
        calls++;
        if (_callbackEnabled) {
            // Disable callbacks before nested execution to prevent recursive loops.
            _callbackEnabled = false;
            if (_bubbleFailure) {
                proxy.executeProposal(_nestedId, _nestedData);
            } else {
                try proxy.executeProposal(_nestedId, _nestedData) {}
                catch (bytes memory reason) {
                    callbackError = reason;
                }
            }
        }
    }
}
