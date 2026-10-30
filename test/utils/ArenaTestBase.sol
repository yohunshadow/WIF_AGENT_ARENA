// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WifAgentArenaV3} from "../../contracts/WifAgentArenaV3.sol";
import {MockWIF} from "../mocks/MockWIF.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @notice Shared setup for the V3 tests. Deploys the UNMODIFIED
/// contracts/WifAgentArenaV3.sol against a mock $WIF and a mock
/// PoolManager, with the same constructor arguments shape as mainnet
/// (agents 1, 2, 3 and the real poolId).
abstract contract ArenaTestBase is Test {
    bytes32 internal constant POOL_ID = 0x71ef4106340f0a3b9c19ec994eef4fc44a1d2513f38faac39d7636b156548c79;
    uint256 internal constant MOMENTUM = 1;
    uint256 internal constant MEAN_REVERSION = 2;
    uint256 internal constant BREAKOUT = 3;
    uint256 internal constant WIF = 1e18;
    uint256 internal constant T0 = 1_793_300_000; // ~30 Oct 2026

    // Realistic starting sqrtPriceX96 for the live WIF/ETH pool (~1.08e32).
    uint160 internal constant P0 = 108_000_000_000_000_000_000_000_000_000_000;

    WifAgentArenaV3 internal arena;
    MockWIF internal wif;
    MockPoolManager internal pm;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");

    function setUp() public virtual {
        vm.warp(T0);
        wif = new MockWIF();
        pm = new MockPoolManager();
        pm.setSqrtPrice(POOL_ID, P0);
        uint256[] memory ids = new uint256[](3);
        ids[0] = MOMENTUM;
        ids[1] = MEAN_REVERSION;
        ids[2] = BREAKOUT;
        arena = new WifAgentArenaV3(address(wif), address(pm), POOL_ID, ids);
        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    // ---------------------------------------------------------------- helpers

    function _fund(address who) internal {
        wif.mint(who, 1_000_000 * WIF);
        vm.prank(who);
        wif.approve(address(arena), type(uint256).max);
    }

    function _enter(address who, uint256 agentId, uint256 amount) internal {
        vm.prank(who);
        arena.enter(agentId, amount);
    }

    function _setPrice(uint160 p) internal {
        pm.setSqrtPrice(POOL_ID, p);
    }

    /// Price as a percentage of P0 (e.g. 105 -> P0 * 1.05).
    function _pct(uint256 percent) internal pure returns (uint160) {
        return uint160((uint256(P0) * percent) / 100);
    }

    function _round() internal view returns (uint256) {
        return arena.currentRoundId();
    }

    function _endTime(uint256 roundId) internal view returns (uint256 endTime) {
        (, endTime,,,,,) = arena.roundInfo(roundId);
    }

    function _startTime(uint256 roundId) internal view returns (uint256 startTime) {
        (startTime,,,,,,) = arena.roundInfo(roundId);
    }

    function _winner(uint256 roundId) internal view returns (uint256 w) {
        (,,, w,,,) = arena.roundInfo(roundId);
    }

    function _prize(uint256 roundId) internal view returns (uint256 p) {
        (,,,, p,,) = arena.roundInfo(roundId);
    }

    /// Records `prices` as snapshots 1..n of the current round, one every
    /// 5 minutes starting 5 minutes after the round start (needs n <= 11).
    function _snapshotPath(uint160[] memory prices) internal {
        uint256 start = _startTime(_round());
        for (uint256 i = 0; i < prices.length; i++) {
            vm.warp(start + (i + 1) * 5 minutes);
            _setPrice(prices[i]);
            vm.prank(keeper);
            arena.snapshot();
        }
    }

    function _settleAtEnd() internal returns (uint256 settledRound) {
        settledRound = _round();
        vm.warp(_endTime(settledRound));
        vm.prank(keeper);
        arena.settle();
    }

    // ------------------------------------------------- reference model

    /// Independent re-implementation of the scoring rules described in the
    /// contract header (same integer math), used to cross-check _scores().
    function _refScores(uint160[] memory p) internal pure returns (uint256[3] memory cap) {
        cap = [uint256(1e18), 1e18, 1e18];
        uint160 maxSoFar = p[0];
        for (uint256 i = 0; i + 1 < p.length; i++) {
            bool mom;
            bool mean;
            bool brk;
            if (i > 0) {
                mom = p[i] > p[i - 1];
                mean = p[i] < p[i - 1];
                brk = p[i] > maxSoFar;
            }
            if (p[i] > maxSoFar) maxSoFar = p[i];
            uint256 f = (uint256(p[i + 1]) * 1e18) / uint256(p[i]);
            if (mom) cap[0] = (cap[0] * f) / 1e18;
            if (mean) cap[1] = (cap[1] * f) / 1e18;
            if (brk) cap[2] = (cap[2] * f) / 1e18;
        }
    }

    /// Reference winner: highest score; exact ties broken by
    /// keccak256(roundId, firstPrice, lastPrice) % tiedCount over tied agents
    /// in agent order 1, 2, 3.
    function _refWinner(uint256 roundId, uint160[] memory p) internal pure returns (uint256) {
        uint256[3] memory s = _refScores(p);
        return _refPick(roundId, s, p[0], p[p.length - 1]);
    }

    function _refPick(uint256 roundId, uint256[3] memory s, uint160 first, uint160 last)
        internal
        pure
        returns (uint256)
    {
        uint256 best = s[0];
        if (s[1] > best) best = s[1];
        if (s[2] > best) best = s[2];
        uint256 tied;
        for (uint256 i = 0; i < 3; i++) {
            if (s[i] == best) tied++;
        }
        uint256 pick = uint256(keccak256(abi.encodePacked(roundId, first, last))) % tied;
        uint256 seen;
        for (uint256 i = 0; i < 3; i++) {
            if (s[i] == best) {
                if (seen == pick) return i + 1;
                seen++;
            }
        }
        revert("unreachable");
    }

    /// Tie-break pick when all three agents tie (scores all 1e18).
    function _tieBreakAll3(uint256 roundId, uint160 first, uint160 last) internal pure returns (uint256) {
        return (uint256(keccak256(abi.encodePacked(roundId, first, last))) % 3) + 1;
    }

    function _arr(uint160 a) internal pure returns (uint160[] memory r) {
        r = new uint160[](1);
        r[0] = a;
    }

    function _arr(uint160 a, uint160 b) internal pure returns (uint160[] memory r) {
        r = new uint160[](2);
        r[0] = a;
        r[1] = b;
    }

    function _arr(uint160 a, uint160 b, uint160 c) internal pure returns (uint160[] memory r) {
        r = new uint160[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _arr(uint160 a, uint160 b, uint160 c, uint160 d) internal pure returns (uint160[] memory r) {
        r = new uint160[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }
}
