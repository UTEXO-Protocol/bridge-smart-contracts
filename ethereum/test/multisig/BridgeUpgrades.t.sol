// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {IBridgeProxy} from "../../src/interfaces/IBridgeProxy.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {BridgeV2Mock} from "../mocks/BridgeV2Mock.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice Typed implementation upgrades enforce compatibility, ownership and payload bounds.
contract MultisigBridgeUpgradesTest is MultisigProxyTestBase {
    function _submitBridgeUpgrade(address nextImplementation, bytes memory initializationData)
        private
        returns (bytes32)
    {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpgradeBridgeImplementation(
            domainSep, address(bridge), nextImplementation, initializationData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        return proxy.proposeUpgradeBridgeImplementation(
            address(bridge),
            nextImplementation,
            initializationData,
            nonce,
            deadline,
            bitmap,
            MultisigHelper.signAll(vm, digest, pks)
        );
    }

    function _expectRejectedBridgeUpgrade(address nextImplementation, bytes memory data, bytes memory expectedError)
        private
    {
        uint256 nonce = proxy.proposalNonce();
        uint256 teeNonceBefore = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 balanceBefore = token.balanceOf(address(bridge));
        address implementationBefore = IBridgeProxy(address(bridge)).implementation();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpgradeBridgeImplementation(
            domainSep, address(bridge), nextImplementation, data, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory signatures = MultisigHelper.signAll(vm, digest, pks);
        vm.expectRevert(expectedError);
        proxy.proposeUpgradeBridgeImplementation(
            address(bridge), nextImplementation, data, nonce, deadline, bitmap, signatures
        );
        assertEq(proxy.proposalNonce(), nonce);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), teeNonceBefore);
        assertEq(IBridgeProxy(address(bridge)).implementation(), implementationBefore);
        assertEq(token.balanceOf(address(bridge)), balanceBefore);
    }

    /// @dev Seed a legacy-style pending payload to exercise execution defenses
    ///      independently of the propose guard. This is test-only storage setup,
    ///      not a capability available to a transaction submitter.
    function _seedUpgradePayloadHash(bytes32 id, bytes memory original, bytes memory replacement) private {
        vm.record();
        proxy.getProposal(id);
        (bytes32[] memory reads,) = vm.accesses(address(proxy));
        for (uint256 i; i < reads.length; ++i) {
            if (vm.load(address(proxy), reads[i]) == keccak256(original)) {
                vm.store(address(proxy), reads[i], keccak256(replacement));
                return;
            }
        }
        revert("proposal dataHash slot not found");
    }

    function test_proposeUpgradeBridgeImplementation_executesAfterTimelockAndPreservesState() public {
        BridgeV2Mock nextImplementation = new BridgeV2Mock();
        bytes memory initializationData = abi.encodeCall(BridgeV2Mock.initializeV2, (777));
        bytes32 id = _submitBridgeUpgrade(address(nextImplementation), initializationData);

        uint256 balanceBefore = token.balanceOf(address(bridge));
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.BridgeImplementationUpgraded(address(bridge), address(nextImplementation));
        proxy.executeProposal(id, abi.encode(address(bridge), address(nextImplementation), initializationData));

        BridgeV2Mock upgraded = BridgeV2Mock(address(bridge));
        assertEq(IBridgeProxy(address(bridge)).implementation(), address(nextImplementation));
        assertEq(upgraded.version(), 2);
        assertEq(upgraded.upgradeValue(), 777);
        assertEq(upgraded.owner(), address(proxy));
        assertEq(upgraded.TOKEN(), address(token));
        assertEq(upgraded.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore);
        assertEq(token.balanceOf(address(upgraded)), balanceBefore);
    }

    function test_upgrade_rejectsCurrentImplementationWithEmptyOrReleaseData() public {
        address current = IBridgeProxy(address(bridge)).implementation();
        bytes memory errorData = abi.encodeWithSelector(IMultisigProxy.InvalidBridgeImplementation.selector, current);
        _expectRejectedBridgeUpgrade(current, "", errorData);
        _expectRejectedBridgeUpgrade(current, abi.encodeCall(IBridge.fundsOut, (_fundsOutParams())), errorData);
        _expectRejectedBridgeUpgrade(
            current, abi.encodeCall(IBridge.rebalanceLiquidity, (_rebalanceParams())), errorData
        );
    }

    function test_upgrade_rejectsReleaseSelectorsOnDifferentImplementation() public {
        BridgeV2Mock candidate = new BridgeV2Mock();
        bytes[2] memory payloads = [
            abi.encodeCall(IBridge.fundsOut, (_fundsOutParams())),
            abi.encodeCall(IBridge.rebalanceLiquidity, (_rebalanceParams()))
        ];
        for (uint256 i; i < payloads.length; ++i) {
            bytes4 selector = bytes4(payloads[i]);
            bytes memory errorData =
                abi.encodeWithSelector(IMultisigProxy.ForbiddenBridgeReleaseSelector.selector, selector);
            _expectRejectedBridgeUpgrade(address(candidate), payloads[i], errorData);
            _expectRejectedBridgeUpgrade(address(candidate), abi.encodePacked(selector), errorData);
            _expectRejectedBridgeUpgrade(address(candidate), bytes.concat(payloads[i], hex"ff"), errorData);
        }
    }

    function test_upgrade_rejectsNonemptyTruncatedSelector() public {
        BridgeV2Mock candidate = new BridgeV2Mock();
        for (uint256 length = 1; length < 4; ++length) {
            _expectRejectedBridgeUpgrade(
                address(candidate), new bytes(length), abi.encodeWithSelector(IMultisigProxy.CallDataTooShort.selector)
            );
        }
    }

    function test_upgradeBridgeImplementation_acceptsEmptyInitializationData() public {
        BridgeV2Mock candidate = new BridgeV2Mock();
        bytes32 id = _submitBridgeUpgrade(address(candidate), "");
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(address(bridge), address(candidate), bytes("")));
        assertEq(IBridgeProxy(address(bridge)).implementation(), address(candidate));
        assertEq(bridge.owner(), address(proxy));
    }

    function test_upgradeCalldata_acceptsExactly4096BytesThroughGovernance() public {
        BridgeV2Mock candidate = new BridgeV2Mock();
        bytes memory initializationData =
            bytes.concat(abi.encodeCall(BridgeV2Mock.initializeV2, (777)), new bytes(4060));
        assertEq(initializationData.length, 4096);
        bytes32 id = _submitBridgeUpgrade(address(candidate), initializationData);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        // The ABI-encoded operation envelope may be larger than 4096 bytes.
        proxy.executeProposal(id, abi.encode(address(bridge), address(candidate), initializationData));
        assertEq(IBridgeProxy(address(bridge)).implementation(), address(candidate));
        assertEq(BridgeV2Mock(address(bridge)).upgradeValue(), 777);
        assertEq(bridge.owner(), address(proxy));
        assertEq(uint256(proxy.getProposal(id).status), uint256(IMultisigProxy.ProposalStatus.Executed));
    }

    function test_upgradeCalldata_rejects4097BytesAtProposal() public {
        BridgeV2Mock candidate = new BridgeV2Mock();
        bytes memory initializationData =
            bytes.concat(abi.encodeCall(BridgeV2Mock.initializeV2, (777)), new bytes(4061));
        _expectRejectedBridgeUpgrade(
            address(candidate),
            initializationData,
            abi.encodeWithSelector(IMultisigProxy.UpgradeCallDataTooLong.selector, uint256(4097), uint256(4096))
        );
    }

    function test_upgradeCalldata_executionRejectsOversizedPayloadIndependently() public {
        BridgeV2Mock candidate = new BridgeV2Mock();
        bytes32 id = _submitBridgeUpgrade(address(candidate), "");
        bytes memory initializationData =
            bytes.concat(abi.encodeCall(BridgeV2Mock.initializeV2, (777)), new bytes(4061));
        bytes memory original = abi.encode(address(bridge), address(candidate), bytes(""));
        bytes memory opData = abi.encode(address(bridge), address(candidate), initializationData);
        _seedUpgradePayloadHash(id, original, opData);
        uint256 nonceBefore = proxy.proposalNonce();
        address implementationBefore = IBridgeProxy(address(bridge)).implementation();
        uint256 balanceBefore = token.balanceOf(address(bridge));
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        // A distinct downstream error proves MultisigProxy rejects the payload
        // itself, rather than relying on BridgeProxy's identical length error.
        vm.mockCallRevert(
            address(bridge),
            abi.encodeCall(IBridgeProxy.upgradeToAndCall, (address(candidate), initializationData)),
            bytes("unexpected proxy call")
        );
        vm.expectRevert(
            abi.encodeWithSelector(IMultisigProxy.UpgradeCallDataTooLong.selector, uint256(4097), uint256(4096))
        );
        proxy.executeProposal(id, opData);
        vm.clearMockedCalls();
        assertEq(uint256(proxy.getProposal(id).status), uint256(IMultisigProxy.ProposalStatus.Pending));
        assertEq(proxy.proposalNonce(), nonceBefore);
        assertEq(IBridgeProxy(address(bridge)).implementation(), implementationBefore);
        assertEq(bridge.owner(), address(proxy));
        assertEq(token.balanceOf(address(bridge)), balanceBefore);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore);
    }

    function test_upgrade_rechecksCurrentImplementationAtExecution() public {
        BridgeV2Mock candidate = new BridgeV2Mock();
        bytes32 first = _submitBridgeUpgrade(address(candidate), "");
        bytes memory initializationData = abi.encodeCall(BridgeV2Mock.initializeV2, (777));
        bytes32 second = _submitBridgeUpgrade(address(candidate), initializationData);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(first, abi.encode(address(bridge), address(candidate), bytes("")));
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.InvalidBridgeImplementation.selector, address(candidate)));
        proxy.executeProposal(second, abi.encode(address(bridge), address(candidate), initializationData));
        assertEq(BridgeV2Mock(address(bridge)).upgradeValue(), 0, "second initializer did not run");
        assertEq(uint256(proxy.getProposal(second).status), uint256(IMultisigProxy.ProposalStatus.Pending));
    }

    function test_upgrade_executionRejectsReleasePayloadsIndependently() public {
        BridgeV2Mock candidate = new BridgeV2Mock();
        bytes[2] memory payloads = [
            abi.encodeCall(IBridge.fundsOut, (_fundsOutParams())),
            abi.encodeCall(IBridge.rebalanceLiquidity, (_rebalanceParams()))
        ];
        address originalImplementation = IBridgeProxy(address(bridge)).implementation();
        uint256 balanceBefore = token.balanceOf(address(bridge));
        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 teeNonceBefore = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 startedAt = vm.getBlockTimestamp();
        for (uint256 i; i < payloads.length; ++i) {
            bytes32 id = _submitBridgeUpgrade(address(candidate), "");
            bytes memory opData = abi.encode(address(bridge), address(candidate), payloads[i]);
            _seedUpgradePayloadHash(id, abi.encode(address(bridge), address(candidate), bytes("")), opData);
            vm.warp(startedAt + (i + 1) * (TIMELOCK + 1));
            vm.expectRevert(
                abi.encodeWithSelector(IMultisigProxy.ForbiddenBridgeReleaseSelector.selector, bytes4(payloads[i]))
            );
            proxy.executeProposal(id, opData);
            assertEq(uint256(proxy.getProposal(id).status), uint256(IMultisigProxy.ProposalStatus.Pending));
            assertEq(IBridgeProxy(address(bridge)).implementation(), originalImplementation);
            assertEq(token.balanceOf(address(bridge)), balanceBefore);
            assertEq(token.balanceOf(recipient), recipientBefore);
            assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore);
            assertEq(proxy.teeNonce(RGB_CHAIN_ID), teeNonceBefore);
        }
    }

    function test_proposeUpgradeBridgeImplementation_signatureBindsInitializationData() public {
        BridgeV2Mock nextImplementation = new BridgeV2Mock();
        bytes memory signedData = abi.encodeCall(BridgeV2Mock.initializeV2, (777));
        bytes memory submittedData = abi.encodeCall(BridgeV2Mock.initializeV2, (778));
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpgradeBridgeImplementation(
            domainSep, address(bridge), address(nextImplementation), signedData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();

        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.proposeUpgradeBridgeImplementation(
            address(bridge),
            address(nextImplementation),
            submittedData,
            nonce,
            deadline,
            bitmap,
            MultisigHelper.signAll(vm, digest, pks)
        );
    }

    function test_executeProposal_rejectsUpgradeAfterBridgeTargetRotation() public {
        address signedBridge = address(bridge);
        BridgeV2Mock nextImplementation = new BridgeV2Mock();
        bytes memory initializationData = bytes("");
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();

        uint256 upgradeNonce = proxy.proposalNonce();
        bytes32 upgradeDigest = MultisigHelper.digestProposeUpgradeBridgeImplementation(
            domainSep, signedBridge, address(nextImplementation), initializationData, upgradeNonce, deadline
        );
        bytes32 upgradeId = proxy.proposeUpgradeBridgeImplementation(
            signedBridge,
            address(nextImplementation),
            initializationData,
            upgradeNonce,
            deadline,
            bitmap,
            MultisigHelper.signAll(vm, upgradeDigest, pks)
        );

        address replacementBridge = makeAddr("replacementBridge");
        uint256 updateNonce = proxy.proposalNonce();
        bytes32 updateDigest =
            MultisigHelper.digestProposeUpdateBridge(domainSep, replacementBridge, updateNonce, deadline);
        bytes32 updateId = proxy.proposeUpdateBridge(
            replacementBridge, updateNonce, deadline, bitmap, MultisigHelper.signAll(vm, updateDigest, pks)
        );

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(updateId, abi.encode(replacementBridge));
        vm.expectRevert(
            abi.encodeWithSelector(IMultisigProxy.StaleBridgeTarget.selector, signedBridge, replacementBridge)
        );
        proxy.executeProposal(upgradeId, abi.encode(signedBridge, address(nextImplementation), initializationData));
    }
}
