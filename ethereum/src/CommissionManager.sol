// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

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
 *      `owner` configures rules and withdraws accumulated pools. Every withdrawal pays the immutable
 *      `commissionRecipient`, regardless of the caller or call path. `renounceOwnership` is disabled.
 *      Withdrawals use `nonReentrant` against reentrancy via ERC-20 hooks or the native recipient.
 */
contract CommissionManager is Ownable2Step, ReentrancyGuard, ICommissionManager {
    using SafeERC20 for IERC20;

    // ============ State Variables ============

    /// @notice Address allowed to credit token and native commission.
    address public bridgeAddress;

    /// @notice Immutable destination for every token and native commission
    ///         withdrawal. Enforced here at the asset-custody layer so no owner
    ///         or alternate proxy call path can redirect accrued commission.
    address public immutable commissionRecipient;

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

    /// @notice Chainlink L2 Sequencer Uptime feed (Arbitrum). NATIVE quotes
    ///         fail closed while this is `address(0)`.
    address public sequencerUptimeFeed;

    /// @notice Seconds after a sequencer restart during which NATIVE quotes are
    ///         rejected — the L2-published price can lag the market right after
    ///         recovery. Chainlink's recommended grace period is 3600s.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600;

    /// @notice Mandatory [min, max] sanity band on the ETH/USD answer (in feed
    ///         decimals). NATIVE quotes fail closed while the band is unset; an
    ///         answer outside it (e.g. an aggregator floored/capped to
    ///         `minAnswer`/`maxAnswer` during an extreme move) reverts
    ///         `PriceOutOfBounds`.
    uint256 public ethUsdMinPrice;
    uint256 public ethUsdMaxPrice;

    // ============ Modifiers ============

    /// @dev Restricts call to `bridgeAddress`.
    modifier onlyBridge() {
        if (msg.sender != bridgeAddress) revert OnlyBridge();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Deploys the manager; `msg.sender` is owner.
     * @param _bridgeAddress Bridge that will send commissions (non-zero).
     * @param _commissionRecipient Immutable destination for all withdrawals (non-zero).
     */
    constructor(address _bridgeAddress, address _commissionRecipient) Ownable(msg.sender) {
        if (_bridgeAddress == address(0)) revert InvalidBridgeAddress();
        if (_commissionRecipient == address(0)) revert InvalidRecipient();
        bridgeAddress = _bridgeAddress;
        commissionRecipient = _commissionRecipient;
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
    function calculateFundsInCommission(uint256 sourceChainId, uint256 destChainId, address token, uint256 amount)
        external
        view
        returns (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount)
    {
        bytes32 ruleKey = buildRouteKey(sourceChainId, destChainId, token);
        CommissionConfig memory config = getEffectiveConfig(ruleKey);

        // Only calculate if this config is for FUNDS_IN
        if (config.side != CommissionSide.FUNDS_IN) {
            return (0, 0, amount);
        }

        // Calculate stable fee in token units
        uint256 stableFee = calculateStableFee(amount, config.stablePercent, config.multiplier);
        _requireNonZeroConfiguredCommission(amount, stableFee, config);

        if (config.currency == CommissionCurrency.TOKEN) {
            // TOKEN commission: deduct from amount
            if (stableFee >= amount) revert ZeroNetAmount(amount, stableFee);
            tokenCommission = stableFee;
            nativeCommission = 0;
            netAmount = amount - tokenCommission;
        } else {
            // NATIVE commission: user pays in ETH/BNB via msg.value
            tokenCommission = 0;
            if (stableFee == 0) {
                nativeCommission = 0;
            } else {
                nativeCommission = convertTokenFeeToNative(stableFee, _tokenDecimals(token));
                if (nativeCommission == 0) {
                    revert CommissionRoundsToZero(amount, config.stablePercent, config.multiplier);
                }
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
    function calculateFundsOutCommission(uint256 sourceChainId, uint256 destChainId, address token, uint256 amount)
        external
        view
        returns (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount)
    {
        bytes32 ruleKey = buildRouteKey(sourceChainId, destChainId, token);
        CommissionConfig memory config = getEffectiveConfig(ruleKey);

        // Only calculate if this config is for FUNDS_OUT
        if (config.side != CommissionSide.FUNDS_OUT) {
            return (0, 0, amount);
        }

        // Calculate stable fee
        uint256 stableFee = calculateStableFee(amount, config.stablePercent, config.multiplier);
        _requireNonZeroConfiguredCommission(amount, stableFee, config);

        if (config.currency == CommissionCurrency.TOKEN) {
            if (stableFee >= amount) revert ZeroNetAmount(amount, stableFee);
            tokenCommission = stableFee;
            nativeCommission = 0;
            netAmount = amount - tokenCommission;
        } else {
            // NATIVE commission for fundsOut: user pays in native (per blueprint)
            tokenCommission = 0;
            if (stableFee == 0) {
                nativeCommission = 0;
            } else {
                nativeCommission = convertTokenFeeToNative(stableFee, _tokenDecimals(token));
                if (nativeCommission == 0) {
                    revert CommissionRoundsToZero(amount, config.stablePercent, config.multiplier);
                }
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
    function calculateStableFee(uint256 amount, uint256 stablePercent, uint256 multiplier)
        public
        pure
        returns (uint256)
    {
        return (amount * stablePercent) / multiplier / multiplier;
    }

    /// @inheritdoc ICommissionManager
    /// @dev Assumes the token is a USD-pegged stablecoin (1 token unit ≈ $1).
    ///      Math:
    ///         tokenFee  is in 10^tokenDecimals units (USD value 1:1)
    ///         price     = ETH/USD scaled by 10^feedDecimals
    ///         nativeFee = (tokenFee_usd / price_usd_per_eth) * 10^18
    ///                   = tokenFee * 10^(18 - tokenDecimals + feedDecimals) / price
    function convertTokenFeeToNative(uint256 tokenFee, uint256 tokenDecimals) public view returns (uint256 nativeFee) {
        if (tokenFee == 0) return 0;
        if (tokenDecimals > 18) revert TokenDecimalsTooLarge();

        address feedAddr = ethUsdFeed;
        if (feedAddr == address(0)) revert EthUsdFeedNotSet();

        // never consume an ETH/USD answer unless both Arbitrum
        // hardening layers are configured. Setters may be executed in separate
        // governance proposals, but the quote path remains fail-closed
        // throughout any partially configured state.
        if (sequencerUptimeFeed == address(0) || ethUsdMinPrice == 0 || ethUsdMaxPrice == 0) {
            revert ChainlinkHardeningNotConfigured();
        }
        _requireSequencerUp();

        AggregatorV3Interface feed = AggregatorV3Interface(feedAddr);

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > ethUsdHeartbeat) revert StalePrice();
        // Mandatory circuit-breaker rejects a floored/capped aggregator answer
        // that the basic `answer > 0` validity check cannot detect.
        if (uint256(answer) < ethUsdMinPrice || uint256(answer) > ethUsdMaxPrice) {
            revert PriceOutOfBounds();
        }

        uint256 scale = 10 ** (18 - tokenDecimals + uint256(feed.decimals()));
        nativeFee = (tokenFee * scale) / uint256(answer);
    }

    /// @dev Reverts unless the Arbitrum L2 sequencer round is initialized, its
    ///      timestamp is sane, and the sequencer is up and past the grace
    ///      period. The uptime feed is a standard `AggregatorV3Interface`:
    ///      `answer == 0` means up, `answer == 1` means down; `startedAt` is when
    ///      the current status round began (the last restart when it returned
    ///      to up).
    function _requireSequencerUp() internal view {
        (, int256 answer, uint256 startedAt,,) = AggregatorV3Interface(sequencerUptimeFeed).latestRoundData();
        if (startedAt == 0 || startedAt > block.timestamp) revert InvalidSequencerRound(startedAt);
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) revert GracePeriodNotOver();
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
        // Joint invariant: the fee fraction is `stablePercent / multiplier^2`.
        // The configured fee must be strictly below 100%. Equality would make
        // TOKEN commission consume the entire amount and create a zero-net
        // settlement; greater values would underflow. Widen to uint256 before
        // squaring — `multiplier` is uint8 and the common `100 * 100` would
        // itself overflow uint8.
        if (stablePercent >= uint256(multiplier) * uint256(multiplier)) {
            revert InvalidFeeShape(stablePercent, multiplier);
        }
        // NATIVE on FUNDS_OUT is unrepresentable: a release has no payer for a
        // native fee
        if (currency == CommissionCurrency.NATIVE && side == CommissionSide.FUNDS_OUT) {
            revert NativeCommissionNotAllowedOnFundsOut();
        }

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

    /// @inheritdoc ICommissionManager
    /// @dev Setting `address(0)` is allowed for staged governance changes or to
    ///      tear down an unused oracle config, but it makes every non-zero
    ///      NATIVE quote revert `ChainlinkHardeningNotConfigured`.
    function setSequencerUptimeFeed(address feed) external onlyOwner {
        sequencerUptimeFeed = feed;
        emit SequencerUptimeFeedUpdated(feed);
    }

    /// @inheritdoc ICommissionManager
    /// @dev Pass `(0, 0)` to clear the band during staged governance changes or
    ///      oracle teardown; NATIVE quotes then fail closed. Otherwise require
    ///      `0 < minPrice < maxPrice` (values in the feed's decimals, e.g.
    ///      `100e8` / `100_000e8` for an 8-decimal ETH/USD feed).
    function setEthUsdPriceBounds(uint256 minPrice, uint256 maxPrice) external onlyOwner {
        if (minPrice == 0 && maxPrice == 0) {
            ethUsdMinPrice = 0;
            ethUsdMaxPrice = 0;
            emit EthUsdPriceBoundsUpdated(0, 0);
            return;
        }
        if (minPrice == 0 || minPrice >= maxPrice) revert InvalidPriceBounds();
        ethUsdMinPrice = minPrice;
        ethUsdMaxPrice = maxPrice;
        emit EthUsdPriceBoundsUpdated(minPrice, maxPrice);
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
        // Joint invariant: the fee fraction is `stablePercent / multiplier^2`.
        // The configured fee must be strictly below 100%. Equality would make
        // TOKEN commission consume the entire amount and create a zero-net
        // settlement; greater values would underflow. Widen to uint256 before
        // squaring — `multiplier` is uint8 and the common `100 * 100` would
        // itself overflow uint8.
        if (config.stablePercent >= uint256(config.multiplier) * uint256(config.multiplier)) {
            revert InvalidFeeShape(config.stablePercent, config.multiplier);
        }
        // NATIVE on FUNDS_OUT is unrepresentable: a release has no payer for a
        // native fee
        if (config.currency == CommissionCurrency.NATIVE && config.side == CommissionSide.FUNDS_OUT) {
            revert NativeCommissionNotAllowedOnFundsOut();
        }

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
    function clearCommissionRule(uint256 sourceChainId, uint256 destChainId, address token) external onlyOwner {
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
    function getEffectiveConfig(bytes32 ruleKey) internal view returns (CommissionConfig memory) {
        CommissionConfig memory config = commissionRules[ruleKey];

        if (config.isSet) {
            return config;
        }

        // Fall back to global defaults
        return CommissionConfig({
            stablePercent: globalStablePercent,
            multiplier: globalMultiplier,
            side: globalSide,
            currency: globalCurrency,
            isSet: true
        });
    }

    /// @dev A deliberately disabled fee (`stablePercent == 0`) is valid. Once
    ///      governance enables a fee, however, every operation governed by that
    ///      rule must pay at least one smallest unit. This runtime check couples
    ///      the effective per-route/global rule to the actual transfer amount,
    ///      so later configuration changes cannot reopen commission-free dust.
    function _requireNonZeroConfiguredCommission(uint256 amount, uint256 stableFee, CommissionConfig memory config)
        private
        pure
    {
        if (config.stablePercent != 0 && stableFee == 0) {
            revert CommissionRoundsToZero(amount, config.stablePercent, config.multiplier);
        }
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
        returns (uint256 stablePercent, uint8 multiplier, CommissionSide side, CommissionCurrency currency)
    {
        return (globalStablePercent, globalMultiplier, globalSide, globalCurrency);
    }

    /**
     * @notice Raw storage read for a route (may be unset; check `config.isSet`).
     * @param sourceChainId Route source id.
     * @param destChainId Route destination id.
     * @param token ERC-20 token.
     * @return config Stored override or empty struct if never set.
     */
    function getCommissionRule(uint256 sourceChainId, uint256 destChainId, address token)
        external
        view
        returns (CommissionConfig memory)
    {
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
    function buildRouteKey(uint256 sourceChainId, uint256 destChainId, address token) public pure returns (bytes32) {
        return keccak256(abi.encode(sourceChainId, destChainId, token));
    }

    // ============ Commission Collection Functions ============

    /**
     * @notice Credits `credited` token units to `tokenCommissionPool[token]`.
     * @param token ERC-20 token (non-zero). Bridge must transfer tokens before this call.
     * @param credited The Bridge-measured balance increase of THIS contract from
     *        its `safeTransfer` (fee-on-transfer safe). Credited as-is rather than
     *        recomputed from `balanceOf - pool`, so a pre-existing/unsolicited
     *        direct transfer is never folded into the pool.
     * @dev Reverts if the resulting pool would exceed the on-chain balance —
     *      guards against a caller crediting more than actually arrived.
     */
    function receiveTokenCommission(address token, uint256 credited) external onlyBridge {
        if (token == address(0)) revert InvalidToken();
        if (credited == 0) revert NothingReceived();
        uint256 newPool = tokenCommissionPool[token] + credited;
        if (IERC20(token).balanceOf(address(this)) < newPool) revert BalanceBelowRecordedPool();
        tokenCommissionPool[token] = newPool;
        emit TokenCommissionReceived(token, credited);
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
     * @notice Owner withdraws `amount` of accrued `token` commission.
     * @param token ERC-20 token (non-zero).
     * @param amount Amount to send (≤ pool).
     * @dev Always pays immutable `commissionRecipient`. `nonReentrant`; updates
     *      pool before `safeTransfer`.
     */
    function withdrawTokenCommission(address token, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0)) revert InvalidToken();
        if (tokenCommissionPool[token] < amount) revert InsufficientBalance();

        tokenCommissionPool[token] -= amount;
        IERC20(token).safeTransfer(commissionRecipient, amount);

        emit TokenCommissionWithdrawn(token, commissionRecipient, amount);
    }

    /**
     * @notice Owner withdraws `amount` wei of native commission.
     * @param amount Wei to send (≤ pool).
     * @dev Always pays immutable `commissionRecipient`. `nonReentrant`; updates
     *      pool before native transfer.
     */
    function withdrawNativeCommission(uint256 amount) external onlyOwner nonReentrant {
        if (nativeCommissionPool < amount) revert InsufficientBalance();

        nativeCommissionPool -= amount;
        (bool success,) = payable(commissionRecipient).call{value: amount}("");
        if (!success) revert NativeTransferFailed();

        emit NativeCommissionWithdrawn(commissionRecipient, amount);
    }

    /**
     * @notice Owner withdraws the full accrued balance for `token`.
     * @param token ERC-20 token (non-zero).
     * @dev Always pays immutable `commissionRecipient`. `nonReentrant`.
     *      Reverts `NoBalance` if pool is zero.
     */
    function withdrawAllTokenCommission(address token) external onlyOwner nonReentrant {
        if (token == address(0)) revert InvalidToken();
        uint256 balance = tokenCommissionPool[token];
        if (balance == 0) revert NoBalance();

        tokenCommissionPool[token] = 0;
        IERC20(token).safeTransfer(commissionRecipient, balance);

        emit TokenCommissionWithdrawn(token, commissionRecipient, balance);
    }

    /**
     * @notice Owner withdraws the full `nativeCommissionPool`.
     * @dev Always pays immutable `commissionRecipient`. `nonReentrant`.
     *      Reverts `NoBalance` if pool is zero.
     */
    function withdrawAllNativeCommission() external onlyOwner nonReentrant {
        uint256 balance = nativeCommissionPool;
        if (balance == 0) revert NoBalance();

        nativeCommissionPool = 0;
        (bool success,) = payable(commissionRecipient).call{value: balance}("");
        if (!success) revert NativeTransferFailed();

        emit NativeCommissionWithdrawn(commissionRecipient, balance);
    }
}
