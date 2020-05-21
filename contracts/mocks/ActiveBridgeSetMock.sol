// SPDX-License-Identifier: MIT

pragma solidity 0.6.8;

import "../ActiveBridgeSetInterface.sol";


/**
 * @title Mock of the Witnet Requests Board to get the ActiveBridgeSetInterface methods
 * @dev The aim of this contract is to mock the ABS methods for testing purposes
 * @author Witnet Foundation
 */
contract ActiveBridgeSetMock is ActiveBridgeSetInterface {

  mapping(address => bool) public fakeABS;

  uint32 public count;

  function absIsMember(address _address) external view override returns (bool) {
    return fakeABS[_address];
  }

  // Pushes the activity in the ABS
  function pushActivity() external {
    address _address = msg.sender;
    if (fakeABS[_address] == false) {
      count++;
      fakeABS[_address] = true;
    }
  }

  // Gets the number of active identities in the ABS
  function absCount() external view override returns (uint32) {
    return count;
  }

  // Sets the number of members in the ABS
  function setAbsIdentitiesNumber(uint32 _identitiesNumber) external {
    count = _identitiesNumber;
  }

}
