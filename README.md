# Utexo Bridge contracts

Solidity contracts for the Arbitrum side of the Utexo bridge between USDT0 and RGB.
The EVM project, tests and deployment scripts are in [`ethereum/`](ethereum/).
See the [EVM documentation](ethereum/docs/README.md) for setup and operation.

## Networks

| Network | Chain identifier |
| --- | --- |
| Arbitrum One | `42161` |
| Ethereum mainnet | `1` |
| RGB | `827166` (protocol-assigned) |

The Bridge runs on Arbitrum. Deposits from other EVM networks arrive through an
external LayerZero adapter. The adapter authenticates the original source chain
and sender before calling Bridge; direct Arbitrum deposits use `block.chainid`.
Adapter contracts are maintained in the USDT0 repository.

RGB addresses are carried in consignments. The EVM RGB deposit API therefore
requires an empty `destinationAddress` instead of duplicating that value.

## Contracts

| Contract | Responsibility |
| --- | --- |
| `BridgeProxy` / `Bridge` | Token custody, liquidity by destination network, replay protection and outflow limits |
| `RouteRegistry` | Dispatch to the verifier and settlement module configured for a route |
| `RGBVerifier` | Bitcoin block commitment and confirmation checks through BtcRelay |
| `RgbSettlementModule` | Permanent RGB backing records for deposits and rebalance credits |
| `RgbOutboundSettlementModule` | Read the RGB ledger for a route without an RGB credit leg |
| `CommissionManager` | Fee quotes, fee custody and withdrawals to a fixed recipient |
| `MultisigProxy` | Enclave-authorized operations and federation governance |
| `RgbRejectList` | Standalone append-only decisions consumed by RGB clients |
| `MinimalBridge` | Separate custody contract for integrations without route or commission modules |

The proxy is the Bridge address used by tokens, users, the registry and CM.
Implementation upgrades preserve that address and require federation governance.

## Authorization

- Direct `fundsIn` is public. The adapter overload accepts only the configured adapter.
- `fundsOut`, `lzFundsOutCall` and `rebalanceCall` require the registered source
  chain's enclave quorum. Enclaves validate RGB consignments; the EVM verifier
  checks the supplied Bitcoin block commitments and confirmation depths.
- Federation configures routes, fees, signer sets and upgrades through proposals
  and a timelock. Its signer addresses must be disjoint from enclave addresses.
- Federation emergency pause/unpause bypasses the timelock. The guardian can
  pause directly, but cannot unpause.

`rebalanceLiquidity` changes network liquidity accounting without moving tokens.
Its destination cannot be the local EVM chain; local token payouts use `fundsOut`.
Releases and rebalances share a source-burn replay key. MultisigProxy also enforces
an operation nonce per source chain.

## Fees and records

Directional fee rules override global defaults. Fees combine a proportional part
and a flat amount. Deposits support token or native payment; releases support token
payment only. CM holds commissions separately and pays withdrawals to its immutable
recipient. Both Bridge amount floors must be positive, with inbound >= outbound.
Rules with a flat fee must pass the live-floor check for either payment currency.

RGB backing records store the net token amount and destination network. They are
not consumed during release. The enclave validates how a consignment uses those
records; Bridge independently enforces source liquidity and burn replay protection.

## Third-party code

`ethereum/src/btc_relay/` is vendored from
[atomiqlabs/atomiq-contracts-evm](https://github.com/atomiqlabs/atomiq-contracts-evm).
RGBVerifier accesses a deployed relay through the local `IBtcRelayView` interface.
Third-party files and dependencies are kept separate from project comment conventions.
