// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice Constructor bounds and proposed signer/timelock configuration.
contract MultisigConfigurationTest is MultisigProxyTestBase {
    /// @dev Deterministic, distinct nonzero signer addresses for quorum checks.
    function _signers(uint256 n) private pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = address(uint160(0xA000 + i));
        }
    }

    /// @dev A second n-element signer array disjoint from `_signers` — used as
    ///      the counterpart set so the two trust domains do not overlap.
    function _signersB(uint256 n) private pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = address(uint160(0xB000 + i));
        }
    }

    function test_constructor_setsState() public view {
        assertEq(proxy.bridge(), address(bridge));
        assertEq(proxy.commissionManager(), address(cm));
        assertEq(proxy.emergencyGuardian(), emergencyGuardian);
        assertEq(proxy.enclaveThreshold(RGB_CHAIN_ID), 2);
        assertEq(proxy.federationThreshold(), 2);
        assertEq(proxy.commissionRecipient(), commissionReceiver);
        assertEq(proxy.timelockDuration(), TIMELOCK);
        assertEq(proxy.proposalNonce(), 0);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), 0);

        address[] memory enc = proxy.getEnclaveSigners(RGB_CHAIN_ID);
        assertEq(enc.length, 3);
        assertEq(enc[0], encA1);

        address[] memory fed = proxy.getFederationSigners();
        assertEq(fed.length, 3);
    }

    function test_operationType_preservesOwnershipGuardianAndUpgradeOrdinals() public pure {
        assertEq(uint256(IMultisigProxy.OperationType.TransferManagedOwnership), 17);
        assertEq(uint256(IMultisigProxy.OperationType.SetEmergencyGuardian), 18);
        assertEq(uint256(IMultisigProxy.OperationType.UpgradeBridgeImplementation), 19);
    }

    function test_constructor_revertsOnZeroBridge() public {
        vm.expectRevert(IMultisigProxy.ZeroBridge.selector);
        new MultisigProxy(
            address(0),
            address(cm),
            emergencyGuardian,
            _validEnc(),
            2,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_revertsOnZeroCommissionManager() public {
        vm.expectRevert(IMultisigProxy.ZeroCommissionManager.selector);
        new MultisigProxy(
            address(bridge),
            address(0),
            emergencyGuardian,
            _validEnc(),
            2,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_revertsOnZeroEmergencyGuardian() public {
        vm.expectRevert(IMultisigProxy.ZeroEmergencyGuardian.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            address(0),
            _validEnc(),
            2,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_revertsOnNoEnclaveSigners() public {
        address[] memory enc = new address[](0);
        vm.expectRevert(IMultisigProxy.NoSigners.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            enc,
            1,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_revertsOnBadEnclaveThreshold() public {
        address[] memory enc = new address[](2);
        enc[0] = encA1;
        enc[1] = encA2;
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            enc,
            3,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_revertsOnTimelockTooLong() public {
        vm.expectRevert(IMultisigProxy.TimelockTooLong.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _validEnc(),
            2,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            30 days,
            MIN_TIMELOCK
        );
    }

    /// @dev Deploying with a timelock below the requested floor reverts.
    function test_constructor_revertsOnTimelockBelowMinTimelock() public {
        // timelock (1h) is below the requested floor (2h) -> TimelockTooShort
        vm.expectRevert(IMultisigProxy.TimelockTooShort.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _validEnc(),
            2,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            1 hours,
            2 hours
        );
    }

    /// @dev The immutable minimum timelock must be nonzero.
    function test_constructor_revertsOnZeroMinTimelock() public {
        vm.expectRevert(IMultisigProxy.InvalidMinTimelock.selector);
        new MultisigProxy(
            address(bridge), address(cm), emergencyGuardian, _validEnc(), 2, RGB_CHAIN_ID, _validFed(), 2, TIMELOCK, 0
        );
    }

    /// @dev A floor at/above the upper bound leaves no valid range — rejected.
    function test_constructor_revertsOnMinTimelockTooLong() public {
        vm.expectRevert(IMultisigProxy.InvalidMinTimelock.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _validEnc(),
            2,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            30 days
        );
    }

    function test_minTimelock_returnsConfiguredFloor() public view {
        assertEq(proxy.MIN_TIMELOCK(), MIN_TIMELOCK);
    }

    function test_constructor_revertsOnDuplicateSigner() public {
        // Duplicate enclave signer with an otherwise-valid 2-of-2 threshold, so
        // the call clears the threshold guard and reverts in _validateSigners.
        address[] memory enc = new address[](2);
        enc[0] = encA1;
        enc[1] = encA1;
        vm.expectRevert(IMultisigProxy.DuplicateSigner.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            enc,
            2,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_revertsOnZeroAddressSigner() public {
        // Zero-address enclave signer in a 2-signer set with a valid 2-of-2
        // threshold, so the call clears the threshold guard and reverts in
        // _validateSigners.
        address[] memory enc = new address[](2);
        enc[0] = address(0);
        enc[1] = encA2;
        vm.expectRevert(IMultisigProxy.ZeroAddressSigner.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            enc,
            2,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_rejectsOneOfThreeEnclave() public {
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _signers(3),
            1,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_rejectsOneOfOneEnclave() public {
        // n < 2 — single-key set, rejected even though 2*1 > 1.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _signers(1),
            1,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_rejectsSubMajorityEnclave() public {
        // 2-of-4: 2*2 == 4, not a strict majority.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _signers(4),
            2,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_rejectsOneOfThreeFederation() public {
        // Enclave valid, federation 1-of-3 — the floor applies to both sets.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _validEnc(),
            2,
            RGB_CHAIN_ID,
            _signers(3),
            1,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_acceptsTwoOfTwo() public {
        MultisigProxy p = new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _signers(2),
            2,
            RGB_CHAIN_ID,
            _signersB(2),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
        assertEq(p.enclaveThreshold(RGB_CHAIN_ID), 2);
        assertEq(p.federationThreshold(), 2);
    }

    function test_constructor_acceptsThreeOfFour() public {
        // Strict majority with a non-trivial set (2*3 > 4).
        MultisigProxy p = new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _signers(4),
            3,
            RGB_CHAIN_ID,
            _signersB(4),
            3,
            TIMELOCK,
            MIN_TIMELOCK
        );
        assertEq(p.enclaveThreshold(RGB_CHAIN_ID), 3);
        assertEq(p.federationThreshold(), 3);
    }

    function test_proposeUpdateEnclaveSigners_rejectsOneOfNAtPropose() public {
        address[] memory newSigners = _signers(3);
        uint256 badThreshold = 1; // 1-of-3
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, badThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // Threshold validity is checked when proposing the rotation.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, badThreshold, nonce, deadline, bitmap, sigs);
    }

    // Intrinsic validation rejects empty, zero-address and duplicate sets at
    // proposal time. Execution checks disjointness against live opposite sets.

    function test_proposeUpdateEnclaveSigners_rejectsEmptySetAtPropose() public {
        address[] memory newSigners = new address[](0);
        uint256 threshold = 2;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, threshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.NoSigners.selector);
        proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, threshold, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateEnclaveSigners_rejectsZeroAddressSignerAtPropose() public {
        address[] memory newSigners = _signers(3);
        newSigners[1] = address(0);
        uint256 threshold = 2;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, threshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.ZeroAddressSigner.selector);
        proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, threshold, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateEnclaveSigners_rejectsDuplicateSignerAtPropose() public {
        address[] memory newSigners = _signers(3);
        newSigners[2] = newSigners[0]; // duplicate
        uint256 threshold = 2;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, threshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DuplicateSigner.selector);
        proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, threshold, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateFederationSigners_rejectsEmptySetAtPropose() public {
        address[] memory newSigners = new address[](0);
        uint256 threshold = 2;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeUpdateFederationSigners(domainSep, newSigners, threshold, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.NoSigners.selector);
        proxy.proposeUpdateFederationSigners(newSigners, threshold, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateFederationSigners_rejectsSubMajorityAtPropose() public {
        address[] memory newSigners = _signers(4);
        uint256 badThreshold = 2; // 2-of-4, sub-majority
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeUpdateFederationSigners(domainSep, newSigners, badThreshold, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // Threshold validity is checked when proposing the rotation.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        proxy.proposeUpdateFederationSigners(newSigners, badThreshold, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateFederationSigners_acceptsStrictMajority() public {
        address[] memory newSigners = _signers(3);
        uint256 newThreshold = 2; // 2-of-3
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeUpdateFederationSigners(domainSep, newSigners, newThreshold, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateFederationSigners(newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(newSigners, newThreshold));
        assertEq(proxy.federationThreshold(), 2);
        assertEq(proxy.getFederationSigners().length, 3);
    }

    // ========================================================================
    // Disjoint signer sets
    // The enclave and federation sets must not share an address, at construction
    // and on signer-update (validated at executeProposal). The setUp sets are
    // already disjoint (encA* vs fedA*).
    // ========================================================================

    function test_constructor_rejectsOverlappingSignerSets() public {
        // encA1 is present in both the enclave and the federation set.
        address[] memory enc = new address[](2);
        enc[0] = encA1;
        enc[1] = encA2;
        address[] memory fed = new address[](2);
        fed[0] = encA1;
        fed[1] = fedA2;
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.SignerSetsOverlap.selector, encA1));
        new MultisigProxy(
            address(bridge), address(cm), emergencyGuardian, enc, 2, RGB_CHAIN_ID, fed, 2, TIMELOCK, MIN_TIMELOCK
        );
    }

    function test_constructor_acceptsDisjointSignerSets() public {
        MultisigProxy p = new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _signers(2),
            2,
            RGB_CHAIN_ID,
            _signersB(2),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
        assertEq(p.getEnclaveSigners(RGB_CHAIN_ID).length, 2);
        assertEq(p.getFederationSigners().length, 2);
    }

    function test_proposeUpdateEnclaveSigners_rejectsOverlapWithFederationAtExecute() public {
        // New enclave set includes fedA1, a current federation signer.
        address[] memory newSigners = new address[](2);
        newSigners[0] = fedA1;
        newSigners[1] = encA2;
        uint256 newThreshold = 2;
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
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.SignerSetsOverlap.selector, fedA1));
        proxy.executeProposal(id, abi.encode(RGB_CHAIN_ID, newSigners, newThreshold));
    }

    function test_proposeUpdateFederationSigners_rejectsOverlapWithEnclaveAtExecute() public {
        // New federation set includes encA1, a current enclave signer.
        address[] memory newSigners = new address[](2);
        newSigners[0] = encA1;
        newSigners[1] = fedA2;
        uint256 newThreshold = 2;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeUpdateFederationSigners(domainSep, newSigners, newThreshold, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateFederationSigners(newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.SignerSetsOverlap.selector, encA1));
        proxy.executeProposal(id, abi.encode(newSigners, newThreshold));
    }

    // ========================================================================
    // Signer-set size cap
    // Either set is capped at MAX_SIGNERS, at construction and on signer-update
    // (validated at construction and proposal creation). The cap bounds the
    // O(N^2) scan and keeps every index within the uint256 signature bitmap.
    // ========================================================================

    function test_constructor_rejectsTooManySigners() public {
        uint256 max = proxy.MAX_SIGNERS();
        address[] memory enc = _signers(max + 1); // 21 distinct enclave signers
        uint256 encThreshold = (max + 1) / 2 + 1; // strict majority, so it clears the threshold guard

        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.TooManySigners.selector, max + 1, max));
        new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            enc,
            encThreshold,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );
    }

    function test_constructor_acceptsSignersAtMax() public {
        uint256 max = proxy.MAX_SIGNERS();
        uint256 threshold = max / 2 + 1; // 11-of-20 strict majority

        MultisigProxy p = new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _signers(max),
            threshold,
            RGB_CHAIN_ID,
            _signersB(max),
            threshold,
            TIMELOCK,
            MIN_TIMELOCK
        );
        assertEq(p.getEnclaveSigners(RGB_CHAIN_ID).length, max);
        assertEq(p.getFederationSigners().length, max);
    }

    function test_proposeUpdateEnclaveSigners_rejectsTooManySignersAtPropose() public {
        uint256 max = proxy.MAX_SIGNERS();
        address[] memory newSigners = _signers(max + 1);
        uint256 newThreshold = (max + 1) / 2 + 1; // valid strict majority
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // Signer-set size is checked when proposing the rotation.
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.TooManySigners.selector, max + 1, max));
        proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateEnclaveSigners_updatesQuorumAfterTimelock() public {
        address newSigner = makeAddr("newEncSigner");
        address[] memory newSigners = new address[](2);
        newSigners[0] = encA1;
        newSigners[1] = newSigner;
        uint256 newThreshold = 2;

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
        proxy.executeProposal(id, abi.encode(RGB_CHAIN_ID, newSigners, newThreshold));

        address[] memory after_ = proxy.getEnclaveSigners(RGB_CHAIN_ID);
        assertEq(after_.length, 2, "executed rotation installs two enclave signers");
        assertEq(after_[1], newSigner, "executed rotation installs the proposed signer");
        assertEq(
            proxy.enclaveThreshold(RGB_CHAIN_ID), newThreshold, "executed rotation installs the proposed threshold"
        );
    }

    function test_proposeSetTimelockDuration_updatesDurationAfterTimelock() public {
        uint256 newDuration = 2 hours;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;

        bytes32 digest = MultisigHelper.digestProposeSetTimelockDuration(domainSep, newDuration, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeSetTimelockDuration(newDuration, nonce, deadline, bitmap, sigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectEmit(false, false, false, true, address(proxy));
        emit IMultisigProxy.TimelockDurationUpdated(newDuration);
        proxy.executeProposal(id, abi.encode(newDuration));

        assertEq(proxy.timelockDuration(), newDuration, "executed proposal updates the timelock duration");
    }

    /// @dev A SetTimelockDuration proposal below the immutable MIN_TIMELOCK
    ///      floor is rejected at execution; the floor holds.
    function test_proposeSetTimelockDuration_revertsBelowMinTimelock() public {
        uint256 t = vm.getBlockTimestamp();
        uint256 newDuration = MIN_TIMELOCK - 1; // just under the floor
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = t + 1 days;

        bytes32 digest = MultisigHelper.digestProposeSetTimelockDuration(domainSep, newDuration, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposeSetTimelockDuration(
            newDuration, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks)
        );

        vm.warp(t + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.TimelockTooShort.selector);
        proxy.executeProposal(id, abi.encode(newDuration));

        assertEq(proxy.timelockDuration(), TIMELOCK, "timelock unchanged");
    }

    /// @dev A value exactly at MIN_TIMELOCK is still accepted (boundary).
    function test_proposeSetTimelockDuration_acceptsAtMinTimelock() public {
        uint256 initialDuration = MIN_TIMELOCK * 2;
        proxy = new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _validEnc(),
            2,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            initialDuration,
            MIN_TIMELOCK
        );
        domainSep = MultisigHelper.domainSeparator(address(proxy), block.chainid);
        assertGt(proxy.timelockDuration(), MIN_TIMELOCK, "initial timelock is above the boundary");

        uint256 t = vm.getBlockTimestamp();
        uint256 newDuration = MIN_TIMELOCK; // exactly the floor
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = t + 1 days;

        bytes32 digest = MultisigHelper.digestProposeSetTimelockDuration(domainSep, newDuration, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposeSetTimelockDuration(
            newDuration, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks)
        );

        vm.warp(t + initialDuration + 1);
        proxy.executeProposal(id, abi.encode(newDuration));
        assertEq(proxy.timelockDuration(), newDuration, "timelock accepts the immutable minimum");
    }

    function test_constructor_preservesDistinctTimelockAndMinimum() public {
        uint256 duration = MIN_TIMELOCK * 2;
        MultisigProxy configured = new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            _validEnc(),
            2,
            RGB_CHAIN_ID,
            _validFed(),
            2,
            duration,
            MIN_TIMELOCK
        );
        assertEq(configured.timelockDuration(), duration, "mutable duration uses its constructor argument");
        assertEq(configured.MIN_TIMELOCK(), MIN_TIMELOCK, "immutable minimum uses its constructor argument");
    }

    function test_executeProposal_revertsWhenTimelockEqualsMaximumLifetime() public {
        uint256 duration = proxy.MAX_PROPOSAL_LIFETIME();
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        (uint256[] memory keys, uint256 bitmap) = _fedSigSet2of3();
        bytes32 digest = MultisigHelper.digestProposeSetTimelockDuration(domainSep, duration, nonce, deadline);
        bytes32 id = proxy.proposeSetTimelockDuration(
            duration, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, keys)
        );
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.TimelockTooLong.selector);
        proxy.executeProposal(id, abi.encode(duration));
        assertEq(proxy.timelockDuration(), TIMELOCK, "rejected duration preserves timelock");
        assertEq(
            uint256(proxy.getProposal(id).status),
            uint256(IMultisigProxy.ProposalStatus.Pending),
            "failed proposal remains pending"
        );
    }
}
