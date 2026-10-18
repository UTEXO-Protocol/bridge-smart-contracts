# Bridge storage layout

The frozen baseline used by CI is [`script/storage-layout/Bridge.v1.json`](../script/storage-layout/Bridge.v1.json).
The copy under `storage-layout/Bridge.v1.json` is not the checker input.

See [the upgrade baseline guide](../storage-layout/README.md) for commands and
compatibility rules. The checker enforces unchanged existing fields and struct
members, append-only new fields, and no collisions with proxy selectors.

OpenZeppelin namespaced storage requires separate review. BridgeProxy reads the
owner at byte offset zero in `openzeppelin.storage.Ownable`, slot
`0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300`.
Candidate implementations and dependency changes must preserve this layout.
