// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title ICommissionManager types & interface
 * @notice Shared enums and struct for {CommissionManager}; see `ICommissionManager` for the external API.
 *
 *         Chain identifiers — both `sourceChainId` and `destChainId` — are uint256
 *         values. EVM chains use their native `block.chainid`. Non-EVM
 *         destinations (RGB, Bitcoin, …) are assigned numeric ids by the Utexo
 *         backend in a namespace reserved above the EVM range (see project
 *         README for the conventions).
 */

/// @notice Which bridge operation a route fee is tied to.
enum CommissionSide {
    FUNDS_IN,
    FUNDS_OUT
}

/// @notice Fee taken in token units or expressed in native wei.
enum CommissionCurrency {
    TOKEN,
    NATIVE
}

/// @notice Commission parameters for one directional route (keyed by `buildRouteKey`).
struct CommissionConfig {
    uint256 stablePercent;
    uint8 multiplier;
    CommissionSide side;
    CommissionCurrency currency;
    bool isSet;
}

/**
 * @title ICommissionManager
 * @notice Commission quotes, owner configuration, and custody of bridge fees. `CommissionManager` is the reference implementation.
 */
interface ICommissionManager {
    // ============ Errors ============

    error OnlyBridge();
    error InvalidBridgeAddress();
    error InvalidToken();
    error InvalidRecipient();
    error StablePercentTooHigh();
    error MultiplierZero();
    error MockTokenToNativeRateNotSet();
    error TokenDecimalsUnavailable();
    error BalanceBelowRecordedPool();
    error NothingReceived();
    error ZeroNativeAmount();
    error InsufficientBalance();
    error NativeTransferFailed();
    error NoBalance();
    error RenounceOwnershipBlocked();

    // ============ Events ============

    event BridgeAddressUpdated(address indexed newBridge);

    event GlobalDefaultsUpdated(
        uint256 stablePercent,
        uint8 multiplier,
        CommissionSide side,
        CommissionCurrency currency
    );

    event CommissionRuleUpdated(
        uint256 sourceChainId,
        uint256 destChainId,
        address indexed token,
        CommissionConfig config
    );

    event CommissionRuleCleared(
        uint256 sourceChainId,
        uint256 destChainId,
        address indexed token
    );

    event TokenCommissionReceived(address indexed token, uint256 amount);
    event NativeCommissionReceived(uint256 amount);

    event MockTokenToNativeRateUpdated(uint256 rate);
    event MockTokenToNativeRateForTokenUpdated(address indexed token, uint256 rate);

    event TokenCommissionWithdrawn(
        address indexed token,
        address indexed to,
        uint256 amount
    );
    event NativeCommissionWithdrawn(address indexed to, uint256 amount);

    // ============ State getters ============

    function bridgeAddress() external view returns (address);

    function globalStablePercent() external view returns (uint256);

    function globalMultiplier() external view returns (uint8);

    function globalSide() external view returns (CommissionSide);

    function globalCurrency() external view returns (CommissionCurrency);

    function tokenCommissionPool(address token) external view returns (uint256);

    function nativeCommissionPool() external view returns (uint256);

    function mockTokenToNativeRate() external view returns (uint256);

    function mockTokenToNativeRateForToken(address token) external view returns (uint256);

    // ============ Core calculations ============

    function calculateFundsInCommission(
        uint256 sourceChainId,
        uint256 destChainId,
        address token,
        uint256 amount
    )
        external
        view
        returns (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount);

    function calculateFundsOutCommission(
        uint256 sourceChainId,
        uint256 destChainId,
        address token,
        uint256 amount
    )
        external
        view
        returns (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount);

    function calculateStableFee(
        uint256 amount,
        uint256 stablePercent,
        uint256 multiplier
    ) external pure returns (uint256);

    function convertTokenToNative(
        uint256 tokenFee,
        uint256 rateWeiPerTokenUnit,
        uint256 tokenDecimals
    ) external pure returns (uint256 nativeFee);

    function resolvedMockTokenToNativeRate(address token) external view returns (uint256);

    // ============ Admin / config ============

    function setGlobalDefaults(
        uint256 stablePercent,
        uint8 multiplier,
        CommissionSide side,
        CommissionCurrency currency
    ) external;

    function setMockTokenToNativeRate(uint256 rate) external;

    function setMockTokenToNativeRateForToken(address token, uint256 rate) external;

    function setCommissionRule(
        uint256 sourceChainId,
        uint256 destChainId,
        address token,
        CommissionConfig calldata config
    ) external;

    function clearCommissionRule(
        uint256 sourceChainId,
        uint256 destChainId,
        address token
    ) external;

    function setBridgeAddress(address newBridge) external;

    function getGlobalDefaults()
        external
        view
        returns (
            uint256 stablePercent,
            uint8 multiplier,
            CommissionSide side,
            CommissionCurrency currency
        );

    function getCommissionRule(
        uint256 sourceChainId,
        uint256 destChainId,
        address token
    ) external view returns (CommissionConfig memory);

    function buildRouteKey(
        uint256 sourceChainId,
        uint256 destChainId,
        address token
    ) external pure returns (bytes32);

    // ============ Commission ingress (bridge) ============

    function receiveTokenCommission(address token) external;

    /// @notice Native commission ingress; only `bridgeAddress` may call with non-zero value (see implementation).
    receive() external payable;

    // ============ Withdrawals (owner) ============

    function withdrawTokenCommission(
        address token,
        address to,
        uint256 amount
    ) external;

    function withdrawNativeCommission(address payable to, uint256 amount) external;

    function withdrawAllTokenCommission(address token, address to) external;

    function withdrawAllNativeCommission(address payable to) external;
}
