// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Bridge} from "../../src/Bridge.sol";
import {BridgeProxy} from "../../src/BridgeProxy.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";

/// @notice Deploys an initialized ERC-1967 Bridge proxy with the canonical payload.
abstract contract BridgeProxyTestUtils {
    uint256 internal constant FUNDS_IN_SIGNER_PRIVATE_KEY = 0xA11CE;
    address internal constant FUNDS_IN_SIGNER = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;

    Vm private constant _AUTH_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("UtexoBridge");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 private constant _AUTHORIZATION_TYPEHASH = keccak256(
        "FundsInAuthorization(address token,uint256 amount,uint256 sourceChainId,bytes32 sourceSender,uint256 destinationChainId,string destinationAddress,bytes settlementData,bytes32 authorizationNonce,uint256 deadline)"
    );

    uint256 private _fundsInAuthorizationSequence;
    mapping(address bridge => address token) private _bridgeTokens;

    function _deployBridge(
        address token,
        address routeRegistry,
        address payable commissionManager,
        address lzAdapter,
        uint256 minFundsInAmount,
        uint256 minFundsOutAmount,
        address initialOwner
    ) internal returns (Bridge bridge) {
        (bridge,,) = _deployBridgeWithImplementation(
            token, routeRegistry, commissionManager, lzAdapter, minFundsInAmount, minFundsOutAmount, initialOwner
        );
    }

    function _deployBridgeWithImplementation(
        address token,
        address routeRegistry,
        address payable commissionManager,
        address lzAdapter,
        uint256 minFundsInAmount,
        uint256 minFundsOutAmount,
        address initialOwner
    ) private returns (Bridge bridge, Bridge implementation, BridgeProxy proxy) {
        implementation = new Bridge();
        (bridge, proxy) = _deployBridgeFromImplementation(
            implementation,
            token,
            routeRegistry,
            commissionManager,
            lzAdapter,
            minFundsInAmount,
            minFundsOutAmount,
            initialOwner
        );
    }

    function _deployBridgeFromImplementation(
        Bridge implementation,
        address token,
        address routeRegistry,
        address payable commissionManager,
        address lzAdapter,
        uint256 minFundsInAmount,
        uint256 minFundsOutAmount,
        address initialOwner
    ) internal returns (Bridge bridge, BridgeProxy proxy) {
        bytes memory initializationData = abi.encodeCall(
            Bridge.initialize,
            (
                token,
                routeRegistry,
                commissionManager,
                lzAdapter,
                FUNDS_IN_SIGNER,
                minFundsInAmount,
                minFundsOutAmount,
                initialOwner
            )
        );
        proxy = new BridgeProxy(address(implementation), initializationData);
        bridge = Bridge(address(proxy));
        _bridgeTokens[address(bridge)] = token;
    }

    function _deployBridgeFromImplementationWithSigner(
        Bridge implementation,
        address token,
        address routeRegistry,
        address payable commissionManager,
        address lzAdapter,
        address fundsInSigner,
        uint256 minFundsInAmount,
        uint256 minFundsOutAmount,
        address initialOwner
    ) internal returns (Bridge bridge, BridgeProxy proxy) {
        bytes memory initializationData = abi.encodeCall(
            Bridge.initialize,
            (
                token,
                routeRegistry,
                commissionManager,
                lzAdapter,
                fundsInSigner,
                minFundsInAmount,
                minFundsOutAmount,
                initialOwner
            )
        );
        proxy = new BridgeProxy(address(implementation), initializationData);
        bridge = Bridge(address(proxy));
        _bridgeTokens[address(bridge)] = token;
    }

    function _fundsInAuthorization(
        Bridge bridge_,
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes memory settlementData
    ) internal returns (IBridge.FundsInAuthorization memory) {
        bytes32 nonce = keccak256(abi.encode(address(this), ++_fundsInAuthorizationSequence));
        return _signFundsInAuthorization(
            bridge_,
            amount,
            sourceChainId,
            sourceSender,
            destinationChainId,
            destinationAddress,
            settlementData,
            nonce,
            block.timestamp + 1 days,
            FUNDS_IN_SIGNER_PRIVATE_KEY
        );
    }

    function _nextFundsInAuthorizationNonce() internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), _fundsInAuthorizationSequence + 1));
    }

    function _signFundsInAuthorization(
        Bridge bridge_,
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes memory settlementData,
        bytes32 authorizationNonce,
        uint256 deadline,
        uint256 signerPrivateKey
    ) internal view returns (IBridge.FundsInAuthorization memory authorization) {
        bytes32 domainSeparator = keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(bridge_))
        );
        bytes32 structHash = keccak256(
            abi.encode(
                _AUTHORIZATION_TYPEHASH,
                _bridgeTokens[address(bridge_)],
                amount,
                sourceChainId,
                sourceSender,
                destinationChainId,
                keccak256(bytes(destinationAddress)),
                keccak256(settlementData),
                authorizationNonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = _AUTH_VM.sign(signerPrivateKey, digest);
        authorization = IBridge.FundsInAuthorization({
            authorizationNonce: authorizationNonce, deadline: deadline, signature: abi.encodePacked(r, s, v)
        });
    }

    function _authorizedFundsIn(
        Bridge bridge_,
        uint256 amount,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes memory settlementData
    ) internal returns (bytes32) {
        (VmSafe.CallerMode mode, address caller, address origin) = _suspendPrank();
        bytes32 sourceSender = bytes32(uint256(uint160(caller)));
        IBridge.FundsInAuthorization memory authorization = _fundsInAuthorization(
            bridge_, amount, block.chainid, sourceSender, destinationChainId, destinationAddress, settlementData
        );
        _restorePrank(mode, caller, origin);
        return bridge_.fundsIn(amount, destinationChainId, destinationAddress, settlementData, authorization);
    }

    function _authorizedFundsInWithValue(
        Bridge bridge_,
        uint256 nativeValue,
        uint256 amount,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes memory settlementData
    ) internal returns (bytes32) {
        (VmSafe.CallerMode mode, address caller, address origin) = _suspendPrank();
        bytes32 sourceSender = bytes32(uint256(uint160(caller)));
        IBridge.FundsInAuthorization memory authorization = _fundsInAuthorization(
            bridge_, amount, block.chainid, sourceSender, destinationChainId, destinationAddress, settlementData
        );
        _restorePrank(mode, caller, origin);
        return bridge_.fundsIn{value: nativeValue}(
            amount, destinationChainId, destinationAddress, settlementData, authorization
        );
    }

    function _authorizedAdapterFundsIn(
        Bridge bridge_,
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes memory settlementData
    ) internal returns (bytes32) {
        (VmSafe.CallerMode mode, address caller, address origin) = _suspendPrank();
        IBridge.FundsInAuthorization memory authorization = _fundsInAuthorization(
            bridge_, amount, sourceChainId, sourceSender, destinationChainId, destinationAddress, settlementData
        );
        _restorePrank(mode, caller, origin);
        return bridge_.fundsIn(
            amount, sourceChainId, sourceSender, destinationChainId, destinationAddress, settlementData, authorization
        );
    }

    function _authorizedAdapterFundsInWithValue(
        Bridge bridge_,
        uint256 nativeValue,
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes memory settlementData
    ) internal returns (bytes32) {
        (VmSafe.CallerMode mode, address caller, address origin) = _suspendPrank();
        IBridge.FundsInAuthorization memory authorization = _fundsInAuthorization(
            bridge_, amount, sourceChainId, sourceSender, destinationChainId, destinationAddress, settlementData
        );
        _restorePrank(mode, caller, origin);
        return bridge_.fundsIn{value: nativeValue}(
            amount, sourceChainId, sourceSender, destinationChainId, destinationAddress, settlementData, authorization
        );
    }

    function _suspendPrank() private returns (VmSafe.CallerMode mode, address caller, address origin) {
        (mode, caller, origin) = _AUTH_VM.readCallers();
        if (mode == VmSafe.CallerMode.None) {
            caller = address(this);
            origin = tx.origin;
        } else if (mode == VmSafe.CallerMode.Prank || mode == VmSafe.CallerMode.RecurrentPrank) {
            _AUTH_VM.stopPrank();
        }
    }

    function _restorePrank(VmSafe.CallerMode mode, address caller, address origin) private {
        if (mode == VmSafe.CallerMode.Prank) {
            _AUTH_VM.prank(caller, origin);
        } else if (mode == VmSafe.CallerMode.RecurrentPrank) {
            _AUTH_VM.startPrank(caller, origin);
        }
    }
}
