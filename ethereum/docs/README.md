# Utexo Bridge — EVM contracts

Solidity 0.8.35 contracts built with Foundry. The production Bridge runs on
Arbitrum One (`42161`); the RGB network identifier is `827166`.
Ethereum mainnet uses chain id `1`. Examples involving chain A or chain B describe
extension points, not additional supported networks.

Run the commands below from `ethereum/`.

## Setup

Install Foundry and initialize the repository's pinned dependencies:

```sh
git submodule update --init --recursive
forge build
forge test
```

See [TESTING.md](TESTING.md) for suite selection and coverage,
[SLITHER.md](SLITHER.md) for static analysis, and
[storage-layout/README.md](../storage-layout/README.md) for upgrade checks.

## Contract responsibilities

| Contract | Responsibility |
| --- | --- |
| `BridgeProxy` | Canonical Bridge address and owner-authorized implementation upgrades |
| `Bridge` | USDT0 custody, per-network liquidity, replay checks, fees and outflow limits |
| `BridgeBaseUpgradeable` | Initializable token, ownership and pause state for Bridge |
| `RouteRegistry` | Enabled routes and dispatch to verifier/settlement plugins |
| `RGBVerifier` | Bitcoin block commitment and confirmation checks through BtcRelay |
| `RgbSettlementModule` | Permanent, network-tagged RGB backing records |
| `RgbOutboundSettlementModule` | Checks the same ledger without creating destination RGB records |
| `NullVerifier` / `NullSettlementModule` | Explicit no-op implementations for routes that omit a layer |
| `CommissionManager` | Fee configuration, quotes, pools and withdrawals |
| `MultisigProxy` | Enclave-authorized calls and timelocked federation governance |
| `RgbRejectList` | Standalone append-only list consumed by RGB clients |
| `MinimalBridge` / `BridgeBase` | Separate constructor-based bridge for integrators |

Bridge, CM and RouteRegistry use two-step ownership. In production their owner
is MultisigProxy. Calling `transferOwnership` only sets `pendingOwner`; the proxy
must also call `acceptOwnership` through the appropriate governance operation.
Ownership renunciation is disabled.

### Deposits

The direct public entry point is:

```solidity
fundsIn(amount, destinationChainId, destinationAddress, settlementData)
```

Bridge derives the source network from `block.chainid`, pulls tokens from the
caller and credits destination liquidity with the actual receipt minus token
commission. For RGB,
`settlementData = abi.encode(uint256 rgbOpId, uint64 beforeBlock)` and
`destinationAddress` must be empty: the destination is carried in the RGB
consignment, not supplied again as an EVM argument. `beforeBlock` is an
exclusive Arbitrum L2 deadline: the deposit reverts when
`ArbSys.arbBlockNumber() >= beforeBlock`.

An adapter-only overload additionally takes `sourceChainId` and `sourceSender`.
The configured LayerZero adapter authenticates those values and supplies tokens.
Bridge does not independently authenticate the originating cross-chain message.

For direct native-fee deposits, `msg.value` must be between the fresh quote and
5% above it. Bridge collects the quote and refunds excess after state updates.
Adapter deposits accept ±5% of the quote and collect the supplied value without
cross-chain refunds. A zero native quote requires zero native payment.

`BridgeFundsIn` includes the derived operation id and settlement payload. A
non-zero correlation id from the settlement module also produces `FundsIn`, with
an amount bounded by `uint64`. The RGB id is derived from the Bridge address,
local chain id, token, RGB network, mint OpId and actual net amount. Other routes
use the sender/nonce deposit context.

`RgbSettlementModule` permanently stores the net amount and destination RGB
network for each RGB backing id. Clients can batch state lookups through
`getFundsInRecords(bytes32[] operationIds)`; results preserve input order and
zero means that a record is absent. This avoids historical `eth_getLogs` scans.
The deadline is deliberately excluded from the backing id, so changing it
cannot create another record for the same RGB mint.

### Releases and rebalances

`fundsOut(FundsOutParams)` is owner-only. MultisigProxy exposes the typed
`fundsOutCall` and `lzFundsOutCall` enclave paths. The latter releases to the
LayerZero adapter, then sends onward the measured token receipt. Bridge checks
source liquidity, the burn replay key, outflow limits, route plugins and token
commission conservation before paying the recipient.

`rebalanceLiquidity(RebalanceParams)` is reached through `rebalanceCall`.
It debits one network's liquidity and credits another without moving tokens or
charging commission. Its destination cannot equal `block.chainid`. Both hooks
use the same enabled `(sourceChainId, destinationChainId)` route. Rebalance
consumes the source-chain bucket and rolling limit, but not global limits.
Use `fundsOut` for physical payouts on Arbitrum.

Both operations share `consumedBurnIds` and derive the same source-burn key:

```text
keccak256(abi.encode(
    BURN_TYPEHASH, bridge, block.chainid, token,
    amount, sourceChainId, keccak256(bytes(sourceAddress)), sourceBurnTxId
))
```

The proof, recipient and destination are excluded from this key but remain signed
in the operation payload. Enclaves must derive the burn fields consistently from
the validated consignment. RGBVerifier requires an empty separate `sourceAddress`.
MultisigProxy additionally consumes a sequential `teeNonce(sourceChainId)` shared
by releases and rebalances.

### Routes and RGB checks

`RouteRegistry.setRoute(src, dst, enabled, verifier, module)` requires both plugins
to contain deployed code, even when disabling a route. `getRoute(src, dst)` reads
the configuration. Disabled and unset routes both fail with `RouteNotEnabled`.
Only the bound Bridge can dispatch hooks. On release, finality verification runs
before settlement validation.

| Production route | Settlement module | Purpose |
| --- | --- | --- |
| `42161 -> 827166` | `RgbSettlementModule` | Record RGB backing on deposit |
| `827166 -> 42161` | `RgbSettlementModule` | Verify records for physical release |

`RGBVerifier` decodes a 128-byte proof containing
`(sourceHeight, sourceCommit, latestHeight, latestCommit)`. Both commitments must
be known to BtcRelay. The source depth must meet `minSourceConfirmations`, the
latest depth must not exceed `maxLatestConfirmations`, and source depth must be
at least latest depth plus `minConfirmationGap`. This checks Bitcoin commitments
and depths; enclaves validate their relationship to the RGB operation.

Deployment defaults are `minSourceConfirmations = 3`, `maxLatestConfirmations = 2`
and `minConfirmationGap = 2`. Set `MIN_SOURCE_CONFIRMATIONS`,
`MAX_LATEST_CONFIRMATIONS` and `MIN_CONFIRMATION_GAP` to override them.

RGB settlement records contain an operation id, exact net amount and network tag.
Release payloads encode `abi.encode(bytes32[] operationIds)`. The module checks
each record's existence and source-network tag. It does not consume records;
Bridge handles liquidity/replay checks and enclaves validate consignment semantics.
Physical releases require non-empty arrays. The canonical module allows empty
arrays for rebalance; the outbound wrapper always requires records.

All credit routes to the same RGB network must use the same canonical ledger.
A new ledger starts empty. Before replacing modules or registry, plan how older
records remain accessible. Changing only the verifier does not require replacing
the ledger. The outbound wrapper can read an older ledger through its public
getters while being paired with a newer registry.

### Fees and outflow limits

CM resolves a directional rule keyed by
`keccak256(abi.encode(sourceChainId, destChainId, token))`, or uses global defaults.
The token-denominated fee is `amount * stablePercent / multiplier^2 + baseFee`.
The effective proportional rate is capped at 90%. Both components zero disable
commission; an enabled fee must not round to zero.

Deposits support TOKEN fees deducted from principal or NATIVE fees paid separately.
Releases support TOKEN only. Native conversion assumes the bridge token is
USD-pegged and uses the configured ETH/USD feed, heartbeat, sequencer status,
restart grace period and price bounds.

Both amount floors must be positive, with `minFundsInAmount >= minFundsOutAmount`.
When a rule has a flat fee, CM rechecks the combined fee at the current side's
floor on every quote, for TOKEN and NATIVE alike. Lowering a floor can invalidate
an existing rule even for a larger transfer. Coordinate fee and floor changes.
The floors are gross amounts: fees may leave a minimum deposit below the release
floor. When changing both floors, respect their ordering at each execution step.

Only Bridge credits CM pools. `receiveTokenCommission(token, credited)` records
the balance increase measured by Bridge for that transfer; unrelated donations
are not credited. Every withdrawal pays the immutable `commissionRecipient`.

Configurable per-chain and global token buckets hold shares of current accounted
liquidity. Their burst plus full-window refill must not exceed 2000 basis points.
Separate immutable rolling limits cap usage at 20% of `liquidity + active usage`
for 24–25 hours. New deposits can increase that reference. Rebalances preserve
total liquidity and consume only source-chain limits. Direct token donations do
not increase accounted liquidity. `effectiveAvailableOutflow(chainId)` combines
liquidity, per-chain/global buckets and rolling limits for physical releases.

### Governance and pause

Enclave and federation signer addresses must be disjoint. Each set needs 2–20
unique non-zero addresses and a strict-majority threshold of at least two.
Enclave sets and nonces are selected by source chain. Federation proposals
snapshot the signer-set version; federation rotation makes older pending
proposals unexecutable.

A federation-authorized proposal stores the operation data hash and, where
applicable, the target address. Anyone can execute it after its saved timelock
and before its deadline. A changed target causes `StaleProposalTarget` rather
than forwarding old approval to a replacement component. `executeProposal` is
non-reentrant; failed execution rolls back the proposal status and can be retried
while still valid. Cancellation requires federation signatures but does not
consume the regular proposal nonce.

| Operation | Target / effect |
| --- | --- |
| `AdminExecute` | Allowed generic Bridge calls |
| `AdminExecuteCommissionManager` | Allowed CM configuration calls and ownership acceptance |
| `AdminExecuteRouteRegistry` | Allowed registry calls and ownership acceptance |
| `AdminExecuteAdapter` | Allowed calls to the current adapter |
| `UpdateEnclaveSigners` / `UpdateFederationSigners` | Signer-set changes |
| `WithdrawTokenCommissionCM` / `WithdrawNativeCommissionCM` | Withdraw commissions to the fixed recipient |
| `UpdateCommissionManager` | Update Bridge and proxy CM pointers atomically |
| `SetRoute` / `UpdateRouteRegistry` | Route configuration / Bridge registry pointer |
| `UpdateLZAdapter` / `DisableLZAdapter` | Set / clear the proxy's adapter target |
| `UpdateBridge` | Point governance at another Bridge |
| `TransferManagedOwnership` | Start ownership transfer for a current managed target |
| `UpgradeBridgeImplementation` | Upgrade the current BridgeProxy implementation |
| `PauseInflow` / `UnpauseInflow` | Timelocked deposit pause controls |
| `SetTimelockDuration` / `SetEmergencyGuardian` | Governance delay / guardian settings |

Generic calls reject selectors reserved for enclave operations, proxy control,
CM rotation, ownership transfer and typed commission withdrawals. Use the typed
operations for those actions. `acceptOwnership()` remains available through the
relevant generic lane.

Planned `pauseInflow` blocks deposits only. Emergency pause blocks deposits,
releases and rebalances. Federation can emergency pause/unpause without a
timelock; the guardian can only pause. Emergency unpause clears both pause flags,
including a planned inflow pause. Successful guardian pauses advance
`emergencyNonce`, even when the Bridge is already paused. They do not consume
proposal or TEE nonces.

EIP-712 signatures use `name = MultisigProxy`, `version = 1`, current EVM chain id
and the proxy address. Bitmap bit i selects signer i; signatures are ordered by
ascending set bit. TEE and emergency deadlines can be at most one day ahead;
proposal and cancellation deadlines can be at most 30 days ahead. These limits
bound submission-time deadlines, not signature age.

## Deployment

For a new Bitcoin relay, run DeployBtcRelay with a reviewed, deep checkpoint
(e.g. roughly 144 blocks of reorg margin, not a finality guarantee). The header
blob includes difficulty-adjustment data and ten prior timestamps; these require
independent validation beyond the script's height/hash/chainwork checks. A reorg
below the checkpoint requires replacement. A relay commitment is the stored-header
commitment, not the display-order Bitcoin block hash.

Copy and fill [`../.env.deploy.example`](../.env.deploy.example), then export it:

```sh
cp .env.deploy.example .env.deploy
set -a; source .env.deploy; set +a
forge script script/deploy/DeployAll.s.sol --rpc-url "$RPC_URL" --broadcast --verify
```

The template documents all inputs. Set token/relay addresses, amount floors,
signer sets, initial source network (`827166` for RGB), guardian, recipient,
timelock and outflow policy. Native fee quotes additionally require the oracle
configuration.

`DeployAll` creates CM, registry, Bridge implementation, initialized BridgeProxy,
plugins and MultisigProxy. The predicted BridgeProxy is at deployer nonce + 3.
The script installs initial outflow policies, applies optional oracle settings
and starts ownership transfers for CM, Bridge and registry.

The script **does not accept ownership or register routes**. After deployment:

1. Complete the three ownership acceptances through `AdminExecute`,
   `AdminExecuteCommissionManager` and `AdminExecuteRouteRegistry`, respectively.
2. Register the two production routes through `SetRoute`; wait for the timelock
   and execute the printed `opData`. Use `getRoute(src, dst)` to check the result.
3. Configure and verify fee rules and oracle inputs.
4. Check Bridge/registry/CM bindings, owner and pendingOwner values, signer sets,
   per-chain nonces, verifier parameters, amount floors and outflow policies.
5. Exercise deposit and release paths with the deployed configuration.

`DeployBridge` creates a fresh implementation and proxy; it is not an upgrade
script. Its predeployed CM and registry must be bound to the predicted proxy.
For this standalone script, if the deployer's next nonce is N, the implementation
is created at N and the proxy at N+1. Compute the proxy with
`cast compute-address <deployer> --nonce <N+1>` using an evaluated integer for N+1,
and do not consume another deployer nonce before broadcasting the script.
`DeployMultisigProxy` creates governance only; it does not transfer managed
ownership. `DeployMinimalBridge` reads USDT0_ADDRESS and creates a separate
integrator bridge owned by the deployer. `DeployRgbRejectList` is standalone and
requires different REJECT_LIST_OWNER and REJECT_LIST_APPENDER values.

### MinimalBridge RGB mint records

`MinimalBridge.fundsIn(amount, operationId, beforeBlock)` accepts a funded RGB
mint only while the current Arbitrum L2 block is strictly less than
`beforeBlock`. It reads the child-chain height from the Arbitrum `ArbSys`
precompile rather than Solidity's approximate L1 `block.number`.

Each successful lock creates one permanent height record under the key returned
by `rgbMintDepositId(operationId, amount)`. The key binds the bridge, EVM chain,
token, RGB operation and amount. `beforeBlock` is a call-time deadline rather
than part of the permanent identity. Records are never deleted by `fundsOut`. A
stored value of zero therefore means that the claim was not recorded; otherwise
the value is the actual L2 block plus one.

An RGB resolver can check one external anchor without scanning historical logs:

```javascript
const abi = [
  "function getFundsInBlock(uint256 operationId,uint256 amount) view returns (uint64 l2BlockPlusOne)"
];
const bridge = new ethers.Contract(bridgeAddress, abi, provider);
const l2BlockPlusOne = await bridge.getFundsInBlock(operationId, amount, {
  blockTag: "finalized"
});
```

The equivalent direct `eth_call` with Foundry's `cast` is:

```bash
cast call "$MINIMAL_BRIDGE" \
  "getFundsInBlock(uint256,uint256)(uint64)" \
  "$OPERATION_ID" "$AMOUNT" \
  --rpc-url "$ARBITRUM_RPC_URL" \
  --block finalized
```

The resolver supplies the operation id and amount from validated RGB history.
It requires a nonzero result, decodes the creation height as
`l2BlockPlusOne - 1`, and checks that height against the `beforeBlock` committed
by the RGB transition. The legacy `FundsIn` event remains unchanged for
compatibility.

### LayerZero adapter wiring

Bridge and MultisigProxy have separate adapter fields. `DeployAll` leaves both
unset; the standalone `DeployBridge` script can set an initial Bridge adapter.
To connect an adapter later, execute both governance actions:

- `AdminExecute` with `Bridge.setLZAdapter(adapter)` authorizes adapter deposits.
- `UpdateLZAdapter(adapter)` sets the target for proxy adapter calls and onward sends.

Use `Bridge.disableLZAdapter()` to disable adapter deposits and
`DisableLZAdapter` to clear the proxy target. The setters reject zero addresses.

### Replacing CommissionManager

The constructor makes the deployer owner, allowing configuration before handoff.
To replace an existing CM:

1. Deploy and configure the replacement with the live BridgeProxy as bridgeAddress.
2. Start `transferOwnership(multisig)` on the replacement.
3. Withdraw the old CM's accrued pools before switching; pointer updates do not
   migrate balances, and normal CM commands address only the current manager.
4. Propose and execute `UpdateCommissionManager` after its timelock.
5. **After the update executes**, propose `AdminExecuteCommissionManager` with
   `acceptOwnership()` calldata. Wait for this proposal's timelock and execute it.
6. Verify both CM pointers and the new manager's owner, recipient, configuration
   and binding.

Do not prepare acceptance before the update: the proposal would bind the old CM
and become stale after switching. This sequence requires a second timelock during
which the active replacement still belongs to the deployer. Account for that
ownership window in the migration plan.

### Implementation upgrades

BridgeProxy owns the upgrade entry point; implementations do not expose UUPS
upgrade functions. Its owner is read from the OpenZeppelin Ownable storage
namespace, independently of the implementation's `owner()` getter. Upgrades must
preserve that namespace, field and stored owner. There is no separate proxy admin.

1. Deploy a locked candidate with `DeployBridgeImplementation.s.sol`.
2. Build the exact candidate and run `python3 script/storage-layout/storage_layout.py`.
   Review storage, dependency namespaces and reserved proxy selectors.
3. Prepare versioned reinitializer calldata, or `0x` for none. Nonempty data must
   include a selector and fit within 4096 bytes.
4. Submit `MultisigProposeUpgradeBridge.s.sol`, wait for the timelock and execute
   its printed `opData`.
5. Verify implementation, ownership, state, balances and transfer behavior.

Candidates must expose the expected direct-call-only compatibility UUID. The
marker is not a substitute for reviewing implementation behavior or storage.
Proxy selectors `implementation` and `upgradeToAndCall` are reserved. Governance
rejects same-implementation upgrades and direct fundsOut/rebalance initializer
selectors. Proxy validates compatibility and checks the stored owner after
initialization; failure rolls back the upgrade and initialization writes.

These checks belong to the deployed proxy and governance bytecode. Replacing only
the Bridge implementation does not retrofit them into older proxy deployments.
Ownership changes use the separate two-step handoff, not an upgrade reinitializer.

## Interaction scripts

Copy [`../.env.interact.example`](../.env.interact.example) to `.env.interact` and
export it before running a script. AMOUNT is in token smallest units, not ETH wei.
Use local signing keys only for local/testnet simulation; production signatures
come from enclave and federation signers.

| Script | Action |
| --- | --- |
| `BridgeFundsIn` | Quote, approve and deposit with RGB settlement data |
| `MultisigExecuteFundsOut` | Sign an RGB release locally and submit it |
| `MultisigProposeSetRoute` | Submit a route proposal; print execution data |
| `MultisigProposeUpgradeBridge` | Submit an implementation-upgrade proposal |
| `MultisigProposeSetEmergencyGuardian` | Submit guardian rotation or disabling |
| `EmergencyPause` / `EmergencyUnpause` | Sign and submit federation emergency actions |
| `GuardianEmergencyPause` | Pause directly as guardian |

Route proposals read **DEST_CHAIN_ID**; deposit and release scripts read
**DESTINATION_CHAIN_ID**. Choose ids for each operation: an RGB deposit targets
827166, while an RGB release on Arbitrum targets 42161. For proposals, choose a
DEADLINE_OFFSET longer than the timelock and execution allowance.

## RGB reject list

RgbRejectList stores append-only `(opId, assignmentType, no, reject)` entries for
RGB operation outputs. Only the appender publishes; the owner can rotate it.
The latest entry for an opout wins, so corrective entries supersede earlier ones
without deleting history. Clients cache entries and request
`entries(cachedLength, length())`; use a fixed block across paginated reads.

The list is independent of the bridge stack. Its address is referenced at RGB
asset issuance, so record it before issuance and preserve that reference. The
contract is not upgradeable and ownership renunciation is blocked.
