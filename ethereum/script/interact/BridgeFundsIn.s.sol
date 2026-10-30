// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bridge} from "../../src/Bridge.sol";
import {ICommissionManager} from "../../src/interfaces/ICommissionManager.sol";

/// @title BridgeFundsIn
/// @notice Approves tokens and submits a direct RGB deposit from PRIVATE_KEY.
/// @dev Encodes the RGB mint OpId and exclusive Arbitrum L2 deadline, quotes commission
///      and attaches a native buffer.
///      AMOUNT is in token smallest units; DESTINATION_ADDRESS is empty for RGB.
///      Bridge refunds excess native value and returns the logged operationId.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `BRIDGE_ADDRESS`, `AMOUNT`, `DESTINATION_CHAIN_ID`, `DESTINATION_ADDRESS`,
///      `RGB_OP_ID`, `RGB_BEFORE_BLOCK`.
contract BridgeFundsIn is Script {
    /// @dev Drift headroom attached on top of the quote. Kept below the
    ///      Bridge's `NATIVE_COMMISSION_TOLERANCE_BPS` so a quote that is still
    ///      current is never rejected for overpaying.
    uint256 private constant NATIVE_BUFFER_BPS = 200; // 2%

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address bridgeAddr = vm.envAddress("BRIDGE_ADDRESS");
        uint256 amount = vm.envUint("AMOUNT");
        uint256 destChainId = vm.envUint("DESTINATION_CHAIN_ID");
        string memory dAddr = vm.envString("DESTINATION_ADDRESS");
        uint256 rgbOpId = vm.envUint("RGB_OP_ID");
        uint256 beforeBlockValue = vm.envUint("RGB_BEFORE_BLOCK");
        require(beforeBlockValue <= type(uint64).max, "RGB_BEFORE_BLOCK exceeds uint64");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 beforeBlock = uint64(beforeBlockValue);

        Bridge bridge = Bridge(bridgeAddr);
        address token = bridge.TOKEN();

        ICommissionManager cm = bridge.commissionManager();
        (, uint256 nativeCommission,) = cm.calculateFundsInCommission(block.chainid, destChainId, token, amount);

        // Attach a buffer; Bridge refunds any excess over its execution-time quote.
        uint256 nativeValue = nativeCommission + (nativeCommission * NATIVE_BUFFER_BPS) / 10_000;

        console2.log("Native commission quote (wei):", nativeCommission);
        console2.log("Native value attached (wei):  ", nativeValue);

        uint256 balanceBefore = vm.addr(pk).balance;

        vm.startBroadcast(pk);
        IERC20(token).approve(bridgeAddr, amount);
        // RGB route: `settlementData` carries the RGB OpId and an exclusive
        // Arbitrum L2 deadline. Other routes define their own blob layout.
        bytes32 operationId =
            bridge.fundsIn{value: nativeValue}(amount, destChainId, dAddr, abi.encode(rgbOpId, beforeBlock));
        vm.stopBroadcast();

        console2.log("fundsIn succeeded. Derived operationId:");
        console2.logBytes32(operationId);
        console2.log("Native spent incl. gas (wei): ", balanceBefore - vm.addr(pk).balance);
        console2.log("Bridge balance:", IERC20(token).balanceOf(bridgeAddr));
    }
}
