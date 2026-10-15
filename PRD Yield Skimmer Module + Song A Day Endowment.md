# PRD: Yield Skimmer Module + Song A Day Endowment

Oct 15, 2026 · @zach

## Thesis

A lossless endowment: capital parked in a Splits account stays mine, and only the yield it throws off is spent — on things that should exist but don't have a buyer every day. The first beneficiary is Jonathan Mann's daily Song A Day auction: the endowment places a standing bid, every day, forever.

The property that makes this worth building is that **no key anywhere can touch principal**. Not a bot key, not a server, not me by accident. That holds because the skimmer is a SmartVault module whose only code path moves yield, and the bidder is a plain contract that can only spend what the skimmer hands it.

Two contracts, one novel:

1. **Yield Skimmer** — a SmartVault module enabled on one endowment subaccount. Reads the Morpho V2 Earn position, computes realized yield above a self-healing principal watermark, and routes it to recipients by share. Permissionless to poke.
2. **Song A Day Endowment** — the first recipient. A contract that pulls its allowance, bids on today's GBM auction on Base, recycles any refund and bid-to-earn incentive into tomorrow's bid, and forwards won songs to me. Not a bot: no key, no server, no discretion.

This is a personal experiment on Splits, shipped and written up as a demonstration. It is not a Splits product — but it exercises the module surface, Earn, and subaccounts in a way that may become one.

## Part 1 — Yield Skimmer module

### Goals

- Move realized yield, and only yield, out of a Splits endowment subaccount without any signer's approval.
- Make principal untouchable by construction: no code path in the module can reduce the position below the watermark.
- Survive my own carelessness: deposits and withdrawals I forget to announce must not become skimmable or brick the module.
- Fan yield out to several recipients by share, each on its own cadence, revocable at any time.
- Be a Safe-style module on the existing `ModuleManager` surface — no SmartVault upgrade, no Splits API dependency at runtime.

### Non-goals

- Deposits and withdrawals of principal. Those stay ordinary Splits transactions on the subaccount; auto-earn keeps sweeping to the vault as usual.
- Choosing the vault. The module reads whatever Earn vault the subaccount already holds (Morpho V2 wrapper, ERC-4626).
- Multi-chain. One chain (Base) for v1.
- Any Splits app or CLI integration. Enabling the module goes through `transactions create custom` as a self-call; the app may not render module activity.
- Scheduling. The module is permissionless to poke; a cron, a keeper or a human calls it.

### Mechanics

The module tracks one number, `principal`, in underlying-asset units (USDC). Everything above it is yield. On every `skim()` call, in order:

1. **Read the position.** `assets = vault.convertToAssets(vault.balanceOf(account))`. Morpho V2 is ERC-4626, and its performance and management fees are already netted out of share price, so this is net yield.
2. **Ratchet down.** If `assets < principal`, set `principal = assets`. In a lending vault the only way assets fall below the watermark is a withdrawal I made, or a vault loss; either way the watermark follows. Withdrawals never need announcing.
3. **Absorb implausible inflows.** `ceiling = principal × capBps × elapsed / (365 days × 10,000)`. If `assets − principal > ceiling`, the excess over the ceiling cannot be yield; treat it as a deposit and fold it into `principal`. A forgotten $10k deposit becomes principal on the next poke, not a $10k skim. False positives only compound.
4. **Compute the skim.** `yield = min(assets − principal, ceiling, vault.maxWithdraw(account), absoluteMaxPerSkim)`. The rate cap bounds any single failure to one period of allowance. `maxWithdraw` respects V2 liquidity; anything the vault can't serve today waits for the next poke. Never call `forceDeallocate` — its penalty is up to 2%.
5. **Execute one batch** via `executeFromModule(Call[])`: `vault.withdraw(yield, account, account)` then `USDC.transfer(module, yield)`. Withdrawing to the account itself sidesteps any `receiveAssetsGate` on the wrapper; moving the USDC out in the same batch keeps auto-earn from sweeping it back.
6. **Credit recipients.** Add `yield × shareBps / 10,000` to each recipient's `accrued`. Set `lastSkim = block.timestamp`.

`capBps` is a stored parameter, not an oracle. Set it well above any real net yield (e.g. 3,000 = 30% APR) so it only bites on money that isn't yield.

### Recipients

Recipients pull; the skimmer never pushes. Each recipient is a plain contract address (never a SmartVault module) with three fields:

| Field | Meaning | Example |
| --- | --- | --- |
| `shareBps` | Share of every skim credited to this recipient. Shares across recipients sum to ≤ 10,000; any remainder is left in the vault and compounds. | Song A Day 4,000 · DCA 3,000 · remainder 3,000 compounds |
| `minInterval` | Minimum seconds between `pull()` calls. `pull()` reverts if called early. | 1 day · 5 days |
| `accrued` | USDC credited but not yet pulled. Held in the module until pulled. | — |

`pull(recipient)` transfers `accrued` to the recipient and zeroes it. Anyone can call it; only the recipient receives. Timing logic beyond the interval lives in the recipient, not here.

### Admin surface

All admin is `onlyAccount`: the call must come from the endowment subaccount itself, which means a threshold-signed Splits transaction. The treasury account, as owner, can also reach it via `execute`.

- `addRecipient(addr, shareBps, minInterval)` / `setRecipient(...)` / `removeRecipient(addr)` — removal forfeits unpulled `accrued` back to the pool.
- `setCap(capBps, absoluteMaxPerSkim)`
- `resetPrincipal()` — sets `principal = assets`. An escape hatch, not a ritual; the self-healing rules should make it rare.
- `pause()` / `unpause()` — stops `skim()` and `pull()`.
- Removal of the module itself is `disableModule` on the account: a Splits transaction, or the treasury via `execute`. Unpulled `accrued` is stranded in the module unless drained first, so `drainTo(account)` is part of the admin set.

### Interface sketch

```solidity
contract YieldSkimmer {
    // immutable at deploy
    address account;   // the endowment SmartVault subaccount
    IERC4626 vault;    // Morpho V2 wrapper vault
    IERC20 asset;      // USDC

    // state
    uint256 principal;
    uint256 lastSkim;
    uint16  capBps;
    uint256 absoluteMaxPerSkim;
    bool    paused;
    mapping(address => Recipient) recipients;

    // permissionless
    function skim() external;
    function pull(address recipient) external;

    // onlyAccount
    function addRecipient(address r, uint16 shareBps, uint32 minInterval) external;
    function setRecipient(address r, uint16 shareBps, uint32 minInterval) external;
    function removeRecipient(address r) external;
    function setCap(uint16 capBps, uint256 absoluteMaxPerSkim) external;
    function resetPrincipal() external;
    function pause() external; function unpause() external;
    function drainTo(address to) external;

    // views
    function previewSkim() external view returns (uint256);
    function accrued(address r) external view returns (uint256);
}
```

One module instance per endowment subaccount; `account` is fixed at deploy so a module can never be pointed at a different account.

### Parameters for the first deployment

| Parameter | Value | Why |
| --- | --- | --- |
| Chain | Base | Earn vault and Song A Day auction both live here |
| `capBps` | 3,000 (30% APR) | Several times any plausible net stablecoin yield; only bites on non-yield |
| `absoluteMaxPerSkim` | \~$50 | Belt-and-suspenders on a single call while the heuristics are unproven |
| Skim cadence | Daily, from a cron | Matches the auction cadence; nothing enforces it onchain |
| Initial principal | Whatever I'm comfortable losing to a bug in v1 | This is an experiment first |

### Invariants and threat model

Invariants the tests should assert:

- After any `skim()`, `vault.convertToAssets(vault.balanceOf(account)) ≥ principal` (the position never drops below the watermark by the module's action).
- `principal` only moves down via the ratchet or up via absorption/reset — never by a skim.
- Total credited to recipients ≤ total skimmed, always.
- Any single `skim()` moves ≤ `min(ceiling, absoluteMaxPerSkim)`.

What the module can and cannot do:

| Actor / failure | Worst case | Bounded by |
| --- | --- | --- |
| Anyone calling `skim()` or `pull()` | Yield moves to its configured recipients a bit early | Rate cap; destinations fixed |
| Buggy heuristic (absorption misses a deposit) | One period of allowance skimmed from a deposit | `capBps` × elapsed, `absoluteMaxPerSkim` |
| Buggy recipient contract | Its unpulled `accrued` plus whatever it already pulled | `shareBps`; `removeRecipient` |
| Module bug that reaches `executeFromModule` with arbitrary calls | **Full subaccount** — a module has unscoped execution power onchain | Keep principal in its own subaccount; treasury `disableModule` via `execute`; audit |
| Vault loss or depeg | Principal ratchets down; nothing skims | Vault choice, not the module |
| Splits API down | Nothing — module has no API dependency | — |

The honest risk is the fourth row: `ModuleManager` grants a module the account's full `_call` surface. The module's code is the scope. That's why the endowment is its own subaccount holding only endowment capital, why the module's `vault`, `asset` and `account` are immutable, and why the only outbound calls it can construct are `vault.withdraw` and `asset.transfer`. No generic `execute` passthrough, ever.

## Part 2 — Song A Day Endowment

A standing bid on Jonathan Mann's daily auction, funded only by yield, that grows until it wins. The intent is to sustain a creator, not to farm his auction: the contract bids to buy songs, and treats bid-to-earn refunds as fuel for the next bid rather than as income.

### Goals

- Bid on every Song A Day auction, every day, with no human in the loop and no key anywhere.
- Accumulate: today's bid is everything the contract holds — yesterday's allowance plus today's plus any refund. It keeps growing until it wins, then starts over.
- Recycle: an outbid refund and its GBM incentive go back into the pot for tomorrow. Nothing leaves the contract except as a bid or as a won song.
- Forward won songs to a fixed recipient (my Splits account) so the contract never holds NFTs.
- Be revocable from the skimmer side in one transaction.

### Non-goals

- Winning cheaply. No sniping, no bidding at the last second, no gaming incentive rates. It bids early and openly.
- Extracting incentives. If the contract ends up net-positive from being outbid, that's a side effect, not the goal; the ETH stays in the pot.
- Multiple auctions or artists. One auction house, one artist, one strategy. A second artist is a second contract.
- Holding or managing the songs. They're forwarded on receipt.

### The auction, as found

Song A Day runs a GBM bid-to-earn auction on Base, in ETH, with the NFTs themselves on Ethereum mainnet via GBM's cross-chain coupon system ([gbm.auction](https://gbm.auction/), [GBM Decentraland launch post](https://medium.com/gbm-auction/gbm-launches-bid-to-earn-auction-house-for-the-decentraland-community-0cb83b781c85)). When a bidder is outbid, they receive their bid back plus an incentive fixed at bid time, paid the instant they're outbid. Bidders also receive an edition just for bidding. Same chain as the Earn vault, so gas is negligible and no bridging is needed.

### Mechanics

The contract holds one pot of ETH and runs one permissionless `execute()` a day. Rules:

1. **Pull.** `skimmer.pull(this)` — collects whatever yield share has accrued since yesterday (USDC).
2. **Swap.** USDC → ETH on a fixed DEX route on Base. The pot is the contract's ETH balance; there is no other accounting.
3. **Bid or hold.** If the pot clears the auction's minimum (and the current high bid plus increment), bid the entire pot on today's auction. If not, do nothing; tomorrow's pull makes the pot bigger. This is the accumulate behavior: day one, then day one plus day two, and so on until a bid can be placed and until it wins.
4. **One bid per auction.** The contract never re-bids after being outbid in the same auction. It bids early and once.
5. **Outbid.** GBM refunds the bid plus the incentive to the contract's `receive()`. Both stay in the pot. Tomorrow's bid is yesterday's pot plus the refund plus the new pull.
6. **Won.** On settlement the song (and the bidding edition) arrive at the contract via `onERC721Received`, which forwards them to `recipient`. The pot is whatever is left — normally near zero — and accumulation starts again.

The caller pays gas for `execute()`; on Base that is cents. An optional `keeperTipWei` reimbursement is a later nicety, not v1.

&#91;embedded content: daily loop · pull, swap, bid or hold, three outcomes\]

Every outcome loops back to the next day's pull; only a win empties the pot.

### Interface sketch

```solidity
contract SongADayEndowment is IERC721Receiver {
    // immutable at deploy
    YieldSkimmer skimmer;
    address recipient;        // my Splits account — songs and editions go here
    IGBMAuctionHouse house;   // GBM auction house on Base (address TBD)
    IERC721 songs;            // the Song A Day contract the house sells
    ISwapRouter router;       // fixed USDC → WETH route on Base

    // state
    uint256 lastBidAuctionId;

    // permissionless
    function execute() external;      // pull, swap, bid-or-hold
    receive() external payable;       // refunds and incentives land here
    function onERC721Received(...) external returns (bytes4); // forward to recipient

    // views
    function pot() external view returns (uint256);
    function canBidToday() external view returns (bool, uint256 auctionId, uint256 minBid);
}
```

There is no admin surface at all. Nothing is pausable or re-pointable; revocation is `skimmer.removeRecipient(this)` on the skimmer side, after which `execute()` pulls nothing and the pot stays wherever it was. If I ever need to retire the contract, a `sweep()` that sends the pot to `recipient` is the one function worth adding — and even that should be callable by anyone, since it only ever sends to `recipient`.

### Parameters

| Parameter | Value | Why |
| --- | --- | --- |
| `shareBps` on the skimmer | 4,000 | Largest single recipient for v1; the rest compounds or goes to a DCA recipient later |
| `minInterval` on the skimmer | 1 day | One auction a day |
| Bid size | Whole pot, always | No sizing logic to tune or get wrong |
| Slippage on swap | Tight, fixed | Amounts are small; a failed swap just means hold |
| Cron | Once a day, early in the auction window | Bid early and visibly |

### GBM integration unknowns

These block implementation and have to be read from the live site's frontend bundle or from GBM directly:

- [ ] Auction house contract address on Base, and whether it's a GBM diamond with a per-token-contract auction id scheme
- [ ] The bid function signature and how the current high bid, minimum increment and incentive rate are read
- [ ] Whether a bid from a contract address is allowed (some GBM deployments gate on EOA or allowlist)
- [ ] How settlement works: does the house push the NFT on close, or must the winner call `claim`? If claim, `execute()` claims yesterday's win before bidding today
- [ ] Where the bidding edition is minted and whether it is also ERC-721
- [ ] Refund path: does the outbid refund go to the bidder address via plain `call` (needs `receive()`), or is it a pull-based `claim` on the house?
- [ ] Whether the auction is in ETH or WETH on Base

## Rollout

Each step proves one thing and is a writeup on its own.

1. **Enable a no-op module.** Deploy a module that does nothing, push `enableModule` through `transactions create custom` as a self-call, confirm it lands onchain, then `disableModule` the same way. Proves the Splits platform doesn't block the module path. If this fails, everything below changes shape.
2. **Skimmer, single recipient = my own account.** Fund the endowment subaccount with a small amount, enable the skimmer with 100% share to an EOA I control, run `skim()` daily for two weeks. Proves the watermark, the ratchet, absorption and the rate cap against real Morpho V2 share-price movement and real auto-earn sweeps. Deliberately deposit and withdraw mid-run without resetting.
3. **Bidder on a test auction.** Deploy `SongADayEndowment` pointed at a GBM auction I set up myself (or a fork), fund it directly, run `execute()` through outbid and win. Proves the GBM integration and the forward-on-receive path without touching Jonathan's auction.
4. **Live, small.** Point the bidder at the real auction with a few days of accumulated yield. Let it bid. Write up what happened.
5. **Scale principal** to the amount that makes the standing bid meaningful, once a month of 4 has gone cleanly.

Steps 1 and 2 are the ones that produce something Splits can learn from regardless of whether the endowment idea goes anywhere.

## Open questions

- [ ] Does the Splits API accept a `transactions create custom` whose call target is the account itself (`enableModule` self-call), or is that filtered as platform policy? Rollout step 1 answers this; worth asking an engineer first.
- [ ] Does the Splits indexer treat `ExecutedTxFromModule` transfers correctly for accounting, or do skims show up as unexplained outflows? Matters for the writeup, not for safety.
- [ ] What is the all-in fee stack on the Earn wrapper — Splits' 20% performance fee plus whatever the base Morpho V2 vault charges, and is the management fee 0? Sets the realistic net yield and therefore how much principal a $X/day bid needs.
- [ ] Does the wrapper set a `receiveAssetsGate`? If so, confirm the account itself is allowed as receiver (the vault's own address always is; the account's should be).
- [ ] Is the Earn vault on Base, and is it the same vault for every subaccount? The skimmer's `vault` is immutable, so it must be known at deploy.
- [ ] Should the skimmer accept more than one vault/asset per account (USDC and ETH yield), or is one module per asset simpler? Leaning one per asset.
- [ ] What does today's Song A Day minimum bid and typical clearing price look like? This sets how many days of accumulation a win takes, and whether $15k of principal at \~5% is the right order of magnitude.
- [ ] Audit scope. The module has unscoped execution power; is a lightweight review by someone who reviewed SmartVault enough for an experiment-sized principal?

## References

Everything this PRD was built from, so an agent picking it up doesn't have to re-find it. Facts are as of 15 Oct 2026.

### Splits

| Source | What it's for | What it says |
| --- | --- | --- |
| [splits.org/llms.txt](https://splits.org/llms.txt) | Architecture overview | SmartVault = ERC-4337 (EntryPoint v0.7), UUPS, forked from Coinbase Smart Wallet, CREATE2-deterministic. Owner executes directly and holds sole upgrade authority; m-of-n signers (passkey + EOA, equal power, no per-op scoping). Root → treasury → subaccount ownership chain; parent recovers child by rotating signers. Action/value restrictions are platform policy, not chain-enforced. Agent access via CLI + MCP. |
| `npx -y @splits/splits-cli@latest --llms-full` | Full CLI/MCP command surface | Run it to get every command. Relevant: `transactions create custom` (arbitrary calldata — the path for the `enableModule` self-call), `accounts` (balances show Earn vault rows as shares + redemption value), earn deposit/withdraw are marked "for a human signer to approve" (API policy, not chain), auto-earn sweeps idle assets into the vault. |
| [0xSplits/splits-contracts-monorepo](https://github.com/0xSplits/splits-contracts-monorepo) → `packages/smart-vaults/src/` | Contract source | `utils/ModuleManager.sol`: Safe-style; `enableModule`/`disableModule` are `onlySelf`; `executeFromModule(Call[])` is `onlyModule` and runs arbitrary calls via the account's `_call`. `vault/SmartVault.sol`: `execute` is `onlyEntryPointOrOwner`, so the owner can self-call `disableModule` to rip a module out. `utils/Caller.sol`, `utils/FallbackManager.sol` also relevant. Also has `AGENTS.md`, `deployments/`, `test/`. Sparse-clone `packages/smart-vaults` only. |

### Morpho Vault V2 (the Earn vault)

| Source | What it says |
| --- | --- |
| [morpho-org/vault-v2](https://github.com/morpho-org/vault-v2) · [README](https://raw.githubusercontent.com/morpho-org/vault-v2/main/README.md) | ERC-4626 + ERC-2612. Performance fee (cap 50%) is a cut on interest, management fee (cap 5%/yr) is a cut on principal; both accrue by minting shares to the fee recipient, so share price is net. Optional gates: `receiveSharesGate`, `sendSharesGate`, `receiveAssetsGate`. `forceDeallocate` carries a per-adapter penalty up to 2% — never use it. Idle vs. allocated liquidity; use `maxWithdraw`. |
| [docs.morpho.org — Vault V2 concept](https://docs.morpho.org/learn/concepts/vault-v2) | Curator/allocator/sentinel roles, timelocks, adapters. |
| [docs.morpho.org — Gates](https://docs.morpho.org/curate/concepts/gates/) | How gates are configured and what they block. |
| [docs.morpho.org — Vault / fee wrapper](https://docs.morpho.org/learn/concepts/vault/) | A fee wrapper is a lightweight vault wrapping one V2 vault and adding a fee layer for a distribution channel — this is what Splits' 20% performance fee is. |

### GBM bid-to-earn auctions

| Source | What it says |
| --- | --- |
| [gbm.auction](https://gbm.auction/) | Outbid bidder gets full refund plus an incentive fixed at bid time, paid the instant they're outbid. Song A Day integrated GBM in 2022 and was still using it as of 2026. Shows Brian Armstrong bidding on a Song A Day auction on Base, Aug 2023. Case study: avg sale $118 → $396, net revenue \~3×. |
| [GBM Decentraland launch post](https://medium.com/gbm-auction/gbm-launches-bid-to-earn-auction-house-for-the-decentraland-community-0cb83b781c85) | Describes the Coupon Auction System: mainnet assets auctioned via an L2 so bidders avoid mainnet gas. This is the pattern Song A Day uses on Base. |
| [Pine Analytics — GBM auction model](https://pineanalytics.substack.com/p/the-gbm-auction-model) | Song A Day case: incentives per bid \~3× gas; avg first bid $43 → $95. |
| [web3.gbm.auction](https://web3.gbm.auction/) · [ida.gbm.auction](https://ida.gbm.auction/) | GBM is moving to an open protocol with a token; staked $GBM holders get enhanced incentive rates. Protocol runs on 5+ EVM networks. Contract addresses and ABI for the Song A Day house are **not** on any of these pages — pull from songaday.world's frontend bundle. |

### Song A Day

| Source | What it says |
| --- | --- |
| [songaday.world](https://songaday.world) | JS-rendered; the auction widget shows "Powered by GBM", ETH-denominated, minimum bid and outbid-earn % per auction. Auction contract address is in the bundle, not the HTML. |
| [OpenSea — Song A Day](https://opensea.io/collection/song-a-day) | NFT collection is on Ethereum mainnet; \~5,857 items, launched Dec 2021. |
| [Jonathan Mann on Hey, Sep 2024](https://hey.xyz/posts/p0n9cc49nsykrn4fzx) | "You get an edition just for bidding." |
| [Web3 Galaxy Brain episode](https://web3galaxybrain.com/episode/Song-A-Day-with-Jonathan-Mann-and-Edouard-Bessire-from-GBM-Auctions) | SongADAO is a Colorado co-op that owns the song copyrights; RaidGuild built the site and contracts; GBM was integrated into existing contracts. |

### Prior art (named, not fetched)

- PoolTogether — the reference point for "lossless" principal with yield as the prize.
- Nouns DAO — daily auction as perpetual funding, from the seller side.
- Safe + Zodiac Roles modifier — the mature version of scoping a key to functions and allowances; still can't express "amount ≤ accrued yield" without custom code, which is why a bespoke module is the answer here.
