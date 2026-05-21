// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script, console2 } from 'forge-std/Script.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { Bridge } from '../../src/Bridge.sol';
import { ICommissionManager } from '../../src/interfaces/ICommissionManager.sol';

/// @title BridgeFundsIn
/// @notice Approves and calls the public `Bridge.fundsIn()` overload as the
///         current signer. Quotes the native commission from CommissionManager
///         and attaches it as `msg.value`. `sourceChainId` is filled with
///         `block.chainid` by the Bridge — the script just reads it back to
///         drive the quote.
///
/// Env:
///   PRIVATE_KEY, BRIDGE_ADDRESS, AMOUNT (wei),
///   DESTINATION_CHAIN_ID, DESTINATION_ADDRESS, OPERATION_ID
contract BridgeFundsIn is Script {
    function run() external {
        uint256 pk            = vm.envUint('PRIVATE_KEY');
        address bridgeAddr    = vm.envAddress('BRIDGE_ADDRESS');
        uint256 amount        = vm.envUint('AMOUNT');
        uint256 destChainId   = vm.envUint('DESTINATION_CHAIN_ID');
        string memory dAddr   = vm.envString('DESTINATION_ADDRESS');
        uint256 operationId   = vm.envUint('OPERATION_ID');

        Bridge bridge = Bridge(bridgeAddr);
        address token = bridge.TOKEN();

        ICommissionManager cm = bridge.commissionManager();
        (, uint256 nativeCommission, ) = cm.calculateFundsInCommission(
            block.chainid,
            destChainId,
            token,
            amount
        );

        console2.log('Native commission (wei):', nativeCommission);

        vm.startBroadcast(pk);
        IERC20(token).approve(bridgeAddr, amount);
        // `settlementData` is empty for the RGB route — its settlement
        // module ignores inbound data. Other routes whose modules consume
        // extra data on `onFundsIn` would need to source the blob from env.
        bridge.fundsIn{ value: nativeCommission }(amount, destChainId, dAddr, operationId, '');
        vm.stopBroadcast();

        console2.log('fundsIn succeeded. Bridge balance:', IERC20(token).balanceOf(bridgeAddr));
    }
}
