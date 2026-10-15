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

1. **Read the position.** `assets = vault.convertToAssets(vault.balanceOf(account))`. The wrapper is a stock Morpho `VaultV2` (ERC-4626, 18-decimal shares); its fees accrue by minting shares to the fee recipient (`VaultV2.sol:636-680`), so share price — and therefore this number — is net of all fees.
2. **Ratchet down.** If `assets < principal`, set `principal = assets`. In a lending vault the only way assets fall below the watermark is a withdrawal I made, or a vault loss; either way the watermark follows. Withdrawals never need announcing.
3. **Absorb implausible inflows.** `ceiling = principal × capBps × elapsed / (365 days × 10,000)`. If `assets − principal > ceiling`, the excess over the ceiling cannot be yield; treat it as a deposit and fold it into `principal`. A forgotten $10k deposit becomes principal on the next poke, not a $10k skim. False positives only compound.
4. **Compute the skim.** `yield = min(assets − principal, ceiling, absoluteMaxPerSkim)`. The rate cap bounds any single failure to one period of allowance. There is no liquidity term: on Morpho V2 `maxWithdraw`, `maxRedeem`, `maxDeposit` and `maxMint` are hard-coded `pure … return 0` (`VaultV2.sol:726-742`), and real liquidity sits three hops down (wrapper → `MorphoVaultV1Adapter` → steakUSDC → `MorphoMarketV1AdapterV2` → Morpho Blue). A skim the vault can't serve reverts and is retried on the next poke; at this size that is tens of dollars against ~$157M of free liquidity in steakUSDC's terminal market. Never call `forceDeallocate` — the wrapper's penalty is 2%, the contract maximum.
5. **Execute one batch** via `executeFromModule(Call[])` (selector `0xde77d70e`): `vault.withdraw(yield, account, account)` then `USDC.transfer(module, yield)`. The account is `msg.sender == onBehalf`, so no share allowance is needed. All four gates on the wrapper are zero and their setters are abdicated, so this path can never be gated later. Moving the USDC out in the same batch matters: `AutoEarnModuleV2.deposit(account)` is permissionless and sweeps the account's entire USDC balance back into the vault.
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

All admin is `onlyAccount`: the call must come from the endowment subaccount itself, which means a threshold-signed Splits transaction — and the platform adds no policy of its own on custom self-calls, so the threshold must include a human. The treasury account, as owner, can also reach it via `execute`.

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
| `vault` | `0x189A1a23F46321a196646314E6a078a404513C8F` (`splitsUSDC`) | The one pooled Earn USDC vault on Base. Confirm the endowment subaccount is enrolled on it and not the legacy Aave vault (`0x4EA71A20e655794051D1eE8b6e4A3269B13ccaCc`, still holding ~$547k) before baking it in as immutable |
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
| Module bug that reaches `executeFromModule` with arbitrary calls | **Full subaccount** — a module has unscoped execution power onchain, including everything `onlySelf` (`MultiSignerAuth`: add/remove signers, change threshold; enabling further modules) | Keep principal in its own subaccount. Upgrades and `execute` are `onlyOwner`, which a module cannot reach, so the treasury can always `disableModule` via `execute` even after a signer rotation; audit |
| Vault loss or depeg | Principal ratchets down; nothing skims | Vault choice, not the module |
| steakUSDC curator raises fees | Net yield drops — the underlying's fee setters have a **0 timelock** (caps 50% performance, 5% management) | Principal untouched; the ratchet absorbs it; vault choice |
| Wrapper allocator repoints the liquidity adapter | Withdrawals stall until liquidity is restored; only `forceDeallocate` (2%) frees them early | Skim reverts and waits; principal stays in the vault. One address holds owner, curator and allocator on the wrapper |
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

Everything below was read from the verified house source and live state on 15 Oct 2026 (addresses in References). It replaces the earlier guess that GBM's cross-chain coupon system is involved — it isn't.

**The house.** `0xd7829F0EFC16086a91Cf211CFbb0E4Ef29D16BEE` on Base: a plain `GBM.sol`, not a proxy, not a diamond, not upgradeable (songs #5914 onward; `0xEaedaDe6A47b08f21C6c0B319024c6fedA3E6539` served #5845–5913). Native ETH only. The owner is an EIP-7702-delegated EOA that registers each day's auction by hand with `registerAnAuctionTokenSongAdao` somewhere between 09:32 and 22:xx UTC, can move start/end times mid-auction, and can pause bidding per collection with `setBiddingAllowed`. No platform fee on bids.

**Bidding.** `bid(uint256 auctionId, uint256 bidAmount, uint256 highestBid, address bidder) payable` (`0x6da79a93`). `msg.value` must equal `bidAmount` and `highestBid` must equal the current high bid (read it in the same call; no race). No signature, no `tx.origin`, no allowlist, no check on `msg.sender`: a contract can bid, confirmed by a fork call from a contract address and by a live multicall-routed bid. Minimum next bid is `ceil(high × 1.1)`; a first bid only needs 2 wei. Parameters: `bidDecimals` 100,000, `stepMin` 10%, `incMin` 1%, `incMax` 10%, `bidMultiplier` 11,000, hammer time 300 s. The outbid incentive is `bid × min(10%, 1% + 0.11 × (bid − 1.1·prev) / (1.1·prev))`, so a first bid earns 10%; incentives come out of the seller's proceeds at claim, not out of the new bidder.

**Auction ids.** `keccak256(abi.encodePacked(songContract, tokenId, bytes4(0x73ad2146)))`, exposed as `getAuctionIDSongADao(address,uint256)`. There is no "latest auction" getter. `tokenId` is the day count since 2009-01-01 inclusive (#6497 on 15 Oct 2026). A bid on an unregistered id reverts. Auctions open at registration and usually close at 20:43:59 UTC the next day, so two are often live at once; a bid in the last 300 s extends the end to bid time + 300 s.

**Refunds.** If the outbid bidder has code, the house does not push: it credits `bid + dueIncentives` internally, and anyone can call `withdraw(address)` to send it to that address (`GBM.sol:472-492`). `receive()` is only hit inside `withdraw`, and a reverting `receive()` only makes `withdraw` revert — nothing is lost and nothing can block the auction.

**Settlement — the important one.** `claim`/`claimMultiple` (anyone can call) send `highestBid − incentives` to the beneficiary and transfer no NFT. The Song A Day contract (`0x19b703f65aA7E1E775BD06c2aa0D0d08c80f1C45`) exists only on Ethereum mainnet. The song is minted there by the operator wallet (`0xabA3A04FC85Fd7bBC2538E708e9E30bbc59899C3`) and transferred to the Base `highestBidder` address, in batches, days to weeks after the auction (recent batches: 8 Apr, 19 May, 28 Jun, 7 Jul, 24 Jul, 24 Aug, 6 Sep, 6 Oct 2026; for 30+ sampled auctions mainnet `ownerOf` equals the Base winner). So a contract that exists only on Base can never hold its winnings — hence the mainnet twin below. Whether the operator uses `safeTransferFrom` or `transferFrom` is unknown; design for plain `transferFrom`.

**The bidding edition.** A Zora Creator ERC-1155 on Base (`0xb3bad5fE12268EDC8a52Ff786076C1D1fA92eF0d`), minted to `bidder` inside the first bid via `adminMint` (`GBM.sol:184-187`) whenever the auction's `editionTokenId` is non-zero. It has been 0 since #6076 (Aug 2025), but the owner can switch it back on at any time, and Zora's mint calls `onERC1155Received` on contracts — a bidder without that hook would start reverting.

**What the market looks like.** Last 60 ended auctions (#6436–#6495, 17 Aug–14 Oct 2026): 56 sold, 4 unsold. Winning bids min 0.0001 / median 0.0021 / mean 0.00287 / max 0.015 ETH; 1.55 bids per auction on average; one bot (`0xBb7e…8Ae5`) won 38 of the 56. Live on 15 Oct: #6497 high bid 0.0012 ETH, #6496 high bid 0.003 ETH. Same chain as the Earn vault, so gas is cents and no bridging is needed.

### Mechanics

The contract holds one pot of ETH and runs one permissionless `execute()` a day. It is deployed at the same address on Base and Ethereum mainnet (CREATE2 through a deterministic deployer, same salt and initcode; the constructor reads no chain state so the initcode is identical). On Base it bids; on mainnet it is inert except for `forward`, which is how won songs get home. Rules, in order:

1. **Pull.** `skimmer.pull(this)` — collects whatever yield share has accrued since yesterday (USDC).
2. **Collect.** If `house.getWithdrawBalance(this) > 0`, call `house.withdraw(this)`. Outbid refunds and incentives are credited to a contract bidder internally, never pushed, so this is where they re-enter the pot.
3. **Swap.** USDC → native ETH on a fixed DEX route on Base (WETH out, unwrapped in the same call). The pot is the contract's ETH balance; there is no other accounting.
4. **Find the auction.** `tokenId = days since 2009-01-01, inclusive` for today and for yesterday (UTC); `id = house.getAuctionIDSongADao(songs, tokenId)`. A candidate is registered (`getAuctionEndTime(id) != 0`), not ended, and not already bid on (`tokenId > lastBidTokenId`). Prefer today's. None → hold.
5. **Bid or hold.** `minNext = max(ceil(high × 1.1), minBidWei)`. If `pot ≥ minNext`, `bid{value: pot}(id, pot, high, address(this))` with `high` read in the same transaction. If not, do nothing; tomorrow's pull makes the pot bigger. This is the accumulate behavior: day one, then day one plus day two, and so on until a bid can be placed and until it wins. Bidding the whole pot is deliberate: the pot is only ever accumulated yield, so paying more than the bot-clearing price (~0.002 ETH) is the endowment doing its job, not a bug. There is no overpayment refund in an English auction, and the pot is bounded by the yield rate.
6. **One bid per auction.** Set `lastBidTokenId`. The contract never re-bids after being outbid in the same auction; it bids early and once.
7. **Outbid.** The house credits bid + incentive to this address; step 2 collects it tomorrow. Tomorrow's bid is yesterday's pot plus the refund plus the new pull.
8. **Won.** Nothing arrives on Base. Days to weeks later the operator mints the song on mainnet to this address; anyone calls `forward(songs, tokenId)` on the mainnet twin to send it to `recipient`. If an edition was minted, `onERC1155Received` accepts it and `forward` sends it to `recipient` on Base. The pot is whatever is left — normally near zero — and accumulation starts again.

The caller pays gas for `execute()` (a bid with an end-time extension is ~125k gas); on Base that is cents. An optional `keeperTipWei` reimbursement is a later nicety, not v1.

&#91;embedded content: daily loop · pull, swap, bid or hold, three outcomes\]

Every outcome loops back to the next day's pull; only a win empties the pot.

### Interface sketch

```solidity
contract SongADayEndowment is IERC721Receiver, IERC1155Receiver {
    // immutable at deploy — Base addresses; meaningless but harmless on the mainnet twin
    YieldSkimmer skimmer;
    address recipient;        // my Splits account — songs (mainnet) and editions (Base) end here
    IGBM house;               // 0xd7829F0EFC16086a91Cf211CFbb0E4Ef29D16BEE
    address songs;            // 0x19b703f65aA7E1E775BD06c2aa0D0d08c80f1C45 — mainnet SAD contract; on Base only an auction-id input
    ISwapRouter router;       // fixed USDC → native ETH route on Base
    uint256 minBidWei;        // floor so a first bid is never dust (the house accepts 2 wei)

    // state
    uint256 lastBidTokenId;

    // permissionless
    function execute() external;      // pull, collect, swap, find auction, bid-or-hold
    receive() external payable;       // house.withdraw() and swap output land here
    function forward(address token, uint256 id) external;   // any ERC-721/1155 held → recipient; the mainnet twin's only job
    function sweep() external;                               // pot → recipient; retirement only
    function onERC721Received(...) external returns (bytes4);  // accept (if the operator ever uses safeTransferFrom)
    function onERC1155Received(...) external returns (bytes4); // accept the bidding edition without reverting the bid

    // views
    function pot() external view returns (uint256);          // balance + house.getWithdrawBalance(this)
    function todayTokenId() external view returns (uint256);
    function canBidToday() external view returns (bool, uint256 auctionId, uint256 minBid);
}
```

There is no admin surface at all. Nothing is pausable or re-pointable; revocation is `skimmer.removeRecipient(this)` on the skimmer side, after which `execute()` pulls nothing and the pot stays wherever it was. `forward` and `sweep` are the only ways anything leaves other than as a bid, and both can only send to `recipient`, so anyone may call them. `recipient` has to be reachable on mainnet as well as Base: a Splits account is CREATE2-deterministic, so the same address works on both chains once it is deployed there, and a song forwarded to it before that simply waits.

### Parameters

| Parameter | Value | Why |
| --- | --- | --- |
| `shareBps` on the skimmer | 4,000 | Largest single recipient for v1; the rest compounds or goes to a DCA recipient later |
| `minInterval` on the skimmer | 1 day | One auction a day |
| Bid size | Whole pot, always | No sizing logic to tune or get wrong; the pot is only ever yield, so overpaying the bot-clearing price is the point |
| `minBidWei` | 0.0005 ETH (≈ a quarter of the median win) | The house accepts 2 wei. A bid that is sure to be outbid costs Jonathan the incentive out of his proceeds, so never place dust |
| Slippage on swap | Tight, fixed | Amounts are small; a failed swap just means hold |
| Cron | Once a day, ~23:00 UTC | After the owner's registration window (09:32–22:xx UTC) and after yesterday's 20:43:59 UTC close, so exactly one auction is live and ours is the early, visible bid |
| Deployment | CREATE2, same address on Base and mainnet | Won songs are minted on mainnet to the Base winner's address |

### GBM integration — answered

Read from the verified house source (`reference/gbm/GBM.sol`) and live state on 15 Oct 2026; the detail is in "The auction, as found" above.

- [x] House: `0xd7829F0EFC16086a91Cf211CFbb0E4Ef29D16BEE` on Base. Plain contract, not a diamond, not a proxy. Auction id = `keccak256(songContract, tokenId, 0x73ad2146)` via `getAuctionIDSongADao`; `tokenId` = days since 2009-01-01 inclusive; no "latest" getter, so the caller derives today's id.
- [x] `bid(uint256 auctionId, uint256 bidAmount, uint256 highestBid, address bidder) payable`. Current high bid via `getAuctionHighestBid`; minimum next = `ceil(high × 1.1)`; incentive via `getAuctionDueIncentives` and the `getAuction{StepMin,IncMin,IncMax,BidMultiplier,BidDecimals}` getters.
- [x] Contracts can bid: no signature, `tx.origin`, allowlist or `msg.sender` check. Confirmed by a fork call and a live multicall-routed bid.
- [x] Settlement: `claim` sends proceeds to the beneficiary only. No NFT on Base; the song is minted on mainnet to the Base winner by the operator, days to weeks later. Hence the mainnet twin and `forward`.
- [x] Edition: Zora Creator 1155 on Base (`0xb3bad5fE12268EDC8a52Ff786076C1D1fA92eF0d`), pushed via `adminMint` inside the first bid when `editionTokenId != 0` (0 since Aug 2025, owner can re-enable). Needs `onERC1155Received`.
- [x] Refunds to contracts are credited internally; pull with `withdraw(address)`, anyone can call. `receive()` is only hit inside that call.
- [x] Native ETH, `msg.value == bidAmount`. No WETH anywhere in the house.

## Rollout

Each step proves one thing and is a writeup on its own.

1. **Enable a no-op module.** Deploy a module that does nothing, push `enableModule` through `transactions create custom` as a self-call, confirm it lands onchain, then `disableModule` the same way. Proves the Splits platform doesn't block the module path. The backend code says it won't (no filter on custom self-calls, only a revert simulation), but this is the onchain proof. If it fails, everything below changes shape.
2. **Skimmer, single recipient = my own account.** Fund the endowment subaccount with a small amount, confirm `isModuleEnabled(AutoEarnModuleV2)` and that its shares are in `splitsUSDC` rather than the legacy Aave vault, enable the skimmer with 100% share to an EOA I control, run `skim()` daily for two weeks. Proves the watermark, the ratchet, absorption and the rate cap against real Morpho V2 share-price movement and real auto-earn sweeps. Deliberately deposit and withdraw mid-run without resetting.
3. **Bidder on a fork.** Registering an auction on the live house is `onlyOwner`, so this runs on a Base fork: deploy `SongADayEndowment`, fund it directly, register a test auction as the house owner, run `execute()` through outbid (collect via `withdraw`) and win. On a mainnet fork, deploy the twin at the same CREATE2 address, `transferFrom` a Song A Day token to it from the operator address, and `forward` it to `recipient`. Also flip `editionTokenId` on and confirm the 1155 hook. Proves the GBM integration and both delivery paths without touching Jonathan's auction.
4. **Live, small.** Point the bidder at the real auction with a few days of accumulated yield. Let it bid. Write up what happened.
5. **Scale principal** to the amount that makes the standing bid meaningful, once a month of 4 has gone cleanly.

Steps 1 and 2 are the ones that produce something Splits can learn from regardless of whether the endowment idea goes anywhere.

## Open questions

- [x] **API policy on the self-call.** Read from the backend: a custom transaction has no self-call, selector, target or value filter — the public schema takes any target and 1–20 calls, and the only gate is the account's signers and threshold. Creation runs a gas-estimation simulation, so a reverting `enableModule` is rejected up front rather than landing as a failed tx. The treasury → subaccount path (`proposals custom` on the treasury carrying `execute(sub, enableModule(…))`) works the same way; the Earn 1.0 → 2.0 migration already uses it. One consequence: a 1-of-N subaccount whose only signer is an agent key can enable a module on itself with no human step, so the endowment subaccount keeps a human in its threshold (or enables via the treasury). The "for a human signer to approve" label is CLI text on earn deposit/withdraw only; nothing server-side applies it to custom calls. Rollout step 1 still proves it onchain.
- [x] **Indexer.** Skims will show up as unexplained outflows. The indexer carries `EnabledModule` / `DisabledModule` / `ExecutedTxFromModule` only as ABI entries and records modules only for auto-earn. A module-initiated USDC transfer is captured as a plain outbound transfer with no reason ("Transferred X to …"), and the feed hides a transfer only when its tx hash matches a Splits transaction, so each skim appears standalone. Earn balances are read live at query time (`previewRedeem`), so the position itself displays correctly. The docs say module calls appear in the feed; that isn't implemented yet. Writeup material, not a safety issue.
- [x] **Fee stack.** Wrapper `performanceFee` 20% (3-day timelock), `managementFee` 0. Underlying steakUSDC 0 / 0, but its fee setters have a **0 timelock** (caps 50% / 5%). Morpho Blue market fee 0 on all five markets. Net ≈ 3.75% today (Morpho API `netApy` 3.748%; onchain share price over exactly 30 days gives 3.56% compounded, 3.73% over 7 days). `net = underlying_net × 0.8`.
- [x] **Gates.** All four gates on the wrapper are zero and all four setters are abdicated — permanently ungated. `withdraw(x, account, account)` from the account itself succeeds in an `eth_call` and in a real tx (`0x4f8c7c82…06b6`).
- [x] **Vault.** One pooled vault per asset per chain; Base USDC is `0x189A1a23F46321a196646314E6a078a404513C8F` (`splitsUSDC`), ~7–8 weeks old. Earn on Base is USDC only (no ETH). A legacy Aave vault (`0x4EA7…caCc`) still holds ~$547k — check which one the subaccount is on.
- [x] **One module per (vault, asset).** Decided. `vault` and `asset` stay immutable; a second asset is a second instance. Moot on Base today since Earn is USDC only.
- [x] **Market.** Median winning bid 0.0021 ETH, mean 0.00287, max 0.015 over the last 60 auctions; ~1.5 bids per auction; one bot wins two-thirds. Sizing: daily yield to the bidder = `principal × 0.0375 × shareBps/10,000 ÷ 365`, so at 40% share $15k gives ≈ $0.62/day and $100k ≈ $4.10/day. Days of accumulation to a median bid = `0.0021 × ETHUSD ÷ daily`. $15k is enough to bid every week or two; a daily standing bid at the median needs principal in the low six figures.
- [ ] **Audit scope.** Proposed: a lightweight review by someone who has reviewed SmartVault is enough for steps 1–4, given the module's outbound calls are fixed to `vault.withdraw` + `asset.transfer`, each skim is bounded by `absoluteMaxPerSkim`, and the subaccount holds only endowment capital. Step 5 (scaling principal) is where a fuller review is warranted. Needs a decision.
- [ ] **Mainnet twin.** Which deterministic deployer to use so Base and mainnet addresses match (Arachnid's deterministic-deployment proxy, `0x4e59b44847b379578588920cA78FbF26c0B4956C`, is on both), and whether `recipient` (my Splits account) is deployed on mainnet or only counterfactual there.
- [ ] **Swap route.** Which fixed USDC → native-ETH route on Base (Uniswap v3 `exactInputSingle` + `unwrapWETH9`, or Aerodrome), and the slippage bound for dust-sized swaps.
- [ ] **Delivery call.** Whether the operator delivers songs with `safeTransferFrom` (hook fires) or `transferFrom` (needs `forward`). Design for plain `transferFrom`; confirm from a delivery tx on mainnet.
- [ ] **Day boundary.** Which timezone the operator's "today" uses for `tokenId` (registration at 09:32–22:xx UTC suggests US daytime). `execute()` sidesteps it by trying today and yesterday in UTC, but the cron hour should be checked against a week of registrations.

## References

Everything this PRD was built from, so an agent picking it up doesn't have to re-find it. Facts are as of 15 Oct 2026.

### Verified onchain, 15 Oct 2026

Read with `cast` against Base (block ~52,653,000) and Sourcify. The house source and ABI are checked in under `reference/gbm/`.

| What | Chain | Address | Notes |
| --- | --- | --- | --- |
| Splits Earn USDC (`splitsUSDC`) | Base | `0x189A1a23F46321a196646314E6a078a404513C8F` | Morpho `VaultV2`, not a proxy, 18-dec shares, TVL ~$4.7M. Owner / curator / sole allocator `0x5d8B947cE5853Bd8e5CacA8a7c39EAcA452b6752`; fee recipient `0x020dB5827cdC1b270Ece1F75c07aa6b841Cd2e05` |
| Its only adapter and liquidity adapter | Base | `0x20E7dc9657EA77EF9a1EBfc50e404795183B3115` | `MorphoVaultV1Adapter` → steakUSDC; `forceDeallocate` penalty 2% |
| Steakhouse Prime USDC (steakUSDC) | Base | `0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9` | Also a `VaultV2`, TVL ~$169M, fees 0 / 0 with 0-timelock setters; curator is a 3-of-9 Safe |
| steakUSDC adapter | Base | `0xfDd31Cdf6712c47A4e67037D9F2E35587f5404C0` | `MorphoMarketV1AdapterV2`, 5 Morpho Blue markets, penalty 0.001% |
| AutoEarnModuleV2 | Base | `0x4A5aCfc49597D1D326221cd159d42817918B9F5f` | `VAULT` immutable = wrapper; `deposit(account)` permissionless, sweeps the full USDC balance |
| AutoEarnEnrollerModule | Base | `0xcb74048F89B6cADA4C6C7903662BDC465e6A7De6` | Enables AutoEarnModuleV2 on a treasury and its subaccounts |
| Legacy Aave vault (`stataBasUSDC`) | Base | `0x4EA71A20e655794051D1eE8b6e4A3269B13ccaCc` | ~$547k still in it; old module `0x204DDc725f37786072a4D4102CBF3945F3597D13` |
| SmartVaultFactory | Base | `0x8E6Af8Ed94E87B4402D0272C5D6b0D47F0483e7C` | Sourcify exact match |
| SmartVault implementation | Base | `0x15ec0Fa66A0D96a64d67C58368641fBE9325F3FA` | Exact match; `ModuleManager.sol` byte-identical to repo main. `enableModule` `0x610b5925`, `disableModule` `0xa95f5246`, `isModuleEnabled` `0x2d9ad53d`, `executeFromModule(Call)` `0x57c94f2e`, `executeFromModule(Call[])` `0xde77d70e`; also `setupAndEnableModule` `0x92c4e7d5`, `teardownAndDisableModule` `0x0ae3f1f2`. Accounts upgrade individually — check the target's ERC-1967 slot |
| GBM house, current (#5914+) | Base | `0xd7829F0EFC16086a91Cf211CFbb0E4Ef29D16BEE` | Plain `GBM.sol`, Sourcify exact match. Owner `0x3d9456Ad6463a77bD77123Cb4836e463030bfAb4` (7702-delegated EOA); beneficiary `0x23D3343D3C6De7ab7764f8133953F67aFF331952` |
| GBM house, old (#5845–5913) | Base | `0xEaedaDe6A47b08f21C6c0B319024c6fedA3E6539` | Verified |
| Song A Day (SAD) ERC-721 | Mainnet only | `0x19b703f65aA7E1E775BD06c2aa0D0d08c80f1C45` | No code on Base. Operator / minter `0xabA3A04FC85Fd7bBC2538E708e9E30bbc59899C3` |
| Bidding edition | Base | `0xb3bad5fE12268EDC8a52Ff786076C1D1fA92eF0d` | Zora Creator 1155 proxy → `0x5eb5babcefea846b220c82f222f00df95934f5f0` |
| Dominant bidder bot | Base | `0xBb7e1373c448575C4086B8153437109ef6198Ae5` | Won 38 of the last 56 sold auctions |

### Splits

| Source | What it's for | What it says |
| --- | --- | --- |
| [splits.org/llms.txt](https://splits.org/llms.txt) | Architecture overview | SmartVault = ERC-4337 (EntryPoint v0.7), UUPS, forked from Coinbase Smart Wallet, CREATE2-deterministic. Owner executes directly and holds sole upgrade authority; m-of-n signers (passkey + EOA, equal power, no per-op scoping). Root → treasury → subaccount ownership chain; parent recovers child by rotating signers. Action/value restrictions are platform policy, not chain-enforced. Agent access via CLI + MCP. |
| `npx -y @splits/splits-cli@latest --llms-full` | Full CLI/MCP command surface | Run it to get every command. Relevant: `transactions create custom` (arbitrary calldata — the path for the `enableModule` self-call), `accounts` (balances show Earn vault rows as shares + redemption value), earn deposit/withdraw are marked "for a human signer to approve" (API policy, not chain), auto-earn sweeps idle assets into the vault. |
| [0xSplits/splits-contracts-monorepo](https://github.com/0xSplits/splits-contracts-monorepo) → `packages/smart-vaults/src/` | Contract source | `utils/ModuleManager.sol`: Safe-style; `enableModule`/`disableModule` are `onlySelf`; `executeFromModule(Call[])` is `onlyModule` and runs arbitrary calls via the account's `_call`. `vault/SmartVault.sol`: `execute` is `onlyEntryPointOrOwner`, so the owner can self-call `disableModule` to rip a module out. `utils/Caller.sol`, `utils/FallbackManager.sol` also relevant. Also has `AGENTS.md`, `deployments/`, `test/`. Sparse-clone `packages/smart-vaults` only. |

### Morpho Vault V2 (the Earn vault)

| Source | What it says |
| --- | --- |
| [morpho-org/vault-v2](https://github.com/morpho-org/vault-v2) · [README](https://raw.githubusercontent.com/morpho-org/vault-v2/main/README.md) | ERC-4626 + ERC-2612. Performance fee (cap 50%) is a cut on interest, management fee (cap 5%/yr) is a cut on principal; both accrue by minting shares to the fee recipient, so share price is net. Optional gates: `receiveSharesGate`, `sendSharesGate`, `receiveAssetsGate`. `forceDeallocate` carries a per-adapter penalty up to 2% — never use it. **`maxWithdraw` / `maxRedeem` / `maxDeposit` / `maxMint` are hard-coded to return 0** (`VaultV2.sol:726-742`); liquidity is idle + `liquidityAdapter` and there is no reliable onchain view of it. |
| [docs.morpho.org — Vault V2 concept](https://docs.morpho.org/learn/concepts/vault-v2) | Curator/allocator/sentinel roles, timelocks, adapters. |
| [docs.morpho.org — Gates](https://docs.morpho.org/curate/concepts/gates/) | How gates are configured and what they block. |
| [docs.morpho.org — Vault / fee wrapper](https://docs.morpho.org/learn/concepts/vault/) | A fee wrapper is a lightweight vault wrapping one V2 vault and adding a fee layer for a distribution channel — this is what Splits' 20% performance fee is. |

### GBM bid-to-earn auctions

| Source | What it says |
| --- | --- |
| [gbm.auction](https://gbm.auction/) | Outbid bidder gets full refund plus an incentive fixed at bid time, paid the instant they're outbid. Song A Day integrated GBM in 2022 and was still using it as of 2026. Shows Brian Armstrong bidding on a Song A Day auction on Base, Aug 2023. Case study: avg sale $118 → $396, net revenue \~3×. |
| [GBM Decentraland launch post](https://medium.com/gbm-auction/gbm-launches-bid-to-earn-auction-house-for-the-decentraland-community-0cb83b781c85) | Describes the Coupon Auction System: mainnet assets auctioned via an L2 so bidders avoid mainnet gas. This is the pattern Song A Day uses on Base. |
| [Pine Analytics — GBM auction model](https://pineanalytics.substack.com/p/the-gbm-auction-model) | Song A Day case: incentives per bid \~3× gas; avg first bid $43 → $95. |
| [web3.gbm.auction](https://web3.gbm.auction/) · [ida.gbm.auction](https://ida.gbm.auction/) | GBM is moving to an open protocol with a token; staked $GBM holders get enhanced incentive rates. Protocol runs on 5+ EVM networks. Contract addresses and ABI for the Song A Day house are not on any of these pages; they are hardcoded in songaday.world's Next.js bundle (chunk `69-*.js`) next to a Goldsky subgraph URL that indexes the house events, and the source is verified on Sourcify. |

### Song A Day

| Source | What it says |
| --- | --- |
| [songaday.world](https://songaday.world) | JS-rendered; the auction widget shows "Powered by GBM", ETH-denominated, minimum bid and outbid-earn % per auction. Auction contract address is in the bundle, not the HTML. |
| [OpenSea — Song A Day](https://opensea.io/collection/song-a-day) | NFT collection is on Ethereum mainnet; \~5,857 items, launched Dec 2021. |
| [Jonathan Mann on Hey, Sep 2024](https://hey.xyz/posts/p0n9cc49nsykrn4fzx) | "You get an edition just for bidding." |
| [Web3 Galaxy Brain episode](https://web3galaxybrain.com/episode/Song-A-Day-with-Jonathan-Mann-and-Edouard-Bessire-from-GBM-Auctions) | SongADAO is a Colorado co-op that owns the song copyrights; RaidGuild built the site and contracts; GBM was integrated into existing contracts. |
| [Goldsky subgraph `songadaygbmbase`](https://api.goldsky.com/api/public/project_cls54edc9ynxy01tq9ibk30n4/subgraphs/songadaygbmbase/v0.0.5/gn) | Song A Day's own index of the house on Base: `auctions { tokenId endsAt highestBid highestBidder firstBid claimed }` and bids. Public RPCs refuse historical `eth_getLogs`, so this is the practical source for history; cross-checked against live `getAuctionHighestBid`. A 120-auction sample is in `reference/gbm/auctions_sample.json`. |
| `reference/gbm/` in this repo | `GBM.sol` (Sourcify exact match for `0xd782…6BEE`), `house_abi.json`, `selectors.txt`, the subgraph sample. |

### Prior art (named, not fetched)

- PoolTogether — the reference point for "lossless" principal with yield as the prize.
- Nouns DAO — daily auction as perpetual funding, from the seller side.
- Safe + Zodiac Roles modifier — the mature version of scoping a key to functions and allowances; still can't express "amount ≤ accrued yield" without custom code, which is why a bespoke module is the answer here.
