// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

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
/// @dev The effective fee is `amount * stablePercent / multiplier^2 + baseFee`:
///      a proportional part plus a flat part. `baseFee` is denominated in the
///      token's smallest units (the bridged token is a USD-pegged stablecoin, so
///      it doubles as a USD figure) and exists to cover a per-operation cost that
///      does not scale with the amount — notably the Bitcoin transaction fee on
///      the RGB leg. Either part may be zero; both zero disables the route's fee.
struct CommissionConfig {
    uint256 stablePercent;
    uint256 baseFee;
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
    error InvalidFeeShape(uint256 stablePercent, uint8 multiplier);
    error FeeRateTooHigh(uint256 stablePercent, uint8 multiplier);
    error CommissionRoundsToZero(uint256 amount, uint256 stablePercent, uint8 multiplier);
    error ZeroNetAmount(uint256 amount, uint256 commission);
    error NativeCommissionNotAllowedOnFundsOut();
    error FeeAboveAmountFloor(uint256 feeAtFloor, uint256 amountFloor);
    error AmountFloorUnavailable();
    error TokenDecimalsUnavailable();
    error BalanceBelowRecordedPool();
    error NothingReceived();
    error ZeroNativeAmount();
    error InsufficientBalance();
    error NativeTransferFailed();
    error NoBalance();
    error RenounceOwnershipBlocked();

    // --- Chainlink-related ---
    error EthUsdFeedNotSet();
    error InvalidPrice();
    error StalePrice();
    error TokenDecimalsTooLarge();
    error InvalidHeartbeat();
    error SequencerDown();
    error GracePeriodNotOver();
    error PriceOutOfBounds();
    error InvalidPriceBounds();
    error ChainlinkHardeningNotConfigured();
    error InvalidSequencerRound(uint256 startedAt);

    // ============ Events ============

    event BridgeAddressUpdated(address indexed newBridge);

    event GlobalDefaultsUpdated(
        uint256 stablePercent, uint256 baseFee, uint8 multiplier, CommissionSide side, CommissionCurrency currency
    );

    event CommissionRuleUpdated(
        uint256 sourceChainId, uint256 destChainId, address indexed token, CommissionConfig config
    );

    event CommissionRuleCleared(uint256 sourceChainId, uint256 destChainId, address indexed token);

    event TokenCommissionReceived(address indexed token, uint256 amount);
    event NativeCommissionReceived(uint256 amount);

    event EthUsdFeedUpdated(address indexed feed, uint256 heartbeat);

    /// @notice Emitted on `setSequencerUptimeFeed`; zero makes NATIVE quotes fail closed.
    event SequencerUptimeFeedUpdated(address indexed feed);

    /// @notice Emitted on `setEthUsdPriceBounds`; both zero make NATIVE quotes fail closed.
    event EthUsdPriceBoundsUpdated(uint256 minPrice, uint256 maxPrice);

    event TokenCommissionWithdrawn(address indexed token, address indexed to, uint256 amount);
    event NativeCommissionWithdrawn(address indexed to, uint256 amount);

    // ============ State getters ============

    function bridgeAddress() external view returns (address);

    function commissionRecipient() external view returns (address);

    function globalStablePercent() external view returns (uint256);

    function globalBaseFee() external view returns (uint256);

    function globalMultiplier() external view returns (uint8);

    function globalSide() external view returns (CommissionSide);

    function globalCurrency() external view returns (CommissionCurrency);

    function tokenCommissionPool(address token) external view returns (uint256);

    function nativeCommissionPool() external view returns (uint256);

    function ethUsdFeed() external view returns (address);

    function ethUsdHeartbeat() external view returns (uint256);

    function sequencerUptimeFeed() external view returns (address);

    function SEQUENCER_GRACE_PERIOD() external view returns (uint256);

    function ethUsdMinPrice() external view returns (uint256);

    function ethUsdMaxPrice() external view returns (uint256);

    // ============ Core calculations ============

    function calculateFundsInCommission(uint256 sourceChainId, uint256 destChainId, address token, uint256 amount)
        external
        view
        returns (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount);

    function calculateFundsOutCommission(uint256 sourceChainId, uint256 destChainId, address token, uint256 amount)
        external
        view
        returns (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount);

    function calculateStableFee(uint256 amount, uint256 stablePercent, uint256 multiplier)
        external
        pure
        returns (uint256);

    /// @notice Total fee for `amount` under the route's effective rule:
    ///         `calculateStableFee(...) + baseFee`, in token smallest units.
    function calculateTotalFee(uint256 sourceChainId, uint256 destChainId, address token, uint256 amount)
        external
        view
        returns (uint256);

    /// @notice The Bridge's current `minFundsInAmount`. Every configured
    ///         `FUNDS_IN` fee must leave a positive net for a deposit sitting
    ///         exactly on this floor; it is the bound an inbound `baseFee` is
    ///         validated and quoted against.
    function depositFloor() external view returns (uint256);

    /// @notice The Bridge's current `minFundsOutAmount` — the same bound for the
    ///         release side.
    function releaseFloor() external view returns (uint256);

    /// @notice Convert a USD-denominated token fee (stablecoin, 1 token ≈ $1) to
    ///         native wei using the configured ETH/USD Chainlink feed. Reverts
    ///         `EthUsdFeedNotSet` when the price feed is unconfigured,
    ///         `ChainlinkHardeningNotConfigured` unless the sequencer feed and
    ///         price band are both configured, `InvalidPrice` on non-positive
    ///         answers, and `StalePrice` when `updatedAt` is older than the
    ///         configured heartbeat.
    function convertTokenFeeToNative(uint256 tokenFee, uint256 tokenDecimals) external view returns (uint256 nativeFee);

    // ============ Admin / config ============

    function setGlobalDefaults(
        uint256 stablePercent,
        uint256 baseFee,
        uint8 multiplier,
        CommissionSide side,
        CommissionCurrency currency
    ) external;

    /// @notice Configure (or rotate) the ETH/USD Chainlink price feed used for
    ///         NATIVE-currency commission quotes. `heartbeat` is the maximum
    ///         allowed staleness in seconds before `calculate*Commission` reverts
    ///         (Chainlink ETH/USD on Arbitrum heartbeats at 86400 s; a sensible
    ///         setting is ~90000 with a safety buffer). Pass `address(0)` to
    ///         disable NATIVE quoting until a new feed is set.
    function setEthUsdFeed(address feed, uint256 heartbeat) external;

    /// @notice Configure (or rotate) the Chainlink L2 Sequencer Uptime feed used
    ///         to gate NATIVE quotes on Arbitrum. Passing `address(0)` clears
    ///         the configuration and makes non-zero NATIVE quotes fail closed.
    function setSequencerUptimeFeed(address feed) external;

    /// @notice Configure the mandatory [min, max] sanity band on the ETH/USD
    ///         answer (feed decimals). Passing `(0, 0)` clears the configuration
    ///         and makes non-zero NATIVE quotes fail closed; otherwise
    ///         `0 < minPrice < maxPrice`.
    function setEthUsdPriceBounds(uint256 minPrice, uint256 maxPrice) external;

    function setCommissionRule(
        uint256 sourceChainId,
        uint256 destChainId,
        address token,
        CommissionConfig calldata config
    ) external;

    function clearCommissionRule(uint256 sourceChainId, uint256 destChainId, address token) external;

    function setBridgeAddress(address newBridge) external;

    function getGlobalDefaults()
        external
        view
        returns (uint256 stablePercent, uint8 multiplier, CommissionSide side, CommissionCurrency currency);

    function getCommissionRule(uint256 sourceChainId, uint256 destChainId, address token)
        external
        view
        returns (CommissionConfig memory);

    function buildRouteKey(uint256 sourceChainId, uint256 destChainId, address token) external pure returns (bytes32);

    // ============ Commission ingress (bridge) ============

    /// @notice Credit `credited` token units to the commission pool. The Bridge
    ///         measures `credited` as the actual balance increase of this
    ///         contract around its `safeTransfer` (so a fee-on-transfer token is
    ///         handled and no pre-existing/unsolicited balance is absorbed).
    ///         Reverts if the resulting pool would exceed the on-chain balance.
    ///         Callable only by the Bridge.
    function receiveTokenCommission(address token, uint256 credited) external;

    /// @notice Native commission ingress; only `bridgeAddress` may call with non-zero value (see implementation).
    receive() external payable;

    // ============ Withdrawals (owner) ============

    /// @notice Withdraw accrued token commission to the immutable
    ///         `commissionRecipient`.
    function withdrawTokenCommission(address token, uint256 amount) external;

    /// @notice Withdraw accrued native commission to the immutable
    ///         `commissionRecipient`.
    function withdrawNativeCommission(uint256 amount) external;

    /// @notice Withdraw all accrued commission for `token` to the immutable
    ///         `commissionRecipient`.
    function withdrawAllTokenCommission(address token) external;

    /// @notice Withdraw all accrued native commission to the immutable
    ///         `commissionRecipient`.
    function withdrawAllNativeCommission() external;
}
