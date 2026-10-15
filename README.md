# skimmer-module

A Splits SmartVault **module** that moves realized yield, and only yield, out of an Earn (Morpho VaultV2, ERC-4626)
position and credits it to recipients by share. The spec is Part 1 of
[`PRD Yield Skimmer Module + Song A Day Endowment.md`](<./PRD Yield Skimmer Module + Song A Day Endowment.md>).
Part 2 (the Song A Day bidder) is not implemented here.

| Path | What it is |
| --- | --- |
| `src/YieldSkimmer.sol` | The module. One instance per endowment subaccount; `account`, `vault` and `asset` are immutable. No owner, no upgrades, no generic execute passthrough. The only calls it can make from the account are `vault.withdraw(take, account, account)` then `asset.transfer(module, take)`, in one `executeFromModule(Call[])` batch. |
| `src/NoopModule.sol` | An intentionally empty module for rollout step 1 (prove the platform lets a module be enabled and disabled). |
| `src/interfaces/ISmartVaultModuleManager.sol` | The slice of the deployed SmartVault `ModuleManager` the module needs (`Call`, `executeFromModule(Call[])`, `enableModule`, `disableModule`, `isModuleEnabled`). |
| `script/` | Forge deploy scripts (`DeployNoopModule`, `DeployYieldSkimmer`): CREATE2 through the default deployer, sanity checks on the account, and the enable/disable calldata plus the Splits CLI call to print. |
| `ops/keeper.sh`, `.github/workflows/keeper.yml` | The keeper: `skim()` when `previewSkim()` has something, `pull()` for each due recipient. Daily from a GitHub Actions cron with a gas-only key. |

## How a skim works

`principal` is a watermark in underlying-asset units; position above it is yield. `skim()` is permissionless:

1. First call ever: `principal = position`, `lastSkim = now`, nothing moves.
2. Ratchet: `if (position < principal) principal = position`.
3. Ceiling: `principal * capBps * elapsed / (365 days * 10_000)`. Position above the ceiling cannot be yield (it is
   treated as a deposit).
4. `yield = min(position - principal, ceiling, absoluteMaxPerSkim)`; `take = yield * totalShareBps / 10_000`.
5. If `take > 0`: withdraw `take` from the vault and move it to the module in one batch. Credit each recipient
   `yield * shareBps / 10_000` (rounding dust stays in the module, uncredited).
6. `lastSkim = now`, and `principal = position` re-read after the batch.

**After every skim the watermark is the position**: everything that stays in the vault (the retained share of yield, an
unannounced deposit, yield the caps cut off) is principal and never skimmable again, so a second `skim()` in the same
block is a no-op. Keep `absoluteMaxPerSkim` above the yield of the longest expected gap between pokes, otherwise the
excess compounds instead of reaching recipients.

Recipients **pull**: `pull(r)` sends `accrued[r]` to `r` once its `minInterval` has passed. Admin
(`addRecipient`, `setRecipient`, `removeRecipient`, `setCap`, `resetPrincipal`, `pause`, `unpause`, `drainTo`) is
`msg.sender == account` only, i.e. a Splits custom transaction from the endowment subaccount that targets the skimmer.

A skim the vault cannot serve reverts (no try/catch) and is retried on the next poke. The module never calls
`maxWithdraw`/`maxRedeem`, which are hard-coded to `0` on Morpho V2, and never calls `forceDeallocate`.

## Setup

```sh
git clone --recurse-submodules https://github.com/zherring/skimmer-module
cd skimmer-module
forge build
```

Dependencies are git submodules under `lib/` (forge-std v1.17.0, OpenZeppelin Contracts v5.7.0); `foundry.lock` pins
them. Solidity is `0.8.28`, the same compiler as the deployed vault, with the optimizer on and no `via_ir`.

## Tests

```sh
forge test -vvv            # unit tests on mocks + invariant tests (no network)
forge fmt --check
```

- `test/YieldSkimmer.t.sol`: unit tests against `test/mocks/` (a 4626 whose share price the test sets and whose
  `withdraw` can be made to revert, and a SmartVault stand-in that honors an `isModule` flag and reverts the whole batch
  when a sub-call fails), plus a fuzz test of a single skim.
- `test/invariants/YieldSkimmer.inv.t.sol`: a handler that deposits, withdraws, moves the share price up and down,
  warps 0-60 days, skims, pulls, adds/changes/removes recipients, pauses and drains. It asserts the four PRD
  invariants (`principal == position` after every skim; principal only lowered by the ratchet; credited <= skimmed; a skim
  moves <= `min(ceiling, absoluteMaxPerSkim)` with the ceiling restated independently), plus: module balance >= sum of
  accrued, `previewSkim` equals what `skim` moves, a same-block second skim is a no-op, a skim only reverts on a liquidity shortfall and then leaves no
  trace, and the result matches a from-scratch reference model of the PRD mechanics. Defaults are 256 runs x depth 100
  (`foundry.toml`).
- `test/fork/YieldSkimmer.fork.t.sol`: a Base fork against the real Splits Earn wrapper and a SmartVault created
  through the real factory. It is excluded from the default profile because it needs an RPC:

  ```sh
  BASE_RPC_URL=https://mainnet.base.org FOUNDRY_PROFILE=fork forge test -vvv
  ```

  `BASE_RPC_URL` defaults to `https://mainnet.base.org`. The test **skips** (it does not fail) if the fork cannot be
  created or the RPC is not Base. Public RPCs serve the live `eth_call`/state reads the test needs but refuse
  historical `eth_getLogs`; the test uses neither historical logs nor a pinned block.

  Note on the wrapper under a fork: `VaultV2.firstTotalAssets` is `transient`, and a forge test is a single
  transaction. After the first state-changing call on the wrapper in a test, `convertToAssets` stops following
  `vm.warp` for the rest of that test. The fork test therefore makes the account's deposit in `setUp` (a separate call,
  clean transient storage) and does its first `skim()` (views only) before anything else mutates the wrapper. In
  production each `skim()` is its own transaction, so this does not apply.

- `ops/test-keeper.sh`: the deploy scripts and the keeper end to end on a local `anvil` fork of Base (needs `anvil`,
  `forge`, `cast`, `jq`; kills anvil on exit):

  ```sh
  BASE_RPC_URL=https://mainnet.base.org ops/test-keeper.sh   # falls back to base-rpc.publicnode.com
  ```

  It creates a SmartVault through the real factory, writes its USDC straight into USDC's balance storage
  (`anvil_setStorageAt`, the `deal` equivalent), deposits into the real wrapper by impersonating the account, deploys
  the skimmer with `script/DeployYieldSkimmer.s.sol`, enables it with the calldata the script prints, and runs
  `ops/keeper.sh` against it: init, `DRY_RUN`, paused, skim plus pull after `anvil_increaseTime` 30 days (real Morpho
  interest does move on anvil, because every call is its own transaction), a recipient whose `pull()` reverts (blacklisted
  in USDC) not failing the run, a skipped no-op skim, and a skim that cannot be sent failing the run. `SIMULATE_YIELD=1`
  swaps the interest for an unannounced 20 USDC deposit (the fallback for an environment where it does not move);
  `VERBOSE=1` prints the whole deploy script output.

## Runbook

Write-ups for the PRD rollout steps. Everything below is Base (8453). You need a funded deployer
(`cast wallet import <keystore-name> --interactive`) and `export BASE_RPC_URL=https://mainnet.base.org`.

**How a module is switched on and off.** `enableModule(address)` and `disableModule(address)` are `onlySelf`: the
account must call itself. In Splits that is a custom transaction with one call `{to: <ACCOUNT>, data: <calldata>,
value: "0"}` that the account's signers approve. Both deploy scripts print the exact calldata, the Splits CLI
invocation and the same payload as MCP tool arguments:

```sh
splits transactions create custom --account <ACCOUNT> --chain-id 8453 \
  --calls '[{"to":"<ACCOUNT>","data":"0x610b5925…","value":"0"}]' --memo "Enable …"
```

Caveat, checked 2026-10-15 (no credentials needed): `splits-cli` 0.3.0 pins `incur` 0.3.13, which passes each `--calls`
item to its validator as a string, so the command above fails with `expected object, received string` whether the
value is one object or an array. The same payload works as the arguments of the MCP tool
`transactions_create_custom` (`claude mcp add splits -e SPLITS_API_KEY=… -- npx @splits/splits-cli --mcp`). Re-check
with a newer CLI before relying on the argv form.

Every script below does a dry run (simulate, send nothing) when `--broadcast` is left off; it prints the predicted
CREATE2 address and all calldata, so run that first. Re-running a broadcast after a successful deploy skips the deploy.

### Step 1: NoopModule

```sh
export ACCOUNT=<SUBACCOUNT>
forge script script/DeployNoopModule.s.sol --rpc-url "$BASE_RPC_URL"                                    # dry run
forge script script/DeployNoopModule.s.sol --rpc-url "$BASE_RPC_URL" --broadcast --account <keystore-name>
```

1. Submit the printed `enableModule` self-call (CLI or MCP form above) and sign it.
2. Confirm onchain: `cast call $ACCOUNT "isModuleEnabled(address)(bool)" <NOOP> --rpc-url "$BASE_RPC_URL"` is `true`.
3. Submit the printed `disableModule` self-call the same way; the same `cast call` now returns `false`.

### Step 2: the skimmer

```sh
export ACCOUNT=<SUBACCOUNT>
# optional: VAULT (default splitsUSDC) ASSET (USDC) CAP_BPS (3000) ABSOLUTE_MAX_PER_SKIM (50000000 = 50 USDC) SALT
forge script script/DeployYieldSkimmer.s.sol --rpc-url "$BASE_RPC_URL"                                  # dry run
forge script script/DeployYieldSkimmer.s.sol --rpc-url "$BASE_RPC_URL" --broadcast --account <keystore-name>
```

Before deploying, the script reverts if `ACCOUNT` has no code or does not answer `isModuleEnabled`, `VAULT.asset()` is
not `ASSET`, or the account holds no `VAULT` shares. It warns, without failing, if the account's ERC-1967 implementation
is not `0x15ec…F3FA` (accounts upgrade individually), if it still holds legacy Aave vault shares (`0x4EA7…caCc`), or if
`AutoEarnModuleV2` (`0x4A5a…9F5f`) is not enabled on it. Shares must already be in the vault: `vault` is immutable.

1. Enable it: submit the printed `enableModule` self-call, then `cast call $ACCOUNT "isModuleEnabled(address)(bool)"
   <SKIMMER> --rpc-url "$BASE_RPC_URL"` is `true`.
2. Verify the source. The script prints this line with your constructor args filled in:

   ```sh
   forge verify-contract --verifier sourcify --chain base --constructor-args <printed hex> <SKIMMER> src/YieldSkimmer.sol:YieldSkimmer
   ```

3. Add the first recipient (step 2 of the rollout: 100% to an EOA you control, no interval). Admin calls are custom
   transactions whose `to` is the **skimmer** and whose sender is the account (the account is `msg.sender`, which is
   what `onlyAccount` checks):

   ```sh
   cast calldata "addRecipient(address,uint16,uint32)" <MY_EOA> 10000 0
   # --calls '[{"to":"<SKIMMER>","data":"<that calldata>","value":"0"}]' --account <ACCOUNT> --chain-id 8453
   ```

4. Set up the keeper (`.github/workflows/keeper.yml`, daily 09:00 UTC; it runs `ops/keeper.sh`):

   ```sh
   cast wallet new                                  # the keeper EOA: gas only, hold ~0.002 ETH on Base
   gh secret set KEEPER_PRIVATE_KEY                 # that key
   gh secret set BASE_RPC_URL
   gh variable set SKIMMER_ADDRESS --body <SKIMMER>
   gh workflow run keeper.yml -f dry_run=true       # prints the cast send commands; then run it without dry_run
   ```

   The first run sees `lastSkim() == 0` and sends the initializing `skim()` (records the watermark, moves nothing).
   After that the keeper sends `skim()` only when `previewSkim()` reports `take > 0`, then `pull(r)` for each recipient
   with `accrued > 0` and `now >= lastPull + minInterval`; a failing `pull` is logged and skipped, a failing `skim`
   fails the run. By hand: `SKIMMER=… RPC_URL=… DRY_RUN=1 ops/keeper.sh`, or look with
   `cast call <SKIMMER> "previewSkim()(uint256,uint256)" --rpc-url "$BASE_RPC_URL"` (yieldAmt, take). A skim moves
   about 650k gas through the wrapper's three hops, still cents on Base. GitHub pauses scheduled workflows after 60 days
   without repo activity.

5. Teardown: submit `drainTo(<ACCOUNT>)` (to the skimmer, as above) so unpulled `accrued` is not stranded, then the
   printed `disableModule` self-call.

### Step 3: another recipient

The Glider portfolio account is a plain address that comes from Glider's enrollment. Shares across recipients sum to at
most 10,000 bps, so first lower or remove the step 2 EOA (`setRecipient(<MY_EOA>, 5000, 0)` or `removeRecipient`), then
register it as one more custom transaction to the skimmer, 50% with a 7-day interval:

```sh
cast calldata "addRecipient(address,uint16,uint32)" <GLIDER_ACCOUNT> 5000 604800
```

## Security notes

- A module has the account's full `_call` surface; the skimmer's code is the scope. Keep the endowment in its own
  subaccount, with a human in its signer threshold.
- `removeRecipient` forfeits the recipient's unpulled `accrued` to the account. Auto-earn sweeps it into the vault,
  where it is treated like any other inflow (up to the ceiling it is yield again, the rest becomes principal).
- This has not been audited.
