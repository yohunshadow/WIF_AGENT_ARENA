# Security notes — WIF Agent Arena V3

Contract: `WifAgentArenaV3` at [`0x845d23dBD7290d7469C4f9f012f44277cbE7702E`](https://robinhoodchain.blockscout.com/address/0x845d23dBD7290d7469C4f9f012f44277cbE7702E) on Robinhood Chain (chain ID 4663).
Source: `contracts/WifAgentArenaV3.sol`, Sourcify exact match (creation + runtime), solc 0.8.38. **Not audited.**

This file is an honest self-review. Every claim below can be checked onchain; tx links are on Blockscout.
State and evidence were last re-read from `https://rpc.mainnet.chain.robinhood.com` on 30 Oct 2026, ~23:30 WIB (UTC+7).

## Design summary

- No owner, no admin, no upgrade path, no privileged function. Constructor arguments are immutable.
- `enter(agentId, amount)`: 100–100,000 $WIF per call while `block.timestamp < endTime`.
- `snapshot()`: anyone, while the round is open, at most once per 5 minutes, max 16 price points per round (in practice at most 12 fit in one hour, because spacing is counted from the round start; see `test_Snapshot_AtMost12PointsFitInOneHour_Max16Unreachable`). The contract reads the WIF/ETH Uniswap V4 pool price itself via `PoolManager.extsload` (Pool.State slot0, `POOLS_SLOT = 6`). The caller supplies no price.
- `settle()`: anyone, after `endTime`. Scores the three fixed strategies over the recorded price points, picks the winner, burns 30% with `$WIF.burn()`, keeps 50% (+ the carried pool) as prize, carries 20% to the next round, and starts the next round.
- `claim(roundId)`: pull-based, pro-rata by $WIF backed on the winning agent.

`POOLS_SLOT = 6` is verified: reading `extsload(keccak256(abi.encode(poolId, 6)))` returns a sqrtPriceX96 consistent with the live WIF/ETH price (~1.83M WIF per ETH, ~$0.0012 per WIF at check time).

## Contracts are immutable for the hackathon — by design

V3 has no owner and cannot be patched. That is the point of V3 (V2 let the owner choose the winner). For the hackathon judging window the deployed V3 stays exactly as is; the issues below are disclosed, mitigated off-contract where possible, and listed as V4 changes. No funds beyond the team's own test entries have ever been at stake (see "Exposure" below).

## Findings

### A. Rounds 1–4 were all decided by the tie-break, not by a strategy (High — design)

Each agent starts flat; a position for step `i → i+1` needs history `0..i`, so step 0→1 is always flat for all three agents. With fewer than **3** price points every agent scores exactly `1e18` and the winner is `keccak256(roundId, firstPrice, lastPrice) % 3` among the tied agents.

| Round | Price points | Scores | Winner | Settle tx |
|---|---|---|---|---|
| 1 | 2 | all 1e18 (tie) | 2 Mean-reversion | [0x56b2a16a…9307](https://robinhoodchain.blockscout.com/tx/0x56b2a16a5ca213de9681719ad7b10adbc6b38ed1b285a4abc2380d5952189307) |
| 2 | 1 | all 1e18 (tie) | 2 Mean-reversion | [0x7827976b…4bb1](https://robinhoodchain.blockscout.com/tx/0x7827976b98a04f7176baa066b8e9029f5d2aa6c8e69d72610411ee6f788b4bb1) |
| 3 | 2 | all 1e18 (tie) | 1 Momentum | [0xb91ef3d9…9d86](https://robinhoodchain.blockscout.com/tx/0xb91ef3d96afb5b560bffa0de5fac9a81989426303446137100710ed0c6cf9d86) |
| 4 | 1 | all 1e18 (tie) | 3 Breakout | [0x662b0292…bccd](https://robinhoodchain.blockscout.com/tx/0x662b0292d8338365c5e4f56085bf3fcf908748704d70ece0affffcd2d525bccd) |

The winner was still computed by the contract (nobody chose it), but it was a deterministic hash, not the strategy contest the UI describes. The web scoreboard and round history now label tie-break wins explicitly.

**Tests:** `test_KnownIssue_A_TieBreakDecidesRoundsWithFewerThan3Points` (mock) and `test_Fork_Rounds1to4WereTieBreakWins` (re-derives the four live winners from onchain price points).

**Mitigation (live):** a public keeper wallet takes 3 snapshots per round (see "Liveness"), so rounds it services get 4 price points (start + 3) and the strategies can actually diverge. Rounds before round 5 did not have this. Ties are still possible if the price does not move between snapshots.

### B. The outcome becomes predictable before entries close (High — design)

`settle()` reads no new price; it only scores the points already recorded. Entries stay open until `endTime`. Therefore:

- Once no further snapshot can land before `endTime` (the next one would need `lastSnapshotTime + 5 min < endTime`), the final scores — and, on a tie, the tie-break hash — are fully computable from public state. A player can then back the known winner at zero risk.
- Anyone can deliberately "freeze" a round early by snapshotting ~4–5 minutes before `endTime`, which blocks later snapshots.
- With 1 point (no snapshots) the winner is computable from the moment the round starts.

**Impact:** a rational late entrant takes the prize from earlier backers of other agents. 
**Mitigation (live, partial):** the keeper's last snapshot targets ~45 s before `endTime`, shrinking the predictable window from up to 5 minutes to under a minute when nobody interferes. This cannot stop a griefer who snapshots earlier. Fix requires a contract change (V4).

**Tests:** `test_KnownIssue_B_OutcomeFrozenLateEntrantWins`, `test_KnownIssue_B_NoSnapshotWinnerKnownAtRoundStart`.

### C. Prize is stranded when nobody backed the winner (Medium — funds locked)

`claim()` requires `wifByAgent[winner] > 0`. If the winning agent has no backers, that round's `prizePool` — which includes the previous round's carried 20% — can never be claimed and is not rolled forward. It stays in the contract forever.

| Round | Stranded | Evidence |
|---|---|---|
| 2 | 20 $WIF (carry from round 1, no entries) | [settle 0x7827976b…4bb1](https://robinhoodchain.blockscout.com/tx/0x7827976b98a04f7176baa066b8e9029f5d2aa6c8e69d72610411ee6f788b4bb1) |
| 4 | 20 $WIF (carry from round 3, no entries) | [settle 0x662b0292…bccd](https://robinhoodchain.blockscout.com/tx/0x662b0292d8338365c5e4f56085bf3fcf908748704d70ece0affffcd2d525bccd) |

The contract's $WIF balance (40 $WIF at check time) equals these two stranded prizes; `nextRoundPool` is 0. Any future round with zero entries on the winning agent strands its prize the same way. There is no admin function to recover it, by design.

**Tests:** `test_KnownIssue_C_StrandedPrize_NoEntriesRoundEatsCarry`, `test_KnownIssue_C_StrandedPrize_WinnerHadNoBackers`, `test_Fork_Rounds2and4PrizesStranded`.

### D. Spot-price (slot0) manipulation (Medium — design)

Snapshots read the pool's instantaneous `sqrtPriceX96`. The WIF/ETH pool is shallow (~$94K liquidity at last check). In a single transaction an attacker can swap to move the price, call `snapshot()`, and swap back, paying only swap fees and gas. One manipulated point can flip which strategy was "long" on a step and therefore the winner. The 5-minute spacing and multi-point scoring dilute but do not prevent this. Slot0's `lpFee` field reads 0 for this pool (it may be a dynamic-fee pool; not confirmed), which would make round-trip manipulation cheaper.

**Test:** `test_KnownIssue_D_SingleTxSpotManipulationFlipsWinner` (one call moves the price, snapshots, restores it, and changes the winner).

### E. Liveness: rounds only advance when someone calls `settle()` (Low — availability)

A new round starts only inside `settle()`. Between 26 Oct 14:42 WIB and 30 Oct 23:27 WIB round 4 sat ended-but-unsettled, so `enter()` reverted ("round closed") for everyone.

**Mitigation (live):**
- Public keeper wallet [`0xD0917194aa2091eB341A41fa806AeD03243b6097`](https://robinhoodchain.blockscout.com/address/0xD0917194aa2091eB341A41fa806AeD03243b6097) settles ended rounds and takes 3 snapshots per round (endTime − 40 min, − 20 min, − 45 s). It can only call `settle()` / `snapshot()`, which are permissionless and price-input-free, so the keeper has no more power than any visitor. It settled round 4 in [0x662b0292…bccd](https://robinhoodchain.blockscout.com/tx/0x662b0292d8338365c5e4f56085bf3fcf908748704d70ece0affffcd2d525bccd).
- The web shows "Round ended — settle to start the next round" and a public **Settle & start next round** button whenever a round has ended unsettled.

**Test:** `test_KnownIssue_E_EndedRoundBlocksEntriesUntilSettle`.

### Other notes

- Rounding dust from pro-rata claims stays in the contract.
- Extreme price moves can overflow the capital math and make `settle()` revert permanently (stated in the source). The tests show it does not need a single huge step: mean-reversion's capital compounds over repeated down→up swings, so with 12 points, five low/high swings of ~1.65e8× in sqrtPrice (~2.7e16× in price) are enough. If that happened, the round could never settle and its entries plus the carry would stay locked. We have not shown this is economically feasible on the live pool; it depends on how much liquidity sits across such a price range. Tests: `test_KnownLimit_ExtremeSwingsOverflowSettle_V4Bounds`, `test_KnownLimit_CompoundingOverflowThreshold`.
- The next round's start price is read at settle time, not at the previous `endTime`.
- Frontend: ethers v6.13.0 is pinned with Subresource Integrity; approvals are for the exact stake only (no unlimited approvals); the site never handles keys.

## Threat model

| Actor | Can | Cannot |
|---|---|---|
| Deployer / team | Nothing beyond any user | Choose winners, pause, upgrade, withdraw, change fees |
| Keeper wallet | Call `settle()` / `snapshot()` (like anyone) | Supply a price, choose a winner, move funds |
| Any player | Enter, snapshot (timing), settle, claim own prize | Supply a price; claim others' prizes |
| Late entrant (B) | Back a winner whose result is already fixed | — (this is the main open risk) |
| Pool manipulator (D) | Skew a snapshot within one tx for swap fees | Fake a price without moving the real pool |
| Frontend host | Serve a modified page | Sign for users (wallet confirms every tx) |

**Exposure so far:** every V3 entry to date (2 × 100 $WIF) came from the team's own wallet; total $WIF burned by V3: 60. Users should treat this as an unaudited hackathon game and stake accordingly.

## What a V4 would change

1. **Close entries early:** entries close at `endTime − X` (e.g. 15 min) and scoring only uses points recorded *after* entries close, so the outcome is unknown at entry time (fixes B).
2. **Scheduled, non-grindable sampling:** fixed snapshot slots (e.g. one per 5-minute slot, any caller, first call per slot wins) plus a mandatory final sample inside `settle()` (fixes B and the freeze grief).
3. **Manipulation-resistant price:** a TWAP/oracle hook or Chainlink-style feed instead of slot0; reject samples taken in the same block as a large price change (mitigates D).
4. **No stranded prizes:** if the winner has no backers, roll the prize into `nextRoundPool` (or refund pro-rata) (fixes C).
5. **Avoid default ties:** require ≥ 3 points to score; otherwise roll the round over or refund (fixes A).
6. **Liveness:** let `enter()` auto-settle/roll an ended round, or start rounds on a fixed clock (fixes E).
7. Keep the Foundry suite (unit, known-issue and live fork tests; see README "Tests") and add an external review before any real-value use. Cap or saturate the capital math so `settle()` can never revert on extreme prices.

## Reporting

Please open a GitHub issue on this repo, or contact the team on X (@3amer_osama). Do not exploit live rounds that include other players' funds.
