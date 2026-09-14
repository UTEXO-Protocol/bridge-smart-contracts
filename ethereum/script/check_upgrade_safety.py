"""Check compiled implementation artifacts against a frozen layout baseline.

Run after forge build. Discovers production contracts exposing the compatibility
marker, and always checks BridgeV2Mock as an append-only positive fixture.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MARKER = "bridgeProxyCompatibilityUUID()"


def normalize(layout):
    types = layout["types"]

    def field(item):
        return {**{k: item[k] for k in ("label", "slot", "offset")},
                "type": types[item["type"]]["label"],
                "numberOfBytes": types[item["type"]]["numberOfBytes"]}

    return {"storage": [field(x) for x in layout["storage"]],
            "structs": sorted([
                {"label": t["label"], "numberOfBytes": t["numberOfBytes"],
                 "members": [field(m) for m in t["members"]]}
                for t in types.values() if "members" in t], key=lambda t: t["label"])}


def check_layout(baseline, candidate):
    old, new = baseline["storage"], candidate["storage"]
    if not old or new[:len(old)] != old:
        raise ValueError("existing storage fields changed, reordered or removed")
    end = max(int(f["slot"]) * 32 + f["offset"] + int(f["numberOfBytes"]) for f in old)
    # Conservative policy: append at the next slot; no gap consumption or
    # packing into the last occupied slot without a separate reviewed migration.
    end = ((end + 31) // 32) * 32
    for f in new[len(old):]:
        if int(f["slot"]) * 32 + f["offset"] < end:
            raise ValueError("new storage overlaps the frozen baseline")
    structs = {s["label"]: s for s in candidate["structs"]}
    for s in baseline["structs"]:
        if structs.get(s["label"]) != s:
            raise ValueError(f"existing struct layout changed: {s['label']}")


def check_selectors(proxy, implementation):
    reserved = {v.removeprefix("0x").lower(): k for k, v in proxy.items()}
    for signature, selector in implementation.items():
        if selector.removeprefix("0x").lower() in reserved:
            raise ValueError(f"proxy selector collision: {signature}")


def main():
    baseline = json.loads((ROOT / "storage-layout/Bridge.v1.json").read_text())
    proxy = json.loads((ROOT / "out/BridgeProxy.sol/BridgeProxy.json").read_text())
    checked = set()
    for path in sorted((ROOT / "out").glob("*/*.json")):
        artifact = json.loads(path.read_text())
        methods = artifact.get("methodIdentifiers", {})
        if MARKER not in methods or not artifact.get("deployedBytecode", {}).get("object", "").removeprefix("0x"):
            continue
        metadata = artifact["metadata"]
        if isinstance(metadata, str):
            metadata = json.loads(metadata)
        targets = metadata["settings"]["compilationTarget"]
        source, name = next(iter(targets.items()))
        if not source.startswith("src/") and name != "BridgeV2Mock":
            continue
        if not (ROOT / source).is_file():
            continue  # ignore artifacts left from deleted sources
        try:
            check_layout(baseline, normalize(artifact["storageLayout"]))
            check_selectors(proxy["methodIdentifiers"], methods)
        except (KeyError, TypeError, ValueError) as error:
            raise SystemExit(f"{source}:{name}: {error}") from error
        checked.add(name)
        print(f"Upgrade safety OK: {source}:{name}")
    if not {"Bridge", "BridgeV2Mock"} <= checked:
        raise SystemExit("Missing required artifacts; run forge build first")


if __name__ == "__main__":
    main()
