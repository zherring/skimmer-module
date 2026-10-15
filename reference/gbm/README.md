# Song A Day GBM house — reference artifacts

Captured 15 Oct 2026 so the PRD's Part 2 can be implemented without re-finding anything.

| File | What | Source |
| --- | --- | --- |
| `GBM.sol` | Verified source of the current house, `0xd7829F0EFC16086a91Cf211CFbb0E4Ef29D16BEE` on Base | Sourcify exact match, `contracts/GBM/GBM.sol` |
| `house_abi.json` | Its ABI | Sourcify |
| `selectors.txt` | Function selectors with mutability, derived from the ABI | — |
| `auctions_sample.json` | 120 most recent auctions as of capture (`tokenId`, `endsAt`, `highestBid`, `highestBidder`, `firstBid`, `claimed`, …) | Goldsky subgraph `songadaygbmbase` v0.0.5 |

The house address and the subgraph URL are hardcoded in songaday.world's Next.js bundle. Load-bearing facts for the bidder contract, all confirmed against this source:

- `bid(uint256 auctionId, uint256 bidAmount, uint256 highestBid, address bidder) payable` — `0x6da79a93`, line 128. `msg.value == bidAmount`; no signature, no `tx.origin`, no `msg.sender` check.
- Contract bidders are refunded by internal credit, not push: `sendbaseCurrency` lines 482–492, `withdraw(address)` line 472.
- Bidding edition is pushed via `adminMint(_bidder, …)` inside `bid`, lines 184–187, only when `editionTokenId != 0`.
- `claim` / `claimMultiple` pay the beneficiary and transfer no NFT; the song is minted on Ethereum mainnet separately.
