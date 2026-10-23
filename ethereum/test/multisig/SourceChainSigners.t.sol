// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MockOutboundLZAdapter} from "../mocks/MockOutboundLZAdapter.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice Per-source signer sets isolate authorization, nonce streams and rotations.
contract MultisigSourceChainSignersTest is MultisigProxyTestBase {
    /// @dev `n` deterministic, globally-unique signer addresses for `chainId`,
    ///      in a keccak namespace disjoint from the setUp enclave/federation
    ///      addresses and from every other chain's generated set.
    function _encSetFor(uint256 chainId, uint256 n) private pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = address(uint160(uint256(keccak256(abi.encode("enc-set", chainId, i)))));
        }
    }

    /// @dev Register (or rotate) an enclave set for `chainId` via the federation
    ///      propose -> timelock -> execute path (signed by the original 2-of-3
    ///      federation, which is left untouched by these helpers).
    function _govUpdateEnclave(uint256 chainId, address[] memory signers, uint256 threshold) private {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeUpdateEnclaveSigners(domainSep, chainId, signers, threshold, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        bytes32 id = proxy.proposeUpdateEnclaveSigners(chainId, signers, threshold, nonce, deadline, bitmap, sigs);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(chainId, signers, threshold));
    }

    /// @dev `fundsOutCall` for a source chain with no registered enclave set
    ///      reverts UnknownSourceChain before touching the nonce/signatures.
    function test_fundsOutCall_revertsOnUnknownSourceBeforeNonceCheck() public {
        IBridge.FundsOutParams memory p = _fundsOutParams();
        p.sourceChainId = 424_242; // not registered
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, uint256(424_242)));
        proxy.fundsOutCall(p, 1, vm.getBlockTimestamp() + 1 hours, 0, new bytes[](0));
    }

    /// @dev A release for chain B signed by chain A's (RGB) enclave keys is
    ///      rejected: selection by sourceChainId verifies A's signatures against
    ///      B's set, which does not contain them.
    function test_fundsOutCall_rejectsSignaturesFromAnotherSourceChain() public {
        uint256 chainB = 7_000_001;
        _govUpdateEnclave(chainB, _encSetFor(chainB, 3), 2);

        IBridge.FundsOutParams memory p = _fundsOutParams();
        p.sourceChainId = chainB;
        uint256 nonce = proxy.teeNonce(chainB); // 0
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, p, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3(); // RGB signers
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // Must fail at the signer check (recovered RGB signer != chainB's set),
        // NOT downstream in the Bridge — that is what proves signer-set isolation.
        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.fundsOutCall(p, nonce, deadline, bitmap, sigs);
    }

    /// @dev Each source chain has an independent teeNonce lane: an RGB release
    ///      advances only RGB's nonce, not another registered chain's.
    function test_fundsOutCall_keepsSourceChainNonceLanesIndependent() public {
        uint256 chainB = 7_000_002;
        _govUpdateEnclave(chainB, _encSetFor(chainB, 3), 2);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), 0, "RGB nonce starts at 0");
        assertEq(proxy.teeNonce(chainB), 0, "chainB nonce starts at 0");

        IBridge.FundsOutParams memory p = _fundsOutParams();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, p, proxy.teeNonce(RGB_CHAIN_ID), deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        proxy.fundsOutCall(p, 0, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), 1, "RGB lane advanced");
        assertEq(proxy.teeNonce(chainB), 0, "chainB lane untouched");
    }

    function test_proposeUpdateEnclaveSigners_registersNewSourceChainAtExecution() public {
        uint256 chainB = 8_000_001;
        address[] memory sB = _encSetFor(chainB, 4);
        _govUpdateEnclave(chainB, sB, 3); // 2*3 > 4

        assertEq(proxy.enclaveThreshold(chainB), 3);
        address[] memory got = proxy.getEnclaveSigners(chainB);
        assertEq(got.length, 4);
        assertEq(got, sB, "every registered signer is stored in order");

        uint256[] memory chains = proxy.getEnclaveSourceChains();
        assertEq(chains.length, 2, "RGB + chainB");
        assertEq(chains[0], RGB_CHAIN_ID);
        assertEq(chains[1], chainB);
    }

    /// @dev Federation rotation must be disjoint from *every* enclave chain.
    function test_proposeUpdateFederationSigners_rejectsOverlapWithAnySourceChain() public {
        uint256 chainB = 8_000_002;
        address[] memory sB = _encSetFor(chainB, 3);
        _govUpdateEnclave(chainB, sB, 2);

        address[] memory newFed = new address[](3);
        newFed[0] = sB[0]; // overlaps chainB
        newFed[1] = fedA2;
        newFed[2] = fedA3;

        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateFederationSigners(domainSep, newFed, 2, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        bytes32 id = proxy.proposeUpdateFederationSigners(newFed, 2, nonce, deadline, bitmap, sigs);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.SignerSetsOverlap.selector, sB[0]));
        proxy.executeProposal(id, abi.encode(newFed, 2));
    }

    /// @dev Different source chains may intentionally reuse the same enclave
    ///      keys. Each set remains internally unique and signatures stay bound
    ///      to their sourceChainId-specific digest and nonce lane.
    function test_proposeUpdateEnclaveSigners_allowsSharedKeysAcrossSourceChains() public {
        uint256 chainB = 8_000_003;
        address[] memory sB = _encSetFor(chainB, 3);
        _govUpdateEnclave(chainB, sB, 2);

        uint256 chainC = 8_000_004;
        _govUpdateEnclave(chainC, sB, 2);

        address[] memory gotB = proxy.getEnclaveSigners(chainB);
        address[] memory gotC = proxy.getEnclaveSigners(chainC);
        assertEq(gotB, sB, "chain B signer set");
        assertEq(gotC, sB, "chain C reuses signer set");
        assertEq(proxy.enclaveThreshold(chainB), 2, "chain B threshold");
        assertEq(proxy.enclaveThreshold(chainC), 2, "chain C threshold");
    }

    /// @dev A partial rotation may keep some of the chain's own keys.
    function test_proposeUpdateEnclaveSigners_allowsRetainedKeysDuringSameChainRotation() public {
        address[] memory newRgb = new address[](2);
        newRgb[0] = encA1; // keep an existing RGB signer
        newRgb[1] = makeAddr("rgbFresh");
        uint256 chainsBefore = proxy.getEnclaveSourceChains().length;
        _govUpdateEnclave(RGB_CHAIN_ID, newRgb, 2);

        address[] memory got = proxy.getEnclaveSigners(RGB_CHAIN_ID);
        assertEq(got.length, 2);
        assertEq(got[0], encA1, "retained enclave key");
        // Rotating an existing chain must not add a duplicate registry entry.
        assertEq(proxy.getEnclaveSourceChains().length, chainsBefore, "no duplicate source-chain entry on rotation");
    }

    /// @dev Registering more than MAX_ENCLAVE_SOURCE_CHAINS source chains is
    ///      rejected at execute (bounds the cross-set disjoint loop).
    function test_executeProposal_rejectsSourceChainCountAboveMaximum() public {
        uint256 maxChains = proxy.MAX_ENCLAVE_SOURCE_CHAINS();
        // RGB already occupies slot 1 — fill the rest.
        for (uint256 k = 0; k < maxChains - 1; k++) {
            uint256 chainId = 6_000_000 + k;
            _govUpdateEnclave(chainId, _encSetFor(chainId, 2), 2);
        }
        assertEq(proxy.getEnclaveSourceChains().length, maxChains);

        uint256 overflowChain = 6_999_999;
        address[] memory s = _encSetFor(overflowChain, 2);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeUpdateEnclaveSigners(domainSep, overflowChain, s, 2, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        bytes32 id = proxy.proposeUpdateEnclaveSigners(overflowChain, s, 2, nonce, deadline, bitmap, sigs);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IMultisigProxy.TooManyEnclaveSourceChains.selector, maxChains + 1, maxChains)
        );
        proxy.executeProposal(id, abi.encode(overflowChain, s, 2));
    }

    /// @dev A per-source set's OWN keys authorize a release for that chain, and
    ///      the correct nonce lane advances. RGB is rotated to keys we control
    ///      so the full release (reusing RGB's configured route/liquidity) runs.
    function test_fundsOutCall_acceptsSourceChainSpecificQuorum() public {
        (address[] memory encAddrs, uint256[] memory encPks) = _signerSetFromPrivateKeys(0xEEE0000, 3);
        _govUpdateEnclave(RGB_CHAIN_ID, encAddrs, 2);

        uint256 balBefore = token.balanceOf(recipient);
        IBridge.FundsOutParams memory p = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, p, nonce, deadline);
        uint256[] memory signPks = new uint256[](2);
        signPks[0] = encPks[0];
        signPks[1] = encPks[1];
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, signPks);

        proxy.fundsOutCall(p, nonce, deadline, 0x3, sigs);

        assertEq(token.balanceOf(recipient), balBefore + AMOUNT, "chain-owned keys authorized the release");
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "RGB nonce advanced");
    }

    /// @dev The LZ branch selects the enclave set + nonce lane by source chain:
    ///      an RGB LZ release advances only RGB's lane and emits sourceChainId.
    function test_lzFundsOutCall_usesSignedSourceChainNonceLane() public {
        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));
        _govUpdateEnclave(7_100_001, _encSetFor(7_100_001, 3), 2); // second registered chain

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.deal(address(this), LZ_NATIVE_FEE);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.LzFundsOutExecuted(RGB_CHAIN_ID, nonce, bitmap, params.dstEid, params.recipient, AMOUNT);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);

        assertEq(token.balanceOf(mockOft), AMOUNT, "LZ release forwarded to OFT");
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "RGB LZ lane advanced");
        assertEq(proxy.teeNonce(7_100_001), 0, "other chain LZ lane untouched");
    }

    /// @dev lzFundsOutCall for an unregistered source chain reverts UnknownSourceChain.
    function test_lzFundsOutCall_revertsForUnregisteredSourceChain() public {
        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());
        params.sourceChainId = 424_242; // unregistered (checked before adapter/signatures)
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, uint256(424_242)));
        proxy.lzFundsOutCall(params, 0, vm.getBlockTimestamp() + 1 hours, 0, new bytes[](0));
    }

    /// @dev An LZ release for chain B signed by RGB keys is rejected at the
    ///      signer check (per-source selection), not downstream.
    function test_lzFundsOutCall_rejectsSignaturesFromAnotherSourceChain() public {
        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));
        uint256 chainB = 7_200_001;
        _govUpdateEnclave(chainB, _encSetFor(chainB, 3), 2);

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, SRC_BURN_TX_ID, _fundsInIds());
        params.sourceChainId = chainB;
        uint256 nonce = proxy.teeNonce(chainB); // 0
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3(); // RGB signers
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.deal(address(this), LZ_NATIVE_FEE);
        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);
    }

    /// @dev The enclave-rotation proposal digest is bound to sourceChainId:
    ///      a digest signed for RGB cannot authorize a rotation of chain B.
    ///      Guards against regressing the sourceChainId out of the typehash.
    function test_proposeUpdateEnclaveSigners_bindsAuthorizationToSourceChain() public {
        uint256 chainB = 7_300_001;
        address[] memory sB = _encSetFor(chainB, 2);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
        // Federation signs the digest for RGB_CHAIN_ID...
        bytes32 digest =
            MultisigHelper.digestProposeUpdateEnclaveSigners(domainSep, RGB_CHAIN_ID, sB, 2, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        // ...but the proposal is submitted for chainB -> digest mismatch.
        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.proposeUpdateEnclaveSigners(chainB, sB, 2, nonce, deadline, bitmap, sigs);
    }

    /// @dev sourceChainId == 0 is reserved (threshold 0 is the "unregistered"
    ///      sentinel), so it is rejected at construction.
    function test_constructor_revertsOnZeroInitialSourceChain() public {
        address[] memory enc = _validEnc();
        address[] memory fed = _validFed();
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, uint256(0)));
        new MultisigProxy(address(bridge), address(cm), emergencyGuardian, enc, 2, 0, fed, 2, TIMELOCK, MIN_TIMELOCK);
    }

    /// @dev ...and rejected up front by proposeUpdateEnclaveSigners (before sigs).
    function test_proposeUpdateEnclaveSigners_revertsOnZeroSourceChain() public {
        address[] memory sB = _encSetFor(1, 2);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
        bytes[] memory noSigs = new bytes[](0);
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, uint256(0)));
        proxy.proposeUpdateEnclaveSigners(0, sB, 2, nonce, deadline, 0, noSigs);
    }

    /// @dev Fills all 32 enclave source-chain slots with 20 signers each, then measures
    ///      enclave and federation rotations against a fixture gas budget. Federation
    ///      rotation checks every enclave set; enclave rotation checks only federation
    ///      keys. Each 20-signer set uses the required strict-majority threshold of 11.
    function test_executeProposal_signerRotationsFitGasBudgetAtMaximumRegistrySize() public {
        uint256 blockGasLimit = 30_000_000; // explicit fixture budget
        uint256 nChains = proxy.MAX_ENCLAVE_SOURCE_CHAINS(); // 32
        uint256 nSigners = proxy.MAX_SIGNERS(); // 20
        uint256 t20 = nSigners / 2 + 1; // strict majority

        // Rotate RGB to 20 signers, then register (nChains - 1) more 20-signer
        // chains so all 32 chains carry the maximum set.
        _govUpdateEnclave(RGB_CHAIN_ID, _encSetFor(RGB_CHAIN_ID, nSigners), t20);
        for (uint256 k = 0; k < nChains - 1; k++) {
            uint256 chainId = 5_000_000 + k;
            _govUpdateEnclave(chainId, _encSetFor(chainId, nSigners), t20);
        }
        assertEq(proxy.getEnclaveSourceChains().length, nChains, "registry filled to the cap");

        // Measure an enclave rotation with a full registry. Candidate enclave keys
        // are checked against federation keys, not other enclave sets.
        {
            uint256 rotChain = 5_000_000;
            address[] memory fresh = _encSetFor(9_999_999, nSigners); // disjoint namespace
            uint256 nonce = proxy.proposalNonce();
            uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
            bytes32 digest =
                MultisigHelper.digestProposeUpdateEnclaveSigners(domainSep, rotChain, fresh, t20, nonce, deadline);
            (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
            bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
            bytes32 id = proxy.proposeUpdateEnclaveSigners(rotChain, fresh, t20, nonce, deadline, bitmap, sigs);
            vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
            uint256 g0 = gasleft();
            proxy.executeProposal(id, abi.encode(rotChain, fresh, t20));
            uint256 gEnc = g0 - gasleft();
            emit log_named_uint("gas: updateEnclaveSigners @32chains x20 (rotate)", gEnc);
            assertLt(gEnc, blockGasLimit, "enclave rotation exceeds block gas limit");
        }

        // Measure federation rotations against all 32 enclave sets, signing each
        // rotation with current federation keys.
        (uint256[] memory origPks, uint256 origBitmap) = _fedSigSet2of3();

        (address[] memory f3, uint256[] memory p3) = _signerSetFromPrivateKeys(0xFED30000, 3);
        uint256 g3 = _rotateFedMeasured(f3, 2, origPks, origBitmap);
        emit log_named_uint("gas: updateFederationSigners size=3 @32x20", g3);
        assertLt(g3, blockGasLimit, "fed(3) rotation exceeds block gas limit");

        (address[] memory f5, uint256[] memory p5) = _signerSetFromPrivateKeys(0xFED50000, 5);
        uint256 g5 = _rotateFedMeasured(f5, 3, _slice(p3, 2), _bitmapFor(2)); // signed by f3 (t=2)
        emit log_named_uint("gas: updateFederationSigners size=5 @32x20", g5);
        assertLt(g5, blockGasLimit, "fed(5) rotation exceeds block gas limit");

        (address[] memory f10,) = _signerSetFromPrivateKeys(0xFED100000, 10);
        uint256 g10 = _rotateFedMeasured(f10, 6, _slice(p5, 3), _bitmapFor(3)); // signed by f5 (t=3)
        emit log_named_uint("gas: updateFederationSigners size=10 @32x20", g10);
        assertLt(g10, blockGasLimit, "fed(10) rotation exceeds block gas limit");
    }

    /// @notice Governance accepts a valid, disjoint signer set without
    ///         on-chain enclave attestation evidence.
    function test_proposeUpdateEnclaveSigners_acceptsValidQuorumWithoutAttestation() public {
        address[] memory newSigners = new address[](3);
        newSigners[0] = makeAddr("unattestedEnc1");
        newSigners[1] = makeAddr("unattestedEnc2");
        newSigners[2] = makeAddr("unattestedEnc3");
        uint256 newThreshold = 2;

        address[] memory before_ = proxy.getEnclaveSigners(RGB_CHAIN_ID);
        assertEq(before_.length, 3, "pre enclave count");
        assertEq(before_[0], encA1, "pre signer 0");
        assertEq(before_[1], encA2, "pre signer 1");
        assertEq(before_[2], encA3, "pre signer 2");
        assertEq(proxy.enclaveThreshold(RGB_CHAIN_ID), 2, "pre enclave threshold");

        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id =
            proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        // Rotation validates signer addresses and quorum policy, not enclave attestation.
        vm.expectEmit(true, false, false, true, address(proxy));
        emit IMultisigProxy.EnclaveSignersUpdated(RGB_CHAIN_ID, newSigners, newThreshold);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit IMultisigProxy.ProposalExecuted(id, IMultisigProxy.OperationType.UpdateEnclaveSigners);

        proxy.executeProposal(id, abi.encode(RGB_CHAIN_ID, newSigners, newThreshold));

        address[] memory after_ = proxy.getEnclaveSigners(RGB_CHAIN_ID);
        assertEq(after_.length, 3, "post enclave count");
        assertEq(after_[0], newSigners[0], "post signer 0");
        assertEq(after_[1], newSigners[1], "post signer 1");
        assertEq(after_[2], newSigners[2], "post signer 2");
        assertEq(proxy.enclaveThreshold(RGB_CHAIN_ID), newThreshold, "post enclave threshold");
    }
}
