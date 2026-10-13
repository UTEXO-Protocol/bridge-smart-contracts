// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {RGBVerifier} from "../../src/verifiers/RGBVerifier.sol";
import {MockSettlementModule} from "../mocks/MockSettlementModule.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Exact payload bounds and excessive data on deposit and release paths.
contract BridgePayloadBoundsTest is BridgeTestBase {
    /// @dev Build an ASCII string of exactly `len` bytes (for address-length caps).
    function _str(uint256 len) private pure returns (string memory) {
        return string(_bytesOfLength(len));
    }

    /// @dev Build a `bytes` blob of exactly `len` bytes.
    function _bytesOfLength(uint256 len) private pure returns (bytes memory b) {
        b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = 0x61;
        }
    }

    function test_fundsIn_revertsOnDestinationAddressTooLong() public {
        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        string memory tooLong = _str(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AddressTooLong.selector, max + 1, max));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, tooLong, _rgbData());
    }

    function test_fundsIn_acceptsDestinationAddressAtMaxLength() public {
        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        MockSettlementModule permissiveModule = new MockSettlementModule();
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(permissiveModule));

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, _str(max), _rgbData());
        assertEq(permissiveModule.onFundsInCount(), 1, "generic route accepts the address-length cap");
    }

    function test_settlementDataCaps_splitByDirection() public view {
        assertEq(bridge.MAX_SETTLEMENT_DATA_IN_LENGTH(), 128, "inbound settlementData cap");
        assertEq(bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH(), 90_000, "outbound settlementData cap");
    }

    function test_fundsIn_revertsOnSettlementDataTooLong() public {
        uint256 max = bridge.MAX_SETTLEMENT_DATA_IN_LENGTH();
        assertLt(max + 1, bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH(), "inbound cap is below outbound cap");
        bytes memory tooLong = _bytesOfLength(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.SettlementDataTooLong.selector, max + 1, max));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, tooLong);
    }

    function test_fundsIn_acceptsSettlementDataAtMaxLength() public {
        // The length guard lives in Bridge, ahead of the route module. A
        // maximal-length blob still decodes as a non-zero RGB OpId (the first
        // 32 bytes read as uint256), so the deposit clears the guard and
        // records normally under the bridge-derived operationId.
        uint256 max = bridge.MAX_SETTLEMENT_DATA_IN_LENGTH();
        bytes memory atMax = _bytesOfLength(max);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, atMax);
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "deposit at the settlement-data cap is accepted");
    }

    function test_fundsOut_acceptsSettlementDataAboveInboundCap() public {
        // A two-record release payload (128 + 64 * 2 = 256 bytes) is above the
        // inbound cap; the release path must be bounded by the outbound cap only.
        vm.prank(user);
        bytes32 opA = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opB = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));
        _ensureRgbSafetyCapacity(2 * AMOUNT);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = opA;
        ids[1] = opB;
        bytes memory settlementData = _settlement(ids);
        assertGt(settlementData.length, bridge.MAX_SETTLEMENT_DATA_IN_LENGTH());

        vm.prank(multisig);
        _fundsOut(
            recipient, 2 * AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), settlementData, SRC_BURN_TX_ID
        );
        assertEq(usdt0.balanceOf(recipient), 2 * AMOUNT, "release above the inbound cap succeeds");
    }

    function test_fundsOut_revertsOnSettlementDataTooLong() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 max = bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH();
        bytes memory tooLong = _bytesOfLength(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.SettlementDataTooLong.selector, max + 1, max));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), tooLong, SRC_BURN_TX_ID);
    }

    function test_fundsOut_acceptsSettlementDataAtMaxLength() public {
        vm.prank(user);
        bytes32 operationId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);
        bytes memory settlementData = _settlement(_ids(operationId));
        bytes memory proof = _proof();
        settlementData =
            bytes.concat(settlementData, new bytes(bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH() - settlementData.length));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData, SRC_BURN_TX_ID);
        assertEq(usdt0.balanceOf(recipient), AMOUNT);
        assertEq(rgbModule.fundsInRecords(operationId), AMOUNT);
    }

    function test_fundsOut_revertsOnSourceAddressTooLong() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        string memory tooLong = _str(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AddressTooLong.selector, max + 1, max));
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, tooLong, _proof(), _settlement(_ids(opId)), SRC_BURN_TX_ID
        );
    }

    function test_fundsOut_sourceAddressAtMaxLengthPassesBridgeLengthGuard() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        // Bridge accepts the exact generic address-length cap. The configured
        // RGB verifier then rejects the non-empty value for the separate,
        // route-specific reason that RGB has no source-address concept.
        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        vm.expectRevert(RGBVerifier.UnexpectedSourceAddress.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            AMOUNT,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            _str(max),
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );
    }

    /// @dev RGB has no source-address concept, so the RGB verifier rejects any
    ///      non-empty value. This keeps `sourceAddress` canonical on RGB routes —
    ///      it is hashed into `burnId`, so a free-form value would let the same
    ///      burn derive a different replay key. Bridge's own length cap is still
    ///      exercised by `test_fundsOut_revertsOnSourceAddressTooLong`.
    function test_fundsOut_rgbRouteRejectsNonEmptySourceAddress() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        vm.expectRevert(RGBVerifier.UnexpectedSourceAddress.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            AMOUNT,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            "rgb:sender",
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );
    }

    function test_fundsOut_revertsOnProofTooLong() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 max = bridge.MAX_PROOF_LENGTH();
        bytes memory tooLong = _bytesOfLength(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.ProofTooLong.selector, max + 1, max));
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, tooLong, _settlement(_ids(opId)), SRC_BURN_TX_ID
        );
    }

    function test_fundsOut_acceptsProofAtMaxLength() public {
        vm.prank(user);
        bytes32 operationId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);
        bytes memory settlementData = _settlement(_ids(operationId));
        bytes memory proof = _proof();
        proof = bytes.concat(proof, new bytes(bridge.MAX_PROOF_LENGTH() - proof.length));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData, SRC_BURN_TX_ID);
        assertEq(usdt0.balanceOf(recipient), AMOUNT);
        assertEq(rgbModule.fundsInRecords(operationId), AMOUNT);
    }

    function test_fundsOut_acceptsRealProofUnderCap() public {
        // The production-shaped 128-byte RGB proof is well under the cap and the
        // happy path still succeeds.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        assertLt(_proof().length, bridge.MAX_PROOF_LENGTH(), "sanity: real proof under cap");

        vm.prank(multisig);
        _fundsOut(
            recipient,
            AMOUNT,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)),
            SRC_BURN_TX_ID
        );
        assertEq(usdt0.balanceOf(recipient), AMOUNT, "release with a normal proof succeeds");
    }
}
