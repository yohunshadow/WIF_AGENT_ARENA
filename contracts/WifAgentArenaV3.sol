// SPDX-License-Identifier: MIT
// WIF Agent Arena V3 — DRAFT, NOT AUDITED, NOT DEPLOYED
// DO NOT DEPLOY YET (revision 2026-10-25 ~19:50 WIB): _poolPrice() now
// reads price via PoolManager.extsload() (see below), which EXISTS on
// the Robinhood PoolManager. Deploy is still on hold until the pools
// storage slot (candidate: slot 6) is verified against a plausible
// sqrtPrice — Robinhood RPC eth_call is currently rate-limited (403),
// and an unverified slot could feed garbage prices into scoring.
// Written 2026-10-25 at user direction: the round winner must be FULLY
// automatic — no human (not the owner, not anyone) may choose or arrange
// which agent wins a round.
//
// How V3 differs from V2:
//  - V2: settle(uint256 winningAgent) onlyOwner. The caller CHOOSES the
//    winner. That is the hole this version closes.
//  - V3: settle() takes NO winner argument and has NO onlyOwner gate.
//    Anyone may call it after endTime. The contract itself COMPUTES the
//    winner from onchain price data + fixed strategy rules that nobody
//    can change after deploy. The caller only pays gas and triggers a
//    computation whose result is identical no matter who calls it.
//
// Price source (no human input, no offchain scorer):
//  - Uniswap V4 PoolManager on Robinhood Chain:
//    0x8366a39CC670B4001A1121B8F6A443A643e40951
//  - WIF / native ETH pool id (DexScreener Pair ID):
//    0x71ef4106340f0a3b9c19ec994eef4fc44a1d2513f38faac39d7636b156548c79
//  - The contract reads the pool price ITSELF via PoolManager.extsload()
//    on the pool's slot0 storage word. A snapshot
//    caller supplies no price, so a caller cannot invent a price — they
//    can only choose WHEN a real pool price gets recorded, and even that
//    is bounded (min interval, max points, see below).
//  - Scoring uses sqrtPriceX96 ratios only (relative movement). Currency
//    order (ETH vs WIF as token0/token1) does not matter for the ranking:
//    sqrtPrice is monotonic in price, so "up" and "down" are the same for
//    every agent. Magnitudes are in sqrt-price space (a true 2x price
//    move reads as ~1.414x here) — identical for all three agents, so the
//    ranking is unaffected.
//
// Snapshots (permissionless, price read onchain):
//  - _startRound() records the pool price at round start as point 0.
//  - snapshot() may be called by ANYONE while the round is live, at most
//    once per SNAPSHOT_MIN_INTERVAL (5 minutes), up to MAX_PRICE_POINTS
//    total points per round (start + 15 snapshots = 16 points over 1h).
//  - If nobody snapshots, the round still settles: all three scores tie
//    at 1e18 and the deterministic tie-break below decides. That is the
//    honest weak point of this design — see DESIGN doc, "snapshot
//    starvation". Mitigation is social, not trusted: the web UI exposes
//    a Snapshot button and anyone may run a public snapshot bot. The bot
//    is untrusted by construction: it cannot fake a price, it can only
//    call snapshot() and let the contract read the pool.
//
// Scoring (fixed rules, one loop, no lookahead):
//  - Each agent starts with virtual capital 1e18. At snapshot i, the
//    agent's position for the NEXT step (i -> i+1) is decided ONLY from
//    snapshots 0..i. Then the step factor f = price[i+1] * 1e18 / price[i]
//    multiplies the capital of every agent that was long for that step.
//  - Agent 1 Momentum: long for the next step iff the last step went UP
//    (price[i] > price[i-1]). Rides trends, sits flat on down steps.
//  - Agent 2 Mean-reversion: long for the next step iff the last step
//    went DOWN (price[i] < price[i-1]). Buys dips, sits flat on up steps.
//  - Agent 3 Breakout: long for the next step iff price[i] is a NEW HIGH
//    vs every earlier snapshot (price[i] > max(price[0..i-1])). Rides
//    breakouts, sits flat otherwise.
//  - Snapshot 0 has no history, so all agents are flat for step 0->1.
//  - Highest final capital wins. Exact ties for first place are broken
//    deterministically: winner = tiedAgents[keccak256(roundId, first
//    price, last price) % tiedCount]. No human, no blockhash, no owner.
//    The tie-break is arbitrary but deterministic, and it only fires on
//    an exact score tie.
//
// Everything else is unchanged from V2:
//  - Round duration 1 hour, entry min 100 / max 100,000 $WIF per call.
//  - Prize pro-rata by $WIF backed on the winning agent (NOT entry count).
//  - Fee split 50% prize / 30% burn / 20% next round. Prize includes the
//    previous round's nextRoundPool, same as V2.
//  - Claim is pull-model: winners call claim(roundId) themselves.
//  - There is NO owner role and NO privileged function in V3. The
//    deployer has zero power after deploy. Constructor arguments are
//    immutable. Trade-off, stated plainly: a bug cannot be fixed in
//    place — a fix means deploying a new contract (same as V1 -> V2).
//
// Known limits (see DESIGN doc for the full analysis):
//  - A single-block price spike can move at most one snapshot, and the
//    min interval + multi-step scoring dilute it. Manipulation is
//    possible in principle, expensive in practice, public onchain, and
//    can never guarantee a win — unlike V2, where the owner guarantees
//    the win by choosing it.
//  - Next round's start price is read at settle-transaction time, not
//    exactly at the previous round's endTime (the contract cannot read a
//    past price without an oracle). Same for all agents, small gap.
//  - Extreme single-step price moves could overflow the capital math
//    and make settle() revert (practically impossible for $WIF hourly;
//    a stuck round would need a new deployment — no admin key exists to
//    rescue it, by design).
//
// $WIF: 0x5173b8eA6923c2d40267890D45C46a3480954773, 18 decimals.

pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function burn(uint256 amount) external;
}

// Price reads go through extsload, NOT getSlot0: current v4-core
// removed getSlot0 from IPoolManager, and the Robinhood PoolManager's
// bytecode has no getSlot0 selector (verified 2026-10-25). extsload's
// selector (0x1e2eaeaf) IS present onchain.
// Slot0 is the first member of Pool.State, so a pool's slot0 word lives
// at keccak256(abi.encode(poolId, POOLS_SLOT)). The word packs
// sqrtPriceX96 (low 160 bits) | tick | protocolFee | lpFee, so the
// price is the low 160 bits. POOLS_SLOT = 6 is derived from the
// canonical layout (Owned owner=0, ProtocolFees accrued=1,
// controller=2, ERC6909 balanceOf=3, isOperator=4, allowance=5, then
// _pools=6) and MUST be verified before deploy: a wrong slot feeds
// unrelated storage into scoring. Verification route: Blockscout Read
// -> extsload with the computed slot word (see DESIGN doc), or RPC
// eth_call once the rate limit clears. The constructor's >0 check
// catches an empty slot but cannot catch a wrong-but-nonzero slot.
interface IPoolManager {
    function extsload(bytes32 slot) external view returns (bytes32);
}

contract WifAgentArenaV3 {
    IERC20 public wif;
    IPoolManager public poolManager;
    bytes32 public poolId;

    uint256 public constant MIN_ENTRY_RAW = 100 * 10 ** 18;
    uint256 public constant MAX_ENTRY_RAW = 100000 * 10 ** 18;
    uint256 public constant ROUND_DURATION = 1 hours;
    uint256 public constant SNAPSHOT_MIN_INTERVAL = 5 minutes;
    uint256 public constant MAX_PRICE_POINTS = 16; // start + up to 15 snapshots
    uint256 public constant VIRTUAL_CAPITAL = 1e18;
    uint256 public constant POOLS_SLOT = 6; // candidate — verify before deploy (see IPoolManager note above)

    uint256 public currentRoundId;
    uint256 public nextRoundPool;
    uint256[] public agentIds;

    struct Round {
        uint256 startTime;
        uint256 endTime;
        bool settled;
        uint256 winningAgent;
        uint256 prizePool;
        uint256 totalCollected;
        uint256 totalBackings;
        uint256 lastSnapshotTime;
        uint160[] prices;
        mapping(uint256 => uint256) wifByAgent;
        mapping(address => mapping(uint256 => uint256)) wifByBacker;
        mapping(address => bool) claimed;
        mapping(uint256 => uint256) scoreByAgent;
    }

    mapping(uint256 => Round) private rounds;
    mapping(uint256 => bool) public agentExists;

    event RoundStarted(uint256 indexed roundId, uint256 endTime, uint160 startPrice);
    event PriceSnapshot(uint256 indexed roundId, uint160 sqrtPriceX96, uint256 timestamp);
    event Entered(uint256 indexed roundId, address indexed backer, uint256 indexed agentId, uint256 amount);
    event RoundSettled(
        uint256 indexed roundId,
        uint256 winningAgent,
        uint256 prizePool,
        uint256 burned,
        uint256 nextPool,
        uint256[] scores
    );
    event Claimed(uint256 indexed roundId, address indexed backer, uint256 amount);

    constructor(address wifToken, address poolManager_, bytes32 poolId_, uint256[] memory agentIds_) {
        require(wifToken != address(0), "bad token");
        require(poolManager_ != address(0), "bad pool manager");
        require(agentIds_.length > 0, "no agents");
        wif = IERC20(wifToken);
        poolManager = IPoolManager(poolManager_);
        poolId = poolId_;
        for (uint256 i = 0; i < agentIds_.length; i++) {
            agentExists[agentIds_[i]] = true;
            agentIds.push(agentIds_[i]);
        }
        _startRound();
    }

    function _poolPrice() internal view returns (uint160) {
        bytes32 slot = keccak256(abi.encode(poolId, POOLS_SLOT));
        bytes32 word = poolManager.extsload(slot);
        uint160 sqrtPriceX96 = uint160(uint256(word));
        require(sqrtPriceX96 > 0, "bad pool price");
        return sqrtPriceX96;
    }

    function _startRound() internal {
        currentRoundId += 1;
        Round storage r = rounds[currentRoundId];
        r.startTime = block.timestamp;
        r.endTime = block.timestamp + ROUND_DURATION;
        r.lastSnapshotTime = block.timestamp;
        uint160 startPrice = _poolPrice();
        r.prices.push(startPrice);
        emit RoundStarted(currentRoundId, r.endTime, startPrice);
    }

    function enter(uint256 agentId, uint256 amount) external {
        require(agentExists[agentId], "unknown agent");
        require(amount >= MIN_ENTRY_RAW, "below min 100 WIF");
        require(amount <= MAX_ENTRY_RAW, "above max 100000 WIF");
        Round storage r = rounds[currentRoundId];
        require(block.timestamp < r.endTime, "round closed");
        require(wif.transferFrom(msg.sender, address(this), amount), "transfer failed");
        r.wifByAgent[agentId] += amount;
        r.wifByBacker[msg.sender][agentId] += amount;
        r.totalCollected += amount;
        r.totalBackings += 1;
        emit Entered(currentRoundId, msg.sender, agentId, amount);
    }

    // Permissionless. The caller supplies NO price: the contract reads
    // the pool itself, so a snapshot can never contain an invented price.
    function snapshot() external {
        Round storage r = rounds[currentRoundId];
        require(block.timestamp < r.endTime, "round closed");
        require(block.timestamp >= r.lastSnapshotTime + SNAPSHOT_MIN_INTERVAL, "too soon");
        require(r.prices.length < MAX_PRICE_POINTS, "max snapshots");
        uint160 price = _poolPrice();
        r.prices.push(price);
        r.lastSnapshotTime = block.timestamp;
        emit PriceSnapshot(currentRoundId, price, block.timestamp);
    }

    // Permissionless. No winner argument, no owner gate. The winner is
    // computed here, from this round's recorded prices + the fixed rules
    // in _scores(). Whoever calls this only triggers the computation.
    function settle() external {
        Round storage r = rounds[currentRoundId];
        require(block.timestamp >= r.endTime, "round not over");
        require(!r.settled, "already settled");
        uint256[] memory scores = _scores(r);
        uint256 winningAgent = _pickWinner(scores, r);
        for (uint256 i = 0; i < agentIds.length; i++) {
            r.scoreByAgent[agentIds[i]] = scores[i];
        }
        uint256 totalCollected = r.totalCollected;
        uint256 prize = (totalCollected * 50) / 100 + nextRoundPool;
        uint256 burned = (totalCollected * 30) / 100;
        uint256 nextPool = totalCollected - (totalCollected * 50) / 100 - burned;
        if (burned > 0) {
            wif.burn(burned);
        }
        r.settled = true;
        r.winningAgent = winningAgent;
        r.prizePool = prize;
        nextRoundPool = nextPool;
        emit RoundSettled(currentRoundId, winningAgent, prize, burned, nextPool, scores);
        _startRound();
    }

    // Pure scoring over a round's price points. positions for step i->i+1
    // are decided at snapshot i from history 0..i only (no lookahead).
    function _scores(Round storage r) internal view returns (uint256[] memory) {
        uint256 n = r.prices.length;
        uint256[] memory capital = new uint256[](agentIds.length);
        for (uint256 i = 0; i < agentIds.length; i++) {
            capital[i] = VIRTUAL_CAPITAL;
        }
        uint160 maxSoFar = r.prices[0];
        for (uint256 i = 0; i + 1 < n; i++) {
            bool momLong = false;
            bool meanLong = false;
            bool breakLong = false;
            if (i > 0) {
                momLong = r.prices[i] > r.prices[i - 1];
                meanLong = r.prices[i] < r.prices[i - 1];
                breakLong = r.prices[i] > maxSoFar;
            }
            if (r.prices[i] > maxSoFar) {
                maxSoFar = r.prices[i];
            }
            uint256 stepFactor = (uint256(r.prices[i + 1]) * VIRTUAL_CAPITAL) / uint256(r.prices[i]);
            // Strategy is keyed by agent ID, not by position in agentIds[],
            // so deploy order cannot silently reassign strategies:
            // 1 = Momentum, 2 = Mean-reversion, 3 = Breakout.
            for (uint256 j = 0; j < agentIds.length; j++) {
                bool long_ = false;
                if (agentIds[j] == 1) {
                    long_ = momLong;
                } else if (agentIds[j] == 2) {
                    long_ = meanLong;
                } else if (agentIds[j] == 3) {
                    long_ = breakLong;
                }
                if (long_) {
                    capital[j] = (capital[j] * stepFactor) / VIRTUAL_CAPITAL;
                }
            }
        }
        return capital;
    }

    // Highest score wins. Exact ties for first place are broken
    // deterministically among the tied agents only — no human input.
    function _pickWinner(uint256[] memory scores, Round storage r) internal view returns (uint256) {
        uint256 best = 0;
        for (uint256 i = 0; i < scores.length; i++) {
            if (scores[i] > best) {
                best = scores[i];
            }
        }
        uint256 tiedCount = 0;
        for (uint256 i = 0; i < scores.length; i++) {
            if (scores[i] == best) {
                tiedCount++;
            }
        }
        uint256 hash = uint256(
            keccak256(abi.encodePacked(currentRoundId, r.prices[0], r.prices[r.prices.length - 1]))
        );
        uint256 pick = hash % tiedCount;
        uint256 seen = 0;
        for (uint256 i = 0; i < scores.length; i++) {
            if (scores[i] == best) {
                if (seen == pick) {
                    return agentIds[i];
                }
                seen++;
            }
        }
        return agentIds[0]; // unreachable: best always has >= 1 tied agent
    }

    function claim(uint256 roundId) external {
        Round storage r = rounds[roundId];
        require(r.settled, "not settled");
        require(!r.claimed[msg.sender], "already claimed");
        uint256 myAmount = r.wifByBacker[msg.sender][r.winningAgent];
        require(myAmount > 0, "not a winner backer");
        uint256 winningTotal = r.wifByAgent[r.winningAgent];
        require(winningTotal > 0, "no winning entries");
        uint256 amount = (r.prizePool * myAmount) / winningTotal;
        r.claimed[msg.sender] = true;
        require(wif.transfer(msg.sender, amount), "claim failed");
        emit Claimed(roundId, msg.sender, amount);
    }

    function roundInfo(uint256 roundId)
        external
        view
        returns (uint256 startTime, uint256 endTime, bool settled, uint256 winningAgent, uint256 prizePool, uint256 totalCollected, uint256 totalBackings)
    {
        Round storage r = rounds[roundId];
        return (r.startTime, r.endTime, r.settled, r.winningAgent, r.prizePool, r.totalCollected, r.totalBackings);
    }

    function agentTotal(uint256 roundId, uint256 agentId) external view returns (uint256) {
        return rounds[roundId].wifByAgent[agentId];
    }

    function backerAmount(uint256 roundId, address backer, uint256 agentId) external view returns (uint256) {
        return rounds[roundId].wifByBacker[backer][agentId];
    }

    function agentScore(uint256 roundId, uint256 agentId) external view returns (uint256) {
        return rounds[roundId].scoreByAgent[agentId];
    }

    function pricePoints(uint256 roundId) external view returns (uint160[] memory) {
        return rounds[roundId].prices;
    }

    function snapshotCount(uint256 roundId) external view returns (uint256) {
        return rounds[roundId].prices.length;
    }
}
