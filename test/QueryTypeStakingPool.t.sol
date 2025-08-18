// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {QueryTypeStakingPool} from "src/QueryTypeStakingPool.sol";
import {QueryTypeStakerFactory} from "src/QueryTypeStakerFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract QueryTypeStakingPoolTest is Test {
  QueryTypeStakingPool public pool;
  MockERC20 public stakingToken;
  QueryTypeStakerFactory public factory;
  address public staker;
  address public feeRecipient;
  uint256 public constant INITIAL_BALANCE = 1_000_000_000 ether;
  uint256 public constant MAX_TIME_SKIP = 1000 * 365 days;

  function setUp() public virtual {
    staker = makeAddr("staker");
    feeRecipient = makeAddr("feeRecipient");
    stakingToken = new MockERC20();
    factory = new QueryTypeStakerFactory(address(this), address(stakingToken));

    factory.setFeeRecipient(feeRecipient);

    address poolAddress = factory.createStakingPool(
      bytes32(uint256(1)), // queryType
      address(this), // poolOwner
      bytes32(uint256(1)), // initialEntry
      100 // decayRate (0% retained, 100% becomes fees)
    );
    pool = QueryTypeStakingPool(poolAddress);

    stakingToken.mint(staker, INITIAL_BALANCE);
    vm.prank(staker);
    stakingToken.approve(address(pool), type(uint256).max);
  }

  function _getStakeInfo(address _staker)
    internal
    view
    returns (QueryTypeStakingPool.StakeInfo memory stakeInfo)
  {
    (
      stakeInfo.amount,
      stakeInfo.conversionTableIndex,
      stakeInfo.lockupEnd,
      stakeInfo.accessEnd,
      stakeInfo.lastClaimed,
      stakeInfo.capacity
    ) = pool.stakes(_staker);
  }
}

contract Constructor is QueryTypeStakingPoolTest {
  function testFuzz_SetsStakingTokenCorrectly(
    address _owner,
    address _stakingToken,
    bytes32 _initialEntry
  ) public {
    vm.assume(_owner != address(0));
    vm.assume(_stakingToken != address(0));

    QueryTypeStakingPool _newPool =
      new QueryTypeStakingPool(_owner, _stakingToken, address(factory), _initialEntry, 0);
    assertEq(address(_newPool.STAKING_TOKEN()), _stakingToken);
    assertEq(_newPool.conversionTableHistory(0), _initialEntry);
  }

  function testFuzz_RevertIf_DecayRateIsInvalid(uint8 _decayRate) public {
    _decayRate = uint8(bound(_decayRate, 101, type(uint8).max));

    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__InvalidDecayRate.selector);
    new QueryTypeStakingPool(
      address(this), // owner
      address(stakingToken), // stakingToken
      address(factory), // factory
      bytes32(uint256(100)), // initialEntry
      _decayRate
    );
  }
}

contract UpdateConversionTable is QueryTypeStakingPoolTest {
  function test_CorrectlyInitializesConversionTableEntry() public view {
    // Check that the constructor set the initial entry correctly
    assertEq(pool.conversionTableHistory(0), bytes32(uint256(1)));
  }

  function testFuzz_CorrectlyUpdatesConversionTableHistory(bytes32 _newEntry) public {
    uint256 currentIndex = pool.getConversionTableHistoryLength();

    vm.expectEmit();
    emit QueryTypeStakingPool.ConversionTableUpdated(_newEntry);

    pool.updateConversionTable(_newEntry);

    assertEq(pool.conversionTableHistory(currentIndex), _newEntry);
  }

  function testFuzz_RevertIf_CallerIsNotOwner(address _notOwner, bytes32 _newEntry) public {
    vm.assume(_notOwner != address(0));
    vm.assume(_notOwner != address(this));
    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
    pool.updateConversionTable(_newEntry);
  }
}

contract Stake is QueryTypeStakingPoolTest {
  function testFuzz_StakesTokensSuccessfully(
    uint256 _amount,
    bytes32 _conversionEntry,
    uint256 _capacity
  ) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);
    pool.updateConversionTable(_conversionEntry);
    uint256 expectedIndex = pool.getConversionTableHistoryLength() - 1;

    uint256 expectedLockupEnd = block.timestamp + pool.lockupPeriod();
    uint256 expectedAccessEnd = expectedLockupEnd + pool.accessPeriod();

    vm.prank(staker);
    pool.stake(_amount);

    QueryTypeStakingPool.StakeInfo memory stakeInfo = _getStakeInfo(staker);

    assertEq(stakeInfo.amount, _amount);
    assertEq(stakeInfo.conversionTableIndex, expectedIndex);
    assertEq(stakeInfo.lockupEnd, expectedLockupEnd);
    assertEq(stakeInfo.accessEnd, expectedAccessEnd);
    assertEq(stakeInfo.lastClaimed, block.timestamp);
    assertEq(stakeInfo.capacity, _amount);
    assertEq(stakingToken.balanceOf(address(pool)), _amount);
    assertEq(pool.totalCapacityStaked(), _amount);
  }

  function testFuzz_UpdatesExistingStakeCorrectly(
    uint256 _initialAmount,
    uint256 _additionalAmount,
    uint256 _capacity,
    uint32 _decayTime
  ) public {
    _initialAmount = bound(_initialAmount, 1, INITIAL_BALANCE / 2);
    _additionalAmount = bound(_additionalAmount, 0, INITIAL_BALANCE - _initialAmount);
    _capacity = bound(_capacity, _initialAmount + _additionalAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    vm.prank(staker);
    pool.stake(_initialAmount);

    QueryTypeStakingPool.StakeInfo memory _originalStake = _getStakeInfo(staker);

    // Advance time a bit to ensure timestamps change
    vm.warp(block.timestamp + _decayTime);

    vm.prank(staker);
    pool.stake(_additionalAmount);

    QueryTypeStakingPool.StakeInfo memory finalStake = _getStakeInfo(staker);

    // Account for 1-day decay applied before the second stake
    uint256 _totalPeriod = _originalStake.accessEnd - _originalStake.lastClaimed;
    uint256 _decayed = _totalPeriod > 0 ? (_initialAmount * _decayTime) / _totalPeriod : 0;
    uint256 _expectedFinal =
      _initialAmount > _decayed ? _initialAmount - _decayed + _additionalAmount : _additionalAmount;

    assertEq(finalStake.amount, _expectedFinal, "Total stake amount incorrect");
    assertEq(finalStake.capacity, _expectedFinal, "Capacity is incorrect");
    assertEq(
      finalStake.conversionTableIndex,
      _originalStake.conversionTableIndex,
      "Conversion table index should not change"
    );
    assertEq(finalStake.lockupEnd, block.timestamp + pool.lockupPeriod(), "Lockup end incorrect");
    assertEq(
      finalStake.accessEnd, finalStake.lockupEnd + pool.accessPeriod(), "Access end incorrect"
    );
    assertEq(stakingToken.balanceOf(address(pool)), _expectedFinal, "Pool balance incorrect");
    assertEq(
      pool.totalCapacityStaked(),
      _initialAmount + _additionalAmount,
      "Total staked amount incorrect"
    );
  }

  function testFuzz_StakeCalculatesEndTimesWithNewPeriods(
    uint256 _amount,
    uint48 _newLockupPeriod,
    uint48 _newAccessPeriod,
    uint256 _capacity
  ) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _newLockupPeriod = uint48(bound(_newLockupPeriod, 0, 1000 days));
    _newAccessPeriod = uint48(bound(_newAccessPeriod, 0, 1000 days));
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);
    pool.setLockupPeriod(_newLockupPeriod);
    pool.setAccessPeriod(_newAccessPeriod);

    uint256 expectedLockupEnd = block.timestamp + _newLockupPeriod;
    uint256 expectedAccessEnd = expectedLockupEnd + _newAccessPeriod;

    vm.prank(staker);
    pool.stake(_amount);

    QueryTypeStakingPool.StakeInfo memory stakeInfo = _getStakeInfo(staker);

    assertEq(stakeInfo.lockupEnd, expectedLockupEnd);
    assertEq(stakeInfo.accessEnd, expectedAccessEnd);
    assertEq(stakeInfo.lastClaimed, block.timestamp);
    assertEq(stakeInfo.capacity, _amount);
  }

  function testFuzz_EmitsStakeEvent(uint256 _amount, bytes32 _conversionEntry, uint256 _capacity)
    public
  {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);
    pool.updateConversionTable(_conversionEntry);
    uint256 expectedIndex = pool.getConversionTableHistoryLength() - 1;

    uint48 expectedLockupEnd = uint48(block.timestamp) + pool.lockupPeriod();
    uint48 expectedAccessEnd = expectedLockupEnd + pool.accessPeriod();

    vm.expectEmit();
    emit QueryTypeStakingPool.Staked(
      staker, _amount, expectedIndex, expectedLockupEnd, expectedAccessEnd
    );

    vm.prank(staker);
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_InsufficientBalance(uint256 _amount, uint256 _capacity) public {
    _amount = bound(_amount, INITIAL_BALANCE + 1, type(uint256).max);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    vm.prank(staker);
    vm.expectRevert(
      abi.encodeWithSignature(
        "ERC20InsufficientBalance(address,uint256,uint256)", staker, INITIAL_BALANCE, _amount
      )
    );
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_TokenTransferFails(uint256 _amount, uint256 _capacity) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);
    stakingToken.setTransferFromShouldFail(true);

    vm.prank(staker);
    vm.expectRevert(
      abi.encodeWithSelector(
        bytes4(keccak256("SafeERC20FailedOperation(address)")), address(stakingToken)
      )
    );
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_ExceedsCapacity(uint256 _amount, uint256 _capacity) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, 0, _amount - 1);

    pool.setStakingTokenCapacity(_capacity);

    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__CapacityExceeded.selector);
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_StakeAmountBelowMinimum(
    uint256 _amount,
    uint256 _minimumStake,
    uint256 _capacity
  ) public {
    // Ensure amount is greater than 0 but less than minimum stake
    _minimumStake = bound(_minimumStake, 2, INITIAL_BALANCE);
    _amount = bound(_amount, 1, _minimumStake - 1);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);
    pool.setMinimumStake(_minimumStake);

    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__AmountBelowMinimum.selector);
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_AddressIsBlocklisted(uint256 _amount, uint256 _capacity) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Setup initial stake to allow blocklisting
    vm.prank(staker);
    pool.stake(_amount);

    // Blocklist the staker
    pool.blocklist(staker);

    // Try to stake more
    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__AddressBlocklisted.selector);
    pool.stake(_amount);
  }
}

contract GetConversionTableHistoryLength is QueryTypeStakingPoolTest {
  function test_ReturnsCorrectLength() public {
    // Initial length should be 1 due to initialEntry in constructor
    assertEq(pool.getConversionTableHistoryLength(), 1);

    // Add 100 new random entries and verify length increases
    for (uint256 i = 2; i <= 100; i++) {
      bytes32 randomEntry = keccak256(abi.encodePacked(block.timestamp, i, msg.sender));
      pool.updateConversionTable(randomEntry);
      assertEq(pool.getConversionTableHistoryLength(), i);
    }

    // Final length should be 100
    assertEq(pool.getConversionTableHistoryLength(), 100);
  }
}

contract SetStakingTokenCapacity is QueryTypeStakingPoolTest {
  function testFuzz_SetStakingTokenCapacitySuccessfully(uint256 _newCapacity) public {
    pool.setStakingTokenCapacity(_newCapacity);
    assertEq(pool.stakingTokenCapacity(), _newCapacity);
  }

  function testFuzz_SetStakingTokenCapacityEmitsEvent(uint256 _newCapacity) public {
    vm.expectEmit();
    emit QueryTypeStakingPool.StakingTokenCapacityUpdated(_newCapacity);

    pool.setStakingTokenCapacity(_newCapacity);
  }

  function testFuzz_SetStakingTokenCapacity_RevertIf_NotOwner(
    address _notOwner,
    uint256 _newCapacity
  ) public {
    vm.assume(_notOwner != address(this)); // not owner

    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
    pool.setStakingTokenCapacity(_newCapacity);
  }
}

contract SetMinimumStake is QueryTypeStakingPoolTest {
  function testFuzz_SetMinimumStakeSuccessfully(uint256 _newMinimumStake) public {
    pool.setMinimumStake(_newMinimumStake);
    assertEq(pool.minimumStake(), _newMinimumStake);
  }

  function testFuzz_SetMinimumStakeEmitsEvent(uint256 _newMinimumStake) public {
    vm.expectEmit();
    emit QueryTypeStakingPool.MinimumStakeUpdated(_newMinimumStake);

    pool.setMinimumStake(_newMinimumStake);
  }

  function testFuzz_SetMinimumStake_RevertIf_NotOwner(address caller, uint256 amount) public {
    vm.assume(caller != address(0) && caller != address(this));

    vm.prank(caller);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    pool.setMinimumStake(amount);
  }
}

contract SetLockupPeriod is QueryTypeStakingPoolTest {
  function testFuzz_SetLockupPeriodSuccessfully(uint48 _newPeriod) public {
    pool.setLockupPeriod(_newPeriod);
    assertEq(pool.lockupPeriod(), _newPeriod);
  }

  function testFuzz_SetLockupPeriodEmitsEvent(uint48 _newPeriod) public {
    vm.expectEmit();
    emit QueryTypeStakingPool.LockupPeriodUpdated(_newPeriod);

    pool.setLockupPeriod(_newPeriod);
  }

  function testFuzz_SetLockupPeriod_RevertIf_NotOwner(address _notOwner, uint48 _newPeriod) public {
    vm.assume(_notOwner != address(this));
    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
    pool.setLockupPeriod(_newPeriod);
  }
}

contract SetAccessPeriod is QueryTypeStakingPoolTest {
  function testFuzz_SetAccessPeriodSuccessfully(uint48 _newPeriod) public {
    pool.setAccessPeriod(_newPeriod);
    assertEq(pool.accessPeriod(), _newPeriod);
  }

  function testFuzz_SetAccessPeriodEmitsEvent(uint48 _newPeriod) public {
    vm.expectEmit();
    emit QueryTypeStakingPool.AccessPeriodUpdated(_newPeriod);

    pool.setAccessPeriod(_newPeriod);
  }

  function testFuzz_SetAccessPeriod_RevertIf_NotOwner(address _notOwner, uint48 _newPeriod) public {
    vm.assume(_notOwner != address(this));
    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
    pool.setAccessPeriod(_newPeriod);
  }
}

contract Unstake is QueryTypeStakingPoolTest {
  function _boundTimeSkipForDecayAndUnstake(uint256 _timeSkip) internal view returns (uint256) {
    return bound(_timeSkip, pool.lockupPeriod() + 1, pool.lockupPeriod() + pool.accessPeriod() - 1);
  }

  function _remainingAfterDecay(uint256 _amountStaked, uint256 _elapsed)
    internal
    view
    returns (uint256)
  {
    QueryTypeStakingPool.StakeInfo memory _stakeInfo = _getStakeInfo(staker);
    uint256 _totalPeriod = _stakeInfo.accessEnd - _stakeInfo.lastClaimed;
    if (_totalPeriod == 0) return 0;

    uint256 _decayed = (_amountStaked * _elapsed) / _totalPeriod;
    if (_decayed > _amountStaked) return 0;
    return _amountStaked - _decayed;
  }

  function testFuzz_UnstakeSuccessfully(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _unstakeAmount = bound(_unstakeAmount, 1, _stakeAmount);
    _timeSkip = _boundTimeSkipForDecayAndUnstake(_timeSkip);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    uint256 _initialBalance = stakingToken.balanceOf(staker);

    QueryTypeStakingPool.StakeInfo memory _preDecayStake = _getStakeInfo(staker);
    uint256 _remainingStake = _remainingAfterDecay(_preDecayStake.amount, _timeSkip);
    vm.assume(_remainingStake > 0);
    uint256 _unstakeAmt = bound(_unstakeAmount, 1, _remainingStake);

    vm.prank(staker);
    pool.unstake(_unstakeAmt);

    assertEq(stakingToken.balanceOf(staker), _initialBalance + _unstakeAmt);
    QueryTypeStakingPool.StakeInfo memory remainingStakeAfter = _getStakeInfo(staker);
    assertEq(remainingStakeAfter.amount, _remainingStake - _unstakeAmt);
    assertEq(remainingStakeAfter.capacity, remainingStakeAfter.amount);

    assertEq(pool.totalCapacityStaked(), _stakeAmount - _unstakeAmt);
  }

  function testFuzz_UnstakeAfterMultipleStakes(
    uint256 _initialStake,
    uint256 _additionalStake,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _initialStake = bound(_initialStake, 1, INITIAL_BALANCE / 2);
    _additionalStake = bound(_additionalStake, 0, INITIAL_BALANCE - _initialStake);
    uint256 totalStaked = _initialStake + _additionalStake;
    _unstakeAmount = bound(_unstakeAmount, 1, totalStaked);
    _timeSkip = _boundTimeSkipForDecayAndUnstake(_timeSkip);
    _capacity = bound(_capacity, totalStaked, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_initialStake);

    // Additional stake
    vm.prank(staker);
    pool.stake(_additionalStake);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    uint256 _initialBalance = stakingToken.balanceOf(staker);

    QueryTypeStakingPool.StakeInfo memory preDecayStake = _getStakeInfo(staker);
    uint256 _remainingStake = _remainingAfterDecay(preDecayStake.amount, _timeSkip);
    vm.assume(_remainingStake > 0);
    uint256 _unstakeAmt = bound(_unstakeAmount, 1, _remainingStake);

    vm.prank(staker);
    pool.unstake(_unstakeAmt);

    assertEq(stakingToken.balanceOf(staker), _initialBalance + _unstakeAmt);
    QueryTypeStakingPool.StakeInfo memory remainingStakeAfter = _getStakeInfo(staker);
    assertEq(remainingStakeAfter.amount, _remainingStake - _unstakeAmt);
    assertEq(remainingStakeAfter.capacity, remainingStakeAfter.amount);
    assertEq(pool.totalCapacityStaked(), totalStaked - _unstakeAmt);
  }

  function testFuzz_RevertIf_TokenTransferFails(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _unstakeAmount = bound(_unstakeAmount, 1, _stakeAmount);
    _timeSkip = _boundTimeSkipForDecayAndUnstake(_timeSkip);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    // Make transfer fail
    stakingToken.setTransferShouldFail(true);

    vm.prank(staker);
    vm.expectRevert(
      abi.encodeWithSelector(
        bytes4(keccak256("SafeERC20FailedOperation(address)")), address(stakingToken)
      )
    );
    pool.unstake(_unstakeAmount);
  }

  function testFuzz_RevertIf_StillInLockup(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _unstakeAmount = bound(_unstakeAmount, 1, _stakeAmount);
    // Bound time skip to be before lockup period ends
    _timeSkip = bound(_timeSkip, 0, pool.lockupPeriod() - 1);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to invalid unstake time
    vm.warp(block.timestamp + _timeSkip);

    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__StillInLockupPeriod.selector);
    pool.unstake(_unstakeAmount);
  }

  function testFuzz_RevertIf_NoStakeFound(address _nonStaker, uint256 _amount, uint256 _capacity)
    public
  {
    vm.assume(_nonStaker != address(0));
    vm.assume(_nonStaker != staker);
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    vm.prank(_nonStaker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__NoStakeFound.selector);
    pool.unstake(_amount);
  }

  function testFuzz_RevertIf_InsufficientBalance(
    uint256 _stakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _timeSkip = _boundTimeSkipForDecayAndUnstake(_timeSkip);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    QueryTypeStakingPool.StakeInfo memory _preDecay = _getStakeInfo(staker);
    uint256 _remaining = _remainingAfterDecay(_preDecay.amount, _timeSkip);
    uint256 _unstakeAmount = _remaining + 1;

    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__InsufficientBalance.selector);
    pool.unstake(_unstakeAmount);
  }

  function testFuzz_RevertIf_BalanceIsZero(
    uint256 _stakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _timeSkip = pool.lockupPeriod() + pool.accessPeriod();
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    uint256 _unstakeAmount = 1;

    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__NoStakeFound.selector);
    pool.unstake(_unstakeAmount);
  }

  function testFuzz_EmitsUnstakeEvent(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _unstakeAmount = bound(_unstakeAmount, 1, _stakeAmount);
    _timeSkip = _boundTimeSkipForDecayAndUnstake(_timeSkip);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    QueryTypeStakingPool.StakeInfo memory _preDecay = _getStakeInfo(staker);
    uint256 _remaining = _remainingAfterDecay(_preDecay.amount, _timeSkip);
    vm.assume(_remaining > 0);
    _unstakeAmount = bound(_unstakeAmount, 1, _remaining);

    vm.expectEmit();
    emit QueryTypeStakingPool.Unstaked(staker, _unstakeAmount);

    vm.prank(staker);
    pool.unstake(_unstakeAmount);
  }

  function testFuzz_UnstakeBlockedUser(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _unstakeAmount = bound(_unstakeAmount, 1, _stakeAmount);
    _timeSkip = _boundTimeSkipForDecayAndUnstake(_timeSkip);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Block the staker
    pool.blocklist(staker);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    uint256 _initialTotalJailed = pool.totalCapacityJailed();

    // Calculate remaining stake after decay due to warp
    uint256 _remainingStake = _remainingAfterDecay(_stakeAmount, _timeSkip);

    _unstakeAmount = bound(_unstakeAmount, 1, _remainingStake);

    vm.prank(staker);
    pool.unstake(_unstakeAmount);

    assertEq(
      pool.totalCapacityJailed(),
      _initialTotalJailed - _unstakeAmount,
      "Total jailed should decrease by unstake amount"
    );
    assertEq(pool.totalCapacityStaked(), 0, "Total staked should be zero after jail scenario");
  }
}

contract SetSigner is QueryTypeStakingPoolTest {
  function testFuzz_SetSignerSuccessfully(address _signer, uint256 _stakeAmount, uint256 _capacity)
    public
  {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    // Setup initial stake
    pool.setStakingTokenCapacity(_capacity);
    vm.prank(staker);
    pool.stake(_stakeAmount);

    assertEq(pool.stakerSigners(staker), address(0));

    vm.prank(staker);
    pool.setSigner(_signer);
    assertEq(pool.stakerSigners(staker), _signer);
  }

  function testFuzz_EmitsSignerUpdatedEvent(
    address _oldSigner,
    address _newSigner,
    uint256 _stakeAmount,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    // Setup initial stake
    pool.setStakingTokenCapacity(_capacity);
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Set initial signer
    vm.prank(staker);
    pool.setSigner(_oldSigner);

    vm.expectEmit();
    emit QueryTypeStakingPool.SignerUpdated(staker, _oldSigner, _newSigner);

    vm.prank(staker);
    pool.setSigner(_newSigner);
  }

  function testFuzz_RevertIf_NoStake(address _signer) public {
    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__NoStakeFound.selector);
    pool.setSigner(_signer);
  }
}

contract Blocklist is QueryTypeStakingPoolTest {
  function testFuzz_BlocklistUserSuccessfully(
    address _user,
    uint256 _stakeAmount,
    uint256 _capacity
  ) public {
    vm.assume(_user != address(0));
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Setup stake for user
    stakingToken.mint(_user, _stakeAmount);
    vm.startPrank(_user);
    stakingToken.approve(address(pool), _stakeAmount);
    pool.stake(_stakeAmount);
    vm.stopPrank();

    // Blocklist user
    pool.blocklist(_user);

    assertTrue(pool.isBlocklisted(_user));
    assertEq(pool.totalCapacityJailed(), _stakeAmount);
    assertEq(pool.totalCapacityStaked(), 0);
  }

  function testFuzz_BlocklistEmitsEvents(address _user, uint256 _stakeAmount, uint256 _capacity)
    public
  {
    vm.assume(_user != address(0));
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Setup stake for user
    stakingToken.mint(_user, _stakeAmount);
    vm.startPrank(_user);
    stakingToken.approve(address(pool), _stakeAmount);
    pool.stake(_stakeAmount);
    vm.stopPrank();

    vm.expectEmit();
    emit QueryTypeStakingPool.StakeJailed(_user, _stakeAmount);
    vm.expectEmit();
    emit QueryTypeStakingPool.AddressBlocklisted(_user);

    pool.blocklist(_user);
  }

  function testFuzz_RevertIf_BlocklistingAlreadyBlocklistedUser(
    address _user,
    uint256 _stakeAmount,
    uint256 _capacity
  ) public {
    vm.assume(_user != address(0));
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Setup stake for user
    stakingToken.mint(_user, _stakeAmount);
    vm.startPrank(_user);
    stakingToken.approve(address(pool), _stakeAmount);
    pool.stake(_stakeAmount);
    vm.stopPrank();

    // First blocklist
    pool.blocklist(_user);

    // Try to blocklist again
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__AlreadyBlocklisted.selector);
    pool.blocklist(_user);
  }

  function testFuzz_BlocklistingUserWithNoStake(address _user) public {
    vm.assume(_user != address(0));

    // Blocklist user with no stake
    pool.blocklist(_user);

    assertTrue(pool.isBlocklisted(_user));
    assertEq(pool.totalCapacityJailed(), 0); // No tokens to jail
    assertEq(pool.totalCapacityStaked(), 0); // No tokens staked
  }

  function testFuzz_RevertIf_NotOwnerTriesToBlocklist(
    address _notOwner,
    address _user,
    uint256 _stakeAmount,
    uint256 _capacity
  ) public {
    vm.assume(_notOwner != address(this)); // not owner
    vm.assume(_user != address(0));
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Setup stake for user
    stakingToken.mint(_user, _stakeAmount);
    vm.startPrank(_user);
    stakingToken.approve(address(pool), _stakeAmount);
    pool.stake(_stakeAmount);
    vm.stopPrank();

    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
    pool.blocklist(_user);
  }
}

contract Claim is QueryTypeStakingPoolTest {
  function _expectedDecay(uint256 _amount, uint256 _elapsed) internal view returns (uint256) {
    // Get stake info to calculate decay period
    QueryTypeStakingPool.StakeInfo memory stakeInfo = _getStakeInfo(staker);
    uint256 totalPeriod = stakeInfo.accessEnd - stakeInfo.lastClaimed;
    if (totalPeriod == 0) return 0;

    uint256 decayed = (_amount * _elapsed) / totalPeriod;
    if (decayed > _amount) return _amount;
    return decayed;
  }

  function testFuzz_ClaimCallerDecaySuccessfully(
    uint256 _stakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _timeSkip = bound(_timeSkip, 1, pool.accessPeriod());
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Stake tokens
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to accrue decay
    vm.warp(block.timestamp + _timeSkip);

    uint256 _decayed = _expectedDecay(_stakeAmount, _timeSkip);
    vm.assume(_decayed > 0);

    uint256 feeBalanceBefore = stakingToken.balanceOf(feeRecipient);

    vm.prank(staker);
    pool.claim(staker);

    // Validate balances and state
    assertEq(
      stakingToken.balanceOf(feeRecipient),
      feeBalanceBefore + _decayed,
      "Fee recipient balance incorrect"
    );
    QueryTypeStakingPool.StakeInfo memory remaining = _getStakeInfo(staker);
    assertEq(remaining.amount, _stakeAmount - _decayed, "Remaining stake incorrect");
    assertEq(pool.totalCapacityStaked(), _stakeAmount, "Total staked incorrect");
  }

  function testFuzz_ClaimCallerDecayEmitsDecayClaimedEvent(
    uint256 _stakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _timeSkip = bound(_timeSkip, 1, pool.accessPeriod());
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Stake tokens
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to accrue decay
    vm.warp(block.timestamp + _timeSkip);

    uint256 _decayed = _expectedDecay(_stakeAmount, _timeSkip);
    vm.assume(_decayed > 0);

    vm.expectEmit();
    emit QueryTypeStakingPool.DecayClaimed(staker, _decayed, feeRecipient);

    vm.prank(staker);
    pool.claim(staker);
  }

  function testFuzz_ClaimArbitraryStakersDecaySuccessfully(
    uint256 _stakeAmount,
    uint256 _timeSkip,
    uint256 _capacity,
    address _caller
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _timeSkip = bound(_timeSkip, 1, pool.accessPeriod());
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    vm.prank(staker);
    pool.stake(_stakeAmount);

    vm.warp(block.timestamp + _timeSkip);

    uint256 _decayed = _expectedDecay(_stakeAmount, _timeSkip);
    vm.assume(_decayed > 0);

    uint256 _feeBalanceBefore = stakingToken.balanceOf(feeRecipient);

    vm.expectEmit();
    emit QueryTypeStakingPool.DecayClaimed(staker, _decayed, feeRecipient);

    vm.prank(_caller);
    pool.claim(staker);

    assertEq(stakingToken.balanceOf(feeRecipient), _feeBalanceBefore + _decayed);
    QueryTypeStakingPool.StakeInfo memory _remaining = _getStakeInfo(staker);
    assertEq(_remaining.amount, _stakeAmount - _decayed);
  }

  function testFuzz_ClaimWithNoStakeDoesNothing(address _nonStaker) public {
    vm.assume(_nonStaker != address(0) && _nonStaker != staker);
    vm.prank(_nonStaker);
    pool.claim(_nonStaker);
    // Should not revert and no state changes; totalStaked remains 0
    assertEq(pool.totalCapacityStaked(), 0);
  }

  function testFuzz_ClaimWhenDecayExceedsStakeAmount(uint256 _stakeAmount, uint256 _capacity)
    public
  {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Stake tokens
    vm.prank(staker);
    pool.stake(_stakeAmount);

    QueryTypeStakingPool.StakeInfo memory _stakeInfo = _getStakeInfo(staker);
    uint256 totalPeriod = _stakeInfo.accessEnd - _stakeInfo.lastClaimed;

    // Warp to a time that would cause decay calculation to exceed stake amount
    uint256 _timeToWarp = totalPeriod * 2;
    vm.warp(block.timestamp + _timeToWarp);

    uint256 feeBalanceBefore = stakingToken.balanceOf(feeRecipient);

    pool.claim(staker);

    // Validate that the entire stake amount was claimed as decay
    assertEq(
      stakingToken.balanceOf(feeRecipient),
      feeBalanceBefore + _stakeAmount,
      "Fee recipient should receive entire stake"
    );
    QueryTypeStakingPool.StakeInfo memory remaining = _getStakeInfo(staker);
    assertEq(remaining.amount, 0, "Stake should be completely decayed");
    assertEq(
      pool.totalCapacityStaked(), _stakeAmount, "Total staked should remain at original amount"
    );
  }

  function testFuzz_DecayRateCalculation(
    uint8 _decayRate,
    uint256 _stakeAmount,
    uint32 _timeElapsed
  ) public {
    // Bound parameters to reasonable ranges
    _decayRate = uint8(bound(_decayRate, 1, 100)); // Valid decay rates only
    _stakeAmount = bound(_stakeAmount, 100 ether, 10_000 ether);
    _timeElapsed = uint32(bound(_timeElapsed, 1 days, 60 days));

    address poolAddress = factory.createStakingPool(
      bytes32(uint256(5)), // queryType
      address(this), // poolOwner
      bytes32(uint256(100)), // initialEntry
      _decayRate // fuzzed decay rate
    );
    QueryTypeStakingPool fuzzedPool = QueryTypeStakingPool(poolAddress);

    // Set capacity based on stake amount
    uint256 capacity = bound(10_000 ether, _stakeAmount, _stakeAmount * 10);
    fuzzedPool.setStakingTokenCapacity(capacity);

    // Setup staker
    stakingToken.mint(staker, INITIAL_BALANCE);
    vm.prank(staker);
    stakingToken.approve(address(fuzzedPool), type(uint256).max);

    // Stake tokens
    vm.prank(staker);
    fuzzedPool.stake(_stakeAmount);

    uint256 initialAmount = _stakeAmount;

    // Get stake info to calculate expected decay
    (uint256 amount,,, uint48 accessEnd, uint48 lastClaimed,) = fuzzedPool.stakes(staker);
    uint256 totalPeriod = accessEnd - lastClaimed;

    // Calculate expected decay using the same formula as the contract
    uint256 elapsed = _timeElapsed;
    uint256 decayed = (amount * elapsed) / totalPeriod;
    decayed = (decayed * _decayRate) / 100;

    // Cap decay at the total amount
    if (decayed > amount) decayed = amount;

    uint256 expectedFinalAmount = amount - decayed;

    // Advance time
    vm.warp(block.timestamp + _timeElapsed);

    // Claim decay
    fuzzedPool.claim(staker);

    // Verify decay behavior with exact values
    (uint256 finalAmount,,,,,) = fuzzedPool.stakes(staker);

    assertEq(
      finalAmount, expectedFinalAmount, "Final amount should match expected decay calculation"
    );
    assertLe(finalAmount, initialAmount, "Amount should not increase with decay");
    assertGe(finalAmount, 0, "Amount should not go negative");
  }

  function test_FiftyPercentDecayRateAfterHalfOfStakePeriod() public {
    // Create pool with 50% decay rate
    address pool50 = factory.createStakingPool(
      bytes32(uint256(10)), // queryType
      address(this), // poolOwner
      bytes32(uint256(1)), // initialEntry
      50 // 50% decay rate
    );
    QueryTypeStakingPool pool50Percent = QueryTypeStakingPool(pool50);
    pool50Percent.setStakingTokenCapacity(1000 ether);

    // Setup and stake 1000 tokens
    stakingToken.mint(staker, INITIAL_BALANCE);
    vm.prank(staker);
    stakingToken.approve(address(pool50), type(uint256).max);
    vm.prank(staker);
    pool50Percent.stake(1000 ether);

    // Advance time by half the access period (should decay 50% of the time-based decay)
    QueryTypeStakingPool.StakeInfo memory stakeInfo = _getStakeInfoFromPool(pool50Percent, staker);
    uint256 halfPeriod = (stakeInfo.accessEnd - stakeInfo.lastClaimed) / 2;
    vm.warp(block.timestamp + halfPeriod);

    uint256 balanceBefore = stakingToken.balanceOf(feeRecipient);
    pool50Percent.claim(staker);
    uint256 balanceAfter = stakingToken.balanceOf(feeRecipient);

    // With 50% time elapsed and 50% decay rate, should lose 25% of stake
    // Time decay: 50% of stake
    // Decay rate: 50% of that = 25% total loss
    uint256 expectedLoss = 250 ether; // 25% of 1000 ether
    assertEq(balanceAfter - balanceBefore, expectedLoss, "50% decay rate should lose 25% of stake");
  }

  function test_HundredPercentDecayRateAfterQuarterOfStakePeriod() public {
    // Create pool with 100% decay rate
    address pool100 = factory.createStakingPool(
      bytes32(uint256(20)), // queryType
      address(this), // poolOwner
      bytes32(uint256(1)), // initialEntry
      100 // 100% decay rate
    );
    QueryTypeStakingPool pool100Percent = QueryTypeStakingPool(pool100);
    pool100Percent.setStakingTokenCapacity(1000 ether);

    // Setup and stake 1000 tokens
    stakingToken.mint(staker, INITIAL_BALANCE);
    vm.prank(staker);
    stakingToken.approve(address(pool100), type(uint256).max);
    vm.prank(staker);
    pool100Percent.stake(1000 ether);

    // Advance time by quarter of access period
    QueryTypeStakingPool.StakeInfo memory stakeInfo = _getStakeInfoFromPool(pool100Percent, staker);
    uint256 quarterPeriod = (stakeInfo.accessEnd - stakeInfo.lastClaimed) / 4;
    vm.warp(block.timestamp + quarterPeriod);

    uint256 balanceBefore = stakingToken.balanceOf(feeRecipient);
    pool100Percent.claim(staker);
    uint256 balanceAfter = stakingToken.balanceOf(feeRecipient);

    // With 25% time elapsed and 100% decay rate, should lose 25% of stake
    uint256 expectedLoss = 250 ether; // 25% of 1000 ether
    assertEq(
      balanceAfter - balanceBefore, expectedLoss, "100% decay rate should lose all time-based decay"
    );
  }

  function test_ZeroPercentDecayRateAfterHalfOfStakePeriod() public {
    // Create pool with 0% decay rate
    address pool0 = factory.createStakingPool(
      bytes32(uint256(30)), // queryType
      address(this), // poolOwner
      bytes32(uint256(1)), // initialEntry
      0 // 0% decay rate
    );
    QueryTypeStakingPool pool0Percent = QueryTypeStakingPool(pool0);
    pool0Percent.setStakingTokenCapacity(1000 ether);

    // Setup and stake 1000 tokens
    stakingToken.mint(staker, INITIAL_BALANCE);
    vm.prank(staker);
    stakingToken.approve(address(pool0), type(uint256).max);
    vm.prank(staker);
    pool0Percent.stake(1000 ether);

    // Advance time by half the access period
    QueryTypeStakingPool.StakeInfo memory stakeInfo = _getStakeInfoFromPool(pool0Percent, staker);
    uint256 halfPeriod = (stakeInfo.accessEnd - stakeInfo.lastClaimed) / 2;
    vm.warp(block.timestamp + halfPeriod);

    uint256 balanceBefore = stakingToken.balanceOf(feeRecipient);
    pool0Percent.claim(staker);
    uint256 balanceAfter = stakingToken.balanceOf(feeRecipient);

    // With 0% decay rate, should lose nothing
    assertEq(balanceAfter - balanceBefore, 0, "0% decay rate should lose nothing");
  }

  function _getStakeInfoFromPool(QueryTypeStakingPool _pool, address _staker)
    internal
    view
    returns (QueryTypeStakingPool.StakeInfo memory stakeInfo)
  {
    (
      stakeInfo.amount,
      stakeInfo.conversionTableIndex,
      stakeInfo.lockupEnd,
      stakeInfo.accessEnd,
      stakeInfo.lastClaimed,
      stakeInfo.capacity
    ) = _pool.stakes(_staker);
  }
}
