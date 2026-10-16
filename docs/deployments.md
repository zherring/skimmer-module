# Deployments

## Base (8453) — Skimmer Test Team, 16 Oct 2026

Rollout step 2: the skimmer against a fresh Splits org with $10 of principal and the org's Treasury as the only recipient.

| What | Address | Notes |
| --- | --- | --- |
| YieldSkimmer | `0x0cd382EA27D5FAF909FF6de2a0f3fC33b37906EA` | CREATE2 via forge's default deployer, salt `keccak256("skimmer-module/YieldSkimmer/v1")`. Deploy tx `0xe86755946e156fecf7095241a6c975a5c486fd2312aa65f48911def69827fbed`. `capBps` 3000, `absoluteMaxPerSkim` 50 USDC. Sourcify verification submitted (job `7df665d7-be8a-49ed-9b45-df7c71fc04d7`) |
| Endowment (SmartVault subaccount) | `0x0E3Bbe2a15432e940F676547656CA043a54B96a7` | The skimmer's `account`. Three passkeys, threshold 1; owner = Treasury. Deployed and enrolled in auto-earn by Splits' first sweep of a $10 USDC deposit — no explicit first transaction was needed |
| Treasury | `0x54573275C42c3c45068a8D4da85e0473B8810521` | Test recipient, `shareBps` 10,000, `minInterval` 0 |
| Glider Owner (SmartVault subaccount) | `0x779262Cbf52a2034D92b809c6BAE9673B66D45D0` | EOA signer `0x70995E4F21C7d37f45AbCeF4545466b0071f26Db`, threshold 1; owner = Treasury. Reserved for Glider's ERC-1271 enrollment. Deployed by a zero-value self-call, tx `0xe18c0e0f384c6777c68bc27183e28c1424a3c1f4a24904c992b4b6af04321777` |
| Keeper / deployer EOA | `0xbe0CD48c0ceF3Aba744523BafF5D8320EF8b260F` | Gas only. Key in the Splits CLI keystore (`splits auth create-key --name keeper`) and in the repo's `KEEPER_PRIVATE_KEY` secret |
| Earn vault | `0x189A1a23F46321a196646314E6a078a404513C8F` | `splitsUSDC`, see the PRD |

First `skim()` (watermark initialized at 10.000004 USDC): tx `0x701f6a839d9b59afaafd201c898e2a88660775c9714fba5286474fe58aba4279`, 244,008 gas, sent with an explicit gas limit because `mainnet.base.org` estimates against a pending block on which the vault's `convertToAssets` panics (see `ops/keeper.sh`). An explainer with a simulation of the mechanics: https://claude.ai/artifact/32tf3MixdoEJBnFhXPU4Dh.

Enable + first recipient went in as one custom transaction from the Endowment: `enableModule(skimmer)` then `addRecipient(Treasury, 10000, 0)`. The Splits CLI's `--calls` flag rejects JSON in 0.3.0, so the proposal was created through the CLI's `--mcp` mode (`transactions_create_custom`).
