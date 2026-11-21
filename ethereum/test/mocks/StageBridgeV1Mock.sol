// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {BridgeBaseUpgradeable} from "../../src/BridgeBaseUpgradeable.sol";
import {ICommissionManager} from "../../src/interfaces/ICommissionManager.sol";
import {OutflowRateLimiter} from "../../src/libraries/OutflowRateLimiter.sol";
import {RollingOutflowLimiter} from "../../src/libraries/RollingOutflowLimiter.sol";

/// @notice Characterization fixture matching the Bridge storage deployed from `dev` to stage.
/// @dev Declaration order through `minFundsOutAmount` is the upgrade contract under test.
contract StageBridgeV1Mock is BridgeBaseUpgradeable {
    address private immutable _IMPLEMENTATION_SELF = address(this);

    ICommissionManager public commissionManager;
    address public routeRegistry;
    address public lzAdapter;
    mapping(uint256 burnId => bool consumed) public consumedBurnIds;
    mapping(uint256 sourceChainId => mapping(bytes32 sourceSender => uint256 nonce)) public sourceSenderNonces;
    mapping(uint256 chainId => uint256 locked) public lockedLiquidity;
    uint256 public totalLockedLiquidity;
    mapping(uint256 chainId => OutflowRateLimiter.Bucket) public chainBuckets;
    OutflowRateLimiter.Bucket public globalBucket;
    mapping(uint256 chainId => RollingOutflowLimiter.Window) private _chainSafetyWindows;
    RollingOutflowLimiter.Window private _globalSafetyWindow;
    uint256 public minFundsInAmount;
    uint256 public minFundsOutAmount;

    error ProxyCompatibilityCheckMustBeDirect();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function bridgeProxyCompatibilityUUID() external view returns (bytes32) {
        if (address(this) != _IMPLEMENTATION_SELF) revert ProxyCompatibilityCheckMustBeDirect();
        return keccak256("utexo.bridge.proxy.compatibility.v1");
    }

    function initialize(
        address token,
        address routeRegistry_,
        address payable commissionManager_,
        address lzAdapter_,
        uint256 minFundsInAmount_,
        uint256 minFundsOutAmount_,
        address initialOwner
    ) external initializer {
        __BridgeBaseUpgradeable_init(token, initialOwner);
        routeRegistry = routeRegistry_;
        commissionManager = ICommissionManager(commissionManager_);
        lzAdapter = lzAdapter_;
        minFundsInAmount = minFundsInAmount_;
        minFundsOutAmount = minFundsOutAmount_;
    }

    function seedLegacyState(uint256 chainId, bytes32 sourceSender, uint256 burnId) external onlyOwner {
        consumedBurnIds[burnId] = true;
        sourceSenderNonces[chainId][sourceSender] = 17;
        lockedLiquidity[chainId] = 4_321;
        totalLockedLiquidity = 4_321;

        chainBuckets[chainId] =
            OutflowRateLimiter.Bucket({tokens: 101, lastUpdated: 202, isEnabled: true, capacity: 303, rate: 4});
        globalBucket =
            OutflowRateLimiter.Bucket({tokens: 505, lastUpdated: 606, isEnabled: true, capacity: 707, rate: 8});

        RollingOutflowLimiter.Window storage chainWindow = _chainSafetyWindows[chainId];
        chainWindow.spent = 909;
        chainWindow.lastEpoch = block.timestamp / 1 hours;
        chainWindow.initialized = true;
        chainWindow.slots[chainWindow.lastEpoch % 25] = 909;

        _globalSafetyWindow.spent = 1_010;
        _globalSafetyWindow.lastEpoch = block.timestamp / 1 hours;
        _globalSafetyWindow.initialized = true;
        _globalSafetyWindow.slots[_globalSafetyWindow.lastEpoch % 25] = 1_010;
    }
}
