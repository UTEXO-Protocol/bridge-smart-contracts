// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {GovernanceTargetMock} from "../mocks/GovernanceTargetMock.sol";

/// @notice Governance signatures bind operations to their intended targets.
contract MultisigTargetBindingTest is Test {
    MultisigProxy private proxy;

    GovernanceTargetMock private bridge;

    GovernanceTargetMock private cm;

    GovernanceTargetMock private registry;

    GovernanceTargetMock private adapter;

    GovernanceTargetMock private replacement;

    bytes32 private domain;

    uint256 private constant DELAY = 1 hours;

    function setUp() public {
        bridge = new GovernanceTargetMock();
        cm = new GovernanceTargetMock();
        registry = new GovernanceTargetMock();
        adapter = new GovernanceTargetMock();
        replacement = new GovernanceTargetMock();
        bridge.setRouteRegistry(address(registry));
        address[] memory enclaves = new address[](2);
        enclaves[0] = vm.addr(11);
        enclaves[1] = vm.addr(12);
        address[] memory federation = new address[](2);
        federation[0] = vm.addr(21);
        federation[1] = vm.addr(22);
        proxy = new MultisigProxy(
            address(bridge), address(cm), address(0x123), enclaves, 2, 1, federation, 2, DELAY, DELAY
        );
        domain = proxy.DOMAIN_SEPARATOR();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 id = proxy.proposeUpdateLZAdapter(
            address(adapter),
            0,
            deadline,
            3,
            _sign(MultisigHelper.digestProposeUpdateLZAdapter(domain, address(adapter), 0, deadline))
        );
        vm.warp(vm.getBlockTimestamp() + DELAY);
        proxy.executeProposal(id, abi.encode(address(adapter)));
    }

    function _sign(bytes32 digest) private pure returns (bytes[] memory) {
        uint256[] memory keys = new uint256[](2);
        keys[0] = 21;
        keys[1] = 22;
        return MultisigHelper.signAll(vm, digest, keys);
    }

    function _target(uint256 lane) private view returns (address) {
        if (lane == 1 || lane == 4 || lane == 5) return proxy.commissionManager();
        if (lane == 2 || lane == 6) return GovernanceTargetMock(proxy.bridge()).routeRegistry();
        if (lane == 3) return proxy.lzAdapter();
        return proxy.bridge();
    }

    function _rotation(uint256 lane) private returns (bytes32 id, bytes memory opData) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        opData = abi.encode(address(replacement));
        if (lane == 1 || lane == 4 || lane == 5) {
            id = proxy.proposeUpdateCommissionManager(
                address(replacement),
                nonce,
                deadline,
                3,
                _sign(
                    MultisigHelper.digestProposeUpdateCommissionManager(
                        domain, proxy.bridge(), address(replacement), nonce, deadline
                    )
                )
            );
        } else if (lane == 2 || lane == 6) {
            id = proxy.proposeUpdateRouteRegistry(
                address(replacement),
                nonce,
                deadline,
                3,
                _sign(
                    MultisigHelper.digestProposeUpdateRouteRegistry(
                        domain, proxy.bridge(), address(replacement), nonce, deadline
                    )
                )
            );
        } else if (lane == 3) {
            id = proxy.proposeUpdateLZAdapter(
                address(replacement),
                nonce,
                deadline,
                3,
                _sign(MultisigHelper.digestProposeUpdateLZAdapter(domain, address(replacement), nonce, deadline))
            );
        } else {
            id = proxy.proposeUpdateBridge(
                address(replacement),
                nonce,
                deadline,
                3,
                _sign(MultisigHelper.digestProposeUpdateBridge(domain, address(replacement), nonce, deadline))
            );
        }
    }

    /// @dev Assemble the public ABI call and independently check the EIP-712
    ///      schema against literal type strings, not helper hash constants.
    function _signedCall(uint256 lane, address target, bool legacy)
        private
        view
        returns (bytes memory submitData, bytes memory opData)
    {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory data = abi.encodeWithSignature("ping(uint256)", uint256(7));
        bytes32 digest;
        bytes32 independentHash;
        if (lane == 0) {
            digest = MultisigHelper.digestProposeAdminExecute(domain, target, bytes4(data), data, nonce, deadline);
            independentHash = keccak256(
                abi.encode(
                    keccak256(
                        "ProposeAdminExecute(address target,bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)"
                    ),
                    target,
                    bytes4(data),
                    keccak256(data),
                    nonce,
                    deadline
                )
            );
            assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domain, independentHash)));
            if (legacy) {
                digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        domain,
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "ProposeAdminExecute(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)"
                                ),
                                bytes4(data),
                                keccak256(data),
                                nonce,
                                deadline
                            )
                        )
                    )
                );
            }
            submitData = abi.encodeCall(MultisigProxy.proposeAdminExecute, (data, nonce, deadline, 3, _sign(digest)));
            opData = data;
        } else if (lane == 1) {
            digest = MultisigHelper.digestProposeAdminExecuteCM(domain, target, bytes4(data), data, nonce, deadline);
            independentHash = keccak256(
                abi.encode(
                    keccak256(
                        "ProposeAdminExecuteCommissionManager(address target,bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)"
                    ),
                    target,
                    bytes4(data),
                    keccak256(data),
                    nonce,
                    deadline
                )
            );
            assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domain, independentHash)));
            if (legacy) {
                digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        domain,
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "ProposeAdminExecuteCommissionManager(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)"
                                ),
                                bytes4(data),
                                keccak256(data),
                                nonce,
                                deadline
                            )
                        )
                    )
                );
            }
            submitData = abi.encodeCall(
                MultisigProxy.proposeAdminExecuteCommissionManager, (data, nonce, deadline, 3, _sign(digest))
            );
            opData = data;
        } else if (lane == 2) {
            digest = MultisigHelper.digestProposeAdminExecuteRouteRegistry(
                domain, target, bytes4(data), data, nonce, deadline
            );
            independentHash = keccak256(
                abi.encode(
                    keccak256(
                        "ProposeAdminExecuteRouteRegistry(address target,bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)"
                    ),
                    target,
                    bytes4(data),
                    keccak256(data),
                    nonce,
                    deadline
                )
            );
            assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domain, independentHash)));
            if (legacy) {
                digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        domain,
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "ProposeAdminExecuteRouteRegistry(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)"
                                ),
                                bytes4(data),
                                keccak256(data),
                                nonce,
                                deadline
                            )
                        )
                    )
                );
            }
            submitData = abi.encodeCall(
                MultisigProxy.proposeAdminExecuteRouteRegistry, (data, nonce, deadline, 3, _sign(digest))
            );
            opData = data;
        } else if (lane == 3) {
            digest =
                MultisigHelper.digestProposeAdminExecuteAdapter(domain, target, bytes4(data), data, nonce, deadline);
            independentHash = keccak256(
                abi.encode(
                    keccak256(
                        "ProposeAdminExecuteAdapter(address target,bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)"
                    ),
                    target,
                    bytes4(data),
                    keccak256(data),
                    nonce,
                    deadline
                )
            );
            assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domain, independentHash)));
            if (legacy) {
                digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        domain,
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "ProposeAdminExecuteAdapter(bytes4 selector,bytes callData,uint256 nonce,uint256 deadline)"
                                ),
                                bytes4(data),
                                keccak256(data),
                                nonce,
                                deadline
                            )
                        )
                    )
                );
            }
            submitData =
                abi.encodeCall(MultisigProxy.proposeAdminExecuteAdapter, (data, nonce, deadline, 3, _sign(digest)));
            opData = data;
        } else if (lane == 4) {
            digest = MultisigHelper.digestProposeWithdrawTokenCommissionCM(
                domain, target, address(0xCAFE), uint256(7), nonce, deadline
            );
            independentHash = keccak256(
                abi.encode(
                    keccak256(
                        "ProposeWithdrawTokenCommissionCM(address target,address token,uint256 amount,uint256 nonce,uint256 deadline)"
                    ),
                    target,
                    address(0xCAFE),
                    uint256(7),
                    nonce,
                    deadline
                )
            );
            assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domain, independentHash)));
            if (legacy) {
                digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        domain,
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "ProposeWithdrawTokenCommissionCM(address token,uint256 amount,uint256 nonce,uint256 deadline)"
                                ),
                                address(0xCAFE),
                                uint256(7),
                                nonce,
                                deadline
                            )
                        )
                    )
                );
            }
            submitData = abi.encodeCall(
                MultisigProxy.proposeWithdrawTokenCommissionCM,
                (address(0xCAFE), uint256(7), nonce, deadline, 3, _sign(digest))
            );
            opData = abi.encode(address(0xCAFE), uint256(7));
        } else if (lane == 5) {
            digest = MultisigHelper.digestProposeWithdrawNativeCommissionCM(domain, target, uint256(7), nonce, deadline);
            independentHash = keccak256(
                abi.encode(
                    keccak256(
                        "ProposeWithdrawNativeCommissionCM(address target,uint256 amount,uint256 nonce,uint256 deadline)"
                    ),
                    target,
                    uint256(7),
                    nonce,
                    deadline
                )
            );
            assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domain, independentHash)));
            if (legacy) {
                digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        domain,
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "ProposeWithdrawNativeCommissionCM(uint256 amount,uint256 nonce,uint256 deadline)"
                                ),
                                uint256(7),
                                nonce,
                                deadline
                            )
                        )
                    )
                );
            }
            submitData = abi.encodeCall(
                MultisigProxy.proposeWithdrawNativeCommissionCM, (uint256(7), nonce, deadline, 3, _sign(digest))
            );
            opData = abi.encode(uint256(7));
        } else if (lane == 6) {
            digest = MultisigHelper.digestProposeSetRoute(
                domain, target, uint256(1), uint256(2), true, address(0x111), address(0x222), nonce, deadline
            );
            independentHash = keccak256(
                abi.encode(
                    keccak256(
                        "ProposeSetRoute(address target,uint256 sourceChainId,uint256 destChainId,bool enabled,address finalityVerifier,address settlementModule,uint256 nonce,uint256 deadline)"
                    ),
                    target,
                    uint256(1),
                    uint256(2),
                    true,
                    address(0x111),
                    address(0x222),
                    nonce,
                    deadline
                )
            );
            assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domain, independentHash)));
            if (legacy) {
                digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        domain,
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "ProposeSetRoute(uint256 sourceChainId,uint256 destChainId,bool enabled,address finalityVerifier,address settlementModule,uint256 nonce,uint256 deadline)"
                                ),
                                uint256(1),
                                uint256(2),
                                true,
                                address(0x111),
                                address(0x222),
                                nonce,
                                deadline
                            )
                        )
                    )
                );
            }
            submitData = abi.encodeCall(
                MultisigProxy.proposeSetRoute,
                (uint256(1), uint256(2), true, address(0x111), address(0x222), nonce, deadline, 3, _sign(digest))
            );
            opData = abi.encode(uint256(1), uint256(2), true, address(0x111), address(0x222));
        } else if (lane == 7) {
            digest = MultisigHelper.digestProposeUpdateCommissionManager(
                domain, target, address(replacement), nonce, deadline
            );
            independentHash = keccak256(
                abi.encode(
                    keccak256(
                        "ProposeUpdateCommissionManager(address target,address newCommissionManager,uint256 nonce,uint256 deadline)"
                    ),
                    target,
                    address(replacement),
                    nonce,
                    deadline
                )
            );
            assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domain, independentHash)));
            if (legacy) {
                digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        domain,
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "ProposeUpdateCommissionManager(address newCommissionManager,uint256 nonce,uint256 deadline)"
                                ),
                                address(replacement),
                                nonce,
                                deadline
                            )
                        )
                    )
                );
            }
            submitData = abi.encodeCall(
                MultisigProxy.proposeUpdateCommissionManager, (address(replacement), nonce, deadline, 3, _sign(digest))
            );
            opData = abi.encode(address(replacement));
        } else if (lane == 8) {
            digest =
                MultisigHelper.digestProposeUpdateRouteRegistry(domain, target, address(replacement), nonce, deadline);
            independentHash = keccak256(
                abi.encode(
                    keccak256(
                        "ProposeUpdateRouteRegistry(address target,address newRouteRegistry,uint256 nonce,uint256 deadline)"
                    ),
                    target,
                    address(replacement),
                    nonce,
                    deadline
                )
            );
            assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domain, independentHash)));
            if (legacy) {
                digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        domain,
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "ProposeUpdateRouteRegistry(address newRouteRegistry,uint256 nonce,uint256 deadline)"
                                ),
                                address(replacement),
                                nonce,
                                deadline
                            )
                        )
                    )
                );
            }
            submitData = abi.encodeCall(
                MultisigProxy.proposeUpdateRouteRegistry, (address(replacement), nonce, deadline, 3, _sign(digest))
            );
            opData = abi.encode(address(replacement));
        } else if (lane == 9) {
            digest = MultisigHelper.digestProposePauseInflow(domain, target, nonce, deadline);
            independentHash = keccak256(
                abi.encode(
                    keccak256("ProposePauseInflow(address target,uint256 nonce,uint256 deadline)"),
                    target,
                    nonce,
                    deadline
                )
            );
            assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domain, independentHash)));
            if (legacy) {
                digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        domain,
                        keccak256(
                            abi.encode(keccak256("ProposePauseInflow(uint256 nonce,uint256 deadline)"), nonce, deadline)
                        )
                    )
                );
            }
            submitData = abi.encodeCall(MultisigProxy.proposePauseInflow, (nonce, deadline, 3, _sign(digest)));
            opData = bytes("");
        } else if (lane == 10) {
            digest = MultisigHelper.digestProposeUnpauseInflow(domain, target, nonce, deadline);
            independentHash = keccak256(
                abi.encode(
                    keccak256("ProposeUnpauseInflow(address target,uint256 nonce,uint256 deadline)"),
                    target,
                    nonce,
                    deadline
                )
            );
            assertEq(digest, keccak256(abi.encodePacked("\x19\x01", domain, independentHash)));
            if (legacy) {
                digest = keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        domain,
                        keccak256(
                            abi.encode(
                                keccak256("ProposeUnpauseInflow(uint256 nonce,uint256 deadline)"), nonce, deadline
                            )
                        )
                    )
                );
            }
            submitData = abi.encodeCall(MultisigProxy.proposeUnpauseInflow, (nonce, deadline, 3, _sign(digest)));
            opData = bytes("");
        } else {
            revert("unknown lane");
        }
    }

    function _submit(bytes memory data) private returns (bytes32 id) {
        (bool ok, bytes memory result) = address(proxy).call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        return abi.decode(result, (bytes32));
    }

    function test_executeProposal_usesSignedTargetInEveryManagedLane() public {
        for (uint256 lane; lane < 11; ++lane) {
            uint256 snapshot = vm.snapshotState();
            address target = _target(lane);
            (bytes memory data, bytes memory opData) = _signedCall(lane, target, false);
            bytes32 id = _submit(data);
            assertEq(proxy.getProposal(id).expectedTarget, target);
            uint256 beforeCalls = GovernanceTargetMock(target).calls();
            vm.warp(vm.getBlockTimestamp() + DELAY);
            proxy.executeProposal(id, opData);
            assertEq(GovernanceTargetMock(target).calls(), beforeCalls + 1);
            assertEq(uint256(proxy.getProposal(id).status), uint256(IMultisigProxy.ProposalStatus.Executed));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_executeProposal_rejectsRotatedTargetInEveryManagedLane() public {
        for (uint256 lane; lane < 11; ++lane) {
            uint256 snapshot = vm.snapshotState();
            address target = _target(lane);
            (bytes memory data, bytes memory opData) = _signedCall(lane, target, false);
            bytes32 id = _submit(data);
            (bytes32 rotation, bytes memory rotationData) = _rotation(lane);
            vm.warp(vm.getBlockTimestamp() + DELAY);
            proxy.executeProposal(rotation, rotationData);
            uint256 oldCalls = GovernanceTargetMock(target).calls();
            uint256 newCalls = replacement.calls();
            uint256 nonce = proxy.proposalNonce();
            vm.expectRevert(
                abi.encodeWithSelector(IMultisigProxy.StaleProposalTarget.selector, target, address(replacement))
            );
            proxy.executeProposal(id, opData);
            assertEq(GovernanceTargetMock(target).calls(), oldCalls);
            assertEq(replacement.calls(), newCalls);
            assertEq(proxy.proposalNonce(), nonce);
            assertEq(uint256(proxy.getProposal(id).status), uint256(IMultisigProxy.ProposalStatus.Pending));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_proposeAdminExecute_rejectsSignaturesForRotatedTargetInEveryLane() public {
        for (uint256 lane; lane < 11; ++lane) {
            uint256 snapshot = vm.snapshotState();
            (bytes32 rotation, bytes memory rotationData) = _rotation(lane);
            (bytes memory data,) = _signedCall(lane, _target(lane), false);
            uint256 nonce = proxy.proposalNonce();
            vm.warp(vm.getBlockTimestamp() + DELAY);
            proxy.executeProposal(rotation, rotationData);
            (bool ok, bytes memory result) = address(proxy).call(data);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(IMultisigProxy.InvalidSignature.selector));
            assertEq(proxy.proposalNonce(), nonce);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_proposeAdminExecute_rejectsWrongTargetAndLegacySignatureInEveryLane() public {
        for (uint256 lane; lane < 11; ++lane) {
            uint256 nonce = proxy.proposalNonce();
            (bytes memory wrong,) = _signedCall(lane, address(replacement), false);
            (bool ok, bytes memory result) = address(proxy).call(wrong);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(IMultisigProxy.InvalidSignature.selector));
            (bytes memory legacy,) = _signedCall(lane, _target(lane), true);
            (ok, result) = address(proxy).call(legacy);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(IMultisigProxy.InvalidSignature.selector));
            assertEq(proxy.proposalNonce(), nonce);
        }
    }

    function test_executeProposal_rejectsTamperedDataInEveryManagedLane() public {
        for (uint256 lane; lane < 11; ++lane) {
            uint256 snapshot = vm.snapshotState();
            (bytes memory data, bytes memory opData) = _signedCall(lane, _target(lane), false);
            bytes32 id = _submit(data);
            vm.warp(vm.getBlockTimestamp() + DELAY);
            vm.expectRevert(IMultisigProxy.DataMismatch.selector);
            proxy.executeProposal(id, bytes.concat(opData, hex"01"));
            assertEq(uint256(proxy.getProposal(id).status), uint256(IMultisigProxy.ProposalStatus.Pending));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_executeProposal_rejectsPendingAdapterCallAfterDisable() public {
        (bytes memory data, bytes memory opData) = _signedCall(3, address(adapter), false);
        bytes32 id = _submit(data);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 disable = proxy.proposeDisableLZAdapter(
            nonce, deadline, 3, _sign(MultisigHelper.digestProposeDisableLZAdapter(domain, nonce, deadline))
        );
        vm.warp(vm.getBlockTimestamp() + DELAY);
        proxy.executeProposal(disable, "");
        vm.expectRevert(
            abi.encodeWithSelector(IMultisigProxy.StaleProposalTarget.selector, address(adapter), address(0))
        );
        proxy.executeProposal(id, opData);
        assertEq(adapter.calls(), 0);
        assertEq(uint256(proxy.getProposal(id).status), uint256(IMultisigProxy.ProposalStatus.Pending));
    }

    function test_proposeAdminExecute_rejectsUnsetRegistryWithoutConsumingNonce() public {
        bridge.setRouteRegistry(address(0));
        for (uint256 lane = 2; lane <= 6; lane += 4) {
            uint256 nonce = proxy.proposalNonce();
            (bytes memory data,) = _signedCall(lane, address(0), false);
            (bool ok, bytes memory result) = address(proxy).call(data);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(IMultisigProxy.ZeroTarget.selector));
            assertEq(proxy.proposalNonce(), nonce);
        }
    }
}
