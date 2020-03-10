pragma solidity ^0.5.0;

import "./ABSWitnetRequestsBoardInterface.sol";
import "./BlockRelayInterface.sol";


/**
 * @title Active Bridge Set Block relay contract
 * @notice Contract to store/read block headers from the Witnet network, implements BFT Finality bsaed on the Active Bridge Set (ABS)
 * @dev More information can be found here https://github.com/witnet/research/blob/master/bridge/docs/BFT_finality.md
 * DISCLAIMER: this is a work in progress, meaning the contract could be voulnerable to attacks
 * @author Witnet Foundation
 */
contract ActiveBridgeSetBlockRelay is BlockRelayInterface {

  struct MerkleRoots {
    // Hash of the merkle root of the DRs in Witnet
    uint256 drHashMerkleRoot;
    // Hash of the merkle root of the tallies in Witnet
    uint256 tallyHashMerkleRoot;
    // Hash of the vote that this block extends
    uint256 previousVote;
  }

  struct Beacon {
    // Hash of the last block
    uint256 blockHash;
    // Epoch of the last block
    uint256 epoch;
  }

  // Struct with the hashes of a votation
  struct Hashes {
    uint256 blockHash;
    uint256 drMerkleRoot;
    uint256 tallyMerkleRoot;
    uint256 previousVote;
    uint256 epoch;
  }

  struct VoteInfo {
    // Information of a Block Candidate
    uint256 numberOfVotes;
    Hashes voteHashes;
  }

  // Array with the votes for the proposed blocks
  uint256[] public candidates;

  // Initializes the block with the maximum number of votes
  uint256 winnerVote;
  uint256 winnerId;
  uint256 winnerDrMerkleRoot;
  uint256 winnerTallyMerkleRoot;
  uint256 winnerEpoch;

  // Needed for the constructor
  uint256 witnetGenesis;
  uint256 epochSeconds;
  uint256 firstBlock;

  // Initializes the current epoch and the epoch in which it is valid to propose blocks
  uint256 currentEpoch;
  uint256 proposalEpoch;

  // Initializes the active identities in the ABS
  uint256 activeIdentities;

  // Witnet address
  address witnet;

  ABSWitnetRequestsBoardInterface wbi;

  // Last block reported
  Beacon public lastBlock;

  // Map a vote proposed to the number of votes received and its hashes
  mapping(uint256=> VoteInfo) internal voteInfo;

  // Map the hash of the block to the merkle roots and the previousVote it extends
  mapping (uint256 => MerkleRoots) public blocks;

  // Map an epoch to the finalized blockHash
  mapping(uint256 => uint256) internal epochFinalizedBlock;

  // Ensure block exists
  modifier blockExists(uint256 _id){
    require(blocks[_id].drHashMerkleRoot!=0, "Non-existing block");
    _;
  }
  // Ensure block does not exist
  modifier blockDoesNotExist(uint256 _id){
    require(blocks[_id].drHashMerkleRoot==0, "The block already existed");
    _;
  }

  // Ensure that neither Poi nor PoE are allowed if the epoch is pending
  modifier epochIsFinalized(uint256 _epoch){
    require(
      (epochFinalizedBlock[_epoch] != 0),
      "The block has not been finalized");
    _;
  }

  // Ensure that the msg.sender is in the abs
  modifier isAbsMember(address _address){

    require(wbi.isABSMember(_address) == true, "Not a member of the abs");
    _;
  }

  // Only the owner should be able to push blocks
  modifier isOwner() {
    require(msg.sender == witnet, "Sender not authorized"); // If it is incorrect here, it reverts.
    _; // Otherwise, it continues.
  }

  // Ensure the epoch for which the block is been proposed is valid
  // Valid if it is one epoch before the current epoch
  modifier epochValid(uint256 _epoch){
    currentEpoch = updateEpoch();
    if (proposalEpoch == 0) {
      proposalEpoch = currentEpoch;
    }
    require(currentEpoch - 1 == _epoch, "Proposing a block for a non valid epoch");
    _;
  }

  constructor(
    uint256 _witnetGenesis, uint256 _epochSeconds, uint256 _firstBlock, address _wbiAddress) public{
    // Set the first epoch in Witnet plus the epoch duration when deploying the contract
    witnetGenesis = _witnetGenesis;
    epochSeconds = _epochSeconds;
    firstBlock = _firstBlock;
    wbi = ABSWitnetRequestsBoardInterface(_wbiAddress);
    witnet = msg.sender;
  }

  /// @dev Retrieve the requests-only merkle root hash that was reported for a specific block header.
  /// @param _blockHash Hash of the block header
  /// @return Requests-only merkle root hash in the block header.
  function readDrMerkleRoot(uint256 _blockHash)
    external
    view
    blockExists(_blockHash)
  returns(uint256 drMerkleRoot)
    {
    drMerkleRoot = blocks[_blockHash].drHashMerkleRoot;
  }

  /// @dev Retrieve the tallies-only merkle root hash that was reported for a specific block header.
  /// @param _blockHash Hash of the block header
  /// tallies-only merkle root hash in the block header.
  function readTallyMerkleRoot(uint256 _blockHash)
    external
    view
    blockExists(_blockHash)
  returns(uint256 tallyMerkleRoot)
  {
    tallyMerkleRoot = blocks[_blockHash].tallyHashMerkleRoot;
  }

  /// @dev Verifies if the contract is upgradable
  /// @return true if the contract upgradable
  function isUpgradable(address _address) external view returns(bool) {
    if (_address == witnet) {
      return true;
    }
    return false;
  }

  /// @dev Read the beacon of the last block inserted
  /// @return bytes to be signed by bridge nodes
  function getLastBeacon()
    external
    view
  returns(bytes memory)
  {
    return abi.encodePacked(lastBlock.blockHash, lastBlock.epoch);
  }

  /// @dev Verifies the validity of a PoI against the DR merkle root
  /// @param _poi the proof of inclusion as [sibling1, sibling2,..]
  /// @param _blockHash the blockHash
  /// @param _index the index in the merkle tree of the element to verify
  /// @param _element the leaf to be verified
  /// @return true or false depending the validity
  function verifyDrPoi(
    uint256[] calldata _poi,
    uint256 _blockHash,
    uint256 _index,
    uint256 _element)
  external
  view
  blockExists(_blockHash)
  epochIsFinalized(currentEpoch)
  returns(bool)
  {
    uint256 drMerkleRoot = blocks[_blockHash].drHashMerkleRoot;
    return(verifyPoi(
      _poi,
      drMerkleRoot,
      _index,
      _element));
  }

  /// @dev Verifies the validity of a PoI against the tally merkle root
  /// @param _poi the proof of inclusion as [sibling1, sibling2,..]
  /// @param _blockHash the blockHash
  /// @param _index the index in the merkle tree of the element to verify
  /// @param _element the element
  /// @return true or false depending the validity
  function verifyTallyPoi(
    uint256[] calldata _poi,
    uint256 _blockHash,
    uint256 _index,
    uint256 _element)
  external
  view
  blockExists(_blockHash)
  returns(bool)
  {
    uint256 tallyMerkleRoot = blocks[_blockHash].tallyHashMerkleRoot;
    return(verifyPoi(
      _poi,
      tallyMerkleRoot,
      _index,
      _element));

  }

  /// @dev Proposes a block into the block relay
  /// @param _blockHash Hash of the block header
  /// @param _epoch Epoch for which the block is proposed
  /// @param _drMerkleRoot Merkle root belonging to the data requests
  /// @param _tallyMerkleRoot Merkle root belonging to the tallies
  /// @param _previousVote Hash of block's hashes proposed in a previous epoch
  function proposeBlock(
    uint256 _blockHash,
    uint256 _epoch,
    uint256 _drMerkleRoot,
    uint256 _tallyMerkleRoot,
    uint256 _previousVote
    )
    external
    epochValid(_epoch)
    isAbsMember(msg.sender)
    blockDoesNotExist(_blockHash)
    returns(bytes32)
  {
    // If the porposal epoch changes try to post the block that got more votes
    // and restart counting votesn for the new proposalEpoch
    if (currentEpoch > proposalEpoch) {
      // If consensus is achieved, call postNewBlock
      if (3 * voteInfo[winnerVote].numberOfVotes >= 2 * activeIdentities) {
        // If it has achieved consensus, post the block
        postNewBlock(
          winnerVote,
          winnerId,
          winnerEpoch,
          winnerDrMerkleRoot,
          winnerTallyMerkleRoot,
          voteInfo[winnerVote].voteHashes.previousVote);
      }
      // Set the winner values to 0
      winnerVote = 0;
      winnerId = 0;
      winnerEpoch = 0;
      winnerDrMerkleRoot = 0;
      winnerTallyMerkleRoot = 0;
      // Update the proposal epoch
      proposalEpoch = currentEpoch;
    }

    // Hash of the elements of the vote
    uint256 vote = uint256(
      sha256(
        abi.encodePacked(
      _blockHash,
      _epoch,
      _drMerkleRoot,
      _tallyMerkleRoot,
      _previousVote)));
    if (voteInfo[vote].numberOfVotes == 0) {
      // Add the vote to candidates
      candidates.push(vote);
      // Mapping the vote into its hashes
      voteInfo[vote].voteHashes.blockHash = _blockHash;
      voteInfo[vote].voteHashes.drMerkleRoot = _drMerkleRoot;
      voteInfo[vote].voteHashes.tallyMerkleRoot = _tallyMerkleRoot;
      voteInfo[vote].voteHashes.previousVote = _previousVote;
      voteInfo[vote].voteHashes.epoch = _epoch;
    }

    // Sum one vote
    voteInfo[vote].numberOfVotes += 1;
    // If needed, update the block that has more votes
    if (vote != winnerVote) {
      // Set as new winner if it has more votes
      if (voteInfo[vote].numberOfVotes > voteInfo[winnerVote].numberOfVotes) {
        winnerVote = vote;
        winnerId = _blockHash;
        winnerEpoch = _epoch;
        winnerDrMerkleRoot = _drMerkleRoot;
        winnerTallyMerkleRoot = _tallyMerkleRoot;
      }
    }

    return bytes32(vote);

  }

  /// @dev Updates the epoch
  function updateEpoch() public view returns(uint256) {
    // solium-disable-next-line security/no-block-members
    return (block.timestamp - witnetGenesis)/epochSeconds;
  }

  /// @dev Post new block into the block relay
  /// @param _vote Vote created when the block was proposed
  /// @param _blockHash Hash of the block headerPost
  /// @param _epoch Witnet epoch to which the block belongs to
  /// @param _drMerkleRoot Merkle root belonging to the data requests
  /// @param _tallyMerkleRoot Merkle root belonging to the tallies
  /// @param _previousVote Hash of block's hashes proposed in the previous epoch
  function postNewBlock(
    uint256 _vote,
    uint256 _blockHash,
    uint256 _epoch,
    uint256 _drMerkleRoot,
    uint256 _tallyMerkleRoot,
    uint256 _previousVote)
    private
    blockDoesNotExist(_blockHash)
  {
    // Map the epoch to the vote's Hashes
    epochFinalizedBlock[_epoch] = voteInfo[_vote].voteHashes.blockHash;
    blocks[_blockHash].drHashMerkleRoot = _drMerkleRoot;
    blocks[_blockHash].tallyHashMerkleRoot = _tallyMerkleRoot;
    blocks[_blockHash].previousVote = _previousVote;

    // Select previous vote and corresponding epoch and blockHash
    uint256 previousVote = blocks[epochFinalizedBlock[_epoch]].previousVote;
    uint256 epoch = voteInfo[_previousVote].voteHashes.epoch;
    uint256 previousBlockHash = voteInfo[previousVote].voteHashes.blockHash;

    // Finalize the previous votes when the corresponding epochs are bigger than the last finalized epoch
    while (epoch > lastBlock.epoch) {
      epochFinalizedBlock[epoch] = previousBlockHash;
      // Map the block hash to its hashes
      blocks[previousBlockHash].drHashMerkleRoot = voteInfo[previousVote].voteHashes.drMerkleRoot;
      blocks[previousBlockHash].tallyHashMerkleRoot = voteInfo[previousVote].voteHashes.tallyMerkleRoot;
      blocks[previousBlockHash].previousVote = voteInfo[previousVote].voteHashes.previousVote;
      // Update previousVote, epoch and previousBlockHash
      previousVote = voteInfo[previousVote].voteHashes.previousVote;
      epoch = voteInfo[previousVote].voteHashes.epoch;
      previousBlockHash = voteInfo[previousVote].voteHashes.blockHash;
    }

    // Assert the concatenation of blocks ends in the right epoch with the right blockHash
    assert(epoch == lastBlock.epoch && previousBlockHash == lastBlock.blockHash);

    // Post the last block
    lastBlock.blockHash = _blockHash;
    lastBlock.epoch = _epoch;

    // Delete the condidates array so its empty for next epoch
    for (uint i = 0; i <= candidates.length - 1; i++) {
      delete voteInfo[candidates[i]].voteHashes;
    }
    delete candidates;

    // Redefine the blockHash and the epoch so it is not deleted when finalized
    voteInfo[_vote].voteHashes.blockHash = _blockHash;
    voteInfo[_vote].voteHashes.epoch = _epoch;

    // Update the ABS activity once finalized
    activeIdentities = wbi.absCount();
  }

  /// @dev Verifies the validity of a PoI
  /// @param _poi the proof of inclusion as [sibling1, sibling2,..]
  /// @param _root the merkle root
  /// @param _index the index in the merkle tree of the element to verify
  /// @param _element the leaf to be verified
  /// @return true or false depending the validity
  function verifyPoi(
    uint256[] memory _poi,
    uint256 _root,
    uint256 _index,
    uint256 _element)
  private pure returns(bool)
  {
    uint256 tree = _element;
    uint256 index = _index;
    // We want to prove that the hash of the _poi and the _element is equal to _root
    // For knowing if concatenate to the left or the right we check the parity of the the index
    for (uint i = 0; i < _poi.length; i++) {
      if (index%2 == 0) {
        tree = uint256(sha256(abi.encodePacked(tree, _poi[i])));
      } else {
        tree = uint256(sha256(abi.encodePacked(_poi[i], tree)));
      }
      index = index >> 1;
    }
    return _root == tree;
  }

}
