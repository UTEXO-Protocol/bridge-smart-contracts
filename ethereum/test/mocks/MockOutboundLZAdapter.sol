// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {MockERC20} from "./MockERC20.sol";

/// @notice LayerZero adapter fixture that transfers delivery tokens and emits SendOut.
contract MockOutboundLZAdapter {
    MockERC20 public immutable token;

    address public immutable oft;

    address public immutable multisigProxy;

    uint256 public immutable nativeFee;

    uint256 public sendOutCalls;

    event SendOut(bytes32 indexed guid, uint32 dstEid, bytes32 recipient, uint256 amountLD);

    constructor(address token_, address oft_, address multisigProxy_, uint256 nativeFee_) {
        token = MockERC20(token_);
        oft = oft_;
        multisigProxy = multisigProxy_;
        nativeFee = nativeFee_;
    }

    function sendOut(
        uint32 dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes calldata /* extraOptions */
    )
        external
        payable
    {
        require(msg.sender == multisigProxy, "only proxy");
        require(msg.value == nativeFee, "native fee");
        require(amount != 0, "zero amount");
        require(recipient != bytes32(0), "zero recipient");
        require(minAmountLD <= amount, "min too high");

        sendOutCalls++;
        token.transfer(oft, amount);
        (bool ok,) = oft.call{value: msg.value}("");
        require(ok, "oft fee");
        emit SendOut(keccak256(abi.encode("mock-send-out", dstEid, recipient, amount)), dstEid, recipient, amount);
    }
}
