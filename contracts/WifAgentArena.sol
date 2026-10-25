// SPDX-License-Identifier: MIT
// WIF Agent Arena — DRAFT, NOT AUDITED, NOT DEPLOYED
// MVP for the worldisflat.fun hackathon.
// Users enter a round by paying $WIF to back one agent.
// Fee split (locked in SCOPE.md): 50% prize pool, 30% burn, 20% next round.
// Settlement is by the owner/oracle in v1. Winners claim pro-rata.
// $WIF verified on Blockscout 2026-10-24 (read-only check, 22:47-22:49 WIB):
// name World is Flat, symbol WIF, decimals 18, total supply 1,000,000,000,
// contract verified as PonsV2LauncherToken, with burn() / burnFrom()
// (OpenZeppelin ERC20Burnable). Entry for the MVP is therefore
// 100 $WIF = 100 * 10**18 raw units. The $WIF pool address for a live
// price feed is still NOT verified — see config.json.

pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function burn(uint256 amount) external;
}

contract WifAgentArena {
    address public owner;
    IERC20 public wif;

    uint256 public entryAmountRaw;
    uint256 public roundDuration = 1 days;
    uint256 public currentRoundId;
    uint256 public nextRoundPool;

    struct Round {
        uint256 startTime;
        uint256 endTime;
        bool settled;
        uint256 winningAgent;
        uint256 prizePool;
        uint256 totalEntries;
        mapping(uint256 => uint256) entriesByAgent;
        mapping(address => mapping(uint256 => uint256)) entriesByBacker;
        mapping(address => bool) claimed;
    }

    mapping(uint256 => Round) private rounds;
    mapping(uint256 => bool) public agentExists;

    event RoundStarted(uint256 indexed roundId, uint256 endTime);
    event Entered(uint256 indexed roundId, address indexed backer, uint256 indexed agentId);
    event RoundSettled(uint256 indexed roundId, uint256 winningAgent, uint256 prizePool, uint256 burned, uint256 nextPool);
    event Claimed(uint256 indexed roundId, address indexed backer, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address wifToken, uint256 _entryAmountRaw, uint256[] memory agentIds) {
        require(wifToken != address(0), "bad token");
        require(_entryAmountRaw > 0, "bad entry");
        owner = msg.sender;
        wif = IERC20(wifToken);
        entryAmountRaw = _entryAmountRaw;
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
        if (nextRoundPool > 0) {
            // Carried pool is added to the prize pool at settlement time
            // by the settle function, not double-counted here.
        }
        emit RoundStarted(currentRoundId, r.endTime);
    }

    function enter(uint256 agentId) external {
        require(agentExists[agentId], "unknown agent");
        Round storage r = rounds[currentRoundId];
        require(block.timestamp < r.endTime, "round closed");
        require(!r.settled, "settled");
        require(wif.transferFrom(msg.sender, address(this), entryAmountRaw), "transfer failed");
        r.entriesByAgent[agentId] += 1;
        r.entriesByBacker[msg.sender][agentId] += 1;
        r.totalEntries += 1;
        emit Entered(currentRoundId, msg.sender, agentId);
    }

    function settle(uint256 winningAgent) external onlyOwner {
        Round storage r = rounds[currentRoundId];
        require(block.timestamp >= r.endTime, "round not over");
        require(!r.settled, "already settled");
        require(agentExists[winningAgent], "unknown agent");
        uint256 totalCollected = r.totalEntries * entryAmountRaw;
        uint256 prize = (totalCollected * 50) / 100 + nextRoundPool;
        uint256 burned = (totalCollected * 30) / 100;
        uint256 nextPool = totalCollected - (totalCollected * 50) / 100 - burned;
        // True burn: $WIF's own burn() is verified on Blockscout, so the
        // arena burns from its own collected balance instead of sending
        // tokens to a dead address.
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
        uint256 backerEntries = r.entriesByBacker[msg.sender][r.winningAgent];
        require(backerEntries > 0, "not a winner backer");
        uint256 winningEntries = r.entriesByAgent[r.winningAgent];
        require(winningEntries > 0, "no winning entries");
        uint256 amount = (r.prizePool * backerEntries) / winningEntries;
        r.claimed[msg.sender] = true;
        require(wif.transfer(msg.sender, amount), "claim failed");
        emit Claimed(roundId, msg.sender, amount);
    }

    function roundInfo(uint256 roundId)
        external
        view
        returns (uint256 startTime, uint256 endTime, bool settled, uint256 winningAgent, uint256 prizePool, uint256 totalEntries)
    {
        Round storage r = rounds[roundId];
        return (r.startTime, r.endTime, r.settled, r.winningAgent, r.prizePool, r.totalEntries);
    }
}
