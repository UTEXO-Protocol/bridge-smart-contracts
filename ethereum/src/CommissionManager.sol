// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
 *      fee in native wei using owner-set **mock** rates and `IERC20Metadata.decimals()` on `token`.
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

    /// @notice Global mock wei-per-token rate for NATIVE conversion if per-token mock is unset.
    uint256 public mockTokenToNativeRate;
    /// @notice Per-token mock rate; zero means use `mockTokenToNativeRate`.
    mapping(address => uint256) public mockTokenToNativeRateForToken;

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
     *      `resolvedMockTokenToNativeRate` and `IERC20Metadata(token).decimals()`.
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
                uint256 rate = resolvedMockTokenToNativeRate(token);
                if (rate == 0) revert MockTokenToNativeRateNotSet();
                nativeCommission = convertTokenToNative(
                    stableFee,
                    rate,
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
                uint256 rate = resolvedMockTokenToNativeRate(token);
                if (rate == 0) revert MockTokenToNativeRateNotSet();
                nativeCommission = convertTokenToNative(
                    stableFee,
                    rate,
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

    /**
     * @notice Convert a token-denominated fee to native wei (blueprint `convertTokenToNative`).
     * @param tokenFee Fee in token smallest units.
     * @param rateWeiPerTokenUnit Mock rate: wei per 10**`tokenDecimals` token units.
     * @param tokenDecimals Token decimals (e.g. 18).
     * @return nativeFee Equivalent native amount in wei.
     */
    function convertTokenToNative(
        uint256 tokenFee,
        uint256 rateWeiPerTokenUnit,
        uint256 tokenDecimals
    ) public pure returns (uint256 nativeFee) {
        nativeFee = (tokenFee * rateWeiPerTokenUnit) / (10 ** tokenDecimals);
    }

    /**
     * @notice Effective mock wei-per-token rate: per-token if non-zero, else global.
     * @param token ERC-20 token (used with decimals in commission math).
     * @return rate Wei-per-token-unit rate for `convertTokenToNative`.
     */
    function resolvedMockTokenToNativeRate(address token) public view returns (uint256) {
        uint256 r = mockTokenToNativeRateForToken[token];
        if (r != 0) return r;
        return mockTokenToNativeRate;
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

    /**
     * @notice Sets `mockTokenToNativeRate` (fallback when per-token mock is zero).
     * @param rate Wei-per-token-unit rate for `convertTokenToNative`.
     */
    function setMockTokenToNativeRate(uint256 rate) external onlyOwner {
        mockTokenToNativeRate = rate;
        emit MockTokenToNativeRateUpdated(rate);
    }

    /**
     * @notice Sets or clears per-token mock rate for NATIVE commission quotes.
     * @param token ERC-20 token (non-zero).
     * @param rate Mock rate; 0 clears override so global `mockTokenToNativeRate` applies.
     */
    function setMockTokenToNativeRateForToken(address token, uint256 rate) external onlyOwner {
        if (token == address(0)) revert InvalidToken();
        mockTokenToNativeRateForToken[token] = rate;
        emit MockTokenToNativeRateForTokenUpdated(token, rate);
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
