# Slither

Run the analyzer from `ethereum/` so it uses the Foundry project, configuration
and reviewed findings in this directory:

```sh
python3 -m venv .venv-slither
source .venv-slither/bin/activate
python -m pip install -r requirements-slither.txt
rm -f slither-report.json
FOUNDRY_PROFILE=ci slither . --fail-high --json slither-report.json
```

Foundry must be available and Git submodules initialized. Slither performs its
own Foundry build. Remove an existing report before rerunning: Slither does not
overwrite JSON output files.

## CI policy

The `Slither` job in `.github/workflows/test.yml` runs on pushes, pull requests
and manual dispatches, alongside the existing Foundry checks. It installs the
pinned Slither release from `requirements-slither.txt` and uploads
`slither-report.json` as an artifact, including when analysis fails.

High findings fail the job (`--fail-high`); Medium and lower remain advisory
and appear in the report. Slither has no separate Critical severity: High is
its highest impact level. Compilation and analyzer errors also fail the job;
there is no `continue-on-error` or `|| true`.
Require the `Slither` check in branch protection to block merges on job failure.
After the remaining Medium findings have been reviewed or fixed in separate
PRs, switch to `--fail-medium` to enforce that severity as well.

## Reviewed exclusions

`slither.config.json` filters findings confined to dependencies, tests or
deployment scripts. Production code under `src/btc_relay/` remains in scope.
No detector is globally disabled.

`slither.db.json` uses Slither's native triage database. Each entry identifies
one reviewed finding and includes a `review_reason`. It contains:

- Ten `uninitialized-local` findings: deliberate default-zero values in Bridge
  and MultisigProxy, or relay loop assignments guaranteed by minimum input length.
- Four `unused-return` findings: intentionally unused commission quote fields
  or oracle round fields, with the relevant accounting and oracle checks retained.
- Two `missing-zero-check` findings: intentionally disabled LayerZero ingress
  or unset sequencer configuration that makes native quotes fail closed.

These exclusions apply to the reviewed implementation. Re-review affected
entries whenever their functions change; a stable finding ID does not prove
that changed code remains safe. Do not automatically regenerate the database
from all findings or blanket-disable their detectors.

To inspect results including these exclusions:

```sh
slither . --fail-none --show-ignored-findings
```
