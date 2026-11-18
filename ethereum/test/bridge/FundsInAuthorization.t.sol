// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice EIP-712 funds-in authorization, replay protection and signer rotation.
contract BridgeFundsInAuthorizationTest is BridgeTestBase {
    uint256 private constant ADAPTER_SOURCE_CHAIN_ID = 137;

    function test_fundsIn_acceptsValidAuthorizationAndConsumesNonce() public {
        bytes32 nonce = keccak256("valid-direct-authorization");
        IBridge.FundsInAuthorization memory authorization = _authorization(
            AMOUNT,
            SOURCE_CHAIN_ID,
            _sourceSender(user),
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData(),
            nonce,
            block.timestamp + 1 days
        );

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), authorization);

        assertTrue(bridge.usedFundsInAuthorizationNonces(nonce));
    }

    function test_fundsIn_rejectsAuthorizationReplayBeforeSettlement() public {
        bytes32 nonce = keccak256("replayed-authorization");
        IBridge.FundsInAuthorization memory authorization = _authorization(
            AMOUNT,
            SOURCE_CHAIN_ID,
            _sourceSender(user),
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData(),
            nonce,
            block.timestamp + 1 days
        );

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), authorization);

        vm.expectRevert(abi.encodeWithSelector(IBridge.FundsInAuthorizationAlreadyUsed.selector, nonce));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), authorization);
    }

    function test_fundsIn_rejectsExpiredAuthorization() public {
        bytes32 nonce = keccak256("expired-authorization");
        uint256 deadline = block.timestamp - 1;
        IBridge.FundsInAuthorization memory authorization = _authorization(
            AMOUNT, SOURCE_CHAIN_ID, _sourceSender(user), RGB_CHAIN_ID, DST_ADDR, _rgbData(), nonce, deadline
        );

        vm.expectRevert(abi.encodeWithSelector(IBridge.FundsInAuthorizationExpired.selector, deadline));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), authorization);

        assertFalse(bridge.usedFundsInAuthorizationNonces(nonce));
    }

    function test_fundsIn_acceptsAuthorizationAtDeadline() public {
        bytes32 nonce = keccak256("at-deadline-authorization");
        IBridge.FundsInAuthorization memory authorization = _authorization(
            AMOUNT, SOURCE_CHAIN_ID, _sourceSender(user), RGB_CHAIN_ID, DST_ADDR, _rgbData(), nonce, block.timestamp
        );

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), authorization);

        assertTrue(bridge.usedFundsInAuthorizationNonces(nonce));
    }

    function test_fundsIn_rejectsWrongSignerAndMalformedSignature() public {
        bytes32 wrongSignerNonce = keccak256("wrong-signer");
        IBridge.FundsInAuthorization memory wrongSignerAuthorization = _signFundsInAuthorization(
            bridge,
            AMOUNT,
            SOURCE_CHAIN_ID,
            _sourceSender(user),
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData(),
            wrongSignerNonce,
            block.timestamp + 1 days,
            0xB0B
        );

        vm.expectRevert(IBridge.InvalidFundsInAuthorizationSignature.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), wrongSignerAuthorization);

        bytes32 malformedNonce = keccak256("malformed-signature");
        IBridge.FundsInAuthorization memory malformed = IBridge.FundsInAuthorization({
            authorizationNonce: malformedNonce, deadline: block.timestamp + 1 days, signature: hex"1234"
        });
        vm.expectRevert(IBridge.InvalidFundsInAuthorizationSignature.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), malformed);

        assertFalse(bridge.usedFundsInAuthorizationNonces(wrongSignerNonce));
        assertFalse(bridge.usedFundsInAuthorizationNonces(malformedNonce));
    }

    function test_fundsIn_signatureBindsCallerAndEveryBusinessField() public {
        bytes32 nonce = keccak256("bound-fields");
        IBridge.FundsInAuthorization memory authorization = _authorization(
            AMOUNT,
            SOURCE_CHAIN_ID,
            _sourceSender(user),
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData(),
            nonce,
            block.timestamp + 1 days
        );

        address stranger = makeAddr("authorization-stranger");
        usdt0.mint(stranger, AMOUNT);
        vm.prank(stranger);
        usdt0.approve(address(bridge), AMOUNT);

        vm.expectRevert(IBridge.InvalidFundsInAuthorizationSignature.selector);
        vm.prank(stranger);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), authorization);

        vm.expectRevert(IBridge.InvalidFundsInAuthorizationSignature.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT - 1, RGB_CHAIN_ID, DST_ADDR, _rgbData(), authorization);

        vm.expectRevert(IBridge.InvalidFundsInAuthorizationSignature.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_LOCK_ID + 1), authorization);

        vm.expectRevert(IBridge.InvalidFundsInAuthorizationSignature.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID + 1, DST_ADDR, _rgbData(), authorization);

        vm.expectRevert(IBridge.InvalidFundsInAuthorizationSignature.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, "changed-destination", _rgbData(), authorization);

        IBridge.FundsInAuthorization memory changedNonce = authorization;
        changedNonce.authorizationNonce = keccak256("changed-authorization-nonce");
        vm.expectRevert(IBridge.InvalidFundsInAuthorizationSignature.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), changedNonce);

        IBridge.FundsInAuthorization memory changedDeadline = authorization;
        changedDeadline.deadline++;
        vm.expectRevert(IBridge.InvalidFundsInAuthorizationSignature.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), changedDeadline);

        vm.chainId(SOURCE_CHAIN_ID + 1);
        vm.expectRevert(IBridge.InvalidFundsInAuthorizationSignature.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), authorization);

        assertFalse(bridge.usedFundsInAuthorizationNonces(nonce));
    }

    function test_fundsIn_adapterAcceptsUnorderedNonces() public {
        address adapter = _configureAdapter();
        bytes32 sourceSender = _sourceSender(user);
        bytes32 highNonce = bytes32(uint256(10_000));
        bytes32 lowNonce = bytes32(uint256(7));
        bytes memory highData = _rgbData(RGB_LOCK_ID + 1);
        bytes memory lowData = _rgbData(RGB_LOCK_ID + 2);
        IBridge.FundsInAuthorization memory highAuthorization = _authorization(
            AMOUNT,
            ADAPTER_SOURCE_CHAIN_ID,
            sourceSender,
            RGB_CHAIN_ID,
            DST_ADDR,
            highData,
            highNonce,
            block.timestamp + 1 days
        );
        IBridge.FundsInAuthorization memory lowAuthorization = _authorization(
            AMOUNT,
            ADAPTER_SOURCE_CHAIN_ID,
            sourceSender,
            RGB_CHAIN_ID,
            DST_ADDR,
            lowData,
            lowNonce,
            block.timestamp + 1 days
        );

        vm.prank(adapter);
        bridge.fundsIn(
            AMOUNT, ADAPTER_SOURCE_CHAIN_ID, sourceSender, RGB_CHAIN_ID, DST_ADDR, highData, highAuthorization
        );
        vm.prank(adapter);
        bridge.fundsIn(AMOUNT, ADAPTER_SOURCE_CHAIN_ID, sourceSender, RGB_CHAIN_ID, DST_ADDR, lowData, lowAuthorization);

        assertTrue(bridge.usedFundsInAuthorizationNonces(highNonce));
        assertTrue(bridge.usedFundsInAuthorizationNonces(lowNonce));
    }

    function test_fundsIn_adapterSignatureBindsAuthenticatedSource() public {
        address adapter = _configureAdapter();
        bytes32 nonce = keccak256("adapter-source-binding");
        IBridge.FundsInAuthorization memory authorization = _authorization(
            AMOUNT,
            ADAPTER_SOURCE_CHAIN_ID,
            _sourceSender(user),
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData(),
            nonce,
            block.timestamp + 1 days
        );

        vm.expectRevert(IBridge.InvalidFundsInAuthorizationSignature.selector);
        vm.prank(adapter);
        bridge.fundsIn(
            AMOUNT, ADAPTER_SOURCE_CHAIN_ID, bytes32(uint256(123)), RGB_CHAIN_ID, DST_ADDR, _rgbData(), authorization
        );
    }

    function test_fundsIn_downstreamRevertDoesNotConsumeAuthorization() public {
        bytes32 nonce = keccak256("rollback-authorization");
        IBridge.FundsInAuthorization memory authorization = _authorization(
            AMOUNT,
            SOURCE_CHAIN_ID,
            _sourceSender(user),
            RGB_CHAIN_ID,
            "invalid-rgb-address",
            _rgbData(),
            nonce,
            block.timestamp + 1 days
        );

        vm.expectRevert(RgbSettlementModule.UnexpectedDestinationAddress.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, "invalid-rgb-address", _rgbData(), authorization);

        assertFalse(bridge.usedFundsInAuthorizationNonces(nonce));
    }

    function test_setFundsInSigner_rotatesAndRejectsZeroOrNonOwner() public {
        address replacement = makeAddr("replacement-funds-in-signer");
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsInSignerUpdated(FUNDS_IN_SIGNER, replacement);
        vm.prank(multisig);
        bridge.setFundsInSigner(replacement);
        assertEq(bridge.fundsInSigner(), replacement);

        vm.expectRevert(IBridge.InvalidFundsInSigner.selector);
        vm.prank(multisig);
        bridge.setFundsInSigner(address(0));

        vm.expectRevert();
        vm.prank(user);
        bridge.setFundsInSigner(FUNDS_IN_SIGNER);
    }

    function _authorization(
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes memory settlementData,
        bytes32 nonce,
        uint256 deadline
    ) private view returns (IBridge.FundsInAuthorization memory) {
        return _signFundsInAuthorization(
            bridge,
            amount,
            sourceChainId,
            sourceSender,
            destinationChainId,
            destinationAddress,
            settlementData,
            nonce,
            deadline,
            FUNDS_IN_SIGNER_PRIVATE_KEY
        );
    }

    function _configureAdapter() private returns (address adapter) {
        adapter = makeAddr("authorization-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        vm.prank(deployer);
        routeRegistry.setRoute(ADAPTER_SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        usdt0.mint(adapter, AMOUNT * 2);
        vm.prank(adapter);
        usdt0.approve(address(bridge), type(uint256).max);
    }

    function _sourceSender(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
