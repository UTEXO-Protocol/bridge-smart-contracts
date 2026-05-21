// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager
} from "./interfaces/ICommissionManager.sol";

/**
 * @title CommissionManager
 * @author UTEXO bridge stack
 * @notice On-chain commission quotes, owner configuration, and custody of bridge fees (ERC-20 and native).
 * @dev Blueprint v3-style design: **global defaults** plus optional **per-route overrides** keyed by
 *      `keccak256(abi.encode(sourceChainId, destChainId, token))`. Chain ids are `uint256` values: EVM
 *      chains use their native `block.chainid`; non-EVM endpoints (RGB, Bitcoin, …) are assigned
 *      numeric ids by the Utexo backend in a namespace reserved above the EVM range (see README).
 *      Routes are **directional** (swapping source and destination yields a different key), so
 *      independent rules can apply to each leg of a round trip (e.g. ETH→RGB vs RGB→ETH).
 *
 *      **Side (`CommissionSide`):** For a given route config, commission applies only to **either**
 *      `FUNDS_IN` **or** `FUNDS_OUT`, matching `calculateFundsInCommission` vs `calculateFundsOutCommission`.
 *      **Currency (`CommissionCurrency`):** `TOKEN` deducts fee from the bridged amount; `NATIVE` expresses
 *      fee in native wei. NATIVE quoting reads ETH/USD from a Chainlink price feed (`ethUsdFeed`) and
 *      assumes the bridged token is a USD-pegged stablecoin (1 token unit ≈ $1) — the bridge currently
 *      only supports USDT0, so a single ETH/USD feed is sufficient and we avoid trusting a USDT/USD feed
 *      whose error margin would be negligible against the fee itself. Stale answers (older than
 *      `ethUsdHeartbeat`) and non-positive answers revert the call.
 *
 *      **Roles:** `bridgeAddress` may call `receiveTokenCommission` and `receive()` to credit fees;
 *      `owner` configures rules and withdraws accumulated pools. `renounceOwnership` is disabled.
 *      Withdrawals use `nonReentrant` against reentrancy via ERC-20 hooks or native recipients.
 */
contract CommissionManager is Ownable, ReentrancyGuard, ICommissionManager {
    using SafeERC20 for IERC20;

    // ============ State Variables ============

    /// @notice Address allowed to credit token and native commission.
    address public bridgeAddress;

    /// @notice Default `stablePercent` when no per-route rule exists (×100; 0 = no % fee until configured).
    uint256 public globalStablePercent = 0;
    /// @notice Default `multiplier` for `calculateStableFee` (typically 100).
    uint8 public globalMultiplier = 100;
    /// @notice Default `side` for routes without an override.
    CommissionSide public globalSide = CommissionSide.FUNDS_IN;
    /// @notice Default `currency` for routes without an override.
    CommissionCurrency public globalCurrency = CommissionCurrency.TOKEN;

    /// @notice Maximum allowed `stablePercent` (9000 = 90%).
    uint256 private constant _MAX_STABLE_PERCENT = 9000;

    /// @notice Per-route overrides; key = `buildRouteKey(sourceChainId, destChainId, token)`.
    mapping(bytes32 => CommissionConfig) public commissionRules;

    /// @notice Accrued ERC-20 commission per token (tracks balance held for that token).
    mapping(address => uint256) public tokenCommissionPool;
    /// @notice Accrued native commission in wei.
    uint256 public nativeCommissionPool;

    /// @notice Chainlink ETH/USD aggregator used to quote NATIVE commissions.
    ///         `address(0)` (default after deploy) closes the NATIVE path until
    ///         federation governance wires a real feed via `setEthUsdFeed`.
    address public ethUsdFeed;
    /// @notice Maximum allowed staleness of `ethUsdFeed.latestRoundData().updatedAt`
    ///         in seconds. Quotes revert `StalePrice` when the answer is older.
    uint256 public ethUsdHeartbeat;

    // ============ Modifiers ============

    /// @dev Restricts call to `bridgeAddress`.
    modifier onlyBridge() {
        if (msg.sender != bridgeAddress) revert OnlyBridge();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Deploys the manager; `msg.sender` is owner; `_bridgeAddress` is the initial bridge.
     * @param _bridgeAddress Bridge that will send commissions (non-zero).
     */
    constructor(address _bridgeAddress) Ownable(msg.sender) {
        if (_bridgeAddress == address(0)) revert InvalidBridgeAddress();
        bridgeAddress = _bridgeAddress;
    }

    /// @inheritdoc Ownable
    /// @notice Always reverts. Use `transferOwnership` to change admin.
    function renounceOwnership() public view override(Ownable) onlyOwner {
        revert RenounceOwnershipBlocked();
    }

    // ============ Core Calculation Functions ============

    /**
     * @notice Quote commission for an inbound (`fundsIn`) transfer on this chain.
     * @param sourceChainId Origin chain id (must match configured route keys).
     *                      EVM source uses `block.chainid`; non-EVM source uses
     *                      the backend's assigned numeric id.
     * @param destChainId Destination chain id (EVM `block.chainid` or assigned
     *                    backend id for non-EVM targets).
     * @param token ERC-20 token used for the transfer.
     * @param amount Gross amount bridged (same units as token).
     * @return tokenCommission Fee in token smallest units (0 if not `TOKEN` currency).
     * @return nativeCommission Fee in wei (0 if not `NATIVE` currency).
     * @return netAmount Amount after fee if `TOKEN`; full `amount` if `NATIVE` (fee paid separately in native).
     * @dev Returns `(0, 0, amount)` if effective `side` is not `FUNDS_IN`. NATIVE path uses
     *      `convertTokenFeeToNative` (Chainlink ETH/USD) and `IERC20Metadata(token).decimals()`.
     */
    function calculateFundsInCommission(
        uint256 sourceChainId,
        uint256 destChainId,
        address token,
        uint256 amount
    )
        external
        view
        returns (
            uint256 tokenCommission,
            uint256 nativeCommission,
            uint256 netAmount
        )
    {
        bytes32 ruleKey = buildRouteKey(sourceChainId, destChainId, token);
        CommissionConfig memory config = getEffectiveConfig(ruleKey);

        // Only calculate if this config is for FUNDS_IN
        if (config.side != CommissionSide.FUNDS_IN) {
            return (0, 0, amount);
        }

        // Calculate stable fee in token units
        uint256 stableFee = calculateStableFee(amount, config.stablePercent, config.multiplier);

        if (config.currency == CommissionCurrency.TOKEN) {
            // TOKEN commission: deduct from amount
            tokenCommission = stableFee;
            nativeCommission = 0;
            netAmount = amount - tokenCommission;
        } else {
            // NATIVE commission: user pays in ETH/BNB via msg.value
            tokenCommission = 0;
            if (stableFee == 0) {
                nativeCommission = 0;
            } else {
                nativeCommission = convertTokenFeeToNative(
                    stableFee,
                    _tokenDecimals(token)
                );
            }
            netAmount = amount; // Full amount bridges
        }
    }

    /**
     * @notice Quote commission for an outbound (`fundsOut`) release on this chain.
     * @param sourceChainId Origin chain id (must match configured route keys).
     *                      For RGB→EVM the source is the backend's assigned id
     *                      for the Bitcoin-side network.
     * @param destChainId Destination chain id (the EVM chain receiving the release).
     * @param token ERC-20 token being released.
     * @param amount Gross amount to release before fee.
     * @return tokenCommission Fee in token units (0 if not `TOKEN` currency).
     * @return nativeCommission Fee in wei (0 if not `NATIVE`).
     * @return netAmount User receives `amount - tokenCommission` for `TOKEN`; `amount` for `NATIVE` (fee separate).
     * @dev Returns `(0, 0, amount)` if effective `side` is not `FUNDS_OUT`. See `calculateFundsInCommission` for rates/decimals.
     */
    function calculateFundsOutCommission(
        uint256 sourceChainId,
        uint256 destChainId,
        address token,
        uint256 amount
    )
        external
        view
        returns (
            uint256 tokenCommission,
            uint256 nativeCommission,
            uint256 netAmount
        )
    {
        bytes32 ruleKey = buildRouteKey(sourceChainId, destChainId, token);
        CommissionConfig memory config = getEffectiveConfig(ruleKey);

        // Only calculate if this config is for FUNDS_OUT
        if (config.side != CommissionSide.FUNDS_OUT) {
            return (0, 0, amount);
        }

        // Calculate stable fee
        uint256 stableFee = calculateStableFee(amount, config.stablePercent, config.multiplier);

        if (config.currency == CommissionCurrency.TOKEN) {
            tokenCommission = stableFee;
            nativeCommission = 0;
            netAmount = amount - tokenCommission;
        } else {
            // NATIVE commission for fundsOut: user pays in native (per blueprint)
            tokenCommission = 0;
            if (stableFee == 0) {
                nativeCommission = 0;
            } else {
                nativeCommission = convertTokenFeeToNative(
                    stableFee,
                    _tokenDecimals(token)
                );
            }
            netAmount = amount;
        }
    }

    /**
     * @notice Stable fee: `(amount * stablePercent) / multiplier / multiplier`.
     * @param amount Token amount in smallest units.
     * @param stablePercent Percent × 100 (e.g. 400 = 4%).
     * @param multiplier Typically 100.
     * @return Fee in token smallest units.
     */
    function calculateStableFee(
        uint256 amount,
        uint256 stablePercent,
        uint256 multiplier
    ) public pure returns (uint256) {
        return (amount * stablePercent) / multiplier / multiplier;
    }

    /// @inheritdoc ICommissionManager
    /// @dev Assumes the token is a USD-pegged stablecoin (1 token unit ≈ $1).
    ///      Math:
    ///         tokenFee  is in 10^tokenDecimals units (USD value 1:1)
    ///         price     = ETH/USD scaled by 10^feedDecimals
    ///         nativeFee = (tokenFee_usd / price_usd_per_eth) * 10^18
    ///                   = tokenFee * 10^(18 - tokenDecimals + feedDecimals) / price
    function convertTokenFeeToNative(
        uint256 tokenFee,
        uint256 tokenDecimals
    ) public view returns (uint256 nativeFee) {
        if (tokenFee == 0) return 0;
        if (tokenDecimals > 18) revert TokenDecimalsTooLarge();

        address feedAddr = ethUsdFeed;
        if (feedAddr == address(0)) revert EthUsdFeedNotSet();
        AggregatorV3Interface feed = AggregatorV3Interface(feedAddr);

        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > ethUsdHeartbeat) revert StalePrice();

        uint256 scale = 10 ** (18 - tokenDecimals + uint256(feed.decimals()));
        nativeFee = (tokenFee * scale) / uint256(answer);
    }

    /**
     * @notice ERC-20 `decimals()` as `uint256` for exponent math.
     * @param token Token to query.
     * @return Token decimals (typically 6–18).
     * @dev Reverts `TokenDecimalsUnavailable` if the call fails (non-standard token).
     */
    function _tokenDecimals(address token) internal view returns (uint256) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return uint256(d);
        } catch {
            revert TokenDecimalsUnavailable();
        }
    }

    // ============ Configuration Functions ============

    /**
     * @notice Sets defaults used when no per-route rule exists for a key.
     * @param stablePercent Percent × 100 (0 = no stable % fee); must be ≤ 9000.
     * @param multiplier Default multiplier (typically 100).
     * @param side Default `FUNDS_IN` vs `FUNDS_OUT`.
     * @param currency Default `TOKEN` vs `NATIVE`.
     */
    function setGlobalDefaults(
        uint256 stablePercent,
        uint8 multiplier,
        CommissionSide side,
        CommissionCurrency currency
    ) external onlyOwner {
        if (stablePercent > _MAX_STABLE_PERCENT) revert StablePercentTooHigh();
        if (multiplier == 0) revert MultiplierZero();

        globalStablePercent = stablePercent;
        globalMultiplier = multiplier;
        globalSide = side;
        globalCurrency = currency;

        emit GlobalDefaultsUpdated(stablePercent, multiplier, side, currency);
    }

    /// @inheritdoc ICommissionManager
    /// @dev Set `feed == address(0)` to disable the NATIVE path entirely
    ///      (all subsequent NATIVE quotes revert `EthUsdFeedNotSet`). When a
    ///      non-zero `feed` is supplied `heartbeat` must be non-zero; a sensible
    ///      value is the feed's published heartbeat plus a small buffer.
    function setEthUsdFeed(address feed, uint256 heartbeat) external onlyOwner {
        if (feed == address(0)) {
            // Closing the path — ignore any provided heartbeat to keep the
            // off-state self-consistent.
            ethUsdFeed = address(0);
            ethUsdHeartbeat = 0;
            emit EthUsdFeedUpdated(address(0), 0);
            return;
        }
        if (heartbeat == 0) revert InvalidHeartbeat();
        ethUsdFeed = feed;
        ethUsdHeartbeat = heartbeat;
        emit EthUsdFeedUpdated(feed, heartbeat);
    }

    /**
     * @notice Writes or replaces the override for `buildRouteKey(sourceChainId, destChainId, token)`.
     * @param sourceChainId Route source id (directional; paired with `destChainId`).
     * @param destChainId Route destination id.
     * @param token ERC-20 token (non-zero).
     * @param config Rule parameters; `isSet` is forced true on store.
     */
    function setCommissionRule(
        uint256 sourceChainId,
        uint256 destChainId,
        address token,
        CommissionConfig calldata config
    ) external onlyOwner {
        if (token == address(0)) revert InvalidToken();
        // Validate config
        if (config.stablePercent > _MAX_STABLE_PERCENT) revert StablePercentTooHigh();
        if (config.multiplier == 0) revert MultiplierZero();

        // Build route key
        bytes32 key = buildRouteKey(sourceChainId, destChainId, token);

        commissionRules[key] = config;
        commissionRules[key].isSet = true;

        emit CommissionRuleUpdated(sourceChainId, destChainId, token, config);
    }

    /**
     * @notice Deletes the override for this route key; `getEffectiveConfig` will use globals.
     * @param sourceChainId Route source id.
     * @param destChainId Route destination id.
     * @param token ERC-20 token (non-zero).
     */
    function clearCommissionRule(
        uint256 sourceChainId,
        uint256 destChainId,
        address token
    ) external onlyOwner {
        if (token == address(0)) revert InvalidToken();
        bytes32 key = buildRouteKey(sourceChainId, destChainId, token);
        delete commissionRules[key];
        emit CommissionRuleCleared(sourceChainId, destChainId, token);
    }

    /**
     * @notice Updates `bridgeAddress` (only that address may credit commissions).
     * @param newBridge Non-zero bridge contract.
     */
    function setBridgeAddress(address newBridge) external onlyOwner {
        if (newBridge == address(0)) revert InvalidBridgeAddress();
        bridgeAddress = newBridge;
        emit BridgeAddressUpdated(newBridge);
    }

    // ============ View Functions ============

    /**
     * @notice Resolves stored rule or materializes global defaults with `isSet: true`.
     * @param ruleKey `buildRouteKey` output.
     * @return config Effective parameters for calculators.
     */
    function getEffectiveConfig(
        bytes32 ruleKey
    ) internal view returns (CommissionConfig memory) {
        CommissionConfig memory config = commissionRules[ruleKey];

        if (config.isSet) {
            return config;
        }

        // Fall back to global defaults
        return
            CommissionConfig({
                stablePercent: globalStablePercent,
                multiplier: globalMultiplier,
                side: globalSide,
                currency: globalCurrency,
                isSet: true
            });
    }

    /**
     * @notice Returns current global defaults (used when no per-route override exists).
     * @return stablePercent Global percent × 100.
     * @return multiplier Global multiplier.
     * @return side Global `CommissionSide`.
     * @return currency Global `CommissionCurrency`.
     */
    function getGlobalDefaults()
        external
        view
        returns (
            uint256 stablePercent,
            uint8 multiplier,
            CommissionSide side,
            CommissionCurrency currency
        )
    {
        return (
            globalStablePercent,
            globalMultiplier,
            globalSide,
            globalCurrency
        );
    }

    /**
     * @notice Raw storage read for a route (may be unset; check `config.isSet`).
     * @param sourceChainId Route source id.
     * @param destChainId Route destination id.
     * @param token ERC-20 token.
     * @return config Stored override or empty struct if never set.
     */
    function getCommissionRule(
        uint256 sourceChainId,
        uint256 destChainId,
        address token
    ) external view returns (CommissionConfig memory) {
        bytes32 ruleKey = buildRouteKey(sourceChainId, destChainId, token);
        return commissionRules[ruleKey];
    }

    /**
     * @notice Deterministic route id for commission rules.
     * @param sourceChainId Route source id.
     * @param destChainId Route destination id.
     * @param token ERC-20 token address.
     * @return key `keccak256(abi.encode(sourceChainId, destChainId, token))`.
     */
    function buildRouteKey(
        uint256 sourceChainId,
        uint256 destChainId,
        address token
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(sourceChainId, destChainId, token));
    }

    // ============ Commission Collection Functions ============

    /**
     * @notice Credits token commission: increases `tokenCommissionPool[token]` by the actual balance delta.
     * @param token ERC-20 token (non-zero). Bridge must transfer tokens before this call.
     * @dev Pool tracks on-chain balance; no calldata amount (supports fee-on-transfer tokens).
     */
    function receiveTokenCommission(address token) external onlyBridge {
        if (token == address(0)) revert InvalidToken();
        uint256 newBalance = IERC20(token).balanceOf(address(this));
        uint256 priorPool = tokenCommissionPool[token];
        if (newBalance < priorPool) revert BalanceBelowRecordedPool();
        uint256 recorded = newBalance - priorPool;
        if (recorded == 0) revert NothingReceived();
        tokenCommissionPool[token] = newBalance;
        emit TokenCommissionReceived(token, recorded);
    }

    /**
     * @notice Accepts native commission from the bridge; increases `nativeCommissionPool`.
     * @dev Callable only by `bridgeAddress`; `msg.value` must be non-zero.
     */
    receive() external payable onlyBridge {
        if (msg.value == 0) revert ZeroNativeAmount();
        nativeCommissionPool += msg.value;
        emit NativeCommissionReceived(msg.value);
    }

    // ============ Withdrawal Functions ============

    /**
     * @notice Owner withdraws `amount` of accrued `token` commission to `to`.
     * @param token ERC-20 token (non-zero).
     * @param to Recipient (non-zero).
     * @param amount Amount to send (≤ pool).
     * @dev `nonReentrant`; updates pool before `safeTransfer`.
     */
    function withdrawTokenCommission(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (token == address(0)) revert InvalidToken();
        if (to == address(0)) revert InvalidRecipient();
        if (tokenCommissionPool[token] < amount) revert InsufficientBalance();

        tokenCommissionPool[token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit TokenCommissionWithdrawn(token, to, amount);
    }

    /**
     * @notice Owner withdraws `amount` wei of native commission.
     * @param to Recipient (non-zero).
     * @param amount Wei to send (≤ pool).
     * @dev `nonReentrant`; updates pool before native transfer.
     */
    function withdrawNativeCommission(
        address payable to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidRecipient();
        if (nativeCommissionPool < amount) revert InsufficientBalance();

        nativeCommissionPool -= amount;
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert NativeTransferFailed();

        emit NativeCommissionWithdrawn(to, amount);
    }

    /**
     * @notice Owner withdraws the full accrued balance for `token` to `to`.
     * @param token ERC-20 token (non-zero).
     * @param to Recipient (non-zero).
     * @dev `nonReentrant`. Reverts `NoBalance` if pool is zero.
     */
    function withdrawAllTokenCommission(address token, address to) external onlyOwner nonReentrant {
        if (token == address(0)) revert InvalidToken();
        if (to == address(0)) revert InvalidRecipient();
        uint256 balance = tokenCommissionPool[token];
        if (balance == 0) revert NoBalance();

        tokenCommissionPool[token] = 0;
        IERC20(token).safeTransfer(to, balance);

        emit TokenCommissionWithdrawn(token, to, balance);
    }

    /**
     * @notice Owner withdraws the full `nativeCommissionPool` to `to`.
     * @param to Recipient (non-zero).
     * @dev `nonReentrant`. Reverts `NoBalance` if pool is zero.
     */
    function withdrawAllNativeCommission(address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidRecipient();
        uint256 balance = nativeCommissionPool;
        if (balance == 0) revert NoBalance();

        nativeCommissionPool = 0;
        (bool success, ) = to.call{value: balance}("");
        if (!success) revert NativeTransferFailed();

        emit NativeCommissionWithdrawn(to, balance);
    }
}
