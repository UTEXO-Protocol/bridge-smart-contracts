# Bridge upgrade baseline

`Bridge.v1.json` is the frozen initial proxy storage baseline. It is currently
the pre-release v1 layout; record the deployed proxy, chain and implementation
in the release record when v1 ships. Do not regenerate this file to make CI pass.

After `forge build`, run `python3 script/check_upgrade_safety.py`. It discovers
every concrete production artifact under `src/` exposing the compatibility
marker, regardless of contract name, and checks `BridgeV2Mock` as an append-only
positive fixture. Deploy only artifacts included in this check.

Existing fields and struct members must retain their layout. New top-level
fields may be appended after the baseline's last occupied slot. This deliberately
conservative policy rejects gap consumption and changes to existing structs.
The script also compares actual four-byte selectors with the proxy ABI, including
inherited implementation methods. Run on clean build artifacts in CI.

For subsequent releases, preserve earlier baselines and add the newly deployed
layout as a versioned baseline; extend the checker to validate against the latest
deployed layout as well. Checking only v1 would not protect state added in v2.
Baseline changes require explicit storage-migration review. The checker covers
compiler-reported storage; OpenZeppelin namespaced storage and dependency upgrades
still require separate review against the deployed dependency version.
