# skimmer-module

A Splits SmartVault **module** that moves realized yield, and only yield, out of an Earn (Morpho VaultV2, ERC-4626)
position and credits it to recipients by share. The spec is Part 1 of
[`PRD Yield Skimmer Module + Song A Day Endowment.md`](<./PRD Yield Skimmer Module + Song A Day Endowment.md>).
Part 2 (the Song A Day bidder) is not implemented here.

| Contract | What it is |
| --- | --- |
| `src/YieldSkimmer.sol` | The module. One instance per endowment subaccount; `account`, `vault` and `asset` are immutable. No owner, no upgrades, no generic execute passthrough. The only calls it can make from the account are `vault.withdraw(take, account, account)` then `asset.transfer(module, take)`, in one `executeFromModule(Call[])` batch. |
| `src/NoopModule.sol` | An intentionally empty module for rollout step 1 (prove the platform lets a module be enabled and disabled). |
| `src/interfaces/ISmartVaultModuleManager.sol` | The slice of the deployed SmartVault `ModuleManager` the module needs (`Call`, `executeFromModule(Call[])`, `enableModule`, `disableModule`, `isModuleEnabled`). |

## How a skim works

`principal` is a watermark in underlying-asset units; position above it is yield. `skim()` is permissionless:

1. First call ever: `principal = position`, `lastSkim = now`, nothing moves.
2. Ratchet: `if (position < principal) principal = position`.
3. Ceiling: `principal * capBps * elapsed / (365 days * 10_000)`. Anything above the ceiling cannot be yield and is folded
   into `principal` (an unannounced deposit becomes principal, not a skim).
4. `yield = min(position - principal, ceiling, absoluteMaxPerSkim)`; `take = yield * totalShareBps / 10_000`.
5. If `take > 0`: withdraw `take` from the vault and move it to the module in one batch. Credit each recipient
   `yield * shareBps / 10_000` (rounding dust stays in the module, uncredited).
6. The retained share (`yield - take`) is folded into `principal`; the position is re-read and the watermark ratcheted
   once more in case share rounding left it a wei under.

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
  invariants (position >= principal after a skim; principal only lowered by the ratchet; credited <= skimmed; a skim
  moves <= `min(ceiling, absoluteMaxPerSkim)` with the ceiling restated independently), plus: module balance >= sum of
  accrued, `previewSkim` equals what `skim` moves, a skim only reverts on a liquidity shortfall and then leaves no
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

## Rollout step 1: enable and disable the no-op module

The module path is `enableModule(address)` called **by the account on itself** (`onlySelf`). With the Splits CLI that
is a custom transaction whose call has `target = <subaccount>`, `value = 0`, and `data` as below.

```sh
# 1. Deploy the no-op module (any funded deployer key).
forge create src/NoopModule.sol:NoopModule --rpc-url "$BASE_RPC_URL" --account <keystore-name> --broadcast
#    -> Deployed to: <NOOP>

# 2. Calldata for the self-call that enables it. selector 0x610b5925
cast calldata "enableModule(address)" <NOOP>
#    e.g. 0x610b5925000000000000000000000000000000000000000000000000000000000000dead

# 3. Submit it as a custom transaction from the subaccount to itself, then confirm onchain:
cast call <SUBACCOUNT> "isModuleEnabled(address)(bool)" <NOOP> --rpc-url "$BASE_RPC_URL"   # -> true

# 4. Tear it down the same way. selector 0xa95f5246
cast calldata "disableModule(address)" <NOOP>
```

## Rollout step 2: the skimmer

```sh
# Deploy (Base). 3000 bps = 30% APR ceiling, 50_000_000 = 50 USDC per-skim cap (USDC has 6 decimals).
forge create src/YieldSkimmer.sol:YieldSkimmer --rpc-url "$BASE_RPC_URL" --account <keystore-name> --broadcast \
  --constructor-args <SUBACCOUNT> 0x189A1a23F46321a196646314E6a078a404513C8F 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 3000 50000000

# Enable it on the subaccount (self-call, as above).
cast calldata "enableModule(address)" <SKIMMER>

# Admin calls are custom transactions from the subaccount to the skimmer, e.g. a 40% recipient with a 1-day interval:
cast calldata "addRecipient(address,uint16,uint32)" <RECIPIENT> 4000 86400

# Before removing the module, drain unpulled accrued back to the account, then disable it.
cast calldata "drainTo(address)" <SUBACCOUNT>
cast calldata "disableModule(address)" <SKIMMER>
```

Before baking the vault in as immutable, confirm the subaccount's shares are in `splitsUSDC`
(`0x189A…3C8F`) and not the legacy Aave vault (`0x4EA7…caCc`).

## Security notes

- A module has the account's full `_call` surface; the skimmer's code is the scope. Keep the endowment in its own
  subaccount, with a human in its signer threshold.
- `removeRecipient` forfeits the recipient's unpulled `accrued` to the account. Auto-earn sweeps it into the vault,
  where it is treated like any other inflow (absorbed or skimmed again within the ceiling).
- Two `skim()` calls in the same block: the second has `elapsed == 0`, so its ceiling is 0 and nothing moves, but any
  excess left above the watermark by `absoluteMaxPerSkim` is folded into `principal` rather than skimmed later.
  Raise `absoluteMaxPerSkim` if that matters; it is the PRD's rule applied literally.
- This has not been audited.
