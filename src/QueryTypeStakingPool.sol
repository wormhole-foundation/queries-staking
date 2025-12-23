// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {QueryTypeStakerFactory} from "src/QueryTypeStakerFactory.sol";

/// @title QueryTypeStakingPool
/// @author ScopeLift
/// @notice This contract manages staking of tokens for query type pools. Users can stake tokens for
/// a specified lockup and access period. During the lockup period, tokens cannot be withdrawn.
/// After the lockup period ends, users have an access period during which they can withdraw their
/// tokens. The contract maintains a conversion table history that tracks changes to the conversion
/// rate between staked tokens and query credits.
contract QueryTypeStakingPool is Ownable {
  using SafeERC20 for IERC20;

  /// @notice The decay rate applied to stake amounts. This rate determines what
  /// percentage of the continuously decaying stake is lost as fees.
  /// @dev Expressed as an integer from 0 to 100:
  ///      - 0: No decay (0% lost as fees)
  ///      - 100: Complete decay (100% lost as fees)
  ///      - 50: 50% decay rate (50% lost as fees)
  /// @dev The decay is applied continuously over time, with users losing stake at a rate
  /// proportional to the time elapsed since their last claim. The DECAY_RATE determines
  /// what portion of this decayed amount is lost as fees.
  uint8 public immutable DECAY_RATE;

  /// @notice The duration in seconds that tokens will be locked after staking. During this period
  /// tokens cannot be withdrawn.
  uint48 public lockupPeriod;

  /// @notice The duration in seconds after the lockup period during which tokens can be withdrawn.
  uint48 public accessPeriod;

  /// @notice The array that stores the history of conversion table entries. Each entry represents a
  /// conversion rate between staked tokens and query credits at a point in time.
  bytes32[] public conversionTableHistory;

  /// @notice The ERC20 token contract that can be staked in this pool.
  IERC20 public immutable STAKING_TOKEN;

  /// @notice Address of the factory that deployed this pool. Provides the feeRecipient.
  address public immutable FACTORY;

  /// @notice A struct containing information about a user's stake, including the amount staked, the
  /// index into the conversion table history at time of staking, and the lockup/access period end
  /// times, and capacity of the stake.
  struct StakeInfo {
    uint256 amount;
    uint256 conversionTableIndex;
    uint48 lockupEnd;
    uint48 accessEnd;
    uint48 lastClaimed;
    uint256 capacity;
  }

  /// @notice A mapping that associates staker addresses with their stake information.
  mapping(address staker => StakeInfo info) private stakes;

  /// @notice A mapping that associates each staker with their signer.
  mapping(address staker => address signer) public stakerSigners;

  /// @notice Reverse mapping to track which stakers have authorized a particular signer.
  mapping(address signer => mapping(address staker => bool authorized)) public signerStakers;

  /// @notice The maximum allowed staking capacity.
  uint256 public stakingTokenCapacity;

  /// @notice The minimum required stake amount.
  uint256 public minimumStake;

  /// @notice The total amount of tokens staked in the pool before decay has been applied.
  uint256 public totalCapacityStaked;

  /// @notice The total amount of tokens currently jailed in the pool before decay has been applied.
  uint256 public totalCapacityJailed;

  /// @notice Maps addresses to their blocklist status for this pool.
  mapping(address user => bool blocked) public isBlocklisted;

  /// @notice Emitted when a new conversion table entry is added to track changes in the conversion
  /// rate.
  event ConversionTableUpdated(bytes32 newEntry);

  /// @notice Emitted when tokens are staked, including details about the stake amount and timing.
  event Staked(
    address indexed staker,
    uint256 amount,
    uint256 conversionTableIndex,
    uint48 lockupEnd,
    uint48 accessEnd
  );

  /// @notice Emitted when the lockup period is updated
  event LockupPeriodUpdated(uint48 newPeriod);

  /// @notice Emitted when the access period is updated
  event AccessPeriodUpdated(uint48 newPeriod);

  /// @notice Emitted when the stakingTokenCapacity is updated.
  event StakingTokenCapacityUpdated(uint256 newCapacity);

  /// @notice Emitted when the minimum stake is updated.
  event MinimumStakeUpdated(uint256 newMinimumStake);

  /// @notice Emitted when tokens are unstaked.
  event Unstaked(address indexed staker, uint256 amount);

  /// @notice Emitted when a staker's signer is updated.
  event SignerUpdated(address indexed staker, address indexed oldSigner, address indexed newSigner);

  /// @notice Emitted when a stake is jailed.
  event StakeJailed(address indexed staker, uint256 amount);

  /// @notice Emitted when an address is blocklisted for this pool
  event AddressBlocklisted(address indexed user);

  /// @notice Emitted when decayed stake is claimed and forwarded to the fee recipient.
  event DecayClaimed(address indexed staker, uint256 amount, address indexed feeRecipient);

  /// @notice Thrown when attempting to set a decay rate outside the allowed range.
  error QueryTypeStakingPool__InvalidDecayRate();

  /// @notice Thrown when attempting to stake with an invalid lockup period.
  error QueryTypeStakingPool__LockupPeriodTooLow();

  /// @notice Thrown when attempting to stake with an invalid access period.
  error QueryTypeStakingPool__AccessPeriodTooLow();

  /// @notice Thrown when a token transfer fails.
  error QueryTypeStakingPool__TokenTransferFailed();

  /// @notice Thrown when the staking amount is below the minimum required.
  error QueryTypeStakingPool__AmountBelowMinimum();

  /// @notice Thrown when staking exceeds the maximum allowed capacity.
  error QueryTypeStakingPool__CapacityExceeded();

  /// @notice Thrown when attempting to unstake during lockup period.
  error QueryTypeStakingPool__StillInLockupPeriod();

  /// @notice Thrown when attempting to unstake with no stake.
  error QueryTypeStakingPool__NoStakeFound();

  /// @notice Thrown when attempting to unstake more than staked amount.
  error QueryTypeStakingPool__InsufficientBalance();

  /// @notice Thrown when only the factory or owner can call setStakingTokenCapacity.
  error QueryTypeStakingPool__OnlyFactoryOrOwner();

  /// @notice Thrown when only the factory can call a function.
  error QueryTypeStakingPool__OnlyFactory();

  /// @notice Thrown when trying to blocklist an already blocklisted address
  error QueryTypeStakingPool__AlreadyBlocklisted();

  /// @notice Thrown when trying to stake from a blocklisted address
  error QueryTypeStakingPool__AddressBlocklisted();

  /// @notice Initializes the contract with the staking token address and initial conversion table
  /// entry.
  /// @param _owner The address that will own the contract and have permission to update the
  /// conversion table.
  /// @param _stakingToken The address of the ERC20 token that will be staked.
  /// @param _factory The address of the factory that deployed this pool.
  /// @param _initialConversionTableEntry The first entry in the conversion table history.
  /// @param _decayRate The decay rate for the stake.
  /// @param _lockupPeriod The duration in seconds that tokens will be locked after staking.
  /// @param _accessPeriod The duration in seconds after lockup during which tokens can be
  /// withdrawn. @param _minimumStake The minimum amount of tokens required to stake.
  constructor(
    address _owner,
    address _stakingToken,
    address _factory,
    bytes32 _initialConversionTableEntry,
    uint8 _decayRate,
    uint48 _lockupPeriod,
    uint48 _accessPeriod,
    uint256 _minimumStake
  ) Ownable(_owner) {
    STAKING_TOKEN = IERC20(_stakingToken);
    FACTORY = _factory;

    if (_decayRate > 100) revert QueryTypeStakingPool__InvalidDecayRate();
    DECAY_RATE = _decayRate;

    _setLockupPeriod(_lockupPeriod);
    _setAccessPeriod(_accessPeriod);
    _setMinimumStake(_minimumStake);

    // Initialize the conversion table with the provided entry
    _updateConversionTable(_initialConversionTableEntry);
  }

  /// @notice Sets the global staking capacity.
  /// @param _capacity The new staking capacity.
  function setStakingTokenCapacity(uint256 _capacity) external {
    _checkOwner();
    _setStakingTokenCapacity(_capacity);
  }

  /// @notice Sets the minimum stake amount.
  /// @param _minimumStake The new minimum stake amount.
  function setMinimumStake(uint256 _minimumStake) external {
    _checkOwner();
    _setMinimumStake(_minimumStake);
  }

  /// @notice Sets the lockup period duration
  /// @param _period The new lockup period in seconds
  function setLockupPeriod(uint48 _period) external {
    _checkOwner();
    _setLockupPeriod(_period);
  }

  /// @notice Sets the access period duration
  /// @param _period The new access period in seconds
  function setAccessPeriod(uint48 _period) external {
    _checkOwner();
    _setAccessPeriod(_period);
  }

  /// @notice Adds a new conversion table entry to track changes in the conversion rate.
  /// @param _newEntry The new conversion table entry to add to the history.
  function updateConversionTable(bytes32 _newEntry) external {
    _checkOwner();
    _updateConversionTable(_newEntry);
  }

  /// @notice Allows users to stake tokens for the predefined lockup and access periods.
  /// @param _amount The amount of tokens to stake.
  function stake(uint256 _amount) external {
    _claimDecay(msg.sender);

    if (_amount < minimumStake) revert QueryTypeStakingPool__AmountBelowMinimum();
    if (isBlocklisted[msg.sender]) revert QueryTypeStakingPool__AddressBlocklisted();

    if (totalCapacityStaked + _amount > stakingTokenCapacity) {
      revert QueryTypeStakingPool__CapacityExceeded();
    }

    // Reset lockup and access periods
    StakeInfo memory _stakeInfo = stakes[msg.sender];
    _stakeInfo.lockupEnd = uint48(block.timestamp) + lockupPeriod;
    _stakeInfo.accessEnd = _stakeInfo.lockupEnd + accessPeriod;
    totalCapacityStaked += _amount;

    if (_stakeInfo.amount == 0) {
      // First-time stake
      _stakeInfo.conversionTableIndex = conversionTableHistory.length - 1;
    }
    _stakeInfo.amount += _amount;
    _stakeInfo.capacity = _stakeInfo.amount;
    _stakeInfo.lastClaimed = uint48(block.timestamp);
    stakes[msg.sender] = _stakeInfo;

    STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), _amount);

    emit Staked(
      msg.sender,
      _amount,
      _stakeInfo.conversionTableIndex,
      _stakeInfo.lockupEnd,
      _stakeInfo.accessEnd
    );
  }

  /// @notice Returns the total number of entries in the conversion table history.
  /// @return The length of the conversion table history array.
  function getConversionTableHistoryLength() external view returns (uint256) {
    return conversionTableHistory.length;
  }

  /// @notice Allows users to unstake their tokens after the lockup period.
  /// @param _amount The amount of tokens the user wishes to unstake.
  function unstake(uint256 _amount) external {
    StakeInfo storage userStake = stakes[msg.sender];

    _claimDecay(msg.sender);

    if (userStake.amount == 0) revert QueryTypeStakingPool__NoStakeFound();
    if (block.timestamp < userStake.lockupEnd) revert QueryTypeStakingPool__StillInLockupPeriod();
    if (_amount > userStake.amount) revert QueryTypeStakingPool__InsufficientBalance();

    uint256 _oldUserCapacity = userStake.capacity;

    userStake.amount -= _amount;
    userStake.capacity = userStake.amount;

    if (isBlocklisted[msg.sender]) totalCapacityJailed -= (_oldUserCapacity - userStake.capacity);
    else totalCapacityStaked -= (_oldUserCapacity - userStake.capacity);

    STAKING_TOKEN.safeTransfer(msg.sender, _amount);

    emit Unstaked(msg.sender, _amount);
  }

  /// @notice Allows a staker to set or update their designated signer.
  /// @param _newSigner The address to set as the signer for the caller.
  function setSigner(address _newSigner) external {
    if (stakes[msg.sender].amount == 0) revert QueryTypeStakingPool__NoStakeFound();

    address _oldSigner = stakerSigners[msg.sender];

    if (_oldSigner != address(0)) signerStakers[_oldSigner][msg.sender] = false;

    if (_newSigner != address(0)) signerStakers[_newSigner][msg.sender] = true;

    emit SignerUpdated(msg.sender, _oldSigner, _newSigner);
    stakerSigners[msg.sender] = _newSigner;
  }

  /// @notice Blocklists an address for this pool.
  /// @param _user The address to blocklist.
  /// @dev Only callable by the pool owner.
  function blocklist(address _user) external {
    _checkOwner();

    if (isBlocklisted[_user]) revert QueryTypeStakingPool__AlreadyBlocklisted();

    uint256 _amountToJail = stakes[_user].amount;

    if (_amountToJail > 0) {
      totalCapacityJailed += _amountToJail;
      totalCapacityStaked -= _amountToJail;
      emit StakeJailed(_user, _amountToJail);
    }

    isBlocklisted[_user] = true;
    emit AddressBlocklisted(_user);
  }

  /// @notice Claims the decayed portion of the caller's stake and forwards it to the
  /// `feeRecipient`.
  /// Any address can call this function on behalf of a staker.
  /// @param _staker The address whose decayed stake should be claimed. If omitted, defaults to
  /// msg.sender.
  function claim(address _staker) public {
    _claimDecay(_staker);
  }

  /// @notice Returns the stake information for a given staker with decay applied.
  /// @param _staker The address of the staker.
  /// @return The stake information with decay applied to the amount.
  function getStakeInfo(address _staker) external view returns (StakeInfo memory) {
    StakeInfo memory _stakeInfo = stakes[_staker];
    if (_stakeInfo.amount == 0) return _stakeInfo;

    uint256 _elapsed = block.timestamp - _stakeInfo.lastClaimed;
    if (_elapsed == 0) return _stakeInfo;

    uint256 _totalPeriod = _stakeInfo.accessEnd - _stakeInfo.lastClaimed;
    if (_totalPeriod == 0) return _stakeInfo;

    uint256 _maxDecay = (_stakeInfo.amount * _elapsed) / _totalPeriod;

    // Apply proportional fee loss based on DECAY_RATE.
    uint256 _decayed = (_maxDecay * DECAY_RATE) / 100;

    if (_decayed > _stakeInfo.amount) _decayed = _stakeInfo.amount;

    // Apply decay to the returned stake info
    _stakeInfo.amount -= _decayed;
    return _stakeInfo;
  }

  /// @notice Internal helper that settles the decayed portion of a stake.
  /// @param _staker The address whose decayed stake should be claimed.
  /// @return _claimed The amount of decayed stake claimed.
  function _claimDecay(address _staker) internal returns (uint256 _claimed) {
    StakeInfo storage stakeInfo = stakes[_staker];
    if (stakeInfo.amount == 0) return 0;

    uint256 _elapsed = block.timestamp - stakeInfo.lastClaimed;
    if (_elapsed == 0) return 0;

    uint256 _totalPeriod = stakeInfo.accessEnd - stakeInfo.lastClaimed;
    if (_totalPeriod == 0) return 0;

    uint256 _maxDecay = (stakeInfo.amount * _elapsed) / _totalPeriod;

    // Apply proportional fee loss based on DECAY_RATE.
    // DECAY_RATE represents the % of the decayed amount that should be lost as fees.
    // Example: DECAY_RATE = 80 → lose 80% of the decayed amount as fees.
    uint256 _decayed = (_maxDecay * DECAY_RATE) / 100;

    if (_decayed == 0) return 0;

    if (_decayed > stakeInfo.amount) _decayed = stakeInfo.amount;

    // Apply decay and update accounting
    stakeInfo.amount -= _decayed;
    stakeInfo.lastClaimed = uint48(block.timestamp);

    address _feeRecipient = QueryTypeStakerFactory(FACTORY).feeRecipient();
    STAKING_TOKEN.safeTransfer(_feeRecipient, _decayed);

    emit DecayClaimed(_staker, _decayed, _feeRecipient);
    return _decayed;
  }

  /// @notice Internal function to set the staking capacity.
  /// @param _capacity The new staking capacity.
  function _setStakingTokenCapacity(uint256 _capacity) internal {
    stakingTokenCapacity = _capacity;
    emit StakingTokenCapacityUpdated(_capacity);
  }

  /// @notice Internal function to set the minimum stake amount.
  /// @param _minimumStake The new minimum stake amount.
  function _setMinimumStake(uint256 _minimumStake) internal {
    minimumStake = _minimumStake;
    emit MinimumStakeUpdated(_minimumStake);
  }

  /// @notice Internal function to set the lockup period.
  /// @param _period The new lockup period in seconds.
  function _setLockupPeriod(uint48 _period) internal {
    lockupPeriod = _period;
    emit LockupPeriodUpdated(_period);
  }

  /// @notice Internal function to set the access period.
  /// @param _period The new access period in seconds.
  function _setAccessPeriod(uint48 _period) internal {
    accessPeriod = _period;
    emit AccessPeriodUpdated(_period);
  }

  /// @notice Internal function to update the conversion table.
  /// @param _newEntry The new conversion table entry to add.
  function _updateConversionTable(bytes32 _newEntry) internal {
    conversionTableHistory.push(_newEntry);
    emit ConversionTableUpdated(_newEntry);
  }
}
