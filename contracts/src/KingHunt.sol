// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CavFi Royal Treasure Hunt
/// @notice Each hunt has a few riddles whose answers are hidden around CavFi. Only a hash of each answer is on chain:
///         key = keccak256(abi.encodePacked(huntId, clueIndex, normalizedAnswer)), normalized = lowercase a-z0-9.
///         A player who cracks a riddle proves it in two steps, so nobody can copy the solution from the chain:
///         1. commit(keccak256(abi.encode(player, huntId, clueIndex, key))) - hides the key;
///         2. reveal(huntId, clueIndex, key) in a later block - checks the key and the commit.
///         The order of solvers counts from the commit block, so a copier is always behind whoever revealed first.
///         The first 3 wallets to solve every riddle of the hunt win 50% / 30% / 20% of its KingS prize, paid at once.
contract KingHunt is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable kings;

    struct Hunt {
        uint64 start;
        uint64 end;
        uint8 clues;
        uint32 finishers;
        uint256 prize;
        uint256 paid;
        string title;
    }

    Hunt[] internal hunts;
    mapping(uint256 => string[]) internal clueText;
    mapping(uint256 => bytes32[]) internal keys;
    mapping(uint256 => uint32[]) internal solverCount;
    mapping(uint256 => address[3]) internal winners;
    mapping(uint256 => mapping(address => uint256)) public solvedMask;
    mapping(uint256 => mapping(address => uint64)) public finishedAt;
    mapping(bytes32 => uint64) public commitBlock;
    mapping(bytes32 => uint64) public commitTime;

    uint16[3] public SHARES = [5000, 3000, 2000];

    event HuntCreated(uint256 indexed id, string title, uint64 start, uint64 end, uint8 clues, uint256 prize);
    event Committed(address indexed player, bytes32 commitment);
    event Solved(uint256 indexed id, address indexed player, uint8 clue, uint32 order);
    event Finished(uint256 indexed id, address indexed player, uint32 place, uint256 prize);

    constructor(address owner_, IERC20 kings_) Ownable(owner_) {
        kings = kings_;
    }

    /// @notice Opens a hunt and pulls its prize (KingS) from the owner.
    function create(string calldata title, uint64 start, uint64 end, string[] calldata clues, bytes32[] calldata answerKeys, uint256 prize)
        external onlyOwner returns (uint256 id)
    {
        require(clues.length > 0 && clues.length == answerKeys.length && clues.length <= 16, "Hunt: clues");
        require(end > start && end > block.timestamp, "Hunt: time");
        id = hunts.length;
        hunts.push(Hunt(start, end, uint8(clues.length), 0, prize, 0, title));
        for (uint256 i; i < clues.length; i++) {
            require(answerKeys[i] != bytes32(0), "Hunt: key");
            clueText[id].push(clues[i]);
            keys[id].push(answerKeys[i]);
            solverCount[id].push(0);
        }
        if (prize > 0) kings.safeTransferFrom(msg.sender, address(this), prize);
        emit HuntCreated(id, title, start, end, uint8(clues.length), prize);
    }

    /// @notice After a hunt has ended, the prize nobody won goes back to the owner.
    function reclaim(uint256 id) external onlyOwner {
        Hunt storage h = hunts[id];
        require(block.timestamp > h.end, "Hunt: running");
        uint256 left = h.prize - h.paid;
        require(left > 0, "Hunt: nothing left");
        h.paid = h.prize;
        kings.safeTransfer(owner(), left);
    }

    function commit(bytes32 c) external {
        require(c != bytes32(0) && commitBlock[c] == 0, "Hunt: committed");
        commitBlock[c] = uint64(block.number);
        commitTime[c] = uint64(block.timestamp);
        emit Committed(msg.sender, c);
    }

    function reveal(uint256 id, uint8 clue, bytes32 key) external {
        Hunt storage h = hunts[id];
        require(block.timestamp >= h.start && block.timestamp <= h.end, "Hunt: closed");
        require(clue < h.clues, "Hunt: clue");
        require(key == keys[id][clue], "Hunt: wrong answer");
        bytes32 c = keccak256(abi.encode(msg.sender, id, clue, key));
        uint64 cb = commitBlock[c];
        require(cb != 0 && cb < block.number, "Hunt: commit first");
        uint256 bit = 1 << clue;
        uint256 mask = solvedMask[id][msg.sender];
        require(mask & bit == 0, "Hunt: solved");
        mask |= bit;
        solvedMask[id][msg.sender] = mask;
        uint32 order = ++solverCount[id][clue];
        emit Solved(id, msg.sender, clue, order);
        if (mask == (1 << h.clues) - 1) {
            finishedAt[id][msg.sender] = uint64(block.timestamp);
            uint32 place = ++h.finishers;
            uint256 amount;
            if (place <= 3) {
                winners[id][place - 1] = msg.sender;
                amount = h.prize * SHARES[place - 1] / 10000;
                h.paid += amount;
                if (amount > 0) kings.safeTransfer(msg.sender, amount);
            }
            emit Finished(id, msg.sender, place, amount);
        }
    }

    // ------------------------------------------------------------- views
    function count() external view returns (uint256) { return hunts.length; }

    function get(uint256 id) external view returns (Hunt memory h, string[] memory clues, bytes32[] memory answerKeys, uint32[] memory solvers, address[3] memory top) {
        return (hunts[id], clueText[id], keys[id], solverCount[id], winners[id]);
    }

    function keyOf(uint256 id, uint8 clue, string calldata normalizedAnswer) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(id, clue, normalizedAnswer));
    }

    function commitmentOf(address player, uint256 id, uint8 clue, bytes32 key) external pure returns (bytes32) {
        return keccak256(abi.encode(player, id, clue, key));
    }
}
