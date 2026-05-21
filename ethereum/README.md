# UTEXO Bridge — EVM Contracts

Solidity smart contracts for the Ethereum/Arbitrum side of the UTEXO bridge. Built with **Foundry**, Solidity 0.8.20.

## Contracts

### BridgeBase (`src/BridgeBase.sol`)

Abstract base contract shared by `BaseBridge` and `Bridge`. Provides:

- Single accepted ERC-20 token (immutable, set at deployment).
- `FundsIn` event (minimal: `sender, operationId, amount`).
- Owner-only `pause` / `unpause`.
- Permanently blocked `renounceOwnership` (reverts with `RenounceOwnershipBlocked`).
- View helpers: `getContractBalance()`, `getChainId()`.

### BaseBridge (`src/BaseBridge.sol`)

Minimal bridge for integrators. Inherits `BridgeBase`.

- `fundsIn(amount, operationId)` — open, no signature required. Locks tokens and emits `FundsIn`.
- `fundsOut(recipient, amount, operationId, sourceAddress)` — `onlyOwner`. Releases tokens and emits `FundsOut`.

No TEE verification, no destination chain field, **no commission integration**, **no route plugins**. Suitable for integrations where the owner is a standard multisig or EOA.

### Bridge (`src/Bridge.sol`)

Production bridge for UTEXO. Inherits `BridgeBase`, implements `IBridge`. Route-agnostic: all per-route logic (finality verification, settlement bookkeeping) is delegated to plugins registered in `RouteRegistry`.

Constructor takes four addresses: the accepted ERC-20 token (immutable), the `RouteRegistry` (mutable — federation can rotate via `UpdateRouteRegistry`), the `CommissionManager` (immutable), and the initial LayerZero adapter (mutable; `address(0)` is allowed — wire it in later via federation governance). The bridge's own chain identifier is `block.chainid` — chain IDs are `uint256` throughout the stack (real EVM chain IDs for EVM legs; backend-assigned IDs in a reserved namespace above `2^32` for non-EVM endpoints, e.g. RGB = `1_000_001`).

- `fundsIn(amount, destinationChainId, destinationAddress, operationId, settlementData)` — open, **`payable`**. Direct entry point for EVM users; the source chain is implicit (`block.chainid`). Quotes commission from `CommissionManager` using route key `(block.chainid, destinationChainId, TOKEN)`; if the route uses NATIVE currency, `msg.value` must equal the quoted native commission. Pulls the full `amount` in tokens from the sender, forwards any token/native commission to `CommissionManager`, and dispatches to the route's `SettlementModule.onFundsIn(...)` via `RouteRegistry`. The `settlementData` blob is opaque to the bridge — its layout is dictated by the destination route's settlement module (empty for routes that don't consume extra data on inbound, e.g. RGB). Emits two events:
  - `FundsIn` (from `BridgeBase`) — minimal, uses `netAmount`.
  - `BridgeFundsIn` (from `IBridge`) — full, consumed by the UTEXO backend.
- `fundsIn(amount, sourceChainId, destinationChainId, destinationAddress, operationId, settlementData)` — `onlyLZAdapter` overload used by `LZAdapter` after a cross-chain `OFT.send` compose lands. The adapter has already authenticated the originating `msg.sender` on the source chain via LayerZero's `OFTComposeMsgCodec.composeFrom`, so it forwards the non-spoofable `sourceChainId` to the bridge. Otherwise identical semantics to `fundsIn`.
- `setLZAdapter(adapter)` — `onlyOwner`. Rotates the address authorized to call the adapter overload. Set to `address(0)` to close the adapter path entirely.
- `setRouteRegistry(newRouteRegistry)` — `onlyOwner`. Rotates the `RouteRegistry` Bridge talks to. Used to migrate to a redeployed registry (the registry's `bridge` is immutable, so a new registry deploy is the only way to rotate). Reverts on `address(0)`.
- `fundsOut(recipient, amount, burnId, sourceChainId, destChainId, sourceAddress, proof, settlementData)` — `onlyOwner`, called via `MultisigProxy.execute()` or `MultisigProxy.executeBatch()`. The four scalar amounts (`amount`, `burnId`, `sourceChainId`, `destChainId`) are `uint256`; `recipient` is an address; `sourceAddress` is a string; `proof` and `settlementData` are opaque `bytes` blobs whose layouts are dictated by the route's `FinalityVerifier` and `SettlementModule` respectively. Checks `burnId` has not been consumed yet (single-use replay guard, marks it consumed before any external interaction), calls `RouteRegistry.beforeFundsOut(...)` which routes into `FinalityVerifier.verify(proof)` and `SettlementModule.beforeFundsOut(settlementData, amount)`, quotes commission from `CommissionManager` using `(sourceChainId, destChainId, TOKEN)`, forwards any token commission to the pool, and releases `netAmount` to the recipient. Emits `BridgeFundsOut`. NATIVE commission on `fundsOut` is disallowed (the caller is the multisig, not a user) — the contract reverts `NativeCommissionNotAllowedOnFundsOut`.

Owner **must** be `MultisigProxy`. `fundsOut` is only reachable through `MultisigProxy.execute()` (single-call) or `MultisigProxy.executeBatch()` (atomic multi-call, e.g. `Bridge.fundsOut` + `LZAdapter.sendOut` for outbound to non-Arbitrum), both of which require M-of-N TEE signatures.

#### Burn-id replay guard (single-use)

Every `fundsOut` call carries a `burnId` — an identifier the backend extracts from the source-side burn consignment. The `Bridge` keeps a `consumedBurnIds` mapping and **rejects** any call whose `burnId` is already recorded (`BurnIdAlreadyConsumed`). The flag is set before any token transfer (CEI ordering), so a revert anywhere downstream rolls the mark back together with the rest of the call. This complements `MultisigProxy`'s per-selector nonce: nonces stop a signature bundle from being executed twice, while `burnId` stops the same logical burn from being settled twice even under independent signature bundles. It also complements each route's `SettlementModule` bookkeeping (e.g. `RgbSettlementModule` consumes `fundsInIds`); `burnId` is the chain-agnostic guard, the module guard is route-specific.

### RouteRegistry (`src/RouteRegistry.sol`)

The routing brain. For every supported `(sourceChainId, destChainId)` pair it stores `(FinalityVerifier, SettlementModule, enabled)`. The `Bridge` calls `onFundsIn` and `beforeFundsOut` on the registry; the registry forwards to the right plugins after gating on `enabled`. The registry's `bridge` is **immutable** (set in the constructor) — rotating it means deploying a new registry and pointing the Bridge at it via `UpdateRouteRegistry`.

- `setRoute(sourceChainId, destChainId, enabled, finalityVerifier, settlementModule)` — `onlyOwner`. Sets or updates a route. Pause-in-place: pass `enabled=false` to keep the plugin addresses on file but reject new traffic; re-enable later by passing `true` again with the same (or new) plugin addresses. Reverts on either plugin being `address(0)`.
- `onFundsIn(ctx)` / `beforeFundsOut(ctx)` — `onlyBridge`. Dispatchers. Read the route for `(ctx.sourceChainId, ctx.destChainId)`, revert `RouteDisabled` if not enabled, then call into the route's plugins. Unknown route → `RouteNotFound`.

Owned by `MultisigProxy`. Federation manages the route table through granular `SetRoute` proposals (see governance table below).

### FinalityVerifier plugins (`src/verifiers/`)

Per-route plugin called by `RouteRegistry.beforeFundsOut`. Interface: `function verify(bytes proof) external view`.

- **`RGBVerifier`** — production verifier for the RGB route. Wraps Atomiq's on-chain Bitcoin SPV light client (`BtcRelay`): expects `proof = abi.encode(uint256 blockHeight, bytes32 commitmentHash)`, calls `IBtcRelayView(btcRelay).verifyBlockheaderHash(...)`, and reverts if the block is unknown to the relay. The TEE backend supplies `blockHeight` and `commitmentHash` as part of the signed call data.
- **`NullVerifier`** — stateless no-op. Used by routes where finality is enforced upstream (e.g. trusted-bridge EVM legs delivered through LayerZero). Stateless ⇒ no auth; `verify` is a no-op.

Adding a new finality source (e.g. an Arch light client) is just a new verifier contract + a `SetRoute` proposal.

### SettlementModule plugins (`src/settlement/`)

Per-route plugin that owns route-specific bookkeeping. Interface: `onFundsIn(ctx)` + `beforeFundsOut(ctx)`, both invoked by `RouteRegistry` on behalf of the Bridge.

- **`RgbSettlementModule`** — production module for the RGB route. On `fundsIn`, stores `operationId => netAmount` so backend operators have an authoritative on-chain ledger of deposits. On `fundsOut`, expects `settlementData = abi.encode(uint256[] fundsInIds)`, walks the array, and partially consumes the referenced deposits in order: full records are deleted; the last record is decremented if its remaining balance exceeds the requested `amount` so the surplus stays available for future calls. This prevents (a) **fake event attacks** — a malicious node operator cannot feed fake `BridgeFundsIn` events to TEE because the contract is the source of truth; (b) **double-spend** — every wei of net liquidity is referenced by exactly one record at all times; (c) **liquidity loss** — partial consumption preserves the residual on the same `operationId`. Auth: `onlyRouteRegistry`.
- **`NullSettlementModule`** — stateless no-op. Used by routes whose settlement is handled entirely by an external delivery layer (e.g. LayerZero compose) or by routes whose verifier already binds the release to a specific deposit. Stateless ⇒ no auth.

### CommissionManager (`src/CommissionManager.sol`)

Standalone fee contract. Holds protocol commissions separately from bridge liquidity so that deployment, auditing, and withdrawal of fees are independent of bridge funds.

- **Route keys** are `keccak256(abi.encode(sourceChainId, destChainId, token))` where both chain IDs are `uint256` — directional, so each leg of a round trip can have its own config. EVM legs use `block.chainid`; non-EVM endpoints get backend-assigned IDs in a reserved namespace (e.g. `RGB = 1_000_001`).
- **Config** selects per route: `side` (`FUNDS_IN` vs `FUNDS_OUT`), `currency` (`TOKEN` vs `NATIVE`), `stablePercent` (×100, capped at 9000 = 90%), and `multiplier`. Global defaults apply to any route without an override.
- **NATIVE quotes** use a Chainlink ETH/USD aggregator (`setEthUsdFeed(feed, heartbeat)`) and the token's `decimals()`. Heartbeat enforces staleness; absent feed ⇒ NATIVE quotes revert.
- **Ingress:** `receiveTokenCommission(token)` and `receive()` are gated by `onlyBridge` — only `Bridge` may credit commissions. Pools are updated from balance deltas, so fee-on-transfer tokens are supported.
- **Owner** (`MultisigProxy` in production) configures rules, updates `bridgeAddress`, wires the ETH/USD feed, and withdraws accumulated pools. `renounceOwnership` is blocked.

### MultisigProxy (`src/MultisigProxy.sol`)

Owner of `Bridge`, `RouteRegistry`, **and** `CommissionManager`. Two-level ECDSA M-of-N multisig:

- **Enclave signers (TEE)** — authorize `execute()` (single-call) and `executeBatch()` (atomic multi-call) calls (M-of-N, bitmap encoding). Used for `fundsOut` (and outbound `LZAdapter.sendOut` paired in a batch). Per-selector sequential nonces prevent replay on `execute`; a sequential `batchNonce` does the same for `executeBatch`. The TEE allowlist is keyed on `(target, selector)` pairs (`teeAllowedCalls`), enabling atomic multi-target batches without granting TEE blanket admin power. Default allowlist seeded in the constructor: `Bridge.fundsOut(address,uint256,uint256,uint256,uint256,string,bytes,bytes)`.
- **Federation signers (governance)** — two-phase timelock for admin operations. Instant `emergencyPause` / `emergencyUnpause` bypass the timelock.

Federation-controlled operations (`OperationType`):

| OpType | Target | Purpose |
| :--- | :--- | :--- |
| `AdminExecute` | Bridge | Generic call, rarely needed |
| `UpdateEnclaveSigners` | self | Rotate TEE signer set / threshold |
| `UpdateFederationSigners` | self | Rotate federation signer set / threshold |
| `UpdateBridge` | self | Migrate to a redeployed Bridge |
| `SetCommissionRecipient` | self | Change destination address for CM withdrawals |
| `SetTeeAllowedCall` | self | Add/remove a `(target, selector)` pair from the TEE allowlist |
| `SetTimelockDuration` | self | Adjust the timelock window |
| `AdminExecuteCommissionManager` | CommissionManager | Generic call into CM (route rules, global defaults, ETH/USD feed, `transferOwnership`, …) |
| `WithdrawTokenCommissionCM` | CommissionManager | Withdraw ERC-20 commission to `commissionRecipient` |
| `WithdrawNativeCommissionCM` | CommissionManager | Withdraw native commission to `commissionRecipient` |
| `UpdateCommissionManager` | self | Migrate to a redeployed CommissionManager |
| `AdminExecuteAdapter` | LZAdapter | Generic call into the registered LayerZero adapter (`setTrustedEntrypoint`, `refundStuckFunds`, …). Reverts `ZeroTarget` if `MultisigProxy.lzAdapter` is unset. |
| `UpdateLZAdapter` | self | Rotate `MultisigProxy.lzAdapter` — the routing target for `AdminExecuteAdapter`. Setting to `address(0)` closes the adapter-admin path. |
| `SetRoute` | RouteRegistry | Register, update, pause, or re-enable a single `(sourceChainId, destChainId)` route on the registry. The opData encodes `(src, dst, enabled, verifier, module)`. |
| `UpdateRouteRegistry` | Bridge | Rotate `Bridge.routeRegistry` to a redeployed registry. Used when a new registry must be deployed (the registry's `bridge` is immutable). |

Note: `MultisigProxy.lzAdapter` and `Bridge.lzAdapter` are **separate** fields with different roles. `Bridge.lzAdapter` gates the adapter `fundsIn` overload (data path); `MultisigProxy.lzAdapter` is the target of `AdminExecuteAdapter` proposals (governance path). Both default to `address(0)` and are wired in by federation after the adapter is deployed.

## How it works

### FundsIn (user deposits)

1. The user (or frontend) quotes commission from `CommissionManager.calculateFundsInCommission(sourceChainId, destinationChainId, token, amount)`. EVM users pass `block.chainid` as `sourceChainId`.
2. The user approves `amount` to `Bridge` and calls `Bridge.fundsIn{ value: nativeCommission }(amount, destinationChainId, destinationAddress, operationId, settlementData)`. No signature required — any user can lock tokens. `settlementData` is empty for the RGB route and any other route whose module ignores inbound data. Cross-chain (LayerZero compose) deposits land through the `fundsIn(amount, sourceChainId, ...)` adapter overload instead, called by the trusted `LZAdapter` with an authenticated `sourceChainId`.
3. Bridge pulls `amount` in tokens, forwards `tokenCommission` and `nativeCommission` (if any) to `CommissionManager`, dispatches to the route's `SettlementModule.onFundsIn` via `RouteRegistry` (which may e.g. record the net deposit), and emits `FundsIn` + `BridgeFundsIn`.

### FundsOut (bridge withdrawals)

`Bridge.fundsOut()` is `onlyOwner`, where the owner is `MultisigProxy`. The backend collects M-of-N ECDSA signatures from TEE signers over an EIP-712 `BridgeOperation` message (selector, callData, nonce, deadline). The call data includes `burnId` (chain-agnostic replay guard) plus the two opaque blobs `proof` (consumed by the route's `FinalityVerifier`) and `settlementData` (consumed by the route's `SettlementModule`), plus `sourceChainId` and `destChainId` so both `RouteRegistry` and `CommissionManager` can pick the right route. `MultisigProxy.execute()` verifies the signatures on-chain and forwards the call to `Bridge`, which then:

1. Checks `burnId` has not been consumed yet and marks it consumed (replay guard).
2. Calls `RouteRegistry.beforeFundsOut(...)` — which gates on the route being `enabled`, calls `FinalityVerifier.verify(proof)` (for RGB: `BtcRelay.verifyBlockheaderHash`), then `SettlementModule.beforeFundsOut(settlementData, amount)` (for RGB: consumes the referenced `fundsInIds`).
3. Quotes outbound commission via `CommissionManager.calculateFundsOutCommission(sourceChainId, destChainId, token, amount)`.
4. Forwards any token commission to `CommissionManager` and releases `netAmount` to the recipient.

### Federation governance (two-phase timelock)

Administrative operations (signer rotation, configuration changes, commission withdrawals, route registration) go through:

1. **Propose.** A federation member submits the operation with M-of-N federation signatures. `MultisigProxy` stores the operation hash and emits `ProposalCreated`. Nothing is executed yet.
2. **Execute.** After `timelockDuration` elapses, anyone calls `executeProposal()` with the original data. `MultisigProxy` verifies the hash, confirms the timelock, and executes.

**Emergency pause/unpause** bypass the timelock — federation can stop or resume `Bridge` instantly.

### EIP-712 signatures

All signatures use EIP-712 typed structured data with domain `name: "MultisigProxy", version: "1"`, bound to the chain ID and `MultisigProxy` address.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge + cast)
- Git

## Setup

```sh
forge install        # fetch forge-std + openzeppelin-contracts submodules
forge build
```

## Commands

```sh
forge build                              # compile
forge test                               # run all tests
forge test --match-path "test/Bridge.t.sol"  # run one file
forge test -vvv                          # with traces
forge coverage                           # coverage report
forge clean                              # delete out/ + cache/
```

## Environment

Two separate templates — one per phase. Copy each to a real file and fill it in only when you actually need that flow:

```sh
cp .env.deploy.example   .env.deploy      # one-time, for deploy/upgrade
cp .env.interact.example .env.interact    # day-to-day, for fundsIn / fundsOut sims
```

Foundry doesn't auto-load arbitrary names — load the file you need before running:

```sh
set -a && source .env.deploy   && set +a   # before deploy scripts
set -a && source .env.interact && set +a   # before interact scripts
```

**Key deploy variables** (`.env.deploy`):
- `USDT0_ADDRESS` — accepted ERC-20 token
- `BTC_RELAY_ADDRESS` — Atomiq BtcRelay contract address (consumed by `RGBVerifier`)
- `LZ_ADAPTER` — initial LayerZero adapter address (optional; pass `0x0` if the adapter has not been deployed yet, then wire it in via federation governance after the adapter ships)
- `ROUTE_REGISTRY_ADDRESS` — `RouteRegistry` address (step-by-step Bridge redeploys only; `DeployAll` predicts it)
- `COMMISSION_MANAGER` — `CommissionManager` address (step-by-step deploys only)
- `COMMISSION_RECIPIENT` — destination for CM withdrawals
- `ETH_USD_FEED` / `ETH_USD_HEARTBEAT` — Chainlink ETH/USD aggregator + staleness window (required if any route uses NATIVE commission)
- `ENCLAVE_SIGNERS` / `FEDERATION_SIGNERS` — comma-separated addresses, ordered by bitmap bit index
- `ENCLAVE_THRESHOLD` / `FEDERATION_THRESHOLD` — M-of-N thresholds
- `TIMELOCK_DURATION` — federation timelock window in seconds

> Chain identifiers are `uint256` everywhere — `block.chainid` for EVM legs, backend-assigned values for non-EVM endpoints (e.g. RGB = `1_000_001`). There is no `SOURCE_CHAIN_NAME` env var anymore; the bridge reads `block.chainid` at runtime.

**Key interact variables** (`.env.interact`):
- `BRIDGE_ADDRESS`, `PROXY_ADDRESS`, `BASE_BRIDGE_ADDRESS` — deployed contracts
- `OPERATION_ID` — backend-assigned operation id
- `BURN_ID` — single-use burn consignment id (fundsOut)
- `SOURCE_CHAIN_ID` / `DESTINATION_CHAIN_ID` — `uint256` chain ids used when building calldata
- `BLOCK_HEIGHT`, `COMMITMENT_HASH` — RGB-route `proof` inputs (packed as `abi.encode(blockHeight, commitmentHash)` by the script)
- `FUNDS_IN_IDS` — RGB-route `settlementData` inputs (packed as `abi.encode(uint256[])` by the script)
- `FINALITY_VERIFIER` / `SETTLEMENT_MODULE` / `ROUTE_ENABLED` / `DEADLINE_OFFSET` — `MultisigProposeSetRoute` inputs
- `ENCLAVE_PKS` / `FED_PKS` — comma-separated private keys for local TEE/federation simulation
- `ENCLAVE_BITMAP` / `FED_BITMAP` — participating-signer bitmaps

## Deployment

All deploy scripts live in `script/deploy/`. They read their inputs from `.env.deploy`.

### Option A — Full production (CM + RouteRegistry + Bridge + plugins + MultisigProxy + ownership transfer)

```sh
forge script script/deploy/DeployAll.s.sol \
  --rpc-url $RPC_URL --broadcast --verify
```

Predicts the Bridge address from the deployer's future nonce, deploys in order:

1. `CommissionManager` (pinned to the predicted Bridge)
2. `RouteRegistry` (pinned to the predicted Bridge, deployer-owned for this batch)
3. `Bridge` (with the live `RouteRegistry` + `CommissionManager`)
4. `RGBVerifier` (wraps the BtcRelay)
5. `RgbSettlementModule` (paired with `RouteRegistry`)
6. `MultisigProxy`
7. (optional) `CommissionManager.setEthUsdFeed`
8. `CommissionManager` / `Bridge` / `RouteRegistry` `transferOwnership` → `MultisigProxy`

**Routes are not registered here.** Federation must run `MultisigProposeSetRoute` for each supported `(sourceChainId, destChainId)` pair before any traffic is accepted — mirrors the permanent governance path.

### Option B — Step-by-step

```sh
forge script script/deploy/DeployCommissionManager.s.sol     --rpc-url $RPC_URL --broadcast --verify
forge script script/deploy/DeployRouteRegistry.s.sol         --rpc-url $RPC_URL --broadcast --verify
forge script script/deploy/DeployBridge.s.sol                --rpc-url $RPC_URL --broadcast --verify
forge script script/deploy/DeployRGBVerifier.s.sol           --rpc-url $RPC_URL --broadcast --verify
forge script script/deploy/DeployRgbSettlementModule.s.sol   --rpc-url $RPC_URL --broadcast --verify
forge script script/deploy/DeployMultisigProxy.s.sol         --rpc-url $RPC_URL --broadcast --verify

# Transfer ownerships to MultisigProxy
cast send $BRIDGE_ADDRESS         "transferOwnership(address)" $PROXY_ADDRESS --rpc-url $RPC_URL --private-key $PRIVATE_KEY
cast send $COMMISSION_MANAGER     "transferOwnership(address)" $PROXY_ADDRESS --rpc-url $RPC_URL --private-key $PRIVATE_KEY
cast send $ROUTE_REGISTRY_ADDRESS "transferOwnership(address)" $PROXY_ADDRESS --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

Note: `RouteRegistry.bridge` is immutable. The step-by-step path either (a) deploys `RouteRegistry` first against a predicted Bridge address, or (b) is reserved for replacing Bridge against an existing registry — uncommon. Use `DeployAll` for greenfield deployments.

### Option C — BaseBridge (integrators, e.g. Bitfinex)

```sh
forge script script/deploy/DeployBaseBridge.s.sol --rpc-url $RPC_URL --broadcast --verify
```

Deploys `BaseBridge` with `TOKEN_ADDRESS`. The deployer becomes the initial owner; transfer to the integrator's multisig after deployment. `BaseBridge` has no dependency on `MultisigProxy`, `RouteRegistry`, or `CommissionManager` — use any multisig or EOA as owner.

## Interaction scripts

Scripts in `script/interact/` let you exercise contracts manually before the backend is wired up. All read inputs from `.env.interact`.

| Script | What it does |
|---|---|
| `BridgeFundsIn.s.sol` | Quotes commission from `CommissionManager`, approves tokens and calls `Bridge.fundsIn{ value: nativeCommission }(...)` |
| `MultisigExecuteFundsOut.s.sol` | Signs a `Bridge.fundsOut()` locally with `ENCLAVE_PKS` (8-arg signature: `recipient, amount, burnId, sourceChainId, destChainId, sourceAddress, proof, settlementData`) and submits via `MultisigProxy.execute()`. Packs `proof = abi.encode(blockHeight, commitmentHash)` (RGBVerifier layout) and `settlementData = abi.encode(fundsInIds[])` (RgbSettlementModule layout). |
| `MultisigProposeSetRoute.s.sol` | Signs and submits a `proposeSetRoute(...)` federation proposal on `MultisigProxy`. Intentionally does **not** call `executeProposal` — prints the `proposalId` + the `opData` blob for the operator to run `cast send` after the timelock. First federation step after `DeployAll`. |
| `EmergencyPause.s.sol` | Signs and submits `MultisigProxy.emergencyPause()` with `FED_PKS` |
| `EmergencyUnpause.s.sol` | Signs and submits `MultisigProxy.emergencyUnpause()` with `FED_PKS` |

Example:

```sh
forge script script/interact/BridgeFundsIn.s.sol --rpc-url $RPC_URL --broadcast
```

> **Security note:** `MultisigExecuteFundsOut` and `MultisigProposeSetRoute` sign with local private keys from `.env.interact`. Only use for testnet and local end-to-end checks. In production, TEE enclaves and federation members produce signatures; these scripts just simulate that flow.

## Post-deployment checklist

1. Verify Bridge ownership: `Bridge.owner()` returns the `MultisigProxy` address.
2. Verify RouteRegistry ownership: `RouteRegistry.owner()` returns the `MultisigProxy` address.
3. Verify CommissionManager ownership: `CommissionManager.owner()` returns the `MultisigProxy` address.
4. Verify Bridge ↔ Registry linkage: `Bridge.routeRegistry()` returns the live `RouteRegistry`; `RouteRegistry.bridge()` returns the live `Bridge`.
5. Verify Bridge ↔ CM linkage: `CommissionManager.bridgeAddress()` returns the live `Bridge`; `Bridge.commissionManager()` returns the live `CommissionManager`.
6. Verify LZ adapter wiring: `Bridge.lzAdapter()` and `MultisigProxy.lzAdapter()` both return `address(0)` immediately after deploy. Once the adapter is live, federation must run two timelocked proposals:
   - `proposeAdminExecute` on the proxy with calldata `Bridge.setLZAdapter(adapter)` — opens the adapter `fundsIn` data path.
   - `proposeUpdateLZAdapter(adapter)` — opens the `AdminExecuteAdapter` governance path on the proxy.
7. Verify enclave signers: `MultisigProxy.getEnclaveSigners()` returns the TEE addresses.
8. Verify federation signers: `MultisigProxy.getFederationSigners()` returns the governance addresses.
9. Verify TEE-allowed call: `MultisigProxy.teeAllowedCalls(bridgeAddress, fundsOutSelector)` returns `true` for the 8-arg `fundsOut(address,uint256,uint256,uint256,uint256,string,bytes,bytes)` selector.
10. **Register routes.** For each supported `(sourceChainId, destChainId)` pair, federation runs `MultisigProposeSetRoute` and — after the timelock — `executeProposal` with the printed `opData`. Verify with `RouteRegistry.routes(src, dst)` that the entry is `enabled` and the plugin addresses match.
11. Test `fundsIn` with a small amount (zero commission by default) on a registered route to confirm token transfer and event emission.

## Project structure

```
src/
  BridgeBase.sol               — Abstract base: token, pause, shared event/errors
  BaseBridge.sol               — Minimal bridge for integrators
  Bridge.sol                   — Production bridge (MultisigProxy owner, RouteRegistry, CommissionManager)
  RouteRegistry.sol            — Per-route plugin dispatcher (verifier + settlement module)
  CommissionManager.sol        — Standalone commission quotes, custody and withdrawal
  MultisigProxy.sol            — M-of-N multisig owner of Bridge, RouteRegistry and CommissionManager
  verifiers/
    RGBVerifier.sol            — Bitcoin SPV finality (wraps Atomiq BtcRelay)
    NullVerifier.sol           — Stateless no-op (routes with upstream finality)
  settlement/
    RgbSettlementModule.sol    — RGB-route net-deposit ledger + consumption
    NullSettlementModule.sol   — Stateless no-op (routes settled by external delivery)
  interfaces/
    IBridge.sol                — Bridge interface, events, and custom errors
    IBtcRelayView.sol          — Minimal read-only interface for Atomiq BtcRelay
    ICommissionManager.sol     — CommissionManager interface, types and errors
    IFinalityVerifier.sol      — FinalityVerifier interface
    ISettlementModule.sol      — SettlementModule interface
    IRouteRegistry.sol         — RouteRegistry interface, events and errors
    IMultisigProxy.sol         — MultisigProxy interface and custom errors
    RouteTypes.sol             — Shared FundsInContext / FundsOutContext structs

script/
  deploy/                      — DeployAll, DeployBridge, DeployBaseBridge,
                                 DeployRouteRegistry, DeployRGBVerifier,
                                 DeployRgbSettlementModule, DeployCommissionManager,
                                 DeployMultisigProxy
  interact/                    — BridgeFundsIn, MultisigExecuteFundsOut,
                                 MultisigProposeSetRoute, EmergencyPause, EmergencyUnpause

test/
  Bridge.t.sol                 — Bridge tests (routing through RouteRegistry, burnId, commission)
  BaseBridge.t.sol             — BaseBridge tests
  RouteRegistry.t.sol          — RouteRegistry tests (setRoute, dispatch, enabled gating)
  RgbSettlementModule.t.sol    — RgbSettlementModule tests (ledger, partial consumption)
  CommissionManager.t.sol      — CommissionManager tests (rules, pools, withdrawals, ETH/USD feed)
  MultisigProxy.t.sol          — MultisigProxy tests (EIP-712, bitmap sigs, proposals incl. SetRoute / UpdateRouteRegistry)
  Integration.t.sol            — End-to-end: user → Bridge → RouteRegistry → TEE multisig → fundsOut → CM withdrawal
  mocks/
    MockERC20.sol              — Mintable ERC-20 for tests
    MockBtcRelay.sol           — Mock BtcRelay for tests
    MockAggregatorV3.sol       — Mock Chainlink aggregator for tests
    MockFinalityVerifier.sol   — Mock verifier for RouteRegistry / Bridge tests
    MockSettlementModule.sol   — Mock settlement module for RouteRegistry / Bridge tests
    MultisigHelper.sol         — EIP-712 digest builders and signAll helper

lib/                           — Foundry submodules (forge-std, openzeppelin-contracts)
foundry.toml                   — Foundry configuration
.env.deploy.example            — Deploy environment template
.env.interact.example          — Interaction environment template
```
