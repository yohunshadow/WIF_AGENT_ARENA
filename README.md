# WIF Agent Arena

An hourly $WIF showdown on Robinhood Chain, built for the worldisflat.fun hackathon.

Three agents — Momentum, Mean-reversion, Breakout — fight for one pot. Users back an agent with $WIF (100 to 100,000 per enter). When the hour ends, the owner settles the winning agent: 50% of the pot goes to the winner's backers (pro-rata by $WIF backed), 30% burns, 20% seeds the next round.

## Live

- Web: https://wif-agent-arena.vercel.app
- Vercel Root Directory: `frontend/`

## Contracts (Robinhood Chain, chain ID 4663)

- **V2 (current, hourly rounds, variable stake):** `0x2da0A8B64843a2bdCeFC78C69F48F549C4fdE160`
  - Deploy tx: `0xf7792596133c21a21a269c2565c21e6138947165984785f8718a1c6b40b87ce`
  - Source verified on Sourcify (Exact Match, solc 0.8.38)
  - See `contracts/WifAgentArenaV2.sol`
- **V1 (daily rounds, fixed 100 $WIF entry, separate contract):** `0x2D042247Cfc91C60a36d87A566FCe11d565Bd5B8`
  - See `contracts/WifAgentArena.sol`
- **$WIF token:** `0x5173b8eA6923c2d40267890D45C46a3480954773`
- **Main $WIF pool:** Uniswap V4 on Robinhood Chain, PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, Pair ID `0x71ef4106340f0a3b9c19ec994eef4fc44a1d2513f38faac39d7636b156548c79`

## How it plays

1. Connect a wallet (Rabby / MetaMask) on Robinhood Chain.
2. Pick an agent, set a stake (100–100,000 $WIF).
3. Approve exactly your stake, then enter. You sign both transactions in your own wallet.
4. After the hour, the owner settles the winning agent and winners claim their share.

## Fight videos

`frontend/assets/` holds a 10-second win video per agent (made with Gemini from the plush fighter images). The web shows a winner's video only after that round is settled onchain — the video never decides the winner.

## Status

Not audited. V2 source is verified on Sourcify. This is a hackathon MVP.
