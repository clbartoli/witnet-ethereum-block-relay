pragma solidity >=0.6.0 <0.7.0;

contract Migrations {
  address public owner;
  uint public lastCompletedMigration;

  modifier restricted() {
    if (msg.sender == owner)
    _;
  }

  constructor() public {
    owner = msg.sender;
  }

  function setCompleted(uint _completed) public restricted {
    lastCompletedMigration = _completed;
  }

  function upgrade(address _newAddress) public restricted {
    Migrations upgraded = Migrations(_newAddress);
    upgraded.setCompleted(lastCompletedMigration);
  }

}
