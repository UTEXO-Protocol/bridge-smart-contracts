// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Bridge} from "../../src/Bridge.sol";
import {ISettlementModule} from "../../src/interfaces/ISettlementModule.sol";
import {FundsInContext, FundsOutContext} from "../../src/interfaces/RouteTypes.sol";

/// @dev Observes intermediate accounting and attempts a nested public deposit.
contract SettlementCallbackObserver is ISettlementModule {
    struct Snapshot {
        uint256 sourceLiquidity;
        uint256 destinationLiquidity;
        uint256 totalLiquidity;
        uint256 custody;
        bool burnConsumed;
        bytes reentryError;
    }

    error HookFailed();

    Bridge private immutable _bridge;
    address private immutable _registry;
    Snapshot private _inbound;
    Snapshot private _outbound;
    uint256 private _burnId;
    bool public failOnInbound;

    constructor(Bridge bridge_, address registry_) {
        _bridge = bridge_;
        _registry = registry_;
    }

    function setFailOnInbound(bool fail) external {
        failOnInbound = fail;
    }

    function snapshot(bool inbound) external view returns (Snapshot memory) {
        return inbound ? _inbound : _outbound;
    }

    function usesRgbMintDepositId() external pure returns (bool) {
        return false;
    }

    function onFundsIn(FundsInContext calldata ctx, bytes calldata) external returns (uint256) {
        require(msg.sender == _registry, "only registry");
        _inbound = _observe(ctx.sourceChainId, ctx.destChainId);
        if (failOnInbound) revert HookFailed();
        return 0;
    }

    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata) external {
        require(msg.sender == _registry, "only registry");
        _burnId = ctx.burnId;
        _outbound = _observe(ctx.sourceChainId, ctx.destChainId);
    }

    function _observe(uint256 sourceChainId, uint256 destinationChainId) private returns (Snapshot memory observed) {
        observed.sourceLiquidity = _bridge.lockedLiquidity(sourceChainId);
        observed.destinationLiquidity = _bridge.lockedLiquidity(destinationChainId);
        observed.totalLiquidity = _bridge.totalLockedLiquidity();
        observed.custody = IERC20(_bridge.TOKEN()).balanceOf(address(_bridge));
        observed.burnConsumed = _bridge.consumedBurnIds(_burnId);
        (bool ok, bytes memory reason) = address(_bridge)
            .call(
                abi.encodeWithSignature("fundsIn(uint256,uint256,string,bytes)", 1, destinationChainId, "", bytes(""))
            );
        require(!ok, "nested deposit succeeded");
        observed.reentryError = reason;
    }
}
