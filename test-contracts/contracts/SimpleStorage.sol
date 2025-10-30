// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SimpleStorage
 * @dev Store & retrieve value in a variable
 * @notice This is a test contract for Monad testnet deployment
 */
contract SimpleStorage {
    uint256 private storedData;
    address public owner;

    event ValueChanged(uint256 newValue, address changedBy);

    constructor(uint256 initialValue) {
        storedData = initialValue;
        owner = msg.sender;
    }

    /**
     * @dev Store value in variable
     * @param newValue value to store
     */
    function set(uint256 newValue) public {
        storedData = newValue;
        emit ValueChanged(newValue, msg.sender);
    }

    /**
     * @dev Return value
     * @return value of 'storedData'
     */
    function get() public view returns (uint256) {
        return storedData;
    }

    /**
     * @dev Increment the stored value by 1
     */
    function increment() public {
        storedData += 1;
        emit ValueChanged(storedData, msg.sender);
    }
}
