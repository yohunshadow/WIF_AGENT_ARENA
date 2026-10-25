# WIF Agent Arena V3 — Design: Fully Automatic Winner

Status: **DRAFT, NOT AUDITED, NOT DEPLOYED.** Written 2026-10-25 at user
direction. Contract draft: `WifAgentArenaV3.sol` (compiled clean, solc
0.8.38, optimizer runs 200, bytecode 7,421 bytes).

> CORRECTION 2026-10-25 ~19:47 WIB, REVISED ~19:50 WIB — DO NOT DEPLOY YET.
> The original price read via `PoolManager.getSlot0()` was INVALID for
> the Robinhood PoolManager at `0x8366…`: its bytecode dispatcher
> contains no `getSlot0` selector, and current canonical v4-core
> `IPoolManager` has no `getSlot0` either (removed; price reads go
> through `extsload`). The contract has since been REVISED to read
> price via `extsload` (recompiled clean, solc 0.8.38, 7,336 bytes).
> VERIFIED 2026-10-25 ~19:57 WIB — deploy is UNBLOCKED. The user read
> `extsload` (No. 8, `0x1e2eaeaf`) on Blockscout with the slot word
> above and got a genuine slot0: sqrtPriceX96 ~1.08e32, tick ~144650,
> implied ~1.9e6 WIF per ETH. POOLS_SLOT = 6 is confirmed. (Note: an
> earlier draft of this doc said "expect ~1.1e31" — that was a 10x
> arithmetic slip; the correct magnitude is ~1.1e32.) Web switch must
> still wait until V2 round 2 is settled and claimed.

## 1. The rule this design must satisfy

> Nobody — not the deployer, not the owner, not any caller, not Muse —
> may choose, arrange, or influence which agent wins a round, except
> through the public, fixed rules below and through real market prices.

V2 violates this by construction: `settle(uint256 winningAgent)` takes the
winner as a human-supplied argument, and only the owner may call it. V3
removes both: `settle()` takes **no winner argument** and has **no owner
gate**. There is no privileged function anywhere in V3. The deployer has
zero power after deploy.

## 2. Mechanism in five steps

1. **Round starts.** `_startRound()` reads the pool price itself from the
   Uniswap V4 PoolManager (`extsload` on the pool's slot0 storage word,
   low 160 bits = `sqrtPriceX96`) and stores it as price point 0.
   Nobody supplies this number.
2. **Snapshots during the round.** Anyone may call `snapshot()` while
   the round is live. The contract reads the pool price itself in that
   same transaction — the caller supplies no price, so a snapshot can
   never contain an invented price. Guardrails: at most one snapshot per
   5 minutes per round, at most 16 price points total (start + 15).
3. **Round ends.** After `endTime`, anyone may call `settle()`. The
   caller only pays gas and triggers a computation.
4. **Contract computes the winner.** `_scores()` runs the three fixed
   strategies over the recorded price points (section 3). Highest
   virtual capital wins. Exact ties for first place use the
   deterministic tie-break in section 4 — no human, no blockhash.
5. **Money moves exactly like V2.** Prize = 50% of the round's pot +
   carried `nextRoundPool`; 30% burned via the token's own `burn()`;
   20% seeded into the next round. Winners claim pull-model, pro-rata
   by $WIF backed on the winning agent. `claim(roundId)` is unchanged.

## 3. The three strategies (fixed, onchain, no lookahead)

Each agent starts with virtual capital `1e18`. At snapshot `i`, the
agent's position for the **next** step (`i -> i+1`) is decided **only**
from snapshots `0..i`. Step factor `f = price[i+1] * 1e18 / price[i]`.
A long agent's capital is multiplied by `f`; a flat agent's capital is
unchanged. Snapshot 0 has no history, so everyone is flat for step 0->1.

| Agent | Long for next step iff… | Character |
|---|---|---|
| 1 Momentum | last step went UP (`price[i] > price[i-1]`) | rides trends |
| 2 Mean-reversion | last step went DOWN (`price[i] < price[i-1]`) | buys dips |
| 3 Breakout | `price[i]` is a NEW HIGH vs all earlier snapshots | rides breakouts |

Strategy is keyed by **agent ID** (1/2/3), not by deploy order, so a
different `agentIds` order at deploy cannot silently reassign strategies.

Prices are `sqrtPriceX96` values. Scoring uses their ratios only, so
currency order (ETH/WIF as token0/token1) does not matter, and all
agents are scored in the same "sqrt-price space" (a true 2x price move
reads as ~1.414x here). Magnitudes are compressed identically for all
three agents, so rankings are unaffected.

### Worked example (verified against a Python mirror of `_scores()`)

Price points (arbitrary units): `[1000, 1100, 1050, 1200, 1150]`

- Momentum: long on steps after an up-step, ends at
  `0.914772727272727271` (rode the 1100->1050 dip down).
- Mean-reversion: long after the down-step, ends at
  `1.142857142857142857` — **winner**.
- Breakout: ends at `0.914772727272727271` (same down-step as Momentum).

Two honest observations from the same mirror:

- **Up-only market** `[1000, 1100, 1200, 1300]`: Momentum and Breakout
  tie at `1.1818…`, Mean-reversion stays flat at `1.0`. In a clean
  trend, two strategies legitimately coincide — the tie-break then
  decides between them (section 4).
- **Down-only market** `[1300, 1200, 1100, 1000]`: Momentum and Breakout
  stay flat at `1.0` and "win" by not losing; Mean-reversion, which
  keeps buying dips into a falling market, ends at `0.8333…`. Sitting
  flat is a valid outcome here: capital preservation is part of the
  game, and every agent faces the same prices.

## 4. Tie-break (deterministic, human-free)

If several agents share the exact highest score, the winner is
`tiedAgents[keccak256(roundId, firstPrice, lastPrice) % tiedCount]`.
It uses only data already onchain for that round — never a caller
argument, never `blockhash`, never the owner's address. It is arbitrary
by design (a tie means the strategies genuinely could not be separated
by the recorded prices) and it fires only on an exact tie. If a round
records no snapshots beyond the start price, all scores tie at `1e18`
and the tie-break decides — the round still settles, it never stalls.

## 5. Price source — and what it is NOT

- **Used:** Uniswap V4 PoolManager `extsload` on the pool's slot0
  storage word (`keccak256(abi.encode(poolId, POOLS_SLOT))`, low 160
  bits = `sqrtPriceX96`), read by the contract itself. PoolManager
  (Robinhood Chain): `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
  WIF/ETH pool id (DexScreener Pair ID):
  `0x71ef4106340f0a3b9c19ec994eef4fc44a1d2513f38faac39d7636b156548c79`.
  (`getSlot0` was the original plan and is WRONG for this PoolManager
  — see the correction banner at the top.)
- **NOT used, deliberately:** no Chainlink feed (none is known for $WIF
  on Robinhood Chain), no V4 TWAP hook (a vanilla V4 pool has no
  built-in TWAP the way V3 did), and no offchain scorer submitting a
  result (that would reintroduce exactly the trust V3 removes — a
  submitter who could lie, with verification as an afterthought).
- **Pre-deploy check (mandatory):** before deploying, verify
  `POOLS_SLOT = 6` by calling `extsload` on the PoolManager with the
  slot word for the main pool
  (`0x29165c39177d9f5cc164b9766636273c3e964f1d405604b7d1696d3c3636dd57`,
  = `keccak256(poolId, 6)`) from Blockscout Read Contract or via RPC,
  and confirm the low 160 bits are a plausible `sqrtPriceX96` (for
  WIF/ETH around $0.00114 with ETH ~$2,350, expect ~1.1e32, i.e. WIF
  per ETH ~2e6; a zero, a tiny number, or an absurd number means the
  slot is wrong and deploy must stop). VERIFIED 2026-10-25 ~19:57 WIB
  via the user's Blockscout read: sqrtPriceX96 ~1.08e32, tick ~144650. Cross-check: the same slot word
  formula with a fake pool id must return zero. The pool's fee tier /
  tick spacing / hook were never verified — they do not matter for an
  `extsload` slot0 read.

## 6. Attack and failure analysis (honest version)

- **Inventing a price: impossible.** Snapshots carry no caller price.
  The contract reads the pool. A liar's transaction simply records the
  real pool price at that block.
- **Snapshot timing games: bounded, not eliminated.** A caller chooses
  *when* to snapshot, within the 5-minute interval rule. They cannot
  create a price, only pick a real one. Timing choice among real prices
  has a bounded effect because scoring uses up to 16 points, not one.
- **Flash-loan spike: expensive, public, diluted.** A one-block spike
  can move at most one snapshot (min interval + real cost to move a
  $95K-liquidity pool, at prices observed 2026-10-25). It cannot
  guarantee a win the way V2's owner choice could, and the spike is
  visible onchain forever.
- **Snapshot starvation (the real weak point).** If nobody snapshots,
  the round settles by tie-break lottery. Mitigation is social, not
  trusted: the web UI gets a Snapshot button, and anyone may run a
  public snapshot bot (every ~5 min). The bot is untrusted by
  construction — it cannot fake prices, only trigger reads. Backers
  also have a direct incentive to snapshot: without price data, their
  agent cannot win on merit.
- **Start-price gap.** The next round's start price is read at settle
  time, not exactly at the previous round's `endTime`, because the
  contract cannot read a past price without an oracle. Same gap for all
  agents; documented, not hidden.
- **Overflow edge.** Absurd single-step moves could overflow the
  capital math and make `settle()` revert. Practically impossible for
  $WIF hourly; if it ever happened, there is **no admin key to rescue
  the round, by design** — a fix would mean a new deployment. This is
  the price of removing all privileged roles.
- **Immutability trade-off.** Fixed rules mean no mid-game rule changes
  — which is exactly what makes the winner unarrangeable — but also
  means bugs cannot be patched in place. Same posture as V1 -> V2.

## 7. What stays the same as V2

1-hour rounds; enter min 100 / max 100,000 $WIF per call; prize
pro-rata by backed $WIF; split 50/30/20; pull-model claim; agent IDs
[1, 2, 3]; `roundInfo` / `agentTotal` / `backerAmount` helpers.
New views: `agentScore(roundId, agentId)`, `pricePoints(roundId)`,
`snapshotCount(roundId)`. New events: `PriceSnapshot`, and
`RoundSettled` now also emits the three scores.

## 8. Migration from V2 (separate contract, no fund movement)

- V3 is a **new contract**. V2 is untouched: its round 2 (ends
  ~19:54 WIB 2026-10-25) still settles and claims on V2, with its own
  pot. No V2 funds migrate to V3.
- Recommended order: (1) settle + claim V2 round 2 first; (2) deploy
  V3; (3) Sourcify-verify V3 like V1/V2; (4) switch the web to the V3
  address + add Snapshot button + scoreboard; (5) new entries go to V3
  only. Switching the web before V2 round 2 is claimed would strand
  the V2 claim button — do not switch early.
- V3 constructor args (to confirm at deploy): wifToken
  `0x5173b8eA6923c2d40267890D45C46a3480954773`, poolManager
  `0x8366a39CC670B4001A1121B8F6A443A643e40951`, poolId
  `0x71ef4106340f0a3b9c19ec994eef4fc44a1d2513f38faac39d7636b156548c79`,
  agentIds `[1, 2, 3]`.

## 9. Web changes needed (after deploy, not in this draft)

- Point ARENA at the V3 address; `enter`/`claim` flows unchanged.
- Add a **Snapshot** button (calls `snapshot()`, anyone, pays gas)
  and a live **scoreboard**: current price points, live preview scores
  (the web must mirror `_scores()` exactly in JS — same sqrtPrice
  ratios, same position rules — and label the preview as unofficial
  until `settle()` runs onchain).
- Add a **Settle** button (calls permissionless `settle()`, anyone)
  — the web finally gets a settle path, because settle no longer needs
  the owner. Keep the on-page honesty line: the winner is computed by
  the contract from pool prices, never chosen by any person.
- Keep the demo fight videos and plush art: they are presentation for
  the settled winner, unchanged by V3.

## 10. Open decisions for Oyen (nothing here deploys itself)

1. Accept the snapshot-starvation trade-off (tie-break lottery if a
   round gets no snapshots), or require a snapshot bot to be running
   before V3 goes live?
2. Deploy V3 right after V2 round 2 settles/claims, or finish the
   submission package on V2 first and launch V3 as the "fairness
   upgrade" story?
3. Keep the 5-minute / 16-point snapshot parameters, or tune them
   (shorter interval = finer strategies, more gas per round)?
