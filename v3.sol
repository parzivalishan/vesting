// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SCEvesting is Ownable, Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    // Vesting Types
    enum Type {
        Linear,
        Monthly,
        Interval,
        Custom
    }

    // Vesting Information
    struct VestingInfo {
        string name;
        uint256 cliff;
        uint256 start;
        uint256 duration;
        uint256 initialUnlockPercent;
        bool revocable;
        Type vestType;
        uint256 interval;
        uint256 unlockPerInterval;
        uint256[] timestamps;
        uint256[] unlockPercentages; // For Custom vesting type
        address token;
        bool paused;
    }

    // Vesting Pool
    struct VestingPool {
        string name;
        uint256 cliff;
        uint256 start;
        uint256 duration;
        uint256 initialUnlockPercent;
        WhitelistInfo[] whitelistPool;
        mapping(address => HasWhitelist) hasWhitelist;
        bool revocable;
        Type vestType;
        uint256 interval;
        uint256 unlockPerInterval;
        uint256[] timestamps;
        uint256[] unlockPercentages; // For Custom vesting type
        address token;
        bool paused;
    }

    // Whitelist Information
    struct WhitelistInfo {
        address wallet;
        uint256 sceAmount;
        uint256 distributedAmount;
        uint256 joinDate;
        uint256 revokeDate;
        bool revoke;
        bool disabled;
    }

    // Has Whitelist
    struct HasWhitelist {
        uint256 arrIdx;
        bool active;
    }

    // State Variables
    VestingPool[] public vestingPools;
    mapping(address => bool) public blacklist;

    // Events
    event AddVestingPool(uint256 indexed poolId, address indexed token);
    event AddWhitelist(uint256 indexed poolId, address indexed wallet);
    event RemoveWhitelist(uint256 indexed poolId, address indexed wallet);
    event ChangeAddressAllocation(uint256 indexed poolId, address indexed wallet, uint256 newAmount);
    event Claim(address indexed wallet, uint256 amount, address indexed token, uint256 time);
    event PoolPaused(uint256 indexed poolId, bool paused);
    event AllTransfersPaused(bool paused);
    event RemoveEth(uint256 amount);
    event RemoveToken(address indexed token, uint256 amount);
    event BlacklistUpdated(address indexed wallet, bool blacklisted);
    event VestingChanged(uint256 indexed poolId);

    // Modifiers
    modifier onlyAdmin() {
        require(msg.sender == owner(), "Only admin can call this function");
        _;
    }

    modifier poolExists(uint256 _poolId) {
        require(_poolId < vestingPools.length, "Pool does not exist");
        _;
    }

    modifier userInWhitelist(uint256 _poolId, address _wallet) {
        require(vestingPools[_poolId].hasWhitelist[_wallet].active, "User is not in whitelist");
        _;
    }

    modifier poolNotPaused(uint256 _poolId) {
        require(!vestingPools[_poolId].paused, "Pool is paused");
        _;
    }

    modifier notBlacklisted(address _wallet) {
        require(!blacklist[_wallet], "Wallet is blacklisted");
        _;
    }

    // Constructor
    constructor() Ownable(msg.sender) {}

    // Struct to group vesting pool parameters
    struct VestingPoolParams {
        string name;
        uint256 cliff;
        uint256 start;
        uint256 duration;
        uint256 initialUnlockPercent;
        bool revocable;
        uint256 interval;
        uint16 unlockPerInterval;
        uint8 monthGap;
        Type vestType;
        address token;
        uint256[] timestamps;
        uint256[] unlockPercentages;
    }

    // Add Vesting Pool
    function addVestingPool(VestingPoolParams memory params) external onlyAdmin returns (uint256 poolId) {
        require(params.token != address(0), "Invalid token address");
        require(params.initialUnlockPercent <= 1000, "Invalid initial unlock percent");
        require(params.start >= block.timestamp, "Start time must be in the future");

        VestingPool storage newPool = vestingPools.push();

        _updatePoolDetails(
            newPool,
            params.name,
            params.cliff,
            params.start,
            params.duration,
            params.initialUnlockPercent,
            params.revocable,
            params.vestType,
            params.token
        );

        if (params.vestType == Type.Interval) {
            _updateIntervalDetails(newPool, params.interval, params.unlockPerInterval);
        } else if (params.vestType == Type.Monthly) {
            _updateMonthlyDetails(newPool, params.unlockPerInterval, params.monthGap);
        } else if (params.vestType == Type.Custom) {
            _updateCustomDetails(newPool, params.timestamps, params.unlockPercentages);
        }

        poolId = vestingPools.length - 1;
        emit AddVestingPool(poolId, params.token);
    }

    // Update Pool Details
    function _updatePoolDetails(
        VestingPool storage pool,
        string memory _name,
        uint256 _cliff,
        uint256 _start,
        uint256 _duration,
        uint256 _initialUnlockPercent,
        bool _revocable,
        Type _type,
        address _token
    ) internal {
        pool.name = _name;
        pool.cliff = _start.add(_cliff);
        pool.start = _start;
        pool.duration = _duration;
        pool.initialUnlockPercent = _initialUnlockPercent;
        pool.revocable = _revocable;
        pool.vestType = _type;
        pool.token = _token;
    }

    // Update Interval Details
    function _updateIntervalDetails(
        VestingPool storage pool,
        uint256 _interval,
        uint16 _unlockPerInterval
    ) internal {
        require(_interval > 0, "Invalid interval");
        require(_unlockPerInterval > 0, "Invalid unlock per interval");

        pool.interval = _interval;
        pool.unlockPerInterval = _unlockPerInterval;
    }

    // Update Monthly Details
    function _updateMonthlyDetails(
        VestingPool storage pool,
        uint16 _unlockPerInterval,
        uint8 _monthGap
    ) internal {
        require(_unlockPerInterval > 0, "Invalid unlock per interval");
        require(_monthGap > 0, "Invalid month gap");

        pool.unlockPerInterval = _unlockPerInterval;

        uint256 time = pool.cliff;
        for (uint16 i = 0; i <= 1000; i += _unlockPerInterval) {
            pool.timestamps.push(time);
            time = addMonths(time, _monthGap);
        }
    }

    // Update Custom Details
    function _updateCustomDetails(
        VestingPool storage pool,
        uint256[] memory _timestamps,
        uint256[] memory _unlockPercentages
    ) internal {
        require(_timestamps.length == _unlockPercentages.length, "Arrays length mismatch");
        require(_timestamps.length > 0, "No timestamps provided");

        pool.timestamps = _timestamps;
        pool.unlockPercentages = _unlockPercentages;
    }

    // Add Months considering leap years
    function addMonths(uint256 _timestamp, uint256 _months) internal pure returns (uint256) {
        (uint256 year, uint256 month, uint256 day) = daysToDate(_timestamp / 86400);
        month += _months;
        year += (month - 1) / 12;
        month = (month - 1) % 12 + 1;
        uint256 daysInMonth = getDaysInMonth(year, month);
        if (day > daysInMonth) {
            day = daysInMonth;
        }
        return dateToDays(year, month, day) * 86400;
    }

    // Convert days to date
    function daysToDate(uint256 _days) internal pure returns (uint256 year, uint256 month, uint256 day) {
        int256 __days = int256(_days);

        int256 L = __days + 68569 + 2440588;
        int256 N = 4 * L / 146097;
        L = L - (146097 * N + 3) / 4;
        int256 _year = 4000 * (L + 1) / 1461001;
        L = L - 1461 * _year / 4 + 31;
        int256 _month = 80 * L / 2447;
        int256 _day = L - 2447 * _month / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;

        year = uint256(_year);
        month = uint256(_month);
        day = uint256(_day);
    }

    // Convert date to days
    function dateToDays(uint256 year, uint256 month, uint256 day) internal pure returns (uint256 _days) {
        int256 _year = int256(year);
        int256 _month = int256(month);
        int256 _day = int256(day);

        if (_month < 3) {
            _year -= 1;
            _month += 12;
        }
        _days = uint256((1461 * _year) / 4 + (153 * _month - 457) / 5 + _day - 719469);
    }

    // Get days in month
    function getDaysInMonth(uint256 year, uint256 month) internal pure returns (uint256) {
        if (month == 1 || month == 3 || month == 5 || month == 7 || month == 8 || month == 10 || month == 12) {
            return 31;
        } else if (month == 4 || month == 6 || month == 9 || month == 11) {
            return 30;
        } else if (isLeapYear(year)) {
            return 29;
        } else {
            return 28;
        }
    }

    // Check if year is leap year
    function isLeapYear(uint256 year) internal pure returns (bool) {
        if (year % 4 != 0) {
            return false;
        }
        if (year % 100 != 0) {
            return true;
        }
        if (year % 400 != 0) {
            return false;
        }
        return true;
    }

    // Add Multiple Users to Whitelist
    function addWhitelistBatch(
        uint256 _poolId,
        address[] memory _wallets,
        uint256[] memory _sceAmounts
    ) external onlyAdmin poolExists(_poolId) {
        require(_wallets.length == _sceAmounts.length, "Arrays length mismatch");

        for (uint256 i = 0; i < _wallets.length; i++) {
            addWhitelist(_poolId, _wallets[i], _sceAmounts[i]);
        }
    }

    // Add User to Whitelist
    function addWhitelist(
        uint256 _poolId,
        address _wallet,
        uint256 _sceAmount
    ) internal onlyAdmin poolExists(_poolId) {
        HasWhitelist storage whitelist = vestingPools[_poolId].hasWhitelist[_wallet];
        require(!whitelist.active, "User already in whitelist");

        WhitelistInfo[] storage pool = vestingPools[_poolId].whitelistPool;

        whitelist.active = true;
        whitelist.arrIdx = pool.length;

        pool.push(
            WhitelistInfo({
                wallet: _wallet,
                sceAmount: _sceAmount,
                distributedAmount: 0,
                joinDate: block.timestamp,
                revokeDate: 0,
                revoke: false,
                disabled: false
            })
        );

        emit AddWhitelist(_poolId, _wallet);
    }

    // Remove User from Whitelist
    function removeWhitelist(uint256 _poolId, address _wallet)
        external
        onlyAdmin
        poolExists(_poolId)
        userInWhitelist(_poolId, _wallet)
    {
        HasWhitelist storage whitelist = vestingPools[_poolId].hasWhitelist[_wallet];
        WhitelistInfo[] storage pool = vestingPools[_poolId].whitelistPool;

        pool[whitelist.arrIdx].disabled = true;
        whitelist.active = false;

        emit RemoveWhitelist(_poolId, _wallet);
    }

    // Change User's Allocation in Pool
    function changeAddressAllocation(
        uint256 _poolId,
        address _wallet,
        uint256 _newAmount
    ) external onlyAdmin poolExists(_poolId) userInWhitelist(_poolId, _wallet) {
        WhitelistInfo storage user = vestingPools[_poolId].whitelistPool[vestingPools[_poolId].hasWhitelist[_wallet].arrIdx];
        user.sceAmount = _newAmount;

        emit ChangeAddressAllocation(_poolId, _wallet, _newAmount);
    }

    // Pause/Unpause a Pool
    function setPoolPaused(uint256 _poolId, bool _paused) external onlyAdmin poolExists(_poolId) {
        vestingPools[_poolId].paused = _paused;
        emit PoolPaused(_poolId, _paused);
    }

    // Pause/Unpause All Transfers
    function setAllTransfersPaused(bool _paused) external onlyAdmin {
        if (_paused) {
            _pause();
        } else {
            _unpause();
        }
        emit AllTransfersPaused(_paused);
    }

    // Claim Tokens from All Eligible Pools
    function claimAll(address _token) external nonReentrant whenNotPaused notBlacklisted(msg.sender) {
        uint256 totalUnlocked;
        for (uint256 i = 0; i < vestingPools.length; i++) {
            if (vestingPools[i].token == _token && vestingPools[i].hasWhitelist[msg.sender].active && !vestingPools[i].paused) {
                uint256 releaseAmount = calculateReleasableAmount(i, msg.sender);
                if (releaseAmount > 0) {
                    totalUnlocked += releaseAmount;
                    vestingPools[i].whitelistPool[vestingPools[i].hasWhitelist[msg.sender].arrIdx].distributedAmount += releaseAmount;
                }
            }
        }
        require(totalUnlocked > 0, "No tokens to claim");
        ERC20(_token).safeTransfer(msg.sender, totalUnlocked);
        emit Claim(msg.sender, totalUnlocked, _token, block.timestamp);
    }

    // Claim Tokens from Specific Pools
    function claimByPoolId(address _token, uint256[] memory _poolIds) external nonReentrant whenNotPaused notBlacklisted(msg.sender) {
        uint256 totalUnlocked;
        for (uint256 i = 0; i < _poolIds.length; i++) {
            uint256 poolId = _poolIds[i];
            require(poolId < vestingPools.length, "Pool does not exist");
            if (vestingPools[poolId].token == _token && vestingPools[poolId].hasWhitelist[msg.sender].active && !vestingPools[poolId].paused) {
                uint256 releaseAmount = calculateReleasableAmount(poolId, msg.sender);
                if (releaseAmount > 0) {
                    totalUnlocked += releaseAmount;
                    vestingPools[poolId].whitelistPool[vestingPools[poolId].hasWhitelist[msg.sender].arrIdx].distributedAmount += releaseAmount;
                }
            }
        }
        require(totalUnlocked > 0, "No tokens to claim");
        ERC20(_token).safeTransfer(msg.sender, totalUnlocked);
        emit Claim(msg.sender, totalUnlocked, _token, block.timestamp);
    }

    // Blacklist a Wallet
    function blacklistWallet(address _wallet, bool _blacklisted) external onlyAdmin {
        blacklist[_wallet] = _blacklisted;
        emit BlacklistUpdated(_wallet, _blacklisted);
    }

    // Calculate Releasable Amount
    function calculateReleasableAmount(uint256 _poolId, address _wallet)
        internal
        view
        userInWhitelist(_poolId, _wallet)
        returns (uint256)
    {
        if (vestingPools[_poolId].paused) {
            return 0;
        }

        uint256 idx = vestingPools[_poolId].hasWhitelist[_wallet].arrIdx;
        WhitelistInfo memory whitelist = vestingPools[_poolId].whitelistPool[idx];
        VestingPool storage vest = vestingPools[_poolId];

        uint256 vestedAmount = calculateVestAmount(whitelist, vest);
        return vestedAmount.sub(whitelist.distributedAmount);
    }

    // Calculate Vest Amount
    function calculateVestAmount(WhitelistInfo memory whitelist, VestingPool storage vest)
        internal
        view
        returns (uint256)
    {
        uint256 initial = whitelist.sceAmount.mul(vest.initialUnlockPercent).div(1000);

        if (whitelist.revoke) {
            return whitelist.distributedAmount;
        }

        if (block.timestamp < vest.start) {
            return 0;
        } else if (block.timestamp >= vest.start && block.timestamp < vest.cliff) {
            return initial;
        } else if (block.timestamp >= vest.cliff) {
            if (vest.vestType == Type.Interval) {
                return calculateVestAmountForInterval(whitelist, vest);
            } else if (vest.vestType == Type.Linear) {
                return calculateVestAmountForLinear(whitelist, vest);
            } else if (vest.vestType == Type.Monthly) {
                return calculateVestAmountForMonthly(whitelist, vest);
            } else if (vest.vestType == Type.Custom) {
                return calculateVestAmountForCustom(whitelist, vest);
            }
        }

        // Default return statement to handle all cases
        return 0;
    }

    // Calculate Vest Amount for Linear
    function calculateVestAmountForLinear(WhitelistInfo memory whitelist, VestingPool storage vest)
        internal
        view
        returns (uint256)
    {
        uint256 initial = whitelist.sceAmount.mul(vest.initialUnlockPercent).div(1000);
        uint256 remaining = whitelist.sceAmount.sub(initial);

        if (block.timestamp >= vest.cliff.add(vest.duration)) {
            return whitelist.sceAmount;
        } else {
            return initial + remaining.mul(block.timestamp.sub(vest.cliff)).div(vest.duration);
        }
    }

    // Calculate Vest Amount for Interval
    function calculateVestAmountForInterval(WhitelistInfo memory whitelist, VestingPool storage vest)
        internal
        view
        returns (uint256)
    {
        uint256 initial = whitelist.sceAmount.mul(vest.initialUnlockPercent).div(1000);
        uint256 remaining = whitelist.sceAmount.sub(initial);

        uint256 intervalsPassed = (block.timestamp.sub(vest.cliff)).div(vest.interval);
        uint256 totalUnlocked = intervalsPassed.mul(vest.unlockPerInterval);

        if (totalUnlocked >= 1000) {
            return whitelist.sceAmount;
        } else {
            return initial + remaining.mul(totalUnlocked).div(1000);
        }
    }

    // Calculate Vest Amount for Monthly
    function calculateVestAmountForMonthly(WhitelistInfo memory whitelist, VestingPool storage vest)
        internal
        view
        returns (uint256)
    {
        uint256 initial = whitelist.sceAmount.mul(vest.initialUnlockPercent).div(1000);
        uint256 remaining = whitelist.sceAmount.sub(initial);

        if (block.timestamp > vest.timestamps[vest.timestamps.length - 1]) {
            return whitelist.sceAmount;
        } else {
            uint256 multi = findCurrentTimestamp(vest.timestamps, block.timestamp);
            uint256 totalUnlocked = multi.mul(vest.unlockPerInterval);

            return initial + remaining.mul(totalUnlocked).div(1000);
        }
    }

    // Calculate Vest Amount for Custom
    function calculateVestAmountForCustom(WhitelistInfo memory whitelist, VestingPool storage vest)
        internal
        view
        returns (uint256)
    {
        uint256 initial = whitelist.sceAmount.mul(vest.initialUnlockPercent).div(1000);
        uint256 remaining = whitelist.sceAmount.sub(initial);

        uint256 totalUnlocked = 0;
        for (uint256 i = 0; i < vest.timestamps.length; i++) {
            if (block.timestamp >= vest.timestamps[i]) {
                totalUnlocked += vest.unlockPercentages[i];
            } else {
                break;
            }
        }

        if (totalUnlocked >= 1000) {
            return whitelist.sceAmount;
        } else {
            return initial + remaining.mul(totalUnlocked).div(1000);
        }
    }

    // Find Current Timestamp
    function findCurrentTimestamp(uint256[] memory timestamps, uint256 target)
        internal
        pure
        returns (uint256 pos)
    {
        uint256 last = timestamps.length;
        uint256 first = 0;
        uint256 mid = 0;

        if (target < timestamps[first]) {
            return 0;
        }

        if (target >= timestamps[last - 1]) {
            return last - 1;
        }

        while (first < last) {
            mid = (first + last) / 2;

            if (timestamps[mid] == target) {
                return mid + 1;
            }

            if (target < timestamps[mid]) {
                if (mid > 0 && target > timestamps[mid - 1]) {
                    return mid;
                }

                last = mid;
            } else {
                if (mid < last - 1 && target < timestamps[mid + 1]) {
                    return mid + 1;
                }

                first = mid + 1;
            }
        }
        return mid + 1;
    }

    // Admin function to remove all ETH from the contract
    function removeEth() external onlyAdmin {
        uint256 balance = address(this).balance;
        payable(msg.sender).transfer(balance);
        emit RemoveEth(balance);
    }

    // Admin function to remove all tokens of a specific type from the contract
    function removeToken(address _token) external onlyAdmin {
        uint256 balance = ERC20(_token).balanceOf(address(this));
        ERC20(_token).safeTransfer(msg.sender, balance);
        emit RemoveToken(_token, balance);
    }

    // Get Allocations for a Specific Pool
    function getPoolAllocations(uint256 _poolId)
        external
        view
        poolExists(_poolId)
        returns (
            address[] memory wallets,
            uint256[] memory claimedAmounts,
            uint256[] memory remainingAmounts
        )
    {
        VestingPool storage pool = vestingPools[_poolId];
        uint256 length = pool.whitelistPool.length;

        wallets = new address[](length);
        claimedAmounts = new uint256[](length);
        remainingAmounts = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            wallets[i] = pool.whitelistPool[i].wallet;
            claimedAmounts[i] = _normalizeAmount(pool.whitelistPool[i].distributedAmount, pool.token);
            remainingAmounts[i] = _normalizeAmount(pool.whitelistPool[i].sceAmount - pool.whitelistPool[i].distributedAmount, pool.token);
        }
    }

    // Get Wallet Details
    function getWalletDetails(address _wallet)
        external
        view
        returns (
            bool isBlacklisted,
            uint256 totalClaimed,
            uint256 totalRemaining,
            PoolAllocation[] memory allocations
        )
    {
        isBlacklisted = blacklist[_wallet];
        totalClaimed = 0;
        totalRemaining = 0;

        uint256 poolCount = vestingPools.length;
        allocations = new PoolAllocation[](poolCount);

        for (uint256 i = 0; i < poolCount; i++) {
            if (vestingPools[i].hasWhitelist[_wallet].active) {
                uint256 claimed = vestingPools[i].whitelistPool[vestingPools[i].hasWhitelist[_wallet].arrIdx].distributedAmount;
                uint256 remaining = vestingPools[i].whitelistPool[vestingPools[i].hasWhitelist[_wallet].arrIdx].sceAmount - claimed;

                totalClaimed += claimed;
                totalRemaining += remaining;

                allocations[i] = PoolAllocation({
                    poolId: i,
                    totalAllocation: _normalizeAmount(vestingPools[i].whitelistPool[vestingPools[i].hasWhitelist[_wallet].arrIdx].sceAmount, vestingPools[i].token),
                    claimed: _normalizeAmount(claimed, vestingPools[i].token),
                    remaining: _normalizeAmount(remaining, vestingPools[i].token)
                });
            }
        }

        // Normalize totals
        totalClaimed = _normalizeAmount(totalClaimed, vestingPools[0].token); // Assuming all pools use the same token
        totalRemaining = _normalizeAmount(totalRemaining, vestingPools[0].token);
    }

    // Get Unlocked Tokens for a Wallet and Token
    function getUnlockedTokens(address _wallet, address _token) external view returns (uint256) {
        uint256 totalUnlocked;
        for (uint256 i = 0; i < vestingPools.length; i++) {
            if (vestingPools[i].token == _token && vestingPools[i].hasWhitelist[_wallet].active && !vestingPools[i].paused) {
                totalUnlocked += calculateReleasableAmount(i, _wallet);
            }
        }
        return _normalizeAmount(totalUnlocked, _token);
    }

    // Helper function to normalize token amounts
    function _normalizeAmount(uint256 amount, address token) internal view returns (uint256) {
        uint256 decimals = ERC20(token).decimals();
        return amount.div(10 ** decimals);
    }

    struct PoolAllocation {
        uint256 poolId;
        uint256 totalAllocation;
        uint256 claimed;
        uint256 remaining;
    }
}
