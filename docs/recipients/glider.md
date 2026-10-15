# Glider as a skimmer recipient

Researched 15 Oct 2026 from [docs.glider.fi](https://docs.glider.fi) (`llms-full.txt`, the public `openapi.json`, and the guides) plus press. No authenticated endpoint was called. Labels: **confirmed** = in Glider's docs or onchain; **inferred** = our reading.

## Verdict

Viable, and the simplest recipient of the three on the table: **a plain address, no adapter contract, no key that can touch principal.** Status 15 Oct 2026: chosen as the first live recipient; enrollment waits on a Glider staging/B2B key. Glider gives each portfolio a per-chain ZeroDev Kernel smart account whose root owner can be **a Splits account** (`accountType: "ERC1271"` — Glider verifies the owner's EIP-712 signature with `isValidSignature` on Base and installs its SmartAccount sudo validator, confirmed in `guides/two-stage-enrollment`); the account is "exposed simply as a deposit address: any tokens sent there are swapped by Glider's automation into the portfolio strategy's target allocations" (confirmed, `guides/security-architecture`). So the skimmer registers that account as a recipient, a cron calls `pull(gliderAccount)` on the skimmer's `minInterval`, and Glider's rebalance schedule sweeps the USDC into the index. The DCA cadence is the skimmer's `minInterval`; Glider has no recurring-buy feature of its own (confirmed — `schedule` is the rebalance cadence, enum `hourly|daily|weekly|monthly` or cron).

What it costs in trust: Glider's offchain agent holds a user-signed, revocable session key over that one account (confirmed). Worst case is the contents of the Glider account — exactly the "buggy recipient" row of the skimmer threat model. Nothing in the model asks for an allowance on the endowment subaccount or any other account (confirmed).

## How it executes (confirmed unless marked)

- Per portfolio: one ZeroDev Kernel smart account per chain, CREATE2-deterministic, same address on every chain. Your wallet is the root owner. Glider's agent holds a KMS/HSM-backed key plus a session key you sign at enrollment; you can rotate or revoke it, and root authority stays onchain if Glider is down. Withdrawing without Glider is possible as the Kernel owner but not documented as a procedure (inferred).
- Base is supported throughout the docs, with Base USDC (`0x8335…2913`) listed as an asset. Chain list is per-environment config — don't assume it.
- Strategies: 1–50 assets (ERC-20, SPL, tokenized RWA), target weights plus a rebalance schedule. Examples: USDC/WETH mix; a "directly indexed Mag7" with Ondo (Jun 2026); Bitwise Mag7X (0.15%, non-US only). Swap prefs: `slippageBps`, `priceImpactBps`, `thresholdUsd` (min $1, example $5). Route is a whitelisted DEX aggregator; gas is paymaster-sponsored.
- Fees: the only documented fee is an integrator `swapBps` on swap output (examples 45–50 bps). A Glider platform fee is mentioned, not documented. No management, performance, deposit or withdrawal fee found. No lockups, delays or minimum deposit documented.
- Backers: a16z CSX-led $4M (Apr 2025), Coinbase Ventures, Uniswap Ventures, GSR. No Glider-specific audit found; Kernel core is audited by ZeroDev. Session-key policy audit status unknown.

## B2B API (confirmed)

`https://api.glider.fi/v2`, `x-api-key` header, keys from console.glidercloud.dev; staging at `staging-api.glider.fi` via developers@glider.fi. Scopes: `strategies:read/write`, `enroll:write`, `portfolios:read/write/withdraw`, `tenant:*`, `fees:*`. No webhooks — poll `GET /portfolios/{id}/operations/{opId}`. Key endpoints: `POST /strategies`, `PUT /strategies/{id}/schedule`, `POST /enroll/signature` → `POST /enroll` (returns `smartAccounts[].accountId` like `eip155:8453:0x…`), `GET /portfolios/{id}`, `/positions`, `POST /portfolios/{id}/start|stop|rebalance`, `POST /withdraw/signature` → `/withdraw`.

Two properties that matter for us:

- **Enrollment and withdrawal need an end-user signature** (EIP-191, or EIP-712 + ERC-1271 for a contract wallet). The API key alone cannot withdraw.
- **There is no deposit route.** "The B2B API does not expose a deposit-builder route. Transfer supported assets using the user's wallet" (`quickstart`). Deposits are plain transfers — which is what `pull()` does.

## Integration with the skimmer

1. Enroll once through the B2B API with `accountType: "ERC1271"` and a Splits account as `ownerAccountId` (the app's wallet-connect can't speak for a SmartVault), into a strategy whose targets are not USDC. The owner account needs `threshold` EOA signers you hold: the deployed SmartVault's ERC-1271 wraps the hash as `SplitMessage(bytes32)` under domain `splitsSmartVault/1` and expects `abi.encode({signerIndex, signatureData}[])`; `ops/sign-as-account/` (PR #2) builds that signature from signer keys and refuses to print it until the vault's own `isValidSignature` accepts it. Passkey signers can't be scripted — Splits' only message-signing path is an internal, session-auth, passkey-only endpoint with no threshold assembly. The treasury can still rotate the owner subaccount's signers, so custody stays in Splits. Record the Base smart-account address.
2. `addRecipient(gliderAccount, shareBps, minInterval)` on the skimmer — e.g. 3,000 bps, 7 days for weekly DCA.
3. Cron: `pull(gliderAccount)` after each interval. Glider picks the USDC up on its next scheduled rebalance, or immediately on `POST /portfolios/{id}/rebalance` (inferred — pickup timing is not documented; sub-`thresholdUsd` amounts probably wait).
4. If you hold an API key at all, scope it to `portfolios:read` + `portfolios:write` (start/stop/rebalance). Never `strategies:write` — a leaked key with that scope can retarget the allocation. Never `portfolios:withdraw` (it still needs your signature, but there's no reason to hold it).

Note rebalancing touches the whole portfolio, not only new USDC, so a daily schedule means daily swap fees on the full position; weekly or monthly is the better fit for a DCA pot.

## Open questions for Glider

1. The exact onchain session-key policy: which contracts and selectors the agent may call, the fee cap, expiry — and whether it has been audited.
2. Is a plain ERC-20 deposit picked up only on the next scheduled tick, and how are amounts under `thresholdUsd` handled?
3. Real fee schedule (platform fee, API pricing) and ToS / US eligibility for the strategies we'd use.
4. Whether a Coinbase-Smart-Wallet-derived account with its own replay-safe wrap (the Splits SmartVault) is on the "supported smart-contract wallets" list. Their verifier "re-hashes the typed-data using the wallet's own `chainId`" and then calls `isValidSignature`; if that call is a plain onchain `eth_call`, any ERC-1271 wallet works. Staging is the test.

## The purer alternative

If "no key anywhere" should hold for recipients too, a **permissionless onchain index** fits better: a tiny recipient contract whose `execute()` pulls USDC, swaps, and mints into the index directly, with nothing offchain. Candidates to look at, not researched: Reserve Protocol DTFs on Base (permissionless mint, e.g. a Mag7 DTF), Index Coop products, or simply swapping into cbBTC/WETH via Uniswap/Aerodrome. Glider is the convenient path; a DTF recipient is the one that matches the thesis exactly. Both can coexist as separate recipients with their own `shareBps`.
