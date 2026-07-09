// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

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
///         The canonical `operationId` is derived on-chain by the Bridge and
///         returned; this script logs it. The RGB route carries the RGB OpId
///         in `settlementData` (`abi.encode(uint256 rgbOpId)`), sourced from
///         `RGB_OP_ID`.
///
/// Env:
///   PRIVATE_KEY, BRIDGE_ADDRESS, AMOUNT (wei),
///   DESTINATION_CHAIN_ID, DESTINATION_ADDRESS, RGB_OP_ID
contract BridgeFundsIn is Script {
    function run() external {
        uint256 pk            = vm.envUint('PRIVATE_KEY');
        address bridgeAddr    = vm.envAddress('BRIDGE_ADDRESS');
        uint256 amount        = vm.envUint('AMOUNT');
        uint256 destChainId   = vm.envUint('DESTINATION_CHAIN_ID');
        string memory dAddr   = vm.envString('DESTINATION_ADDRESS');
        uint256 rgbOpId       = vm.envUint('RGB_OP_ID');

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
        // RGB route: `settlementData` carries the RGB OpId as `abi.encode(uint256)`;
        // the settlement module decodes it and surfaces it in the FundsIn event.
        // Other routes define their own blob layout.
        bytes32 operationId = bridge.fundsIn{ value: nativeCommission }(
            amount, destChainId, dAddr, abi.encode(rgbOpId)
        );
        vm.stopBroadcast();

        console2.log('fundsIn succeeded. Derived operationId:');
        console2.logBytes32(operationId);
        console2.log('Bridge balance:', IERC20(token).balanceOf(bridgeAddr));
    }
}
