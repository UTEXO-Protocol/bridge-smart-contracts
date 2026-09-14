// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Bridge} from "../src/Bridge.sol";
import {BridgeProxy} from "../src/BridgeProxy.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BridgeV2Mock} from "./mocks/BridgeV2Mock.sol";

contract IncompatibleImplementation {
    uint256 public value;
}

contract BridgeProxyTest is Test {
    Bridge internal implementation;
    BridgeProxy internal proxy;
    Bridge internal bridge;
    MockERC20 internal token;

    address internal owner = makeAddr("bridgeOwner");
    address internal routeRegistry = makeAddr("routeRegistry");
    address payable internal commissionManager = payable(makeAddr("commissionManager"));
    address internal lzAdapter = makeAddr("lzAdapter");

    function setUp() public {
        token = new MockERC20("Mock USDT0", "USDT0");
        implementation = new Bridge();
        proxy = new BridgeProxy(address(implementation), _initializationData());
        bridge = Bridge(address(proxy));
    }

    function test_constructor_atomicallyInitializesBridgeAndErc1967Slots() public view {
        assertEq(proxy.implementation(), address(implementation));
        assertEq(bridge.TOKEN(), address(token));
        assertEq(bridge.owner(), owner);
        assertEq(bridge.routeRegistry(), routeRegistry);
        assertEq(address(bridge.commissionManager()), commissionManager);
        assertEq(bridge.lzAdapter(), lzAdapter);
        assertEq(bridge.minFundsInAmount(), 11);
        assertEq(bridge.minFundsOutAmount(), 22);
    }

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(token), routeRegistry, commissionManager, lzAdapter, 11, 22, owner);
    }

    function test_proxyCannotBeInitializedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        bridge.initialize(address(token), routeRegistry, commissionManager, lzAdapter, 11, 22, owner);
    }

    function test_upgradeRequiresOwner() public {
        BridgeV2Mock nextImplementation = new BridgeV2Mock();
        vm.expectRevert(abi.encodeWithSelector(BridgeProxy.UnauthorizedBridgeOwner.selector, address(this)));
        proxy.upgradeToAndCall(address(nextImplementation), bytes(""));
    }

    function test_upgradeAuthorityMovesOnlyAfterOwnershipAcceptance() public {
        address nextOwner = makeAddr("nextOwner");
        BridgeV2Mock nextImplementation = new BridgeV2Mock();
        vm.prank(owner);
        bridge.transferOwnership(nextOwner);

        vm.prank(nextOwner);
        vm.expectRevert(abi.encodeWithSelector(BridgeProxy.UnauthorizedBridgeOwner.selector, nextOwner));
        proxy.upgradeToAndCall(address(nextImplementation), bytes(""));

        vm.prank(owner);
        proxy.upgradeToAndCall(address(nextImplementation), bytes(""));
        assertEq(bridge.pendingOwner(), nextOwner);
        vm.prank(nextOwner);
        bridge.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BridgeProxy.UnauthorizedBridgeOwner.selector, owner));
        proxy.upgradeToAndCall(address(implementation), bytes(""));
        vm.prank(nextOwner);
        proxy.upgradeToAndCall(address(implementation), bytes(""));
        assertEq(proxy.implementation(), address(implementation));
        assertEq(bridge.owner(), nextOwner);
    }

    function test_upgradeRejectsIncompatibleImplementation() public {
        IncompatibleImplementation incompatible = new IncompatibleImplementation();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BridgeProxy.IncompatibleBridgeImplementation.selector, address(incompatible))
        );
        proxy.upgradeToAndCall(address(incompatible), bytes(""));
    }

    function test_upgradeRejectsProxyItselfAsImplementation() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BridgeProxy.IncompatibleBridgeImplementation.selector, address(proxy)));
        proxy.upgradeToAndCall(address(proxy), bytes(""));
    }

    function test_upgradeRejectsAnotherProxyAsImplementation() public {
        Bridge anotherImplementation = new Bridge();
        BridgeProxy anotherProxy = new BridgeProxy(address(anotherImplementation), _initializationData());

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BridgeProxy.IncompatibleBridgeImplementation.selector, address(anotherProxy))
        );
        proxy.upgradeToAndCall(address(anotherProxy), bytes(""));
    }

    function test_upgradeRejectsPlainErc1967ProxyAsImplementation() public {
        Bridge anotherImplementation = new Bridge();
        ERC1967Proxy plainProxy = new ERC1967Proxy(address(anotherImplementation), _initializationData());

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BridgeProxy.IncompatibleBridgeImplementation.selector, address(plainProxy))
        );
        proxy.upgradeToAndCall(address(plainProxy), bytes(""));
    }

    function test_compatibilityMarkerRejectsDelegatedCall() public {
        vm.expectRevert(IBridge.ProxyCompatibilityCheckMustBeDirect.selector);
        bridge.bridgeProxyCompatibilityUUID();
    }

    function test_upgradeAndCallPreservesStateAndInitializesV2() public {
        vm.prank(owner);
        bridge.pauseInflow();
        token.mint(address(proxy), 123 ether);

        BridgeV2Mock nextImplementation = new BridgeV2Mock();
        vm.prank(owner);
        proxy.upgradeToAndCall(address(nextImplementation), abi.encodeCall(BridgeV2Mock.initializeV2, (777)));

        BridgeV2Mock upgraded = BridgeV2Mock(address(proxy));
        assertEq(proxy.implementation(), address(nextImplementation));
        assertEq(upgraded.version(), 2);
        assertEq(upgraded.upgradeValue(), 777);
        assertEq(upgraded.TOKEN(), address(token));
        assertEq(upgraded.owner(), owner);
        assertEq(upgraded.routeRegistry(), routeRegistry);
        assertEq(address(upgraded.commissionManager()), commissionManager);
        assertEq(upgraded.lzAdapter(), lzAdapter);
        assertEq(upgraded.minFundsInAmount(), 11);
        assertEq(upgraded.minFundsOutAmount(), 22);
        assertTrue(upgraded.paused());
        assertEq(token.balanceOf(address(proxy)), 123 ether);
    }

    function test_failedUpgradeInitializationRollsBackImplementation() public {
        BridgeV2Mock nextImplementation = new BridgeV2Mock();
        vm.prank(owner);
        vm.expectRevert(BridgeV2Mock.UpgradeInitializationFailed.selector);
        proxy.upgradeToAndCall(address(nextImplementation), abi.encodeCall(BridgeV2Mock.initializeV2AndRevert, (777)));

        assertEq(proxy.implementation(), address(implementation));
    }

    function test_constructorRejectsEmptyInitializationData() public {
        Bridge nextImplementation = new Bridge();
        vm.expectRevert(ERC1967Proxy.ERC1967ProxyUninitialized.selector);
        new BridgeProxy(address(nextImplementation), bytes(""));
    }

    function _initializationData() internal view returns (bytes memory) {
        return abi.encodeCall(
            Bridge.initialize,
            (address(token), routeRegistry, commissionManager, lzAdapter, uint256(11), uint256(22), owner)
        );
    }
}
