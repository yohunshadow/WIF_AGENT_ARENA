// SPDX-License-Identifier: MIT
// WIF Agent Arena V2 — DRAFT, NOT AUDITED
// Changes vs V1, at user direction 2026-10-25:
//  - Round duration: 1 day -> 1 hour, so fights happen hourly, not daily.
//  - Entry: fixed 100 $WIF -> variable, min 100 $WIF, max 100,000 $WIF
//    per enter call, so backing is a real stake with a real range.
//  - Prize is pro-rata by $WIF backed on the winning agent, NOT by
//    entry count (V1 counted entries; with variable stakes, counting
//    entries would let a 100 $WIF backer take the same share as a
//    100,000 $WIF backer, which would be wrong).
//  - Fee split unchanged: 50% prize pool / 30% burn / 20% next round.
//  - Settlement still by the owner/oracle in V2. Winners claim pro-rata.
//  - New read helpers (agentTotal, backerAmount) so a frontend can show
//    per-agent totals live — V1 exposed only the round total.
// $WIF: 0x5173b8eA6923c2d40267890D45C46a3480954773, 18 decimals,
// burn() verified on Blockscout. Entry bounds are in raw units:
// 100 $WIF = 100 * 10**18, 100,000 $WIF = 100,000 * 10**18.

pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function burn(uint256 amount) external;
}

contract WifAgentArenaV2 {
    address public owner;
    IERC20 public wif;

    uint256 public constant MIN_ENTRY_RAW = 100 * 10 ** 18;
    uint256 public constant MAX_ENTRY_RAW = 100000 * 10 ** 18;
    uint256 public roundDuration = 1 hours;
    uint256 public currentRoundId;
    uint256 public nextRoundPool;

    struct Round {
        uint256 startTime;
        uint256 endTime;
        bool settled;
        uint256 winningAgent;
        uint256 prizePool;
        uint256 totalCollected;
        uint256 totalBackings;
        mapping(uint256 => uint256) wifByAgent;
        mapping(address => mapping(uint256 => uint256)) wifByBacker;
        mapping(address => bool) claimed;
    }

    mapping(uint256 => Round) private rounds;
    mapping(uint256 => bool) public agentExists;

    event RoundStarted(uint256 indexed roundId, uint256 endTime);
    event Entered(uint256 indexed roundId, address indexed backer, uint256 indexed agentId, uint256 amount);
    event RoundSettled(uint256 indexed roundId, uint256 winningAgent, uint256 prizePool, uint256 burned, uint256 nextPool);
    event Claimed(uint256 indexed roundId, address indexed backer, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address wifToken, uint256[] memory agentIds) {
        require(wifToken != address(0), "bad token");
        owner = msg.sender;
        wif = IERC20(wifToken);
        for (uint256 i = 0; i < agentIds.length; i++) {
            agentExists[agentIds[i]] = true;
        }
        _startRound();
    }

    function _startRound() internal {
        currentRoundId += 1;
        Round storage r = rounds[currentRoundId];
        r.startTime = block.timestamp;
        r.endTime = block.timestamp + roundDuration;
        emit RoundStarted(currentRoundId, r.endTime);
    }

    function enter(uint256 agentId, uint256 amount) external {
        require(agentExists[agentId], "unknown agent");
        require(amount >= MIN_ENTRY_RAW, "below min 100 WIF");
        require(amount <= MAX_ENTRY_RAW, "above max 100000 WIF");
        Round storage r = rounds[currentRoundId];
        require(block.timestamp < r.endTime, "round closed");
        require(!r.settled, "settled");
        require(wif.transferFrom(msg.sender, address(this), amount), "transfer failed");
        r.wifByAgent[agentId] += amount;
        r.wifByBacker[msg.sender][agentId] += amount;
        r.totalCollected += amount;
        r.totalBackings += 1;
        emit Entered(currentRoundId, msg.sender, agentId, amount);
    }

    function settle(uint256 winningAgent) external onlyOwner {
        Round storage r = rounds[currentRoundId];
        require(block.timestamp >= r.endTime, "round not over");
        require(!r.settled, "already settled");
        require(agentExists[winningAgent], "unknown agent");
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
        emit RoundSettled(currentRoundId, winningAgent, prize, burned, nextPool);
        _startRound();
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
}
