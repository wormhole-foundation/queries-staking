// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {QueryTypeStakerFactory} from "src/QueryTypeStakerFactory.sol";
import {QueryTypeStakingPool} from "src/QueryTypeStakingPool.sol";
import {VmSafe} from "forge-std/Vm.sol";

contract QueryTypeStakerFactoryTest is Test {
  QueryTypeStakerFactory public factory;
  address public owner;
  address public stakingToken;
  bytes32 public queryType;
  uint48 public constant DEFAULT_LOCKUP_PERIOD = 30 days;
  uint48 public constant DEFAULT_ACCESS_PERIOD = 60 days;
  uint256 public constant DEFAULT_MINIMUM_STAKE = 0;

  function setUp() public virtual {
    owner = makeAddr("owner");
    stakingToken = makeAddr("stakingToken");
    vm.prank(owner);
    factory = new QueryTypeStakerFactory(owner, stakingToken);
    queryType = bytes32(uint256(1));
  }

  function _assumeSafeDecayRate(uint8 _decayRate) internal pure returns (uint8) {
    return uint8(bound(_decayRate, 0, 100));
  }

  /// @notice Helper to encode a query type with decay rate in the last 8 bits
  function _encodeQueryType(bytes32 _baseQueryType, uint8 _decayRate)
    internal
    pure
    returns (bytes32)
  {
    // Clear the last 8 bits and set them to the decay rate
    uint256 baseValue =
      uint256(_baseQueryType) & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00;
    return bytes32(baseValue | uint256(_decayRate));
  }
}

contract Constructor is QueryTypeStakerFactoryTest {
  function testFuzz_SetsOwnerAndWTokenCorrectly(address _owner, address _stakingToken) public {
    vm.assume(_owner != address(0) && _stakingToken != address(0));
    vm.prank(_owner);
    QueryTypeStakerFactory newFactory = new QueryTypeStakerFactory(_owner, _stakingToken);
    assertEq(newFactory.owner(), _owner);
    assertEq(address(newFactory.STAKING_TOKEN()), _stakingToken);
    assertEq(newFactory.feeRecipient(), _owner);
  }

  function testFuzz_RevertIf_StakingTokenAddressIsZero(address _owner) public {
    vm.assume(_owner != address(0));
    vm.prank(_owner);
    vm.expectRevert(QueryTypeStakerFactory.QueryTypeStakerFactory__InvalidTokenAddress.selector);
    new QueryTypeStakerFactory(_owner, address(0));
  }

  function testFuzz_EmitsFeeRecipientUpdatedEventWithArbitraryOwner(
    address _owner,
    address _stakingToken
  ) public {
    vm.assume(_owner != address(0) && _stakingToken != address(0));
    vm.expectEmit();
    emit QueryTypeStakerFactory.FeeRecipientUpdated(address(0), _owner);
    new QueryTypeStakerFactory(_owner, _stakingToken);
  }
}

contract CreateStakingPool is QueryTypeStakerFactoryTest {
  function testFuzz_CreatesNewStakingPoolWithArbitraryQueryType(
    bytes32 _baseQueryType,
    address _poolOwner,
    bytes32 _initialEntry,
    uint8 _decayRate
  ) public {
    _decayRate = _assumeSafeDecayRate(_decayRate);
    bytes32 _queryType = _encodeQueryType(_baseQueryType, _decayRate);

    vm.assume(_poolOwner != address(0));
    vm.prank(owner);
    address poolAddress = factory.createStakingPool(
      _queryType,
      _poolOwner,
      _initialEntry,
      DEFAULT_LOCKUP_PERIOD,
      DEFAULT_ACCESS_PERIOD,
      DEFAULT_MINIMUM_STAKE
    );

    assertTrue(poolAddress != address(0));
    assertEq(factory.queryTypePools(_queryType), poolAddress);
    assertEq(QueryTypeStakingPool(poolAddress).owner(), _poolOwner);
    assertEq(QueryTypeStakingPool(poolAddress).DECAY_RATE(), _decayRate);
  }

  function testFuzz_EmitsCreateQueryTypeStakingPoolEventWithArbitraryQueryType(
    bytes32 _baseQueryType,
    address _poolOwner,
    bytes32 _initialEntry,
    uint8 _decayRate
  ) public {
    _decayRate = _assumeSafeDecayRate(_decayRate);
    bytes32 _queryType = _encodeQueryType(_baseQueryType, _decayRate);

    vm.assume(_poolOwner != address(0));

    // Record logs to verify all events
    vm.recordLogs();

    vm.prank(owner);
    address poolAddress = factory.createStakingPool(
      _queryType,
      _poolOwner,
      _initialEntry,
      DEFAULT_LOCKUP_PERIOD,
      DEFAULT_ACCESS_PERIOD,
      DEFAULT_MINIMUM_STAKE
    );

    // Get recorded logs and verify each event
    VmSafe.Log[] memory entries = vm.getRecordedLogs();

    // Verify we got the expected number of events
    assertEq(entries.length, 6, "Should emit exactly 6 events");

    // Event 0: OwnershipTransferred from the pool
    assertEq(entries[0].emitter, poolAddress);
    assertEq(entries[0].topics[0], keccak256("OwnershipTransferred(address,address)"));
    assertEq(entries[0].topics[1], bytes32(uint256(uint160(address(0))))); // previousOwner
    assertEq(entries[0].topics[2], bytes32(uint256(uint160(_poolOwner)))); // newOwner

    // Event 1: LockupPeriodUpdated from the pool
    assertEq(entries[1].emitter, poolAddress);
    assertEq(entries[1].topics[0], keccak256("LockupPeriodUpdated(uint48)"));
    assertEq(abi.decode(entries[1].data, (uint48)), DEFAULT_LOCKUP_PERIOD);

    // Event 2: AccessPeriodUpdated from the pool
    assertEq(entries[2].emitter, poolAddress);
    assertEq(entries[2].topics[0], keccak256("AccessPeriodUpdated(uint48)"));
    assertEq(abi.decode(entries[2].data, (uint48)), DEFAULT_ACCESS_PERIOD);

    // Event 3: MinimumStakeUpdated from the pool
    assertEq(entries[3].emitter, poolAddress);
    assertEq(entries[3].topics[0], keccak256("MinimumStakeUpdated(uint256)"));
    assertEq(abi.decode(entries[3].data, (uint256)), DEFAULT_MINIMUM_STAKE);

    // Event 4: ConversionTableUpdated from the pool
    assertEq(entries[4].emitter, poolAddress);
    assertEq(entries[4].topics[0], keccak256("ConversionTableUpdated(bytes32)"));
    assertEq(abi.decode(entries[4].data, (bytes32)), _initialEntry);

    // Event 5: CreateQueryTypeStakingPool from the factory
    assertEq(entries[5].emitter, address(factory));
    assertEq(entries[5].topics[0], keccak256("CreateQueryTypeStakingPool(bytes32,address)"));
    assertEq(entries[5].topics[1], _queryType); // queryType (indexed)
    assertEq(entries[5].topics[2], bytes32(uint256(uint160(poolAddress)))); // poolAddress (indexed)
  }

  function testFuzz_RevertIf_CallerIsNotOwner(
    address _notOwner,
    address _poolOwner,
    bytes32 _initialEntry,
    uint8 _decayRate
  ) public {
    _decayRate = _assumeSafeDecayRate(_decayRate);
    bytes32 _queryType = _encodeQueryType(queryType, _decayRate);

    vm.assume(_notOwner != owner && _notOwner != address(0));
    vm.assume(_poolOwner != address(0));

    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", _notOwner));
    factory.createStakingPool(
      _queryType,
      _poolOwner,
      _initialEntry,
      DEFAULT_LOCKUP_PERIOD,
      DEFAULT_ACCESS_PERIOD,
      DEFAULT_MINIMUM_STAKE
    );
  }

  function testFuzz_RevertIf_PoolAlreadyExistsWithArbitraryQueryType(
    bytes32 _baseQueryType,
    address _poolOwner,
    bytes32 _initialEntry,
    uint8 _decayRate
  ) public {
    _decayRate = _assumeSafeDecayRate(_decayRate);
    bytes32 _queryType = _encodeQueryType(_baseQueryType, _decayRate);

    vm.assume(_poolOwner != address(0));
    vm.startPrank(owner);
    factory.createStakingPool(
      _queryType,
      _poolOwner,
      _initialEntry,
      DEFAULT_LOCKUP_PERIOD,
      DEFAULT_ACCESS_PERIOD,
      DEFAULT_MINIMUM_STAKE
    );

    vm.expectRevert(QueryTypeStakerFactory.QueryTypeStakerFactory__PoolExists.selector);
    factory.createStakingPool(
      _queryType,
      _poolOwner,
      _initialEntry,
      DEFAULT_LOCKUP_PERIOD,
      DEFAULT_ACCESS_PERIOD,
      DEFAULT_MINIMUM_STAKE
    );
    vm.stopPrank();
  }

  function testFuzz_RevertIf_DecayRateExceeds100(
    bytes32 _baseQueryType,
    address _poolOwner,
    bytes32 _initialEntry,
    uint8 _invalidDecayRate
  ) public {
    _invalidDecayRate = uint8(bound(_invalidDecayRate, 101, 255));
    bytes32 _queryType = _encodeQueryType(_baseQueryType, _invalidDecayRate);

    vm.assume(_poolOwner != address(0));
    vm.prank(owner);
    vm.expectRevert(QueryTypeStakerFactory.QueryTypeStakerFactory__InvalidDecayRate.selector);
    factory.createStakingPool(
      _queryType,
      _poolOwner,
      _initialEntry,
      DEFAULT_LOCKUP_PERIOD,
      DEFAULT_ACCESS_PERIOD,
      DEFAULT_MINIMUM_STAKE
    );
  }
}

contract SetFeeRecipient is QueryTypeStakerFactoryTest {
  function testFuzz_SetsFeeRecipientCorrectly(address _newRecipient) public {
    vm.assume(_newRecipient != address(0));
    vm.prank(owner);
    factory.setFeeRecipient(_newRecipient);
    assertEq(factory.feeRecipient(), _newRecipient);
  }

  function testFuzz_RevertIf_CallerIsNotOwner(address _notOwner, address _newRecipient) public {
    vm.assume(_notOwner != owner && _notOwner != address(0));
    vm.assume(_newRecipient != address(0));

    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", _notOwner));
    factory.setFeeRecipient(_newRecipient);
  }

  function testFuzz_EmitsFeeRecipientUpdatedEventWithArbitraryRecipient(address _newRecipient)
    public
  {
    vm.assume(_newRecipient != address(0));
    vm.expectEmit();
    emit QueryTypeStakerFactory.FeeRecipientUpdated(owner, _newRecipient);
    vm.prank(owner);
    factory.setFeeRecipient(_newRecipient);
  }

  function testFuzz_RevertIf_NewRecipientIsZeroAddress(address _newRecipient) public {
    vm.assume(_newRecipient != address(0));
    vm.prank(owner);
    vm.expectRevert(QueryTypeStakerFactory.QueryTypeStakerFactory__InvalidRecipient.selector);
    factory.setFeeRecipient(address(0));
  }
}
