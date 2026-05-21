# Utexo Bridge — Smart Contracts

Smart contracts for the Utexo cross-chain bridge. Each supported network has its own directory with chain-specific contract implementations, tests, and deployment scripts.

## Repository structure

```
ethereum/   — EVM contracts (Solidity, Foundry)
```

See the README in each directory for setup and deployment instructions.

## Architecture overview

The bridge transfers assets between the EVM side and Bitcoin-anchored networks (RGB, and other Bitcoin L2s in the future). A transfer consists of two on-chain operations: `FundsIn` on the source network (user deposit) and `FundsOut` on the destination network (bridge releases funds to the recipient).

### Deployment topology

The EVM-side contracts in this repository are deployed on Arbitrum. Cross-chain delivery from other EVM networks is implemented by an external delivery layer that lives outside this repository — from the perspective of the contracts here, every deposit lands on Arbitrum and is treated identically regardless of where the user originated from.

```
        ┌──────────────────────────────── Arbitrum ─────────────────────────────────┐
        │                                                                           │
        │                       ┌─────────── RouteRegistry ────────────┐            │
        │                       │  per-route (srcChainId, dstChainId): │            │
        │                       │      FinalityVerifier + SettlementModule          │
        │                       └──────────────────┬───────────────────┘            │
        │                                          │                                │
        │                                       Bridge                              │
        │                                          │                                │
        │                              CommissionManager                            │
        │                                          ▲                                │
        │                                          │                                │
        │                                   MultisigProxy                           │
        │                              (TEE + Federation)                           │
        └───────────────────────────────────────────────────────────────────────────┘
```

**Arbitrum — main contracts:**

- **`Bridge`** — the value-holding contract. Locks the bridged ERC-20 on `fundsIn`, releases it on `fundsOut`. Route-agnostic by design: it delegates all finality-verification and per-route bookkeeping to the registered plugin contracts (see `RouteRegistry` below), so adding a new destination chain (RGB, Arch, another EVM rollup, …) is a deploy-the-plugins + register-the-route operation rather than a Bridge upgrade. Emits the events that the backend watches to drive cross-chain actions. Owned by `MultisigProxy`.

- **`RouteRegistry`** — the routing brain. For every supported `(sourceChainId, destChainId)` pair it stores two addresses: a `FinalityVerifier` and a `SettlementModule`. The `Bridge` calls into the registry on every transfer; the registry forwards to the right plugins. Routes are registered, paused, and rotated through federation governance (granular `SetRoute` proposals on `MultisigProxy`). Owned by `MultisigProxy`; `bridge` is immutable, so rotating the registry itself means redeploy + `UpdateRouteRegistry`.

- **`FinalityVerifier`** — a per-route plugin consulted by `Bridge.fundsOut` to confirm that the source-side event justifying the release is final on its origin chain. The current production verifier is `RGBVerifier`, a wrapper around Atomiq's on-chain Bitcoin SPV light client (`BtcRelay`) — it stores Bitcoin block headers and validates proof-of-work continuity and the difficulty-retarget rules. This removes the need to trust any single oracle or off-chain attestation for Bitcoin finality: the EVM-side release is gated by Bitcoin's own consensus, observed on-chain. Routes that don't need finality verification (e.g. trusted-bridge EVM legs) use `NullVerifier`.

- **`SettlementModule`** — a per-route plugin that owns route-specific state. For RGB-anchored transfers, `RgbSettlementModule` tracks per-`operationId` net deposit balances and consumes them on `fundsOut` (the double-spend / fake-event guard formerly built into `Bridge`). Routes whose settlement is handled entirely by an external delivery layer (e.g. LayerZero compose paths) use `NullSettlementModule`.

- **`CommissionManager`** — a dedicated fee-accounting contract that holds the protocol's commissions strictly separated from bridge liquidity. The `Bridge` consults it on every transfer to determine the per-route commission (token vs. native; charged on `FundsIn` vs. `FundsOut`) and forwards the fee to it. Withdrawal is gated by federation governance through `MultisigProxy`. Owned by `MultisigProxy`.

- **`MultisigProxy`** — the authorization layer. Owns `Bridge`, `RouteRegistry`, and `CommissionManager`. Two independent signer sets and two execution paths: TEE-authorized routine operations (`FundsOut`) execute immediately on M-of-N enclave signatures; federation-authorized administrative operations (signer rotation, configuration changes, commission withdrawal, route registration, contract address updates) go through a two-phase propose → timelock → execute flow. Emergency pause/unpause is the only federation operation that is instant.

### Signing model

The bridge uses a federated M-of-N signing model. Multiple independent signer nodes run inside Enclaves (TEE). Each node validates transfer data independently and produces a signature only after its own checks pass. A `FundsOut` transaction executes only after the required threshold of valid signatures is collected.

There are two independent signer sets:

**Enclave signers (TEE)** — authorize routine value-transfer operations. For `FundsOut`, M-of-N signatures are required. In turn, `FundsIn` does not perform any TEE signature verification, so anyone can call it.

**Federation signers (governance)** — authorize administrative operations: signer rotation, configuration changes, commission withdrawal, and updates to the addresses of `Bridge` / `CommissionManager`. All federation operations go through a two-phase timelock (propose → wait → execute), except emergency pause/unpause which are instant.

Private keys are held inside Enclaves and cannot be extracted. Key persistence is handled through attested enclave-to-enclave cloning.

### Signing scope by direction

| Direction | FundsIn (source side) | FundsOut (destination side) |
| :---- | :---- | :---- |
| EVM → RGB | Anyone can call FundsIn and lock funds in the EVM contract | M-of-N PSBT signing inside TEE enclaves |
| RGB → EVM |  | M-of-N ECDSA verified on the EVM contract via `MultisigProxy` |

### Commission

Each transfer deducts a service commission, configured per-route: source side (`FundsIn`) or destination side (`FundsOut`), in the bridged token or the native currency of the chain. On EVM the commission is held by the `CommissionManager` contract — kept separate from bridge liquidity — and withdrawal is controlled by federation governance through the timelock.

### Replay protection

Each network enforces replay protection at the smart-contract level. On EVM the `Bridge` records consumed `burnId`s on-chain (each `FundsOut` carries the `burnId` extracted from the source-side burn consignment and is rejected if already seen) and `MultisigProxy` enforces per-selector sequential nonces on `execute` plus a sequential `batchNonce` on `executeBatch`. Route-specific bookkeeping — e.g. matching `FundsOut` against the exact source-side deposits being settled — lives in the per-route `SettlementModule` (for the RGB route, `RgbSettlementModule` tracks net deposit balances and consumes them atomically with the release).
