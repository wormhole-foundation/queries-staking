// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {QueryTypeStakingPool} from "src/QueryTypeStakingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title QueryTypeStakerFactory
/// @author [ScopeLift](https://scopelift.co)
/// @notice This contract manages the creation of staking pools for different query type bit fields.
/// Each query type bit field can have one active staking pool, and only the contract owner can
/// create new pools.
contract QueryTypeStakerFactory is Ownable {
  /// @notice The token that will be used for staking.
  IERC20 public immutable STAKING_TOKEN;

  /// @notice Address that receives fees and decayed stake from pools
  address public feeRecipient;

  /// @notice Maps query type bit fields to their corresponding staking pool addresses.
  mapping(bytes32 queryType => address poolAddress) public queryTypePools;

  /// @notice Emitted when fee recipient is updated
  event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

  /// @notice Emitted when a new staking pool is created for a query type bit field.
  event CreateQueryTypeStakingPool(bytes32 indexed queryType, address indexed poolAddress);

  /// @notice Thrown when attempting to create a pool for a query type bit field that exists.
  error QueryTypeStakerFactory__PoolExists();

  /// @notice Thrown when an invalid (zero) token address is provided.
  error QueryTypeStakerFactory__InvalidTokenAddress();

  /// @notice Thrown when an invalid (zero) recipient address is provided.
  error QueryTypeStakerFactory__InvalidRecipient();

  /// @notice Constructor that sets the initial owner and staking token.
  /// @param _owner The address that will be set as the contract owner.
  /// @param _stakingToken The address of the Wormhole token that will be used for staking.
  constructor(address _owner, address _stakingToken) Ownable(_owner) {
    if (_stakingToken == address(0)) revert QueryTypeStakerFactory__InvalidTokenAddress();
    STAKING_TOKEN = IERC20(_stakingToken);
    _setFeeRecipient(_owner);
  }

  /// @notice Creates a new staking pool for a specific query type bit field.
  /// @param _queryType The bit field representing the queries this pool will support.
  /// @param _poolOwner The address that will own the staking pool.
  /// @param _initialEntry The initial conversion table entry for the pool.
  /// @return _poolAddress The address of the newly created staking pool.
  /// @dev Only callable by the contract owner.
  function createStakingPool(bytes32 _queryType, address _poolOwner, bytes32 _initialEntry)
    external
    returns (address _poolAddress)
  {
    _checkOwner();
    if (queryTypePools[_queryType] != address(0)) revert QueryTypeStakerFactory__PoolExists();

    // Deploy new staking pool with STAKING_TOKEN address and initial conversion entry
    QueryTypeStakingPool _newPool =
      new QueryTypeStakingPool(_poolOwner, address(STAKING_TOKEN), address(this), _initialEntry);
    _poolAddress = address(_newPool);

    // Store the pool address
    queryTypePools[_queryType] = _poolAddress;

    emit CreateQueryTypeStakingPool(_queryType, _poolAddress);
  }

  /// @notice Updates the fee recipient address.
  /// @param _newRecipient The new address to receive fees.
  function setFeeRecipient(address _newRecipient) external {
    _checkOwner();
    _setFeeRecipient(_newRecipient);
  }

  /// @notice Internal function to update the fee recipient and emit an event.
  /// @param _newRecipient The new address to receive fees.
  function _setFeeRecipient(address _newRecipient) internal {
    if (_newRecipient == address(0)) revert QueryTypeStakerFactory__InvalidRecipient();
    address old = feeRecipient;
    feeRecipient = _newRecipient;
    emit FeeRecipientUpdated(old, _newRecipient);
  }
}
