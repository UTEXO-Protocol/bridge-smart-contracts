// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {FundsOutContext} from "../../src/interfaces/RouteTypes.sol";
import {NullVerifier} from "../../src/verifiers/NullVerifier.sol";

/// @notice A route that opts out of proof verification accepts empty and arbitrary proofs.
contract NullVerifierTest is Test {
    NullVerifier private verifier;

    function setUp() public {
        verifier = new NullVerifier();
    }

    function test_verify_acceptsEmptyAndArbitraryProofs() public view {
        FundsOutContext memory context;
        context.amount = 100;
        context.sourceAddress = "attested-source";
        verifier.verify(context, "");
        verifier.verify(context, hex"deadbeef");
    }
}
