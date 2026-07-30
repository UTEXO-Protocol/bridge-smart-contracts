// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bridge} from "../../src/Bridge.sol";
import {ICommissionManager} from "../../src/interfaces/ICommissionManager.sol";

/// @title BridgeFundsIn
/// @notice Approves and calls the public `Bridge.fundsIn()` overload as the
///         current signer. Quotes the native commission from CommissionManager
///         and attaches the quote plus `NATIVE_BUFFER_BPS` of headroom to absorb
///         limited ETH/USD drift between quoting and execution. The call still
///         reverts if the fresh quote exceeds the attached value or the attached
///         value falls outside the Bridge's immutable tolerance. Bridge charges
///         exactly the quote it computes at execution and refunds the unused
///         buffer. `sourceChainId` is filled with `block.chainid` by the Bridge —
///         the script just reads it back to drive the quote.
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

        Bridge bridge = Bridge(bridgeAddr);
        address token = bridge.TOKEN();

        ICommissionManager cm = bridge.commissionManager();
        (, uint256 nativeCommission,) = cm.calculateFundsInCommission(block.chainid, destChainId, token, amount);

        // Attach the quote plus drift headroom. Bridge charges the quote it
        // computes at execution and refunds the rest, so this is a ceiling on
        // what may be spent, not the amount actually paid.
        uint256 nativeValue = nativeCommission + (nativeCommission * NATIVE_BUFFER_BPS) / 10_000;

        console2.log("Native commission quote (wei):", nativeCommission);
        console2.log("Native value attached (wei):  ", nativeValue);

        uint256 balanceBefore = vm.addr(pk).balance;

        vm.startBroadcast(pk);
        IERC20(token).approve(bridgeAddr, amount);
        // RGB route: `settlementData` carries the RGB OpId as `abi.encode(uint256)`;
        // the settlement module decodes it and surfaces it in the FundsIn event.
        // Other routes define their own blob layout.
        bytes32 operationId = bridge.fundsIn{value: nativeValue}(amount, destChainId, dAddr, abi.encode(rgbOpId));
        vm.stopBroadcast();

        console2.log("fundsIn succeeded. Derived operationId:");
        console2.logBytes32(operationId);
        console2.log("Native spent incl. gas (wei): ", balanceBefore - vm.addr(pk).balance);
        console2.log("Bridge balance:", IERC20(token).balanceOf(bridgeAddr));
    }
}
