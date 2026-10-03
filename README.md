# Iridius contracts

These are the smart contracts behind Iridius, a non-custodial venue for swapping tokenized real-world assets on Robinhood Chain. In every market, anchor vaults quote both sides around the guarded Chainlink mid, while block-size orders settle against signed RFQ maker quotes; a single router stitches the two together behind one entry point, with everything settled in USDG.

The target is Robinhood Chain (chain ID 4663), which runs on Arbitrum Nitro, and the toolchain is Foundry.

## Layout

```
src/
  SwapRouter.sol              the only entry point for traders: eligibility, choosing vault or RFQ, two-leg composition
  AnchorVault.sol             one per market: quotes anchored to the oracle, inventory skew, LP shares, in-kind withdrawal
  VaultFactory.sol            deploys vaults and doubles as the registry the router looks them up in
  RfqSettlement.sol           EIP-712 maker quotes, cancellation by nonce, atomic settlement checked against the band
  OracleRouter.sol            Chainlink feeds and streams behind session, staleness, move-cap and sequencer guards
  EligibilityRegistry.sol     role checks delegated to a policy adapter that can be swapped
  adapters/NativeAttestationAdapter.sol   standalone attestation store following EAS semantics
  ParamController.sol         all tunable parameters sit behind a timelock; the guardian's only power is pausing swaps
  FeeCollector.sol            collects the itemised swap fees, the RFQ fees and the protocol's share of the spread
  libraries/                  Types (quotes, breakdowns, roles and constants)
  interfaces/                 interfaces for the protocol and for external systems (Chainlink, ERC-8056)
  mocks/                      stand-ins for local development: USDG, Stock Token, aggregator, stream adapter
script/Deploy.s.sol           deploys and configures everything, then opens the launch market
script/Seed.s.sol             gives a fresh testnet deployment liquidity and its first pair of fills
script/Activity.s.sol         runs one round of activity across several wallets (deposits, a withdrawal, a batch of swaps)
test/                         Foundry suite covering vault accounting, swap pricing, regimes and halts, RFQ and governance
deployments/                  addresses recorded by the deploy script, one JSON file for each chain ID
```

## Deployments

### Robinhood Chain testnet (chain ID 46630)

The deployment went out on 6 October 2026 from `0x63037Ec2c60f5017842Ea7034E1ab6609ab9Db9a`, an address that also serves as bootstrap owner, guardian and attestation issuer on testnet. [Blockscout](https://explorer.testnet.chain.robinhood.com) has verified source for all twelve contracts. Every external dependency is mocked: the deploy script brings its own USDG, NVDAx stock token and Chainlink aggregator, with NVDAx priced at 176.40 USDG. See `deployments/46630.json` for the complete list.

Roughly 1,000,000 USDG of balanced liquidity sits in the launch vault, and the seed and activity scripts have left it with deposits, a withdrawal and a batch of fills, giving the explorer and the platform genuine history to display.

| Contract | Address |
| --- | --- |
| SwapRouter | [`0xdb80db0EA45ab6f25234d751b1709B01BFcCC912`](https://explorer.testnet.chain.robinhood.com/address/0xdb80db0EA45ab6f25234d751b1709B01BFcCC912) |
| RfqSettlement | [`0x779d8F12d5542F3740D674214552ee54Dbd207AE`](https://explorer.testnet.chain.robinhood.com/address/0x779d8F12d5542F3740D674214552ee54Dbd207AE) |
| VaultFactory | [`0x37F97F5B1aD039E802B42D6c6EaEE515a9bbd6dA`](https://explorer.testnet.chain.robinhood.com/address/0x37F97F5B1aD039E802B42D6c6EaEE515a9bbd6dA) |
| AnchorVault (NVDAx / USDG, `zvNVDAx`) | [`0x106a8E5b9963f245Fb425f4f36be5459972F6bAA`](https://explorer.testnet.chain.robinhood.com/address/0x106a8E5b9963f245Fb425f4f36be5459972F6bAA) |
| OracleRouter | [`0x87939B317C563358D13e066a7B013bCC405b991e`](https://explorer.testnet.chain.robinhood.com/address/0x87939B317C563358D13e066a7B013bCC405b991e) |
| EligibilityRegistry | [`0xB9d2C0BAE8a31Cc13B912E59d901B5933BeBcf5C`](https://explorer.testnet.chain.robinhood.com/address/0xB9d2C0BAE8a31Cc13B912E59d901B5933BeBcf5C) |
| NativeAttestationAdapter | [`0x7C723430530338b1c244a2f89A253cfA46409229`](https://explorer.testnet.chain.robinhood.com/address/0x7C723430530338b1c244a2f89A253cfA46409229) |
| ParamController | [`0x0a4Eb9Bf998Fb0c26Ef3798222CA804beEDfc329`](https://explorer.testnet.chain.robinhood.com/address/0x0a4Eb9Bf998Fb0c26Ef3798222CA804beEDfc329) |
| FeeCollector | [`0x40729a4810E5E4A61A2F3967ED6b6e6a3961FCC7`](https://explorer.testnet.chain.robinhood.com/address/0x40729a4810E5E4A61A2F3967ED6b6e6a3961FCC7) |
| USDG (mock) | [`0x24747A258Bc380006b5Ed446f91AAAbe6A3caFb3`](https://explorer.testnet.chain.robinhood.com/address/0x24747A258Bc380006b5Ed446f91AAAbe6A3caFb3) |
| NVDAx stock token (mock) | [`0xF5c95f7bd6D3837d067360f891F5c20eA4d4F7B3`](https://explorer.testnet.chain.robinhood.com/address/0xF5c95f7bd6D3837d067360f891F5c20eA4d4F7B3) |
| NVDAx / USD aggregator (mock) | [`0x91c712Bd45Bf22c76c306342bcbf643c7e80dAC2`](https://explorer.testnet.chain.robinhood.com/address/0x91c712Bd45Bf22c76c306342bcbf643c7e80dAC2) |

On testnet the documented launch parameters apply, `TIMELOCK_DELAY=3600` and `FINISH_BOOTSTRAP=false`, which leaves the deployer able to call the `ParamController` setters without the timelock. The deployer also holds attestations for every role (trader, LP, maker, relayer), so each flow can be tried from that account immediately.

### Robinhood Chain mainnet (chain ID 4663)

There is no mainnet deployment yet. It needs the live `USDG`, `STOCK_TOKEN`, `STOCK_FEED` and `SEQUENCER_FEED` addresses, and on chain ID 4663 the script will not deploy mocks.

## Swap settlement, step by step

1. A trader calls `SwapRouter.swapExactIn`, passing the pair, an exact input amount, a minimum output and a deadline, and may also attach a signed maker quote.
2. The router confirms the trader's `TRADER` attestation, recomputes the anchor vault's price from oracle and vault state within the same transaction, checks the maker quote's signature when one is supplied, and settles on whichever venue gives the larger output.
3. Vault pricing follows the formula: guarded Chainlink mid, the tier half-spread multiplied by the session multiplier, signed inventory skew and an itemised fee. Each fill emits its complete breakdown, and neither venue can settle outside the tier's oracle band.
4. A token-to-token swap is two atomic legs routed through USDG; should either leg fail to clear within its market's guards, the whole swap reverts.

## Quick start

```bash
forge soldeer install     # pulls forge-std and OpenZeppelin into dependencies/
forge build
forge test -vv
```

Soldeer handles dependencies, so there are no git submodules. The build uses Solidity 0.8.26, the Cancun EVM and via-IR.

## Deploying

1. Make a copy of `.env.example` named `.env` and fill in `PRIVATE_KEY`, the RPC URL of the chain you are targeting (`ROBINHOOD_TESTNET_RPC` or `ROBINHOOD_RPC`; docs.robinhood.com/chain lists the official URLs) and the corresponding Blockscout API URL used for verification.
2. Point `USDG`, `STOCK_TOKEN` and `STOCK_FEED` at the live addresses. For a local Anvil chain or the testnet, leaving them empty makes the script deploy mocks.
3. Run the deployment. Use the RPC alias `robinhood_testnet` for chain ID 46630 and `robinhood` for mainnet:

```bash
source .env
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --verify
```

Every address is written to `deployments/<chainId>.json`; the script also opens the launch market and applies the documented launch parameters (Tier A: 10 bps half-spread, 75 bps band, 50,000 USDG clip; session multipliers of x1.5 extended and x3 closed; 2 bps fees and a 10% spread share). To pass ownership to the governance multisig, set `GOV`, and to put parameters behind the timelock, set `FINISH_BOOTSTRAP=true`. If mocks are deployed and the deployer is the attestation issuer, the deployer attests itself for every role so that each flow works straight away.

`--verify` handles the eleven contracts the script deploys itself. Because the factory deploys the `AnchorVault`, forge has no way to recover its constructor arguments and Blockscout turns down the automatic submission. Verify it manually using the addresses in the deployments file:

```bash
ARGS=$(cast abi-encode "constructor(address,address,address,address,address,address,string,string)" \
  $PARAM_CONTROLLER $ELIGIBILITY_REGISTRY $ORACLE_ROUTER $FEE_COLLECTOR $USDG $STOCK_TOKEN \
  "Iridius NVDAx Vault" "zvNVDAx")
forge verify-contract $ANCHOR_VAULT src/AnchorVault.sol:AnchorVault --chain 46630 \
  --verifier blockscout --verifier-url "$ROBINHOOD_TESTNET_BLOCKSCOUT_API" --constructor-args "$ARGS" --watch
```

### Populating testnet with seed data

Each script reads `deployments/<chainId>.json` and relies on the mock tokens, which limits them to testnet or a local chain.

```bash
forge script script/Seed.s.sol --rpc-url robinhood_testnet --broadcast
forge script script/Activity.s.sol --rpc-url robinhood_testnet --broadcast --slow
```

`Seed` mints the deployer's balances, puts 500,000 USDG per side into the launch vault and sends one buy and one sell through the router. `Activity` derives two LP wallets and five trader wallets from the deployer key, gives each a small gas stipend, attests them, then performs two deposits, a partial withdrawal and twenty swaps across both directions. Runs of `Activity` stack on the state already there; give `ROUND` a fresh value each time so trade sizes vary. Allow about 0.003 ETH on the deployer for one deploy plus a single round of each script, mostly spent on gas stipends.

## Governance model

- `ParamController` begins in bootstrap mode, where the owner calls setters directly. Calling `finishBootstrap()` cannot be undone and sends every subsequent change through `schedule` / `execute` with the configured delay.
- Pausing swaps is the guardian's only power. Deposits, withdrawals and RFQ cancellation cannot be paused by anyone.
- There is no proxy and no admin on `SwapRouter`, `AnchorVault`, `VaultFactory` or `RfqSettlement`. Upgrades arrive as fresh deployments, and LPs choose whether to migrate.

## Key invariants

- Whatever the regime and whatever parameter set the controller accepts, no fill from a vault or a maker clears outside the tier's oracle band.
- Withdrawing from a vault is pro-rata and in kind, and it works in every state: halted, paused by the guardian, market retired or attestation expired. LP funds cannot be trapped.
- A swap never lowers value per share, and rounding on mint and burn always goes in the vault's favour.
- No fill may push a vault outside its inventory band, or move it further out when a price move has already done so, and the preview matches the fill exactly; the harmful side therefore turns one-sided rather than soaking up unlimited inventory, while the rebalancing side brings the vault back inside.
- Each market is priced from the feed configured for the precise token held in the vault, never from a wrapper or a derived rate.
- Every quote is itemised on-chain, with the fill event recording mid, spread, skew and fee in line with the quote.

## Integration guidance

- Traders approve the router and makers approve `RfqSettlement`; Permit2 and ERC-4337 batching live a layer above these contracts, not within them.
- Because deposits value incoming assets at the guarded mid, they revert while a market is halted; withdrawals consult no oracle and never revert because of market state.
- `AnchorVault.quoteSwap` gives the exact preview. It reverts while the market is halted, and the router reads that as "no vault quote", letting RFQ keep the market running.
- `SwapRouter.previewExactIn` accepts the same params as `swapExactIn` and returns the output and venue the fill would settle on, covering the RFQ candidate and two-leg composition. It throws the same errors the fill would, except for the deadline, eligibility and the candidate's signature, which only the call itself checks.
- If a feed print lands further than the move cap from a recent checkpoint, the market halts in that same block for previews, fills and RFQ settlement alike. Anyone may call `OracleRouter.refresh`: on a halted market it records the pause so that it persists beyond the move-cap window, and only a governance `resume` lifts it.

## Security

`docs/architecture/security.md` sets out the security programme (testing, audits, bounty and disclosure). Please send vulnerability reports to security@iridius.xyz instead of opening public issues.
