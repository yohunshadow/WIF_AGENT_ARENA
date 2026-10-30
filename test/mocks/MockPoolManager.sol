// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Stand-in for the Uniswap v4 PoolManager. Only `extsload` is
/// implemented, which is all WifAgentArenaV3 uses. Storage words are set
/// directly by tests; `setSqrtPrice` writes a realistic packed Slot0 word
/// (sqrtPriceX96 | tick | protocolFee | lpFee) at the same slot the arena
/// computes: keccak256(abi.encode(poolId, POOLS_SLOT)).
///
/// In tests, calling `setSqrtPrice` models "someone swapped and the pool
/// price moved". It is NOT a capability of the real PoolManager.
contract MockPoolManager {
    uint256 public constant POOLS_SLOT = 6;
    mapping(bytes32 => bytes32) public words;

    function slot0Slot(bytes32 poolId) public pure returns (bytes32) {
        return keccak256(abi.encode(poolId, POOLS_SLOT));
    }

    function setWord(bytes32 slot, bytes32 word) external {
        words[slot] = word;
    }

    /// Packs Slot0 the way v4-core does: low 160 bits sqrtPriceX96, next
    /// 24 bits tick, then 24-bit protocolFee and 24-bit lpFee.
    function setSqrtPrice(bytes32 poolId, uint160 sqrtPriceX96) external {
        int24 tick = 144650; // arbitrary non-zero tick so the upper bits are not empty
        uint256 word = uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(0x000BB8) << 208);
        words[slot0Slot(poolId)] = bytes32(word);
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return words[slot];
    }
}
