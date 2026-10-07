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

contract MissingOwnerImplementation {
    function bridgeProxyCompatibilityUUID() external pure returns (bytes32) {
        return keccak256("utexo.bridge.proxy.compatibility.v1");
    }
}

contract RevertingOwnerImplementation is MissingOwnerImplementation {
    function owner() external pure returns (address) {
        revert("broken owner");
    }
}

contract MalformedOwnerImplementation is MissingOwnerImplementation {
    fallback() external {
        assembly { return(0, 1) }
    }
}

/// @dev A view getter can report a different owner without changing storage.
contract SpoofedOwnerImplementation is BridgeV2Mock {
    address private immutable _reportedOwner;

    constructor(address reportedOwner_) {
        _reportedOwner = reportedOwner_;
    }

    function owner() public view override returns (address) {
        return _reportedOwner;
    }
}

/// @dev A genuine implementation may answer unknown selectors with one word.
contract WordFallbackImplementation is BridgeV2Mock {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 42)
            return(0, 32)
        }
    }
}

contract InvalidCompatibilityMarkerImplementation {
    uint8 private immutable _mode;

    constructor(uint8 mode_) {
        _mode = mode_;
    }

    function initializeStub() external pure {}

    fallback() external {
        if (_mode == 2) revert("marker reverted");
        bytes32 response = _mode == 0 ? bytes32(0) : keccak256("utexo.bridge.proxy.compatibility.v1");
        uint256 length = _mode == 1 ? 31 : 32;
        assembly ("memory-safe") {
            mstore(0, response)
            return(0, length)
        }
    }
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
        assertEq(_storedOwner(), owner, "owner occupies the OpenZeppelin Ownable namespace");
        assertEq(bridge.routeRegistry(), routeRegistry);
        assertEq(address(bridge.commissionManager()), commissionManager);
        assertEq(bridge.lzAdapter(), lzAdapter);
        assertEq(bridge.minFundsInAmount(), 22);
        assertEq(bridge.minFundsOutAmount(), 11);
    }

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(token), routeRegistry, commissionManager, lzAdapter, 22, 11, owner);
    }

    function test_rgbMintDepositId_matchesPublishedVectorThroughProxy() public {
        address vectorBridge = 0x1111111111111111111111111111111111111111;
        address vectorToken = 0x2222222222222222222222222222222222222222;
        vm.chainId(42161);
        vm.etch(vectorBridge, address(proxy).code);
        vm.store(
            vectorBridge,
            0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc,
            bytes32(uint256(uint160(address(implementation))))
        );
        Bridge(vectorBridge).initialize(vectorToken, routeRegistry, commissionManager, address(0), 1, 1, owner);
        assertEq(
            Bridge(vectorBridge).RGB_MINT_DEPOSIT_TYPEHASH(),
            bytes32(0x1a137b1271ebe5dab41e95404f65ad059a653667420a6527377e0d45e75d3e36)
        );
        assertEq(
            Bridge(vectorBridge).rgbMintDepositId(96, 0xabcdef, 1_000_000),
            bytes32(0x6f0c19c7e7e8764fbd2afa1fc8211144acc9b45766be22d6b9bba1b20ed6cbd9)
        );
    }

    function test_proxyCannotBeInitializedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        bridge.initialize(address(token), routeRegistry, commissionManager, lzAdapter, 22, 11, owner);
    }

    function test_burnId_matchesPublishedVectorOnBothPathsThroughProxy() public {
        address vectorBridge = 0x1111111111111111111111111111111111111111;
        address vectorToken = 0x2222222222222222222222222222222222222222;
        uint256 expectedBurnId = 0x5f7d9d965dd22d924a86f6d23852911167ff751aa0d6a7227ad84d93fc20041d;
        vm.chainId(42161);
        vm.etch(vectorBridge, address(proxy).code);
        vm.store(
            vectorBridge,
            0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc,
            bytes32(uint256(uint160(address(implementation))))
        );
        vm.etch(vectorToken, address(token).code);
        MockERC20(vectorToken).mint(vectorBridge, 1_000_000);
        Bridge pinned = Bridge(vectorBridge);
        pinned.initialize(vectorToken, routeRegistry, commissionManager, address(0), 1, 1, owner);
        assertEq(pinned.BURN_TYPEHASH(), bytes32(0x09f8684e07c29653e96d992d7bca89a5ff94761a0d3c0d5e67c35dda03184e41));

        // InvalidBurnId exposes the actual private derivation before route calls.
        // Different settlement payloads must all produce the published value.
        for (uint256 i; i < 3; ++i) {
            bytes memory settlement = i == 0 ? bytes("") : abi.encode(i, bytes32(uint256(0x1234)));
            vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, 0, expectedBurnId));
            vm.prank(owner);
            pinned.fundsOut(
                IBridge.FundsOutParams({
                    recipient: owner,
                    amount: 1_000_000,
                    burnId: 0,
                    sourceChainId: 96,
                    destinationChainId: 42161,
                    sourceAddress: "",
                    proof: "",
                    settlementData: settlement,
                    sourceBurnTxId: bytes32(uint256(0xabcdef))
                })
            );
            vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, 0, expectedBurnId));
            vm.prank(owner);
            pinned.rebalanceLiquidity(
                IBridge.RebalanceParams({
                    amount: 1_000_000,
                    burnId: 0,
                    sourceChainId: 96,
                    destinationChainId: 97,
                    sourceAddress: "",
                    destinationAddress: "",
                    proof: "",
                    settlementDataOut: settlement,
                    settlementDataIn: abi.encode(i + 1),
                    sourceBurnTxId: bytes32(uint256(0xabcdef))
                })
            );
        }
    }

    function test_compatibilityMarker_constructorAcceptsImplementationWithWordFallback() public {
        WordFallbackImplementation candidate = new WordFallbackImplementation();
        BridgeProxy created = new BridgeProxy(address(candidate), _initializationData());
        assertEq(created.implementation(), address(candidate));
        assertEq(Bridge(address(created)).owner(), owner);
        assertEq(Bridge(address(created)).TOKEN(), address(token));
        assertEq(Bridge(address(created)).minFundsInAmount(), 22);
        assertEq(Bridge(address(created)).minFundsOutAmount(), 11);
    }

    function test_compatibilityMarker_upgradeAcceptsImplementationWithWordFallback() public {
        WordFallbackImplementation candidate = new WordFallbackImplementation();
        // No implementation() getter exists: the fallback returns an arbitrary word.
        (bool ok, bytes memory response) = address(candidate).staticcall(abi.encodeCall(BridgeProxy.implementation, ()));
        assertTrue(ok);
        assertEq(response.length, 32);
        assertEq(abi.decode(response, (uint256)), 42);
        assertEq(candidate.bridgeProxyCompatibilityUUID(), keccak256("utexo.bridge.proxy.compatibility.v1"));
        token.mint(address(proxy), 123 ether);

        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), abi.encodeCall(BridgeV2Mock.initializeV2, (777)));
        assertEq(proxy.implementation(), address(candidate));
        assertEq(BridgeV2Mock(address(proxy)).upgradeValue(), 777);
        assertEq(bridge.owner(), owner);
        assertEq(token.balanceOf(address(proxy)), 123 ether);
    }

    function test_compatibilityMarker_constructorRejectsNestedBridgeProxy() public {
        Bridge candidateImplementation = new Bridge();
        BridgeProxy candidate = new BridgeProxy(address(candidateImplementation), _initializationData());
        vm.expectRevert(
            abi.encodeWithSelector(BridgeProxy.IncompatibleBridgeImplementation.selector, address(candidate))
        );
        // The base constructor initializes before compatibility validation. Use
        // a nondelegating selector to reach the marker check without recursion.
        new BridgeProxy(address(candidate), abi.encodeCall(BridgeProxy.implementation, ()));
    }

    function test_compatibilityMarker_upgradeRejectsWrongTruncatedAndRevertingResponses() public {
        for (uint8 mode; mode < 3; ++mode) {
            InvalidCompatibilityMarkerImplementation candidate = new InvalidCompatibilityMarkerImplementation(mode);
            vm.expectRevert(
                abi.encodeWithSelector(BridgeProxy.IncompatibleBridgeImplementation.selector, address(candidate))
            );
            vm.prank(owner);
            proxy.upgradeToAndCall(address(candidate), bytes(""));
            assertEq(proxy.implementation(), address(implementation));
            assertEq(bridge.owner(), owner);
        }
    }

    function test_compatibilityMarker_constructorRejectsWrongTruncatedAndRevertingResponses() public {
        for (uint8 mode; mode < 3; ++mode) {
            InvalidCompatibilityMarkerImplementation candidate = new InvalidCompatibilityMarkerImplementation(mode);
            vm.expectRevert(
                abi.encodeWithSelector(BridgeProxy.IncompatibleBridgeImplementation.selector, address(candidate))
            );
            new BridgeProxy(
                address(candidate), abi.encodeCall(InvalidCompatibilityMarkerImplementation.initializeStub, ())
            );
        }
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
        assertEq(upgraded.minFundsInAmount(), 22);
        assertEq(upgraded.minFundsOutAmount(), 11);
        assertTrue(upgraded.paused());
        assertEq(token.balanceOf(address(proxy)), 123 ether);
    }

    function test_upgradeCalldata_acceptsExactly4096Bytes() public {
        BridgeV2Mock candidate = new BridgeV2Mock();
        bytes memory initializationData =
            bytes.concat(abi.encodeCall(BridgeV2Mock.initializeV2, (777)), new bytes(4060));
        assertEq(initializationData.length, 4096);

        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), initializationData);
        assertEq(proxy.implementation(), address(candidate));
        assertEq(BridgeV2Mock(address(proxy)).upgradeValue(), 777);
        assertEq(bridge.owner(), owner);
    }

    function test_upgradeCalldata_rejects4097BytesAndAllowsRetry() public {
        BridgeV2Mock candidate = new BridgeV2Mock();
        bytes memory initializationData =
            bytes.concat(abi.encodeCall(BridgeV2Mock.initializeV2, (777)), new bytes(4061));
        token.mint(address(proxy), 123 ether);

        vm.expectRevert(
            abi.encodeWithSelector(BridgeProxy.UpgradeCallDataTooLong.selector, uint256(4097), uint256(4096))
        );
        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), initializationData);
        assertEq(proxy.implementation(), address(implementation));
        assertEq(bridge.owner(), owner);
        assertEq(token.balanceOf(address(proxy)), 123 ether);

        // The rejected call did not consume the reinitializer version.
        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), abi.encodeCall(BridgeV2Mock.initializeV2, (42)));
        assertEq(BridgeV2Mock(address(proxy)).upgradeValue(), 42);
    }

    function testFuzz_upgradeCalldata_rejectsOversizedPayloads(uint256 length) public {
        length = bound(length, 4097, 65_536);
        BridgeV2Mock candidate = new BridgeV2Mock();
        bytes memory initializationData =
            bytes.concat(abi.encodeCall(BridgeV2Mock.initializeV2, (777)), new bytes(length - 36));
        vm.expectRevert(abi.encodeWithSelector(BridgeProxy.UpgradeCallDataTooLong.selector, length, uint256(4096)));
        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), initializationData);
        assertEq(proxy.implementation(), address(implementation));
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

    function test_storedOwnerUpgrade_recoversFromMissingRevertingAndMalformedGetter() public {
        address[3] memory candidates = [
            address(new MissingOwnerImplementation()),
            address(new RevertingOwnerImplementation()),
            address(new MalformedOwnerImplementation())
        ];
        for (uint256 i; i < candidates.length; ++i) {
            vm.prank(owner);
            proxy.upgradeToAndCall(candidates[i], bytes(""));
            assertEq(proxy.implementation(), candidates[i]);
            assertEq(_storedOwner(), owner);

            vm.expectRevert(abi.encodeWithSelector(BridgeProxy.UnauthorizedBridgeOwner.selector, address(this)));
            proxy.upgradeToAndCall(address(implementation), bytes(""));
            vm.prank(owner);
            proxy.upgradeToAndCall(address(implementation), bytes(""));
            assertEq(proxy.implementation(), address(implementation));
            assertEq(bridge.owner(), owner);
        }
    }

    function test_storedOwnerUpgrade_rejectsHiddenOwnerChangesAndRollsBackInitializer() public {
        SpoofedOwnerImplementation candidate = new SpoofedOwnerImplementation(owner);
        address[2] memory changedOwners = [address(0), makeAddr("hiddenOwner")];
        token.mint(address(proxy), 123 ether);
        for (uint256 i; i < changedOwners.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(BridgeProxy.IncompatibleBridgeImplementation.selector, address(candidate))
            );
            vm.prank(owner);
            proxy.upgradeToAndCall(
                address(candidate), abi.encodeCall(BridgeV2Mock.initializeV2WithOwner, (changedOwners[i]))
            );
            assertEq(proxy.implementation(), address(implementation));
            assertEq(_storedOwner(), owner);
            assertEq(bridge.owner(), owner);
            assertEq(token.balanceOf(address(proxy)), 123 ether);
        }

        // Neither the write to upgradeValue nor the reinitializer version persisted.
        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), bytes(""));
        assertEq(BridgeV2Mock(address(proxy)).upgradeValue(), 0);
        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), abi.encodeCall(BridgeV2Mock.initializeV2, (42)));
        assertEq(BridgeV2Mock(address(proxy)).upgradeValue(), 42);
    }

    function test_storedOwnerUpgrade_rejectsGetterImpersonatorAndAllowsRealOwnerRecovery() public {
        address impostor = makeAddr("getterImpostor");
        SpoofedOwnerImplementation candidate = new SpoofedOwnerImplementation(impostor);
        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), bytes(""));
        assertEq(bridge.owner(), impostor, "getter reports an address without upgrade authority");
        assertEq(_storedOwner(), owner);

        vm.expectRevert(abi.encodeWithSelector(BridgeProxy.UnauthorizedBridgeOwner.selector, impostor));
        vm.prank(impostor);
        proxy.upgradeToAndCall(address(implementation), bytes(""));
        assertEq(proxy.implementation(), address(candidate));

        vm.prank(owner);
        proxy.upgradeToAndCall(address(implementation), bytes(""));
        assertEq(proxy.implementation(), address(implementation));
        assertEq(bridge.owner(), owner);
    }

    function test_storedOwnerUpgrade_rejectsGetterAuthorityWhenSlotIsZero() public {
        SpoofedOwnerImplementation candidate = new SpoofedOwnerImplementation(owner);
        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), bytes(""));
        // Test-only corruption: a getter cannot grant authority if storage has no owner.
        vm.store(address(proxy), _ownableOwnerSlot(), bytes32(0));
        assertEq(bridge.owner(), owner);
        vm.expectRevert(abi.encodeWithSelector(BridgeProxy.UnauthorizedBridgeOwner.selector, owner));
        vm.prank(owner);
        proxy.upgradeToAndCall(address(implementation), bytes(""));
        assertEq(proxy.implementation(), address(candidate));
        assertEq(_storedOwner(), address(0));
    }

    function test_storedOwnerUpgrade_usesOnlyAddressBitsOfOwnerSlot() public {
        bytes32 ownerWord = bytes32((uint256(type(uint96).max) << 160) | uint256(uint160(owner)));
        vm.store(address(proxy), _ownableOwnerSlot(), ownerWord);
        assertEq(bridge.owner(), owner);
        BridgeV2Mock candidate = new BridgeV2Mock();
        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), abi.encodeCall(BridgeV2Mock.initializeV2, (42)));
        assertEq(proxy.implementation(), address(candidate));
        assertEq(BridgeV2Mock(address(proxy)).upgradeValue(), 42);
        assertEq(vm.load(address(proxy), _ownableOwnerSlot()), ownerWord);
    }

    function testFuzz_storedOwnerUpgrade_rejectsHiddenOwnerChanges(address changedOwner) public {
        vm.assume(changedOwner != owner);
        SpoofedOwnerImplementation candidate = new SpoofedOwnerImplementation(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BridgeProxy.IncompatibleBridgeImplementation.selector, address(candidate))
        );
        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), abi.encodeCall(BridgeV2Mock.initializeV2WithOwner, (changedOwner)));
        assertEq(proxy.implementation(), address(implementation));
        assertEq(_storedOwner(), owner);
    }

    function test_upgradeRollsBackZeroOrChangedOwnerAndInitializerWrites() public {
        BridgeV2Mock candidate = new BridgeV2Mock();
        address[2] memory owners = [address(0), makeAddr("unexpectedOwner")];
        for (uint256 i; i < owners.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(
                abi.encodeWithSelector(BridgeProxy.IncompatibleBridgeImplementation.selector, address(candidate))
            );
            proxy.upgradeToAndCall(address(candidate), abi.encodeCall(BridgeV2Mock.initializeV2WithOwner, (owners[i])));
            assertEq(proxy.implementation(), address(implementation));
            assertEq(bridge.owner(), owner);
        }
        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), bytes(""));
        assertEq(BridgeV2Mock(address(proxy)).upgradeValue(), 0);
        // Reinitializer version was rolled back too.
        vm.prank(owner);
        proxy.upgradeToAndCall(address(candidate), abi.encodeCall(BridgeV2Mock.initializeV2, (42)));
        assertEq(BridgeV2Mock(address(proxy)).upgradeValue(), 42);
    }

    /// @dev Derive the ERC-7201 slot independently of BridgeProxy's constant.
    function _ownableOwnerSlot() internal pure returns (bytes32) {
        return bytes32(
            uint256(keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Ownable")) - 1))) & ~uint256(0xff)
        );
    }

    function _storedOwner() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(proxy), _ownableOwnerSlot()))));
    }

    function _initializationData() internal view returns (bytes memory) {
        return abi.encodeCall(
            Bridge.initialize,
            (address(token), routeRegistry, commissionManager, lzAdapter, uint256(22), uint256(11), owner)
        );
    }
}
