// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArenaTestBase} from "./utils/ArenaTestBase.sol";
import {WifAgentArenaV3} from "../contracts/WifAgentArenaV3.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {stdError} from "forge-std/StdError.sol";

/// @notice Unit tests for the deployed, unmodified WifAgentArenaV3 source.
contract WifAgentArenaV3Test is ArenaTestBase {
    event RoundSettled(
        uint256 indexed roundId,
        uint256 winningAgent,
        uint256 prizePool,
        uint256 burned,
        uint256 nextPool,
        uint256[] scores
    );

    // ------------------------------------------------------------ deploy

    function test_Constructor_StartsRound1AtPoolPrice() public view {
        assertEq(arena.currentRoundId(), 1);
        (uint256 start, uint256 end, bool settled,,,,) = arena.roundInfo(1);
        assertEq(start, T0);
        assertEq(end, T0 + 1 hours);
        assertFalse(settled);
        uint160[] memory pts = arena.pricePoints(1);
        assertEq(pts.length, 1);
        assertEq(pts[0], P0);
        assertTrue(arena.agentExists(1) && arena.agentExists(2) && arena.agentExists(3));
        assertFalse(arena.agentExists(0) || arena.agentExists(4));
    }

    function test_Constructor_Constants() public view {
        assertEq(arena.ROUND_DURATION(), 3600);
        assertEq(arena.SNAPSHOT_MIN_INTERVAL(), 300);
        assertEq(arena.MAX_PRICE_POINTS(), 16);
        assertEq(arena.MIN_ENTRY_RAW(), 100 * WIF);
        assertEq(arena.MAX_ENTRY_RAW(), 100_000 * WIF);
        assertEq(arena.POOLS_SLOT(), 6);
    }

    function test_Constructor_RevertsOnBadArgs() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        vm.expectRevert("bad token");
        new WifAgentArenaV3(address(0), address(pm), POOL_ID, ids);
        vm.expectRevert("bad pool manager");
        new WifAgentArenaV3(address(wif), address(0), POOL_ID, ids);
        vm.expectRevert("no agents");
        new WifAgentArenaV3(address(wif), address(pm), POOL_ID, new uint256[](0));
        // Wrong pool id -> empty slot -> price 0 -> constructor reverts.
        vm.expectRevert("bad pool price");
        new WifAgentArenaV3(address(wif), address(pm), bytes32(uint256(1)), ids);
    }

    function test_PoolPrice_ReadsLow160BitsOfSlot0AtPoolsSlot6() public {
        // Upper bits (tick / fees) are set by the mock; only sqrtPriceX96 must be recorded.
        MockPoolManager fresh = new MockPoolManager();
        bytes32 slot = keccak256(abi.encode(POOL_ID, uint256(6)));
        assertEq(slot, fresh.slot0Slot(POOL_ID));
        uint256 word = (uint256(0xABCDEF) << 160) | uint256(P0);
        fresh.setWord(slot, bytes32(word));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        WifAgentArenaV3 a = new WifAgentArenaV3(address(wif), address(fresh), POOL_ID, ids);
        assertEq(a.pricePoints(1)[0], P0);
    }

    // ------------------------------------------------------------- enter

    function test_Enter_RecordsBackingPerAgentAndBacker() public {
        _enter(alice, MOMENTUM, 100 * WIF);
        _enter(alice, MOMENTUM, 50_000 * WIF);
        _enter(bob, MOMENTUM, 200 * WIF);
        _enter(bob, BREAKOUT, 300 * WIF);

        assertEq(arena.agentTotal(1, MOMENTUM), 50_300 * WIF);
        assertEq(arena.agentTotal(1, MEAN_REVERSION), 0);
        assertEq(arena.agentTotal(1, BREAKOUT), 300 * WIF);
        assertEq(arena.backerAmount(1, alice, MOMENTUM), 50_100 * WIF);
        assertEq(arena.backerAmount(1, bob, MOMENTUM), 200 * WIF);
        assertEq(arena.backerAmount(1, bob, BREAKOUT), 300 * WIF);
        (,,,,, uint256 collected, uint256 backings) = arena.roundInfo(1);
        assertEq(collected, 50_600 * WIF);
        assertEq(backings, 4); // counts enter() calls, not unique wallets
        assertEq(wif.balanceOf(address(arena)), 50_600 * WIF);
    }

    function test_Enter_BoundsAreInclusive() public {
        _enter(alice, MEAN_REVERSION, 100 * WIF);
        _enter(alice, MEAN_REVERSION, 100_000 * WIF);
        assertEq(arena.agentTotal(1, MEAN_REVERSION), 100_100 * WIF);
    }

    function test_Enter_Reverts() public {
        vm.startPrank(alice);
        vm.expectRevert("unknown agent");
        arena.enter(4, 100 * WIF);
        vm.expectRevert("unknown agent");
        arena.enter(0, 100 * WIF);
        vm.expectRevert("below min 100 WIF");
        arena.enter(1, 100 * WIF - 1);
        vm.expectRevert("above max 100000 WIF");
        arena.enter(1, 100_000 * WIF + 1);
        vm.stopPrank();

        vm.warp(T0 + 1 hours); // endTime is exclusive for entries
        vm.expectRevert("round closed");
        _enter(alice, 1, 100 * WIF);
    }

    function test_Enter_RevertsWithoutAllowance() public {
        address dave = makeAddr("dave");
        wif.mint(dave, 1000 * WIF);
        vm.prank(dave);
        vm.expectRevert("allowance");
        arena.enter(1, 100 * WIF);
    }

    // ---------------------------------------------------------- snapshot

    function test_Snapshot_EnforcesFiveMinuteSpacing() public {
        vm.warp(T0 + 5 minutes - 1);
        vm.expectRevert("too soon");
        arena.snapshot();

        vm.warp(T0 + 5 minutes);
        _setPrice(_pct(101));
        arena.snapshot();
        assertEq(arena.snapshotCount(1), 2);

        vm.warp(T0 + 10 minutes - 1);
        vm.expectRevert("too soon");
        arena.snapshot();

        vm.warp(T0 + 10 minutes);
        arena.snapshot();
        assertEq(arena.snapshotCount(1), 3);
        uint160[] memory pts = arena.pricePoints(1);
        assertEq(pts[1], _pct(101));
    }

    function test_Snapshot_IsPermissionless() public {
        vm.warp(T0 + 5 minutes);
        vm.prank(makeAddr("random visitor"));
        arena.snapshot();
        assertEq(arena.snapshotCount(1), 2);
    }

    function test_Snapshot_RevertsAtOrAfterEndTime() public {
        vm.warp(T0 + 1 hours);
        vm.expectRevert("round closed");
        arena.snapshot();
    }

    function test_Snapshot_RevertsOnZeroPoolPrice() public {
        vm.warp(T0 + 5 minutes);
        pm.setWord(pm.slot0Slot(POOL_ID), bytes32(0));
        vm.expectRevert("bad pool price");
        arena.snapshot();
    }

    /// FINDING (not a security issue): with a 1-hour round and a 5-minute
    /// minimum spacing measured from the round start, at most 11 snapshots
    /// fit (t+5m ... t+55m), i.e. 12 price points. MAX_PRICE_POINTS = 16 can
    /// never be reached, so the "max snapshots" check is unreachable.
    function test_Snapshot_AtMost12PointsFitInOneHour_Max16Unreachable() public {
        for (uint256 k = 1; k <= 11; k++) {
            vm.warp(T0 + k * 5 minutes);
            _setPrice(_pct(100 + k));
            arena.snapshot();
        }
        assertEq(arena.snapshotCount(1), 12);
        // Next legal time would be t+60m == endTime, where snapshot() is closed.
        vm.warp(T0 + 1 hours - 1);
        vm.expectRevert("too soon");
        arena.snapshot();
        vm.warp(T0 + 1 hours);
        vm.expectRevert("round closed");
        arena.snapshot();
        assertLt(arena.snapshotCount(1), arena.MAX_PRICE_POINTS());
    }

    // ------------------------------------------------------------ settle

    function test_Settle_RevertsBeforeEndTime() public {
        vm.warp(T0 + 1 hours - 1);
        vm.expectRevert("round not over");
        arena.settle();
    }

    function test_Settle_IsPermissionlessAndStartsNextRound() public {
        vm.warp(T0 + 1 hours);
        _setPrice(_pct(110));
        vm.prank(makeAddr("random visitor"));
        arena.settle();

        (,, bool settled,,,,) = arena.roundInfo(1);
        assertTrue(settled);
        assertEq(arena.currentRoundId(), 2);
        (uint256 start2, uint256 end2, bool settled2,,,,) = arena.roundInfo(2);
        assertEq(start2, T0 + 1 hours);
        assertEq(end2, T0 + 2 hours);
        assertFalse(settled2);
        // Round 2 starts from the price at settle time.
        assertEq(arena.pricePoints(2)[0], _pct(110));
    }

    function test_Settle_CannotSettleSameRoundTwice() public {
        vm.warp(T0 + 1 hours);
        arena.settle();
        // currentRound is now round 2, which has not ended.
        vm.expectRevert("round not over");
        arena.settle();
        (,, bool settled,,,,) = arena.roundInfo(1);
        assertTrue(settled);
    }

    function test_Settle_LateSettleStartsNextRoundAtSettleTime() public {
        vm.warp(T0 + 5 days); // nobody settled for days
        arena.settle();
        assertEq(_startTime(2), T0 + 5 days);
        assertEq(_endTime(2), T0 + 5 days + 1 hours);
    }

    function test_Settle_FeeSplit_50_30_20_Exact() public {
        _enter(alice, MEAN_REVERSION, 700 * WIF);
        _enter(bob, MOMENTUM, 300 * WIF);
        uint256 supplyBefore = wif.totalSupply();

        vm.warp(T0 + 1 hours);
        arena.settle();

        assertEq(_prize(1), 500 * WIF, "prize = 50%");
        assertEq(wif.totalBurned(), 300 * WIF, "burn = 30%");
        assertEq(wif.totalSupply(), supplyBefore - 300 * WIF, "burn reduces supply");
        assertEq(arena.nextRoundPool(), 200 * WIF, "carry = 20%");
        assertEq(wif.balanceOf(address(arena)), 700 * WIF, "prize + carry stay in contract");
    }

    function testFuzz_Settle_FeeSplitConservesFunds(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 100 * WIF, 100_000 * WIF);
        b = bound(b, 100 * WIF, 100_000 * WIF);
        c = bound(c, 100 * WIF, 100_000 * WIF);
        _enter(alice, MOMENTUM, a);
        _enter(bob, MEAN_REVERSION, b);
        _enter(carol, BREAKOUT, c);
        uint256 total = a + b + c;

        vm.warp(T0 + 1 hours);
        arena.settle();

        uint256 prize = _prize(1);
        uint256 burned = wif.totalBurned();
        uint256 carry = arena.nextRoundPool();
        assertEq(prize, (total * 50) / 100);
        assertEq(burned, (total * 30) / 100);
        assertEq(prize + burned + carry, total, "nothing created or lost");
        assertEq(wif.balanceOf(address(arena)), prize + carry);
    }

    function test_Settle_NoEntriesBurnsNothing() public {
        vm.warp(T0 + 1 hours);
        arena.settle();
        assertEq(wif.totalBurned(), 0);
        assertEq(_prize(1), 0);
        assertEq(arena.nextRoundPool(), 0);
    }

    function test_Settle_CarryOverIsAddedToNextRoundPrize() public {
        // Round 1: 1000 in -> prize 500, burn 300, carry 200.
        _enter(alice, MOMENTUM, 1000 * WIF);
        _settleAtEnd();
        assertEq(arena.nextRoundPool(), 200 * WIF);

        // Round 2: 400 in -> prize 200 + 200 carry, burn 120, carry 80.
        _enter(bob, MEAN_REVERSION, 400 * WIF);
        _settleAtEnd();
        assertEq(_prize(2), 400 * WIF);
        assertEq(wif.totalBurned(), 300 * WIF + 120 * WIF);
        assertEq(arena.nextRoundPool(), 80 * WIF);
    }

    function test_Settle_EmitsScores() public {
        _snapshotPath(_arr(_pct(99), _pct(105)));
        vm.warp(T0 + 1 hours);
        uint256[] memory scores = new uint256[](3);
        uint256[3] memory ref = _refScores(_arr(P0, _pct(99), _pct(105)));
        scores[0] = ref[0];
        scores[1] = ref[1];
        scores[2] = ref[2];
        vm.expectEmit(true, false, false, true, address(arena));
        emit RoundSettled(1, MEAN_REVERSION, 0, 0, 0, scores);
        arena.settle();
    }

    // ------------------------------------------------------------ scoring

    function test_Scoring_MeanReversionWins() public {
        // 100 -> 99 (down: mean-reversion goes long) -> 105 (up: it profits)
        _snapshotPath(_arr(_pct(99), _pct(105)));
        _settleAtEnd();
        assertEq(_winner(1), MEAN_REVERSION);
        assertEq(arena.agentScore(1, MOMENTUM), 1e18);
        assertEq(arena.agentScore(1, BREAKOUT), 1e18);
        assertGt(arena.agentScore(1, MEAN_REVERSION), 1e18);
    }

    function test_Scoring_MomentumWins() public {
        // 100 -> 98 -> 99 -> 101: mean-rev rides 98->99, momentum rides 99->101.
        _snapshotPath(_arr(_pct(98), _pct(99), _pct(101)));
        _settleAtEnd();
        assertEq(_winner(1), MOMENTUM);
        assertGt(arena.agentScore(1, MOMENTUM), arena.agentScore(1, MEAN_REVERSION));
        assertGt(arena.agentScore(1, MEAN_REVERSION), arena.agentScore(1, BREAKOUT));
    }

    function test_Scoring_BreakoutWinsByStayingFlat() public {
        // 100 -> 95 -> 90 -> 92 -> 91: mean-rev and momentum both lose, breakout never trades.
        _snapshotPath(_arr(_pct(95), _pct(90), _pct(92), _pct(91)));
        _settleAtEnd();
        assertEq(_winner(1), BREAKOUT);
        assertEq(arena.agentScore(1, BREAKOUT), 1e18);
        assertLt(arena.agentScore(1, MOMENTUM), 1e18);
        assertLt(arena.agentScore(1, MEAN_REVERSION), 1e18);
    }

    function test_Scoring_BreakoutOnlyLongOnNewHigh() public {
        // 100 -> 110 -> 105 -> 108 -> 112
        // i=3 (108): up step but not a new high (110) -> momentum long, breakout flat.
        _snapshotPath(_arr(_pct(110), _pct(105), _pct(108), _pct(112)));
        _settleAtEnd();
        uint256[3] memory ref = _refScores(_arr5(P0, _pct(110), _pct(105), _pct(108), _pct(112)));
        assertEq(arena.agentScore(1, MOMENTUM), ref[0]);
        assertEq(arena.agentScore(1, BREAKOUT), ref[2]);
        assertGt(arena.agentScore(1, MOMENTUM), arena.agentScore(1, BREAKOUT));
    }

    /// Cross-checks the onchain scoring + winner against the independent
    /// reference model for random price paths of 1..12 points.
    function testFuzz_ScoringMatchesReferenceModel(uint256 seed, uint8 nSnaps) public {
        uint256 n = bound(nSnaps, 0, 11);
        uint160[] memory snaps = new uint160[](n);
        uint160[] memory all = new uint160[](n + 1);
        all[0] = P0;
        for (uint256 i = 0; i < n; i++) {
            // each point within +-20% of P0; small integer grid makes exact ties likely too
            uint256 r = uint256(keccak256(abi.encode(seed, i))) % 41;
            snaps[i] = _pct(80 + r);
            all[i + 1] = snaps[i];
        }
        _snapshotPath(snaps);
        _settleAtEnd();
        uint256[3] memory ref = _refScores(all);
        assertEq(arena.agentScore(1, MOMENTUM), ref[0], "momentum");
        assertEq(arena.agentScore(1, MEAN_REVERSION), ref[1], "mean-reversion");
        assertEq(arena.agentScore(1, BREAKOUT), ref[2], "breakout");
        assertEq(_winner(1), _refWinner(1, all), "winner");
    }

    // -------------------------------------------------------------- claim

    function test_Claim_ProRataByWifBacked() public {
        _enter(alice, MEAN_REVERSION, 100 * WIF);
        _enter(bob, MEAN_REVERSION, 300 * WIF);
        _enter(carol, MOMENTUM, 600 * WIF);
        _snapshotPath(_arr(_pct(99), _pct(105)));
        _settleAtEnd();
        assertEq(_winner(1), MEAN_REVERSION);
        assertEq(_prize(1), 500 * WIF);

        uint256 a0 = wif.balanceOf(alice);
        uint256 b0 = wif.balanceOf(bob);
        vm.prank(alice);
        arena.claim(1);
        vm.prank(bob);
        arena.claim(1);
        assertEq(wif.balanceOf(alice) - a0, 125 * WIF, "alice 25%");
        assertEq(wif.balanceOf(bob) - b0, 375 * WIF, "bob 75%");
        // Only the 20% carry remains.
        assertEq(wif.balanceOf(address(arena)), 200 * WIF);
    }

    function test_Claim_LoserCannotClaim() public {
        _enter(alice, MEAN_REVERSION, 100 * WIF);
        _enter(carol, MOMENTUM, 600 * WIF);
        _snapshotPath(_arr(_pct(99), _pct(105)));
        _settleAtEnd();
        vm.prank(carol);
        vm.expectRevert("not a winner backer");
        arena.claim(1);
    }

    function test_Claim_DoubleClaimReverts() public {
        _enter(alice, MEAN_REVERSION, 100 * WIF);
        _snapshotPath(_arr(_pct(99), _pct(105)));
        _settleAtEnd();
        vm.startPrank(alice);
        arena.claim(1);
        vm.expectRevert("already claimed");
        arena.claim(1);
        vm.stopPrank();
    }

    function test_Claim_UnsettledRoundReverts() public {
        _enter(alice, MEAN_REVERSION, 100 * WIF);
        vm.prank(alice);
        vm.expectRevert("not settled");
        arena.claim(1);
        vm.prank(alice);
        vm.expectRevert("not settled");
        arena.claim(99);
    }

    function test_Claim_OldRoundStillClaimableLater() public {
        _enter(alice, MEAN_REVERSION, 100 * WIF);
        _snapshotPath(_arr(_pct(99), _pct(105)));
        _settleAtEnd();
        _settleAtEnd(); // round 2
        _settleAtEnd(); // round 3
        uint256 a0 = wif.balanceOf(alice);
        vm.prank(alice);
        arena.claim(1);
        assertEq(wif.balanceOf(alice) - a0, 50 * WIF);
    }

    /// Pro-rata claims never pay out more than the prize; rounding dust stays.
    function testFuzz_Claim_SumNeverExceedsPrize(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 100 * WIF, 100_000 * WIF);
        b = bound(b, 100 * WIF, 100_000 * WIF);
        c = bound(c, 100 * WIF, 100_000 * WIF);
        _enter(alice, MEAN_REVERSION, a);
        _enter(bob, MEAN_REVERSION, b);
        _enter(carol, MEAN_REVERSION, c);
        _snapshotPath(_arr(_pct(99), _pct(105)));
        _settleAtEnd();
        uint256 before = wif.balanceOf(address(arena));
        vm.prank(alice);
        arena.claim(1);
        vm.prank(bob);
        arena.claim(1);
        vm.prank(carol);
        arena.claim(1);
        uint256 paid = before - wif.balanceOf(address(arena));
        uint256 prize = _prize(1);
        assertLe(paid, prize);
        assertLt(prize - paid, 3, "dust < number of claimers (wei)");
    }

    // -------------------------------------------------------- tie-break

    /// With no snapshots (1 point) every agent scores exactly 1e18 and the
    /// winner is keccak256(roundId, firstPrice, lastPrice) % 3.
    function test_TieBreak_NoSnapshotsAllTieAndHashPicks() public {
        _settleAtEnd();
        for (uint256 id = 1; id <= 3; id++) {
            assertEq(arena.agentScore(1, id), 1e18);
        }
        assertEq(_winner(1), _tieBreakAll3(1, P0, P0));
    }

    /// With 2 points step 0->1 is always flat, so it is still a 3-way tie
    /// no matter how far the price moved.
    function test_TieBreak_TwoPointsAlwaysTie() public {
        _snapshotPath(_arr(_pct(150)));
        _settleAtEnd();
        for (uint256 id = 1; id <= 3; id++) {
            assertEq(arena.agentScore(1, id), 1e18);
        }
        assertEq(_winner(1), _tieBreakAll3(1, P0, _pct(150)));
    }

    /// A flat price (no trades between snapshots) also ties all agents.
    function test_TieBreak_FlatPriceTies() public {
        _snapshotPath(_arr(P0, P0, P0));
        _settleAtEnd();
        assertEq(_winner(1), _tieBreakAll3(1, P0, P0));
    }

    /// Partial tie: only the tied leaders are eligible.
    function test_TieBreak_OnlyAmongLeaders() public {
        // 100 -> 101 -> 102: momentum and breakout both ride 101->102, mean-rev flat.
        _snapshotPath(_arr(_pct(101), _pct(102)));
        _settleAtEnd();
        assertEq(arena.agentScore(1, MOMENTUM), arena.agentScore(1, BREAKOUT));
        assertEq(arena.agentScore(1, MEAN_REVERSION), 1e18);
        uint256 w = _winner(1);
        assertTrue(w == MOMENTUM || w == BREAKOUT);
        uint256 pick = uint256(keccak256(abi.encodePacked(uint256(1), P0, _pct(102)))) % 2;
        assertEq(w, pick == 0 ? MOMENTUM : BREAKOUT);
    }

    function _arr5(uint160 a, uint160 b, uint160 c, uint160 d, uint160 e) internal pure returns (uint160[] memory r) {
        r = new uint160[](5);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
        r[4] = e;
    }
}
