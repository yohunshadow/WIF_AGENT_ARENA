// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WifAgentArenaV3} from "../contracts/WifAgentArenaV3.sol";

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice Read-only checks against the LIVE deployment on Robinhood Chain.
/// Runs on a local fork; nothing is ever broadcast. Any state change in
/// these tests (e.g. the simulated settle) happens only in the local fork.
/// Skips itself if the RPC is unreachable or SKIP_FORK=true.
/// RPC override: ROBINHOOD_RPC_URL.
contract ForkLiveV3Test is Test {
    address internal constant V3 = 0x845d23dBD7290d7469C4f9f012f44277cbE7702E;
    address internal constant WIF_TOKEN = 0x5173b8eA6923c2d40267890D45C46a3480954773;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    bytes32 internal constant POOL_ID = 0x71ef4106340f0a3b9c19ec994eef4fc44a1d2513f38faac39d7636b156548c79;
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    WifAgentArenaV3 internal arena = WifAgentArenaV3(V3);
    bool internal forked;

    function setUp() public {
        if (vm.envOr("SKIP_FORK", false)) return;
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        try vm.createSelectFork(url) {
            forked = block.chainid == 4663 && V3.code.length > 0;
        } catch {
            forked = false;
        }
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// Executable bytecode of the live contract equals contracts/WifAgentArenaV3.sol
    /// compiled with this repo's foundry.toml (solc 0.8.38, optimizer off).
    /// The trailing CBOR metadata hash is excluded (it encodes compiler-input
    /// paths/settings, not logic); Sourcify reports a full exact match.
    function test_Fork_LiveRuntimeBytecodeMatchesSource() public onlyFork {
        bytes memory live = V3.code;
        bytes memory local = vm.getDeployedCode("WifAgentArenaV3.sol:WifAgentArenaV3");
        assertEq(live.length, local.length, "runtime length");
        assertEq(keccak256(_stripMetadata(live)), keccak256(_stripMetadata(local)), "runtime code");
    }

    function test_Fork_ConstructorArgsAndConstants() public onlyFork {
        assertEq(address(arena.wif()), WIF_TOKEN);
        assertEq(address(arena.poolManager()), POOL_MANAGER);
        assertEq(arena.poolId(), POOL_ID);
        assertEq(arena.agentIds(0), 1);
        assertEq(arena.agentIds(1), 2);
        assertEq(arena.agentIds(2), 3);
        assertEq(arena.ROUND_DURATION(), 1 hours);
        assertEq(arena.SNAPSHOT_MIN_INTERVAL(), 5 minutes);
        assertEq(arena.POOLS_SLOT(), 6);
    }

    /// POOLS_SLOT = 6 reads a real, in-range sqrtPriceX96 from the live pool.
    function test_Fork_PoolsSlot6ReadsLivePrice() public onlyFork {
        bytes32 slot = keccak256(abi.encode(POOL_ID, uint256(6)));
        (bool ok, bytes memory ret) = POOL_MANAGER.staticcall(abi.encodeWithSignature("extsload(bytes32)", slot));
        assertTrue(ok, "extsload");
        uint160 sqrtP = uint160(uint256(abi.decode(ret, (bytes32))));
        assertGt(sqrtP, MIN_SQRT_PRICE);
        assertLt(sqrtP, MAX_SQRT_PRICE);
        emit log_named_uint("live sqrtPriceX96", sqrtP);
    }

    /// Evidence for SECURITY.md A: rounds 1-4 were all 3-way ties at 1e18 and
    /// each winner equals keccak256(roundId, firstPrice, lastPrice) % 3.
    function test_Fork_Rounds1to4WereTieBreakWins() public onlyFork {
        uint256[4] memory expectedWinner = [uint256(2), 2, 1, 3];
        for (uint256 r = 1; r <= 4; r++) {
            (,, bool settled, uint256 winner,,,) = arena.roundInfo(r);
            assertTrue(settled);
            for (uint256 id = 1; id <= 3; id++) {
                assertEq(arena.agentScore(r, id), 1e18, "tie");
            }
            uint160[] memory p = arena.pricePoints(r);
            assertLt(p.length, 3, "fewer than 3 points");
            uint256 pick = uint256(keccak256(abi.encodePacked(r, p[0], p[p.length - 1]))) % 3;
            assertEq(winner, pick + 1, "tie-break formula");
            assertEq(winner, expectedWinner[r - 1]);
        }
    }

    /// Evidence for SECURITY.md C: rounds 2 and 4 had a 20 $WIF prize and no
    /// backers on the winner, so it can never be claimed.
    function test_Fork_Rounds2and4PrizesStranded() public onlyFork {
        uint256[2] memory rs = [uint256(2), 4];
        for (uint256 k = 0; k < 2; k++) {
            (,,, uint256 winner, uint256 prize,,) = arena.roundInfo(rs[k]);
            assertEq(prize, 20e18);
            assertEq(arena.agentTotal(rs[k], winner), 0);
        }
        assertGe(IERC20View(WIF_TOKEN).balanceOf(V3), 40e18);
    }

    /// Current round is consistent with the contract's rules. If it has ended,
    /// settle() is simulated LOCALLY on the fork (never broadcast) to show it
    /// works against the real $WIF token and PoolManager.
    function test_Fork_CurrentRoundStateAndLocalSettleSimulation() public onlyFork {
        uint256 id = arena.currentRoundId();
        assertGe(id, 5);
        (uint256 start, uint256 end, bool settled,,, uint256 collected,) = arena.roundInfo(id);
        assertEq(end - start, 1 hours);
        assertFalse(settled);
        uint256 n = arena.snapshotCount(id);
        assertGe(n, 1);
        assertLe(n, 12);
        emit log_named_uint("current round", id);
        emit log_named_uint("price points", n);
        emit log_named_uint("WIF collected", collected);

        if (block.timestamp < end) vm.warp(end);
        uint256 supply0 = IERC20View(WIF_TOKEN).totalSupply();
        arena.settle(); // local fork only
        (,, bool nowSettled,,,,) = arena.roundInfo(id);
        assertTrue(nowSettled);
        assertEq(arena.currentRoundId(), id + 1);
        assertEq(supply0 - IERC20View(WIF_TOKEN).totalSupply(), (collected * 30) / 100, "real $WIF burn");
    }

    function _stripMetadata(bytes memory code) internal pure returns (bytes memory out) {
        uint256 len = code.length;
        uint256 metaLen = (uint256(uint8(code[len - 2])) << 8) | uint256(uint8(code[len - 1]));
        out = new bytes(len - metaLen - 2);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = code[i];
        }
    }
}
