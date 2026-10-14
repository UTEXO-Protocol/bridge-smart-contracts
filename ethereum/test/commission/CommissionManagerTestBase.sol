// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {CommissionCurrency, CommissionSide} from "../../src/interfaces/ICommissionManager.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockDepositFloor} from "../mocks/MockDepositFloor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared fixture and helpers for commission tests; contains no test cases.
abstract contract CommissionManagerTestBase is Test {
    CommissionManager internal cm;

    MockERC20 internal token;

    MockAggregatorV3 internal ethUsdFeed;

    address internal constant BRIDGE = address(0xB01);

    address internal owner = makeAddr("owner");

    address internal user = makeAddr("user");

    address internal recipient = makeAddr("recipient");

    /// @dev Chain identifiers are uint256: EVM uses native block.chainid;
    ///      non-EVM endpoints use backend-assigned identifiers.
    uint256 internal constant SRC_CHAIN_ID = 1; // Ethereum mainnet

    uint256 internal constant DST_CHAIN_ID = 1_000_001; // RGB (backend-assigned)

    // Chainlink feed defaults. ETH/USD on Arbitrum reports with 8 decimals;
    // heartbeat 86400 s in production — tests use 1 hour to keep stale-path
    // timestamps deterministic.
    uint8 internal constant FEED_DECIMALS = 8;

    int256 internal constant DEFAULT_ETH_USD = 2_000e8; // $2000 / ETH

    uint256 internal constant HEARTBEAT = 1 hours;

    uint256 internal constant MIN_ETH_USD = 100e8;

    uint256 internal constant MAX_ETH_USD = 100_000e8;

    /// @dev Bridge dust floors the manager reads to bound a flat `baseFee` on
    ///      each side, in token base units. Deliberately different values make
    ///      a test that reads the wrong one fail. This isolated getter fixture
    ///      intentionally inverts the Bridge ordering (inbound >= outbound);
    ///      real Bridge minimum-order validation is covered in bridge/AmountFloors.
    uint256 internal constant DEPOSIT_FLOOR = 1_000_000;

    uint256 internal constant RELEASE_FLOOR = 2_000_000;

    function setUp() public {
        // Start past the heartbeat so stale-time interval subtraction is safe.
        vm.warp(HEARTBEAT * 10);

        // Install deterministic amount-floor getters at the manager's
        // configured Bridge address for these isolated unit tests.
        _installFloors(BRIDGE, DEPOSIT_FLOOR, RELEASE_FLOOR);

        vm.prank(owner);
        cm = new CommissionManager(BRIDGE, recipient);
        token = new MockERC20("Test", "TST");
        vm.prank(owner);
        cm.setGlobalDefaults(0, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        // Install a complete healthy Arbitrum oracle config. The sequencer feed
        // and price band are mandatory whenever a non-zero NATIVE
        // quote consumes ETH/USD.
        ethUsdFeed = new MockAggregatorV3(FEED_DECIMALS, DEFAULT_ETH_USD, vm.getBlockTimestamp());
        MockAggregatorV3 sequencerFeed =
            new MockAggregatorV3(0, 0, vm.getBlockTimestamp() - cm.SEQUENCER_GRACE_PERIOD() - 1);
        vm.startPrank(owner);
        cm.setSequencerUptimeFeed(address(sequencerFeed));
        cm.setEthUsdPriceBounds(MIN_ETH_USD, MAX_ETH_USD);
        cm.setEthUsdFeed(address(ethUsdFeed), HEARTBEAT);
        vm.stopPrank();
    }

    /// @dev Put the Bridge dust-floor getters at `where`, reporting `inFloor`
    ///      for deposits and `outFloor` for releases.
    function _installFloors(address where, uint256 inFloor, uint256 outFloor) private {
        vm.etch(where, address(new MockDepositFloor()).code);
        MockDepositFloor(where).setMinFundsInAmount(inFloor);
        MockDepositFloor(where).setMinFundsOutAmount(outFloor);
    }
}
