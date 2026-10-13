// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Bridge} from "../../src/Bridge.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Depositor that cannot receive native refunds, exercising NativeRefundFailed.
contract NonPayableDepositor {
    Bridge private immutable _bridge;

    MockERC20 private immutable _token;

    constructor(Bridge bridge_, MockERC20 token_) {
        _bridge = bridge_;
        _token = token_;
    }

    function approveBridge(uint256 amount) external {
        _token.approve(address(_bridge), amount);
    }

    function deposit(
        uint256 amount,
        uint256 destinationChainId,
        string calldata destinationAddress,
        bytes calldata settlementData,
        uint256 nativeValue
    ) external returns (bytes32) {
        return _bridge.fundsIn{value: nativeValue}(amount, destinationChainId, destinationAddress, settlementData);
    }
}
