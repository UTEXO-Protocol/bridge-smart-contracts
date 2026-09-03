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

Constructor takes four addresses — the accepted ERC-20 token (immutable), the `RouteRegistry` (mutable — federation can rotate via `UpdateRouteRegistry`), the initial `CommissionManager` (mutable — federation can rotate it via `UpdateCommissionManager`), and the initial LayerZero adapter (mutable; `address(0)` is allowed) — plus non-zero `minFundsInAmount` and `minFundsOutAmount` values in token smallest units. Federation may retune either minimum through the timelocked owner path. The bridge's own chain identifier is `block.chainid` — chain IDs are `uint256` throughout the stack (real EVM chain IDs for EVM legs; backend-assigned IDs in a reserved namespace above `2^32` for non-EVM endpoints, e.g. RGB = `1_000_001`).

- `fundsIn(amount, destinationChainId, destinationAddress, settlementData)` — open, **`payable`**. Direct entry point for EVM users; the source chain is implicit (`block.chainid`). Requires `amount >= minFundsInAmount`. Quotes commission from `CommissionManager` using route key `(block.chainid, destinationChainId, TOKEN)`; if the route uses NATIVE currency, `msg.value` must be between the fresh quote and 5% above it. Exactly the fresh quote is collected and any surplus is refunded to the caller. Pulls the full `amount` in tokens from the sender, forwards any token/native commission to `CommissionManager`, and dispatches to the route's `SettlementModule.onFundsIn(...)` via `RouteRegistry`. The `settlementData` blob is opaque to the bridge — its layout is dictated by the destination route's settlement module (empty for routes that don't consume extra data on inbound, e.g. RGB). Emits two events:
  - `FundsIn` — RGB-only compatibility event using `netAmount`; `sender` is indexed while `rgbOpId` is carried in event data.
  - `BridgeFundsIn` (from `IBridge`) — full, consumed by the UTEXO backend.
- `fundsIn(amount, sourceChainId, sourceSender, destinationChainId, destinationAddress, settlementData)` — `onlyLZAdapter` overload used by `LZAdapter` after a cross-chain `OFT.send` compose lands. The adapter has already authenticated the originating sender on the source chain via LayerZero's `OFTComposeMsgCodec.composeFrom`, so it forwards the non-spoofable `sourceChainId` and `sourceSender` to the bridge. For NATIVE commission routes, the source-agreed `msg.value` must remain within the immutable ±5% band around the fresh destination quote. Cross-domain refunds are deliberately unsupported, so the complete accepted value is collected as commission.
- `setLZAdapter(adapter)` — `onlyOwner`. Rotates the address authorized to call the adapter overload. Set to `address(0)` to close the adapter path entirely.
- `setRouteRegistry(newRouteRegistry)` — `onlyOwner`. Rotates the `RouteRegistry` Bridge talks to. Used to migrate to a redeployed registry (the registry's `bridge` is immutable, so a new registry deploy is the only way to rotate). Reverts on `address(0)`.
- `setCommissionManager(newCommissionManager)` — `onlyOwner`. Rotates the manager used for fee quotes and custody. Production migration uses the typed `UpdateCommissionManager` operation so the Bridge and `MultisigProxy` pointers change atomically. Reverts on `address(0)`.
- `fundsOut(FundsOutParams)` — `onlyOwner`, called only by the typed `MultisigProxy.fundsOutCall` / `lzFundsOutCall` enclave paths. The params bind recipient, amount, burn id, source/destination chains, source address, finality proof, and settlement data. The Bridge checks replay protection and isolated liquidity/rate limits, dispatches route verification and settlement bookkeeping, charges any token commission, and releases the net amount. NATIVE commission is disallowed because the release has no native-currency payer.

Owner **must** be `MultisigProxy`. `fundsOut` is reachable only through the purpose-built `fundsOutCall` or `lzFundsOutCall` entrypoints, and `rebalanceLiquidity` only through `rebalanceCall`; all require the registered source chain's M-of-N enclave signatures. These Bridge selectors are blocked from every federation generic-call lane.

#### Burn-id replay guard (single-use)

Every `fundsOut` call carries a `burnId` derived from the complete release intent. The `Bridge` keeps a `consumedBurnIds` mapping and **rejects** any call whose `burnId` is already recorded (`BurnIdAlreadyConsumed`). The flag is set before any token transfer (CEI ordering), so a downstream revert rolls the mark back with the rest of the call. This complements `MultisigProxy`'s per-source-chain `teeNonce`: the nonce prevents replaying one signature bundle, while `burnId` prevents independently signed duplication of the same logical release. Route-specific settlement records provide an additional guard where applicable.

#### Outflow controls and reference liquidity

The configurable per-chain and global token buckets store allowance as percentage shares. A release prices those shares against the actual pre-debit `lockedLiquidity[sourceChainId]` and `totalLockedLiquidity`, respectively. Consequently, bucket capacity follows real deposits, releases, and rebalances immediately, but does not change merely because an old rolling-usage slot expires.

The immutable rolling safety limits are a separate defence layer. They retain each outflow for 24–25 hours and calculate their ceiling from `lockedLiquidity + rollingSpent`, preserving a stable pre-window reference while liquidity is released. `effectiveAvailableOutflow(chainId)` returns the minimum allowed by isolated liquidity, both configurable buckets, and both immutable safety limits.

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

- **`RgbSettlementModule`** — canonical RGB mint/burn ledger. On `fundsIn`, stores the Bridge-derived `operationId => netAmount`, tags it with the destination RGB network, and returns the supplied RGB OpId so Bridge emits both `FundsIn` and `BridgeFundsIn`. On `fundsOut`, `settlementData = abi.encode(bytes32[] operationIds, uint256[] amounts)` must reference existing exact-amount records tagged with the debit network. Records are permanent proof-of-mint entries; replay and solvency are enforced independently by `consumedBurnIds` and isolated liquidity.
- **`RgbOutboundSettlementModule`** — canonical-ledger reader for routes whose RGB debit is followed by a destination that must not create a new record. In production it serves the `96 -> 97` mint/burn-to-pool rebalance: it performs the network-scoped debit check, then returns `0` and writes nothing on the pool credit.
- **`RgbPoolSettlementModule`** — asymmetric pool adapter pinned to immutable pool and backing-network ids. A credit into pool network `97` writes no canonical record and returns `0`, so a normal pool deposit emits only `BridgeFundsIn`. A physical release from `97` must cite exact records from the canonical mint/burn ledger tagged with network `96`.
- **`NullSettlementModule`** — stateless no-op. Used by routes whose settlement is handled entirely by an external delivery layer (e.g. LayerZero compose) or by routes whose verifier already binds the release to a specific deposit. Stateless ⇒ no auth.

Production route-module topology:

| Route | Settlement module | Result |
|---|---|---|
| `42161 -> 96` | `RgbSettlementModule` | writes canonical record; emits `FundsIn` + `BridgeFundsIn` |
| `96 -> 42161` | `RgbSettlementModule` | verifies a network-96 canonical record |
| `42161 -> 97` | `RgbPoolSettlementModule` | no record; emits only `BridgeFundsIn` |
| `97 -> 42161` | `RgbPoolSettlementModule` | verifies backing records tagged with network 96 |
| `96 -> 97` rebalance | `RgbOutboundSettlementModule` | verifies network 96; writes no pool record |
| `97 -> 96` rebalance | `RgbSettlementModule` | accounting-only debit; writes the new network-96 record |

### CommissionManager (`src/CommissionManager.sol`)

Standalone fee contract. Holds protocol commissions separately from bridge liquidity so that deployment, auditing, and withdrawal of fees are independent of bridge funds.

- **Route keys** are `keccak256(abi.encode(sourceChainId, destChainId, token))` where both chain IDs are `uint256` — directional, so each leg of a round trip can have its own config. EVM legs use `block.chainid`; non-EVM endpoints get backend-assigned IDs in a reserved namespace (e.g. `RGB = 1_000_001`).
- **Config** selects per route: `side` (`FUNDS_IN` vs `FUNDS_OUT`), `currency` (`TOKEN` vs `NATIVE`), `stablePercent`, `baseFee`, and `multiplier`. Global defaults apply to any route without an override. The fee in token smallest units is `amount * stablePercent / multiplier^2 + baseFee`; either component may be zero, and both zero disable commission for that rule. The effective proportional rate is capped at 90% independently of `multiplier`.
- **Flat-fee bounds:** `baseFee` is validated together with the proportional component against the Bridge floor for the selected side. At `minFundsInAmount` or `minFundsOutAmount`, respectively, the combined fee must remain strictly below the gross amount so the operation has a positive net. `FUNDS_IN` supports `TOKEN` or `NATIVE` commission; `FUNDS_OUT` supports `TOKEN` only.
- **NATIVE quotes** use a Chainlink ETH/USD aggregator (`setEthUsdFeed(feed, heartbeat)`) and the token's `decimals()`. Heartbeat enforces staleness; absent feed ⇒ NATIVE quotes revert.
- **Ingress:** `receiveTokenCommission(token)` and `receive()` are gated by `onlyBridge` — only `Bridge` may credit commissions. Pools are updated from balance deltas, so fee-on-transfer tokens are supported.
- **Owner** (`MultisigProxy` in production) configures rules, updates `bridgeAddress`, wires the ETH/USD feed, and withdraws accumulated pools. Every token/native withdrawal pays the immutable constructor-configured `commissionRecipient`; withdrawal functions do not accept a free recipient. `renounceOwnership` is blocked.

### MultisigProxy (`src/MultisigProxy.sol`)

Owner of `Bridge`, `RouteRegistry`, **and** `CommissionManager`. Two-level ECDSA M-of-N multisig:

- **Enclave signers (TEE)** — authorize only the purpose-built `fundsOutCall`, `lzFundsOutCall`, and `rebalanceCall` operations (M-of-N, bitmap encoding). Signer sets and replay-protection nonces are isolated per source chain; there is no generic enclave call dispatch.
- **Federation signers (governance)** — two-phase timelock for admin operations. Instant `emergencyPause` / `emergencyUnpause` bypass the timelock.

Federation-controlled operations (`OperationType`):

| OpType | Target | Purpose |
| :--- | :--- | :--- |
| `AdminExecute` | Bridge | Generic call, rarely needed |
| `UpdateEnclaveSigners` | self | Rotate TEE signer set / threshold |
| `UpdateFederationSigners` | self | Rotate federation signer set / threshold |
| `UpdateBridge` | self | Migrate to a redeployed Bridge |
| `SetTimelockDuration` | self | Adjust the timelock window |
| `AdminExecuteCommissionManager` | CommissionManager | Permitted generic call into CM (route rules, global defaults, ETH/USD feed, …) |
| `WithdrawTokenCommissionCM` | CommissionManager | Withdraw ERC-20 commission to CM's immutable `commissionRecipient` |
| `WithdrawNativeCommissionCM` | CommissionManager | Withdraw native commission to CM's immutable `commissionRecipient` |
| `UpdateCommissionManager` | Bridge + self | Atomically migrate Bridge and proxy to a redeployed CommissionManager |
| `AdminExecuteAdapter` | LZAdapter | Generic call into the registered LayerZero adapter (`setTrustedEntrypoint`, `refundStuckFunds`, …). Reverts `ZeroTarget` if `MultisigProxy.lzAdapter` is unset. |
| `UpdateLZAdapter` | self | Rotate `MultisigProxy.lzAdapter` — the routing target for `AdminExecuteAdapter`. Setting to `address(0)` closes the adapter-admin path. |
| `SetRoute` | RouteRegistry | Register, update, pause, or re-enable a single `(sourceChainId, destChainId)` route on the registry. The opData encodes `(src, dst, enabled, verifier, module)`. |
| `UpdateRouteRegistry` | Bridge | Rotate `Bridge.routeRegistry` to a redeployed registry. Used when a new registry must be deployed (the registry's `bridge` is immutable). |
| `AdminExecuteRouteRegistry` | RouteRegistry | Permitted generic registry call; ownership transfer is excluded. |
| `TransferManagedOwnership` | managed target | Typed `transferOwnership(newOwner)` for the current Bridge, CommissionManager, LZAdapter, or RouteRegistry. |
| `PauseInflow` / `UnpauseInflow` | Bridge | Timelocked planned inflow-only pause controls. |
| `DisableLZAdapter` | self | Explicitly clear the adapter governance target. |

Note: `MultisigProxy.lzAdapter` and `Bridge.lzAdapter` are **separate** fields with different roles. `Bridge.lzAdapter` gates the adapter `fundsIn` overload (data path); `MultisigProxy.lzAdapter` is the target of `AdminExecuteAdapter` proposals (governance path). Both default to `address(0)` and are wired in by federation after the adapter is deployed.

For a CommissionManager migration, deploy and configure the replacement with
the current Bridge as `bridgeAddress`, start its two-step ownership transfer to
`MultisigProxy`, and prepare both `UpdateCommissionManager` and a subsequent
`AdminExecuteCommissionManager(acceptOwnership())` proposal. After their
timelocks, execute the update first and the ownership acceptance immediately
after it. The update changes the Bridge and proxy pointers atomically.

## How it works

### FundsIn (user deposits)

1. The user (or frontend) ensures `amount >= Bridge.minFundsInAmount()` and quotes commission from `CommissionManager.calculateFundsInCommission(sourceChainId, destinationChainId, token, amount)`. EVM users pass `block.chainid` as `sourceChainId`.
2. The user approves `amount` to `Bridge` and calls `Bridge.fundsIn{ value: nativeCommission }(amount, destinationChainId, destinationAddress, operationId, settlementData)`. No signature required — any user can lock tokens. `settlementData` is empty for the RGB route and any other route whose module ignores inbound data. Cross-chain (LayerZero compose) deposits land through the `fundsIn(amount, sourceChainId, ...)` adapter overload instead, called by the trusted `LZAdapter` with an authenticated `sourceChainId`.
3. Bridge pulls `amount` in tokens, forwards `tokenCommission` and `nativeCommission` (if any) to `CommissionManager`, dispatches to the route's `SettlementModule.onFundsIn` via `RouteRegistry` (which may e.g. record the net deposit), and emits `FundsIn` + `BridgeFundsIn`.

### FundsOut (bridge withdrawals)

`Bridge.fundsOut()` is `onlyOwner`, where the owner is `MultisigProxy`. The backend collects M-of-N ECDSA signatures from the source chain's enclave signer set over the typed release intent and submits it through `fundsOutCall` (or `lzFundsOutCall` for an onward LayerZero send). The signed data includes `burnId`, both chain ids, proof and settlement data, nonce, and deadline. The proxy verifies the signatures and invokes the exact typed Bridge path, which then:

1. Requires `amount >= Bridge.minFundsOutAmount()`; source-side tooling must apply the same floor before producing a burn or release intent.
2. Checks `burnId` has not been consumed yet and marks it consumed (replay guard).
3. Calls `RouteRegistry.beforeFundsOut(...)` — which gates on the route being `enabled`, calls `FinalityVerifier.verify(proof)` (for RGB: `BtcRelay.verifyBlockheaderHash`), then `SettlementModule.beforeFundsOut(settlementData, amount)` (for RGB: consumes the referenced `fundsInIds`).
4. Quotes outbound commission via `CommissionManager.calculateFundsOutCommission(sourceChainId, destChainId, token, amount)`.
5. Forwards any token commission (`percentage + baseFee`) to `CommissionManager` and releases `netAmount` to the recipient.

### Federation governance (two-phase timelock)

Administrative operations (signer rotation, configuration changes, commission withdrawals, route registration) go through:

1. **Propose.** A federation member submits the operation with M-of-N federation signatures. `MultisigProxy` stores the operation hash together with the current `federationSignerSetVersion` and emits `ProposalCreated`. Nothing is executed yet.
2. **Execute.** After `timelockDuration` elapses, anyone calls `executeProposal()` with the original data. `MultisigProxy` verifies the hash, timelock, and signer-set version before executing. A successful federation rotation increments the version, automatically invalidating every still-pending proposal approved by the previous signer set; the live federation may still cancel those stale records for cleanup.

Raw generic calls cannot invoke `transferOwnership(address)`. Ownership migration uses the typed `TransferManagedOwnership` operation, which binds the exact allowlisted target and new owner into the federation's EIP-712 signatures and revalidates the target at execution. `acceptOwnership()` remains available through the relevant generic lane for two-step deployment and migration handoffs.

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
- `RGB_SETTLEMENT_MODULE_ADDRESS`, `RGB_MINT_BURN_CHAIN_ID`, `RGB_POOL_CHAIN_ID` — standalone `DeployRgbPoolSettlementModule` inputs (`96` and `97` in production)
- `COMMISSION_MANAGER` — `CommissionManager` address (step-by-step deploys only)
- `COMMISSION_RECIPIENT` — immutable destination for every CM withdrawal; choose a long-lived treasury address
- `MIN_FUNDS_IN_AMOUNT` / `MIN_FUNDS_OUT_AMOUNT` — required non-zero operation floors in token smallest units; configure the outbound value consistently in source-side tooling and TEE policy
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

1. `CommissionManager` (pinned to the predicted Bridge and immutable commission recipient)
2. `RouteRegistry` (pinned to the predicted Bridge, deployer-owned for this batch)
3. `Bridge` (with the live `RouteRegistry` + `CommissionManager` and the configured inbound/outbound amount floors)
4. `RGBVerifier` (wraps the BtcRelay)
5. `RgbSettlementModule`, `NullVerifier`, `RgbOutboundSettlementModule`, `RgbPoolSettlementModule`, and `NullSettlementModule`
6. `MultisigProxy`
7. Optional `CommissionManager` oracle configuration
8. `CommissionManager` / `Bridge` / `RouteRegistry` `transferOwnership` → `MultisigProxy`

**Routes are not registered here.** Federation must run `MultisigProposeSetRoute` for each supported `(sourceChainId, destChainId)` pair before any traffic is accepted — mirrors the permanent governance path.

### Option B — Step-by-step

```sh
forge script script/deploy/DeployCommissionManager.s.sol     --rpc-url $RPC_URL --broadcast --verify
forge script script/deploy/DeployRouteRegistry.s.sol         --rpc-url $RPC_URL --broadcast --verify
forge script script/deploy/DeployBridge.s.sol                --rpc-url $RPC_URL --broadcast --verify
forge script script/deploy/DeployRGBVerifier.s.sol           --rpc-url $RPC_URL --broadcast --verify
forge script script/deploy/DeployRgbSettlementModule.s.sol   --rpc-url $RPC_URL --broadcast --verify
forge script script/deploy/DeployRgbPoolSettlementModule.s.sol --rpc-url $RPC_URL --broadcast --verify
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
| `MultisigExecuteFundsOut.s.sol` | Signs a typed release locally with `ENCLAVE_PKS` and submits it through `MultisigProxy.fundsOutCall()`, using the source chain's `teeNonce`. |
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
4. Verify immutable commission destination: `CommissionManager.commissionRecipient()` returns the intended treasury.
5. Verify Bridge ↔ Registry linkage: `Bridge.routeRegistry()` returns the live `RouteRegistry`; `RouteRegistry.bridge()` returns the live `Bridge`.
6. Verify Bridge ↔ CM linkage: `CommissionManager.bridgeAddress()` returns the live `Bridge`; `Bridge.commissionManager()` returns the live `CommissionManager`.
7. Verify amount floors: `Bridge.minFundsInAmount()` and `Bridge.minFundsOutAmount()` return the intended non-zero values, and source-side tooling rejects burns below the outbound floor.
8. Verify LZ adapter wiring: `Bridge.lzAdapter()` and `MultisigProxy.lzAdapter()` both return `address(0)` immediately after deploy. Once the adapter is live, federation must run two timelocked proposals:
   - `proposeAdminExecute` on the proxy with calldata `Bridge.setLZAdapter(adapter)` — opens the adapter `fundsIn` data path.
   - `proposeUpdateLZAdapter(adapter)` — opens the `AdminExecuteAdapter` governance path on the proxy.
9. Verify enclave signers: `MultisigProxy.getEnclaveSigners()` returns the TEE addresses.
10. Verify federation signers: `MultisigProxy.getFederationSigners()` returns the governance addresses.
11. Verify the typed TEE path: `MultisigProxy.getEnclaveSigners(sourceChainId)`, `enclaveThreshold(sourceChainId)`, and `teeNonce(sourceChainId)` match the intended source-chain signer configuration.
12. **Register routes.** For each supported `(sourceChainId, destChainId)` pair, federation runs `MultisigProposeSetRoute` and — after the timelock — `executeProposal` with the printed `opData`. Verify with `RouteRegistry.routes(src, dst)` that the entry is `enabled` and the plugin addresses match.
13. Configure and verify each route's proportional and flat commission; ensure the combined fee at the applicable Bridge floor leaves a positive net amount.
14. Test `fundsIn` with an amount at or above `minFundsInAmount` on a registered route to confirm token transfer, commission forwarding, and event emission.

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
    RgbSettlementModule.sol    — canonical RGB mint/burn proof ledger
    RgbOutboundSettlementModule.sol — ledger reader with stateless credit
    RgbPoolSettlementModule.sol — pool credit no-op + mint/burn-ledger debit check
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
                                 DeployRgbSettlementModule, DeployRgbPoolSettlementModule,
                                 DeployCommissionManager,
                                 DeployMultisigProxy
  interact/                    — BridgeFundsIn, MultisigExecuteFundsOut,
                                 MultisigProposeSetRoute, EmergencyPause, EmergencyUnpause

test/
  Bridge.t.sol                 — Bridge tests (routing through RouteRegistry, burnId, commission)
  BaseBridge.t.sol             — BaseBridge tests
  RouteRegistry.t.sol          — RouteRegistry tests (setRoute, dispatch, enabled gating)
  RgbSettlementModule.t.sol    — canonical RGB ledger tests
  RgbPoolSettlementModule.t.sol — asymmetric RGB pool settlement tests
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
