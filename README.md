# WIF Agent Arena

An hourly $WIF showdown on Robinhood Chain, built for the worldisflat.fun hackathon.

Three agents — Momentum, Mean-reversion, Breakout — fight for one pot. Users back an agent with $WIF (100 to 100,000 per enter). When the hour ends, anyone can settle the round: the **V3 contract computes the winner itself** from Uniswap V4 WIF/ETH pool prices recorded during the round (no owner, nobody chooses the winner). 50% of the pot goes to the winner's backers (pro-rata by $WIF backed), 30% burns via `$WIF.burn()`, 20% seeds the next round.

See [SECURITY.md](SECURITY.md) for an honest self-review of known issues (tie-break wins, predictable outcome near round end, stranded prizes, spot-price manipulation, liveness).

## Live

- Web: https://wif-agent-arena.vercel.app
- Vercel Root Directory: `frontend/`

## Contracts (Robinhood Chain, chain ID 4663)

- **V3 (current, used by the web and the submission; hourly, no owner, winner computed onchain):** `0x845d23dBD7290d7469C4f9f012f44277cbE7702E`
  - Source verified on Sourcify (Exact Match, solc 0.8.38) · not audited
  - See `contracts/WifAgentArenaV3.sol` and `contracts/WifAgentArenaV3-DESIGN.md`
- **V2 (hourly, owner-settled — superseded by V3, untouched):** `0x2da0A8B64843a2bdCeFC78C69F48f549C4fdE160`
  - See `contracts/WifAgentArenaV2.sol`
- **V1 (daily rounds, fixed 100 $WIF entry — superseded, untouched):** `0x2D042247Cfc91C60a36d87A566FCe11d565Bd5B8`
  - See `contracts/WifAgentArena.sol`
- **$WIF token:** `0x5173b8eA6923c2d40267890D45C46a3480954773`
- **Main $WIF pool:** Uniswap V4 on Robinhood Chain, PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, Pool ID `0x71ef4106340f0a3b9c19ec994eef4fc44a1d2513f38faac39d7636b156548c79`

## How it plays

1. Open the site — the live round, bars, clock, scoreboard and round history load from chain without a wallet.
2. Connect a wallet (Rabby / MetaMask) on Robinhood Chain, pick an agent, set a stake (100–100,000 $WIF).
3. Approve exactly your stake, then enter. You sign both transactions in your own wallet.
4. During the hour anyone may press **Snapshot** (records the live pool price; at most once per 5 minutes).
5. After the hour anyone may press **Settle & start next round**; the contract scores the agents and picks the winner.
6. Winners press **Claim** — the page finds every settled round where your wallet backed the winner and has not claimed yet.

## Onchain proof

All transactions below were re-checked (receipt status 1) on 30 Oct 2026 via `https://rpc.mainnet.chain.robinhood.com`. Times are WIB (UTC+7). Links go to Blockscout.

| Contract | Action | Time (WIB) | Tx |
|---|---|---|---|
| V1 | Deploy | 25 Oct 15:06 | [0x35b64ba20ae275473966f11f9570a93404e9b1a674023173314da1dd91b5ae28](https://robinhoodchain.blockscout.com/tx/0x35b64ba20ae275473966f11f9570a93404e9b1a674023173314da1dd91b5ae28) |
| V1 | Enter 100 $WIF (Breakout) | 25 Oct 15:30 | [0xb9e84ed6cc555fb28e8d2bcf759f9b978d82668743d9c629b95acfe24cf018eb](https://robinhoodchain.blockscout.com/tx/0xb9e84ed6cc555fb28e8d2bcf759f9b978d82668743d9c629b95acfe24cf018eb) |
| V2 | Deploy | 25 Oct 16:55 | [0xf7792596133c21a21a269c2565c21e6138947165984785f8718a1c6b40b87cec](https://robinhoodchain.blockscout.com/tx/0xf7792596133c21a21a269c2565c21e6138947165984785f8718a1c6b40b87cec) |
| V2 | Enter 100 $WIF (Breakout) | 25 Oct 19:01 | [0x383d7a3325fa6dd06c70b70abee768d575dfcbe1b04172b95cb097ae7ce1e8f7](https://robinhoodchain.blockscout.com/tx/0x383d7a3325fa6dd06c70b70abee768d575dfcbe1b04172b95cb097ae7ce1e8f7) |
| V2 | Settle (owner-chosen) · burn 30 $WIF | 25 Oct 20:02 | [0xbb8b7fc502dd0e2c90309c38475f3d38540244ad169ff49275ff76ef1de8caf3](https://robinhoodchain.blockscout.com/tx/0xbb8b7fc502dd0e2c90309c38475f3d38540244ad169ff49275ff76ef1de8caf3) |
| V2 | Claim 50 $WIF | 25 Oct 20:04 | [0x2ae0c95b58e48ce28e74bc19d04960796b919cf9084833c8f2a4ce8214f6733a](https://robinhoodchain.blockscout.com/tx/0x2ae0c95b58e48ce28e74bc19d04960796b919cf9084833c8f2a4ce8214f6733a) |
| V3 | Deploy · round 1 start | 25 Oct 20:19 | [0xeaf09b380f4e8c72fb25ff0444a8971d06499b860b31eed92064799d5676a11a](https://robinhoodchain.blockscout.com/tx/0xeaf09b380f4e8c72fb25ff0444a8971d06499b860b31eed92064799d5676a11a) |
| V3 | Round 1 enter 100 $WIF (Mean-reversion) | 25 Oct 20:57 | [0x79c4be24ceb34757d9621469e2d1530ebf15529a38ce1be021c8cb9350d51122](https://robinhoodchain.blockscout.com/tx/0x79c4be24ceb34757d9621469e2d1530ebf15529a38ce1be021c8cb9350d51122) |
| V3 | Round 1 snapshot | 25 Oct 20:58 | [0x0b17d9b45ff036ad3a03c267cd7ca9164ffb6e99e398c6e153d64cfb9092e59d](https://robinhoodchain.blockscout.com/tx/0x0b17d9b45ff036ad3a03c267cd7ca9164ffb6e99e398c6e153d64cfb9092e59d) |
| V3 | Round 1 settle · burn 30 $WIF · round 2 start | 26 Oct 00:22 | [0x56b2a16a5ca213de9681719ad7b10adbc6b38ed1b285a4abc2380d5952189307](https://robinhoodchain.blockscout.com/tx/0x56b2a16a5ca213de9681719ad7b10adbc6b38ed1b285a4abc2380d5952189307) |
| V3 | Round 1 claim 50 $WIF | 26 Oct 00:22 | [0x5d6137afcfb1b6bce14d49654f3eb0fd4b5c548e9105c2ab61b64bbaffd390f6](https://robinhoodchain.blockscout.com/tx/0x5d6137afcfb1b6bce14d49654f3eb0fd4b5c548e9105c2ab61b64bbaffd390f6) |
| V3 | Round 2 settle (no entries) · round 3 start | 26 Oct 12:23 | [0x7827976b98a04f7176baa066b8e9029f5d2aa6c8e69d72610411ee6f788b4bb1](https://robinhoodchain.blockscout.com/tx/0x7827976b98a04f7176baa066b8e9029f5d2aa6c8e69d72610411ee6f788b4bb1) |
| V3 | Round 3 enter 100 $WIF (Momentum) | 26 Oct 12:29 | [0x1704658d3440bc4965401594f241ac364874c4d6b70ac077bb8b1f5576fb99e3](https://robinhoodchain.blockscout.com/tx/0x1704658d3440bc4965401594f241ac364874c4d6b70ac077bb8b1f5576fb99e3) |
| V3 | Round 3 snapshot | 26 Oct 12:30 | [0xc0522498d16aae957b83d41191816334e5560be39f8f942a0f0cf49039a85a4c](https://robinhoodchain.blockscout.com/tx/0xc0522498d16aae957b83d41191816334e5560be39f8f942a0f0cf49039a85a4c) |
| V3 | Round 3 settle · burn 30 $WIF · round 4 start | 26 Oct 13:42 | [0xb91ef3d96afb5b560bffa0de5fac9a81989426303446137100710ed0c6cf9d86](https://robinhoodchain.blockscout.com/tx/0xb91ef3d96afb5b560bffa0de5fac9a81989426303446137100710ed0c6cf9d86) |
| V3 | Round 3 claim 50 $WIF | 26 Oct 13:43 | [0x4660b635ca257fb93831e0fa795644362190bf6b743cc136a9ab2a51552d6eed](https://robinhoodchain.blockscout.com/tx/0x4660b635ca257fb93831e0fa795644362190bf6b743cc136a9ab2a51552d6eed) |
| V3 | Round 4 settle (no entries) · round 5 start — by keeper | 30 Oct 23:27 | [0x662b0292d8338365c5e4f56085bf3fcf908748704d70ece0affffcd2d525bccd](https://robinhoodchain.blockscout.com/tx/0x662b0292d8338365c5e4f56085bf3fcf908748704d70ece0affffcd2d525bccd) |

Notes: earlier drafts carried truncated hashes for the V2 deploy and the V3 round 3 claim; the full hashes above are the correct ones. The live, always-current list is the **Round history** table on the website, built from V3's onchain events.

## Keeper

A public keeper wallet, [`0xD0917194aa2091eB341A41fa806AeD03243b6097`](https://robinhoodchain.blockscout.com/address/0xD0917194aa2091eB341A41fa806AeD03243b6097), keeps rounds moving: it calls `settle()` when a round has ended and takes 3 `snapshot()`s per round (endTime − 40 min, − 20 min, − 45 s). Both functions are permissionless and take no price input — the keeper has exactly the same power as any visitor pressing the buttons, and the contract reads the pool price itself. It never sends value and calls nothing else. If it stops, anyone can still press **Snapshot** and **Settle** on the site.

## Fight videos

`frontend/assets/` holds a 10-second win video per agent (made with Gemini from the plush fighter images). The web shows a winner's video only after that round is settled onchain — the video never decides the winner.

## Status

Not audited. V1, V2 and V3 sources are verified on Sourcify. This is a hackathon MVP. Known issues: [SECURITY.md](SECURITY.md).

<!-- Git deploy trigger: Vercel Git connected 2026-10-25, Root Directory frontend/ -->
