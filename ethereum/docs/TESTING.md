# Tests and coverage

Run commands from `ethereum/`. Tests require the pinned Foundry v1.7.1 toolchain and
initialized Git submodules.

## Organization

The `test/` tree groups suites by the contract or subsystem under test:

| Directory | Responsibility |
| --- | --- |
| `bridge/` | Deposits, releases, liquidity, limits, fees, rebalances and callbacks |
| `multisig/` | Signer sets, proposals, upgrades, emergency operations and LayerZero releases |
| `commission/` | Fee configuration, quotes, oracle checks and commission pools |
| `integration/` | Interactions between Bridge, registry, multisig and commission manager |
| `proxy/` | Bridge proxy compatibility, initialization and upgrade state |
| `settlement/` | RGB records, outbound settlement and reject lists |
| `registry/`, `verifiers/`, `btc_relay/` | Route dispatch, finality checks and checkpoint behavior |
| `libraries/` | Token buckets and rolling outflow accounting |
| `helpers/` | Deployment, signing, library and script harnesses |
| `mocks/` | External counterparties, adversarial implementations and observation harnesses |

Each `.t.sol` suite owns a coherent behavior group. Shared bases are abstract,
contain no test functions, and hold only fixtures and helpers used across suites.
Helpers used by one suite stay in that suite. The target-binding and proposal
reentrancy suites use their own small fixtures instead of deploying the full
Bridge stack.

The integration suites exercise EVM contract interactions with mocked Bitcoin
finality. They do not verify an actual cross-chain delivery or RGB mint/burn
pipeline.

## Conventions

- Name deterministic cases `test_<subject>_<expectedBehavior>` and fuzz
  properties `testFuzz_<subject>_<property>`, using camelCase within each segment.
  These are project conventions, not additional Solidity language requirements.
- Use descriptive suite names and private or internal `_helper` functions.
  Keep fixture visibility explicit and constants in uppercase.
- Test the observable result: state, balances, events, authorization and rollback.
  For known failures, match the error selector and relevant arguments or the exact
  revert string. An unrelated revert must not satisfy the intended scenario.
- Generate valid-domain fuzz inputs when asserting success. Test rejection
  domains explicitly rather than accepting every revert in a catch block.
- Use named memory snapshots for larger accounting checks. Preserve individual
  assertions; reducing stack pressure must not reduce what a test verifies.
- Read test time with `vm.getBlockTimestamp()` when using `vm.warp`. The compiler
  may cache `block.timestamp` within a transaction, so repeated relative warps
  and deadlines must use fresh reads. Absolute timestamps are useful for boundary
  checks and explicit multi-stage timelocks.
- Comments explain the invariant, fixture constraint or ordering dependency.
  Avoid PR history and narration that merely repeats the next call. A meaningful
  regression explanation should survive a rename or file move.
- Annotate assembly as memory-safe only after checking memory accesses. The
  annotation describes memory use, not ABI return width: a safe block can
  intentionally return malformed data. Preserve adversarial mock behavior.
- Similar checks on different contracts, networks or authorization paths are
  independent scenarios. Remove a duplicate only when its setup, operation and
  assertions are equivalent.

## Run tests

```sh
forge fmt --check
forge test
forge test --match-path 'test/multisig/*.t.sol'
forge test --match-path 'test/bridge/Rollback.t.sol' -vvv
FOUNDRY_PROFILE=ci forge test
```

The CI profile explicitly uses 256 fuzz runs, matching Foundry's default, and
seed `0x1` for reproducible pull-request results. A fixed seed repeats the same
inputs; use separate campaigns with other seeds to explore new inputs:

```sh
forge test --fuzz-runs 1000 --fuzz-seed 0x2
```

## Coverage

```sh
forge coverage --ir-minimum --skip script --exclude-tests --no-match-coverage '^src/btc_relay/' \
  --report summary --report lcov --report-file lcov.info
```

All test suites run. `--exclude-tests` removes test/support code from the report;
`--skip script` avoids compiling unrelated deployment and interaction entrypoints.
Scripts imported by a test harness remain available as dependencies.
`--no-match-coverage` excludes the complete vendored `src/btc_relay/` tree
from summary and LCOV metrics. Its existing tests still run; our RGB verifier
and bridge integration code remain included.

Ordinary `forge coverage` disables the optimizer and via-IR pipeline and hits
stack-depth limits in this project. The minimal IR mode runs coverage without
changing production contracts. The test fixtures use memory snapshots and small
execution helpers to compile in this mode.

Minimal IR can produce imprecise source mappings and missing-anchor warnings.
Use the report to investigate untested paths; it is not a release safety proof
or a strict percentage gate. CI runs the test suite without a coverage threshold.

If LCOV tools are installed, generate an HTML view:

```sh
genhtml lcov.info --output-directory coverage
```

Both `lcov.info` and `coverage/` are generated outputs and are ignored by Git.
