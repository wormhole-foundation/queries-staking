// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {QueryTypeStakerFactory} from "src/QueryTypeStakerFactory.sol";
import {QueryTypeStakingPool} from "src/QueryTypeStakingPool.sol";
import {VmSafe} from "forge-std/Vm.sol";

contract QueryTypeStakerFactoryTest is Test {
  QueryTypeStakerFactory public factory;
  address public owner;
  address public stakingToken;
  bytes32 public queryType;

  function setUp() public virtual {
    owner = makeAddr("owner");
    stakingToken = makeAddr("stakingToken");
    vm.prank(owner);
    factory = new QueryTypeStakerFactory(owner, stakingToken);
    queryType = bytes32(uint256(1));
  }

  function _createPool() internal returns (address) {
    vm.prank(owner);
    return factory.createStakingPool(queryType, owner, bytes32(0));
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
    bytes32 _queryType,
    address _poolOwner,
    bytes32 _initialEntry
  ) public {
    vm.assume(_poolOwner != address(0));
    vm.prank(owner);
    address poolAddress = factory.createStakingPool(_queryType, _poolOwner, _initialEntry);

    assertTrue(poolAddress != address(0));
    assertEq(factory.queryTypePools(_queryType), poolAddress);
    assertEq(QueryTypeStakingPool(poolAddress).owner(), _poolOwner);
  }

  function testFuzz_EmitsCreateQueryTypeStakingPoolEventWithArbitraryQueryType(
    bytes32 _queryType,
    address _poolOwner,
    bytes32 _initialEntry
  ) public {
    vm.assume(_poolOwner != address(0));
    vm.recordLogs();
    vm.prank(owner);
    address poolAddress = factory.createStakingPool(_queryType, _poolOwner, _initialEntry);

    VmSafe.Log[] memory entries = vm.getRecordedLogs();
    assertEq(entries[2].topics[0], keccak256("CreateQueryTypeStakingPool(bytes32,address)"));
    assertEq(entries[2].topics[1], _queryType); // queryType
    assertEq(entries[2].topics[2], bytes32(uint256(uint160(poolAddress)))); // poolAddress
  }

  function testFuzz_RevertIf_CallerIsNotOwner(
    address _notOwner,
    address _poolOwner,
    bytes32 _initialEntry
  ) public {
    vm.assume(_notOwner != owner && _notOwner != address(0));
    vm.assume(_poolOwner != address(0));

    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", _notOwner));
    factory.createStakingPool(queryType, _poolOwner, _initialEntry);
  }

  function testFuzz_RevertIf_PoolAlreadyExistsWithArbitraryQueryType(
    bytes32 _queryType,
    address _poolOwner,
    bytes32 _initialEntry
  ) public {
    vm.assume(_poolOwner != address(0));
    vm.startPrank(owner);
    factory.createStakingPool(_queryType, _poolOwner, _initialEntry);

    vm.expectRevert(QueryTypeStakerFactory.QueryTypeStakerFactory__PoolExists.selector);
    factory.createStakingPool(_queryType, _poolOwner, _initialEntry);
    vm.stopPrank();
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
