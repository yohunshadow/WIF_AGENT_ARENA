// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArenaTestBase} from "./utils/ArenaTestBase.sol";
import {WifAgentArenaV3} from "../contracts/WifAgentArenaV3.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {stdError} from "forge-std/StdError.sol";

/// @notice Stands in for an attacker who, in ONE transaction, swaps to move
/// the pool price, calls snapshot(), and swaps back. In the mock, "swap" is
/// modelled by writing the pool's slot0 directly.
contract SpotManipulator {
    function moveSnapshotRestore(
        MockPoolManager pm,
        WifAgentArenaV3 arena,
        bytes32 poolId,
        uint160 fakePrice,
        uint160 realPrice
    ) external {
        pm.setSqrtPrice(poolId, fakePrice); // swap in
        arena.snapshot(); // contract records the manipulated spot price
        pm.setSqrtPrice(poolId, realPrice); // swap back
    }
}

/// @notice Tests that DEMONSTRATE the known issues listed in SECURITY.md.
/// They pass by asserting the current (flawed) behaviour of the deployed,
/// immutable V3 contract. They are documentation, not fixes.
contract KnownIssuesTest is ArenaTestBase {
    // Uniswap v4 TickMath bounds for sqrtPriceX96.
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    // ---------------------------------------------------------------- A

    /// SECURITY.md A: rounds with < 3 price points are always a 3-way tie,
    /// so the winner is a hash, not a strategy result. Mirrors live rounds
    /// 1-4 (1 or 2 points each).
    function test_KnownIssue_A_TieBreakDecidesRoundsWithFewerThan3Points() public {
        // Round 1: 2 points (one snapshot), like live rounds 1 and 3.
        _enter(alice, MEAN_REVERSION, 100 * WIF);
        _snapshotPath(_arr(_pct(97)));
        _settleAtEnd();
        // Round 2: 1 point (no snapshots), like live rounds 2 and 4.
        _settleAtEnd();

        for (uint256 r = 1; r <= 2; r++) {
            for (uint256 id = 1; id <= 3; id++) {
                assertEq(arena.agentScore(r, id), 1e18, "every agent ties at 1e18");
            }
        }
        assertEq(_winner(1), _tieBreakAll3(1, P0, _pct(97)));
        uint160 r2Start = arena.pricePoints(2)[0];
        assertEq(_winner(2), _tieBreakAll3(2, r2Start, r2Start));
    }

    // ---------------------------------------------------------------- B

    /// SECURITY.md B: once the last possible snapshot has landed, the result
    /// is fixed and public while entries are still open. A late entrant backs
    /// the known winner and takes most of the prize from earlier backers.
    function test_KnownIssue_B_OutcomeFrozenLateEntrantWins() public {
        uint256 start = _startTime(1);
        uint256 end = _endTime(1);

        // Early honest players.
        _enter(alice, MOMENTUM, 1000 * WIF);
        _enter(bob, BREAKOUT, 1000 * WIF);

        // Price moves; someone snapshots 4 minutes before the end. After this
        // no further snapshot is possible (next legal time > endTime).
        vm.warp(start + 20 minutes);
        _setPrice(_pct(98));
        arena.snapshot();
        vm.warp(end - 4 minutes);
        _setPrice(_pct(103));
        arena.snapshot();
        vm.warp(end - 1);
        vm.expectRevert("too soon");
        arena.snapshot();

        // Anyone can now compute the final result from public state.
        uint160[] memory pts = arena.pricePoints(1);
        uint256 predicted = _refWinner(1, pts);
        assertEq(predicted, MEAN_REVERSION);

        // Late entrant, 1 second before close, backs the known winner.
        _enter(carol, predicted, 100_000 * WIF);

        // Real price keeps moving wildly; it no longer matters.
        vm.warp(end);
        _setPrice(_pct(50));
        arena.settle();

        assertEq(_winner(1), predicted, "settle() matched the prediction");
        uint256 c0 = wif.balanceOf(carol);
        vm.prank(carol);
        arena.claim(1);
        // carol put in 100,000 and gets back the whole prize: 50% of 102,000.
        assertEq(wif.balanceOf(carol) - c0, 51_000 * WIF);
        vm.prank(alice);
        vm.expectRevert("not a winner backer");
        arena.claim(1);
    }

    /// SECURITY.md B: with no snapshots the winner (tie-break hash over the
    /// start price) is computable the moment the round starts.
    function test_KnownIssue_B_NoSnapshotWinnerKnownAtRoundStart() public {
        uint256 predicted = _tieBreakAll3(1, P0, P0);
        _enter(carol, predicted, 100 * WIF);
        _settleAtEnd();
        assertEq(_winner(1), predicted);
    }

    // ---------------------------------------------------------------- C

    /// SECURITY.md C: if nobody backed the winning agent, the prize (including
    /// the previous round's 20% carry) can never be claimed and is not rolled
    /// forward. Mirrors live rounds 1->2 and 3->4 (20 $WIF stranded each).
    function test_KnownIssue_C_StrandedPrize_NoEntriesRoundEatsCarry() public {
        // Round 1: one 100 $WIF entry; pick the agent that the tie-break will choose.
        uint256 w1 = _tieBreakAll3(1, P0, P0);
        _enter(alice, w1, 100 * WIF);
        _settleAtEnd();
        vm.prank(alice);
        arena.claim(1); // 50 $WIF
        assertEq(arena.nextRoundPool(), 20 * WIF);

        // Round 2: no entries. Its prize = 0 + 20 carry, winner has no backers.
        _settleAtEnd();
        assertEq(_prize(2), 20 * WIF);
        assertEq(arena.nextRoundPool(), 0, "carry is NOT rolled forward");
        vm.prank(alice);
        vm.expectRevert("not a winner backer");
        arena.claim(2);

        // The 20 $WIF stays in the contract with no way out.
        assertEq(wif.balanceOf(address(arena)), 20 * WIF);
        _settleAtEnd();
        assertEq(_prize(3), 0);
        assertEq(wif.balanceOf(address(arena)), 20 * WIF);
    }

    function test_KnownIssue_C_StrandedPrize_WinnerHadNoBackers() public {
        // Everyone backs momentum/breakout; mean-reversion wins.
        _enter(alice, MOMENTUM, 1000 * WIF);
        _enter(bob, BREAKOUT, 1000 * WIF);
        _snapshotPath(_arr(_pct(99), _pct(105)));
        _settleAtEnd();
        assertEq(_winner(1), MEAN_REVERSION);
        assertEq(arena.agentTotal(1, MEAN_REVERSION), 0);
        assertEq(_prize(1), 1000 * WIF);

        vm.prank(alice);
        vm.expectRevert("not a winner backer");
        arena.claim(1);
        vm.prank(bob);
        vm.expectRevert("not a winner backer");
        arena.claim(1);
        // prize 1000 stranded + 400 carry still in contract.
        assertEq(wif.balanceOf(address(arena)), 1400 * WIF);
    }

    // ---------------------------------------------------------------- D

    /// SECURITY.md D: one transaction (swap -> snapshot -> swap back) inserts
    /// an arbitrary spot price and flips the winner. Price in the pool is
    /// unchanged before and after the attacker's transaction.
    function test_KnownIssue_D_SingleTxSpotManipulationFlipsWinner() public {
        // Find a flat start price whose honest tie-break does NOT pick
        // mean-reversion, so the flip is visible.
        uint160 p = P0;
        while (_tieBreakAll3(1, p, p) == MEAN_REVERSION) p += 1;
        _redeployAt(p);

        uint256 start = _startTime(1);
        uint256 snap = vm.snapshotState();

        // Honest run: price stays flat, keeper snapshots at +20m and +40m.
        vm.warp(start + 20 minutes);
        arena.snapshot();
        vm.warp(start + 40 minutes);
        arena.snapshot();
        _settleAtEnd();
        uint256 honestWinner = _winner(1);
        assertTrue(honestWinner != MEAN_REVERSION);

        vm.revertToState(snap);

        // Attack: at +20m, one tx pushes the price down 5%, snapshots, restores.
        SpotManipulator attacker = new SpotManipulator();
        vm.warp(start + 20 minutes);
        attacker.moveSnapshotRestore(pm, arena, POOL_ID, uint160((uint256(p) * 95) / 100), p);
        assertEq(uint160(uint256(pm.extsload(pm.slot0Slot(POOL_ID)))), p, "pool back to real price");
        vm.warp(start + 40 minutes);
        arena.snapshot();
        _settleAtEnd();

        assertEq(_winner(1), MEAN_REVERSION, "manipulated point decided the round");
        assertTrue(_winner(1) != honestWinner);
    }

    // ---------------------------------------------------------------- E

    /// SECURITY.md E: an ended-but-unsettled round blocks every entry until
    /// someone calls settle().
    function test_KnownIssue_E_EndedRoundBlocksEntriesUntilSettle() public {
        vm.warp(_endTime(1) + 4 days);
        vm.expectRevert("round closed");
        _enter(alice, MOMENTUM, 100 * WIF);
        vm.expectRevert("round closed");
        arena.snapshot();

        arena.settle(); // anyone
        _enter(alice, MOMENTUM, 100 * WIF);
        assertEq(arena.agentTotal(2, MOMENTUM), 100 * WIF);
    }

    // ------------------------------------------------- overflow limit

    /// SECURITY.md "Other notes" (overflow). The source says extreme
    /// single-step moves could overflow. These tests show the overflow can
    /// also come from COMPOUNDING across steps: mean-reversion's virtual
    /// capital multiplies on every down->up swing. If settle() overflows it
    /// reverts with a panic and, because nothing else can start a new round,
    /// the arena is stuck for good: entries and carry stay locked.
    ///
    /// Whether this is reachable on the live pool depends on how much it
    /// costs to push the WIF/ETH pool across such huge price ranges (it
    /// depends on the pool's liquidity distribution); we have NOT shown it
    /// is economically feasible. It is a demonstration of the math only.
    function test_KnownLimit_ExtremeSwingsOverflowSettle_V4Bounds() public {
        _enter(alice, MOMENTUM, 1000 * WIF);
        // Points: P0, MAX, MIN, MAX, MIN, MAX (all within Uniswap v4 bounds).
        uint160[] memory s = new uint160[](5);
        s[0] = MAX_SQRT_PRICE;
        s[1] = MIN_SQRT_PRICE;
        s[2] = MAX_SQRT_PRICE;
        s[3] = MIN_SQRT_PRICE;
        s[4] = MAX_SQRT_PRICE;
        _snapshotPath(s);
        _assertSettleStuck();
    }

    /// Threshold for this pattern with all 12 points used (five down->up
    /// cycles for mean-reversion): a sqrtPrice ratio between lows and highs
    /// of ~1.65e8 overflows (price ratio ~2.7e16). 1.6e8 still settles.
    function test_KnownLimit_CompoundingOverflowThreshold() public {
        uint256 snap = vm.snapshotState();
        _snapshotPath(_swingPath(1.6e8));
        _settleAtEnd(); // fine
        vm.revertToState(snap);
        _snapshotPath(_swingPath(1.7e8));
        _assertSettleStuck();
    }

    // ---------------------------------------------------------------- helpers

    function _swingPath(uint256 ratio) internal pure returns (uint160[] memory s) {
        // P0 high, then low/high alternating: 11 snapshots -> 12 points.
        s = new uint160[](11);
        for (uint256 i = 0; i < 11; i++) {
            s[i] = i % 2 == 0 ? uint160(uint256(P0) / ratio) : P0;
        }
    }

    function _assertSettleStuck() internal {
        vm.warp(_endTime(1));
        vm.expectRevert(stdError.arithmeticError);
        arena.settle();
        vm.warp(_endTime(1) + 30 days);
        vm.expectRevert(stdError.arithmeticError);
        arena.settle();
        vm.expectRevert("round closed");
        _enter(bob, MOMENTUM, 100 * WIF);
        assertEq(arena.currentRoundId(), 1, "no new round can ever start");
    }

    function _redeployAt(uint160 price) internal {
        pm.setSqrtPrice(POOL_ID, price);
        uint256[] memory ids = new uint256[](3);
        ids[0] = MOMENTUM;
        ids[1] = MEAN_REVERSION;
        ids[2] = BREAKOUT;
        arena = new WifAgentArenaV3(address(wif), address(pm), POOL_ID, ids);
    }
}
