// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script, console2 } from 'forge-std/Script.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { Bridge } from '../../src/Bridge.sol';
import { ICommissionManager } from '../../src/interfaces/ICommissionManager.sol';

/// @title BridgeFundsIn
/// @notice Approves and calls Bridge.fundsIn() as the current signer. Quotes the
///         native commission from CommissionManager and attaches it as msg.value.
///
/// Env:
///   PRIVATE_KEY, BRIDGE_ADDRESS, AMOUNT (wei),
///   DESTINATION_CHAIN, DESTINATION_ADDRESS, OPERATION_ID
contract BridgeFundsIn is Script {
    function run() external {
        uint256 pk           = vm.envUint('PRIVATE_KEY');
        address bridgeAddr   = vm.envAddress('BRIDGE_ADDRESS');
        uint256 amount       = vm.envUint('AMOUNT');
        string memory dChain = vm.envString('DESTINATION_CHAIN');
        string memory dAddr  = vm.envString('DESTINATION_ADDRESS');
        uint256 operationId  = vm.envUint('OPERATION_ID');

        Bridge bridge = Bridge(bridgeAddr);
        address token = bridge.TOKEN();

        ICommissionManager cm = bridge.commissionManager();
        // FIXME(PR2): the chain identifiers become uint256 throughout in the
        // matching Bridge refactor. Until then, the script keccak-casts the
        // strings to satisfy the new CM signature.
        (, uint256 nativeCommission, ) = cm.calculateFundsInCommission(
            uint256(keccak256(bytes(bridge.sourceChainName()))),
            uint256(keccak256(bytes(dChain))),
            token,
            amount
        );

        console2.log('Native commission (wei):', nativeCommission);

        vm.startBroadcast(pk);
        IERC20(token).approve(bridgeAddr, amount);
        bridge.fundsIn{ value: nativeCommission }(amount, dChain, dAddr, operationId);
        vm.stopBroadcast();

        console2.log('fundsIn succeeded. Bridge balance:', IERC20(token).balanceOf(bridgeAddr));
    }
}
