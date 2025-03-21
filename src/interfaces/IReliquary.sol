// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

/**
 * @notice Info for each Reliquary position.
 * `amount` LP token amount the position owner has provided.
 * `rewardDebt` Amount of reward token accumalated before the position's entry or last harvest.
 * `rewardCredit` Amount of reward token owed to the user on next harvest.
 * `entry` Used to determine the maturity of the position.
 * `poolId` ID of the pool to which this position belongs.
 * `level` Index of this position's level within the pool's array of levels.
 */
struct PositionInfo {
    uint256 amount;
    uint256 rewardDebt;
    uint256 rewardCredit;
    uint256 entry; // position owner's relative entry into the pool.
    uint256 poolId; // ensures that a single Relic is only used for one pool.
    uint256 level;
}

/**
 * @notice Info of each Reliquary pool.
 * `accRewardPerShare` Accumulated reward tokens per share of pool (1 / 1e12).
 * `lastRewardTime` Last timestamp the accumulated reward was updated.
 * `allocPoint` Pool's individual allocation - ratio of the total allocation.
 * `name` Name of pool to be displayed in NFT image.
 */
struct PoolInfo {
    uint256 accRewardPerShare;
    uint256 lastRewardTime;
    uint256 allocPoint;
    string name;
}

/**
 * @notice Info for each level in a pool that determines how maturity is rewarded.
 * `requiredMaturities` The minimum maturity (in seconds) required to reach each Level.
 * `multipliers` Multiplier for each level applied to amount of incentivized token when calculating rewards in the pool.
 *     This is applied to both the numerator and denominator in the calculation such that the size of a user's position
 *     is effectively considered to be the actual number of tokens times the multiplier for their level.
 *     Also note that these multipliers do not affect the overall emission rate.
 * `balance` Total (actual) number of tokens deposited in positions at each level.
 */
struct LevelInfo {
    uint256[] requiredMaturities;
    uint256[] multipliers;
    uint256[] balance;
}

/**
 * @notice Object representing pending rewards and related data for a position.
 * `relicId` The NFT ID of the given position.
 * `poolId` ID of the pool to which this position belongs.
 * `pendingReward` pending reward amount for a given position.
 */
struct PendingReward {
    uint256 relicId;
    uint256 poolId;
    uint256 pendingReward;
}

interface IReliquary is IERC721Enumerable {
    function setEmissionCurve(address _emissionCurve) external;
    function addPool(
        uint256 allocPoint,
        address _poolToken,
        address _rewarder,
        uint256[] calldata requiredMaturity,
        uint256[] calldata allocPoints,
        string memory name,
        address _nftDescriptor
    ) external;
    function modifyPool(
        uint256 pid,
        uint256 allocPoint,
        address _rewarder,
        string calldata name,
        address _nftDescriptor,
        bool overwriteRewarder
    ) external;
    function massUpdatePools(uint256[] calldata pids) external;
    function updatePool(uint256 pid) external;
    function deposit(uint256 amount, uint256 relicId) external;
    function withdraw(uint256 amount, uint256 relicId) external;
    function harvest(uint256 relicId, address harvestTo) external;
    function withdrawAndHarvest(uint256 amount, uint256 relicId, address harvestTo) external;
    function emergencyWithdraw(uint256 relicId) external;
    function updatePosition(uint256 relicId) external;
    function getPositionForId(uint256) external view returns (PositionInfo memory);
    function getPoolInfo(uint256) external view returns (PoolInfo memory);
    function getLevelInfo(uint256) external view returns (LevelInfo memory);
    function pendingRewardsOfOwner(address owner) external view returns (PendingReward[] memory pendingRewards);
    function relicPositionsOfOwner(address owner)
        external
        view
        returns (uint256[] memory relicIds, PositionInfo[] memory positionInfos);
    function isApprovedOrOwner(address, uint256) external view returns (bool);
    function createRelicAndDeposit(address to, uint256 pid, uint256 amount) external returns (uint256 id);
    function split(uint256 relicId, uint256 amount, address to) external returns (uint256 newId);
    function shift(uint256 fromId, uint256 toId, uint256 amount) external;
    function merge(uint256 fromId, uint256 toId) external;
    function burn(uint256 tokenId) external;
    function pendingReward(uint256 relicId) external view returns (uint256 pending);
    function levelOnUpdate(uint256 relicId) external view returns (uint256 level);
    function poolLength() external view returns (uint256);

    function rewardToken() external view returns (address);
    function nftDescriptor(uint256) external view returns (address);
    function emissionCurve() external view returns (address);
    function poolToken(uint256) external view returns (address);
    function rewarder(uint256) external view returns (address);
    function totalAllocPoint() external view returns (uint256);
}
