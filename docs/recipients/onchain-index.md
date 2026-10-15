# Permissionless index targets on Base

The fallback if Glider doesn't work out: a ~100-line recipient contract that pulls USDC, swaps under a 30-minute TWAP bound, and forwards the output to the Splits account. No key, no platform. Researched 15 Oct 2026 onchain (quotes at ETH ≈ $2,455, BTC ≈ $82.2k); **confirmed** unless marked.

## What a single onchain call can buy

| Target | Entry point | $50 / $500 buy | TWAP | Notes |
| --- | --- | --- | --- | --- |
| **cbBTC** | Uniswap v3 0.05% USDC/cbBTC `0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef`, `exactInputSingle` on SwapRouter02 | 0.00060832 / 0.00608322 cbBTC, impact ≈ 0 beyond the fee | cardinality 2,000 | ~$9.7M TVL. The cleanest option |
| **WETH** | Uniswap v3 0.05% `0xd0b53D9277642d899DF5C87A3966A349A798F224` | see PRD | cardinality 5,000 | Same pattern as the bidder's swap |
| LCAP — CF Large Cap Index (Reserve DTF) `0x4da9a0f397db1397902070f93a4d6ddbc0e0e6e8` | Aerodrome Slipstream USDC/LCAP `0xC8C15670050541255f9b797C008047682524861F`, router `0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5` (takes `tickSpacing` 200 and a deadline, not SwapRouter02's ABI) | 7.2159 / 72.132 LCAP ≈ $6.93 each, ~0.7% over NAV incl. 0.3% fee | cardinality 360, Uniswap-style `observe` | Pool ~$150k. Basket (inferred from the Reserve API): cbBTC 42%, WETH 21%, cbXRP 13%, SOL 11%, HYPE 9%, dust. DTF fees: 0.3% mint, 1.5%/yr TVL. Admin/rebalance roles behind 48 h timelocks |
| BGCI — Bloomberg Galaxy Crypto Index `0x23418de10d422ad71c9d5713a2b8991a9c586443` | Two-hop `exactInput` USDC→WETH (500)→BGCI (3000), pool `0xD38d1AB8A150e6eE0AE70C86A8E9Fb0c83255b76` | 24.049 / 240.465 BGCI, 0.35% over NAV | cardinality 10 — must call `increaseObservationCardinalityNext` first (~1M gas), and a two-hop TWAP sums two pools | One LP holds ~84% of supply. 2%/yr TVL fee. Second-best |

## What is not reachable without offchain data

- **Reserve `Folio.mint`** pulls every basket token pro rata; USDC-only minting goes through their zapper, whose calldata comes from `api.reserve.org` (~26 KB, ~12M gas for a $50 zap). Not callable from a contract.
- **Index Coop on Base**: every diversified product (DPI, MVI, dsETH, hyETH) has dust supply; FlashMint needs 0x or caller-supplied DEX paths. Nothing live and liquid.
- **AMKT**: ~$10k supply, a $55 pool. **Phuture, Cook, Bitwise, Ondo, xStocks**: no Base deployment found (inferred).
- Other Reserve DTFs (ABX, CLX, VTF, MVTT10F): under $150k each, 1.5–6% over NAV, or not diversified.

## Recommendation

A fixed **cbBTC/WETH** split (50/50 or 60/40) is the practical "index": both pools are deep and TWAP-ready, and it is ~63% of what LCAP holds anyway. LCAP is an optional third leg if altcoin exposure matters more than its premium, fee and thin-pool risk. Rebalancing is not worth building at $5–50 a week.
