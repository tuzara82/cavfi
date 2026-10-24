// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CavFi Royal Raffle
/// @notice A weekly KingS draw. Tickets are earned, not bought: the CavFi bot gives one ticket per
///         daily quest a wallet completes. When the week ends anyone can close the round, and a few
///         blocks later anyone can draw it: three winners get 50%, 30% and 20% of the pot, picked
///         with a chance proportional to their tickets. The pot is KingS that anyone can add with fund().
/// @dev Randomness is the hash of a block chosen when the round is closed (a future block at that
///      moment). On a testnet with one sequencer that block producer could in theory influence it,
///      so this is a game, not a lottery for value. If the chosen block becomes too old (256 blocks),
///      drawing picks a new future block instead.
contract KingRaffle is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_PLAYERS = 2000;
    uint16[3] public SHARES = [5000, 3000, 2000];

    IERC20 public immutable kings;
    mapping(address => bool) public attester;
    uint64 public roundLength = 7 days;

    struct Round {
        uint64 start;
        uint64 end;
        uint64 drawBlock; // 0 = not closed
        bool drawn;
        uint256 totalTickets;
        uint256 pot;      // set when drawn
        address[3] winners;
        uint256[3] prizes;
    }

    uint256 public currentId;
    mapping(uint256 => Round) internal rounds;
    mapping(uint256 => address[]) internal players;
    mapping(uint256 => mapping(address => uint256)) public ticketsOf;

    event Funded(address indexed from, uint256 amount);
    event Tickets(uint256 indexed id, address indexed who, uint256 added, uint256 total);
    event Closed(uint256 indexed id, uint64 drawBlock);
    event Drawn(uint256 indexed id, address[3] winners, uint256[3] prizes, uint256 pot);
    event AttesterSet(address indexed who, bool allowed);

    constructor(address owner_, IERC20 kings_) Ownable(owner_) {
        kings = kings_;
        _open(1);
    }

    function setAttester(address a, bool allowed) external onlyOwner {
        attester[a] = allowed;
        emit AttesterSet(a, allowed);
    }

    /// @notice Length of rounds opened from now on (1 hour .. 30 days).
    function setRoundLength(uint64 len) external onlyOwner {
        require(len >= 1 hours && len <= 30 days, "Raffle: length");
        roundLength = len;
    }

    function fund(uint256 amount) external nonReentrant {
        kings.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    function addTickets(address[] calldata users, uint256[] calldata counts) external {
        require(attester[msg.sender], "Raffle: not attester");
        require(users.length == counts.length, "Raffle: length");
        Round storage r = rounds[currentId];
        require(block.timestamp < r.end && r.drawBlock == 0, "Raffle: round over");
        for (uint256 i; i < users.length; i++) {
            if (counts[i] == 0 || users[i] == address(0)) continue;
            if (ticketsOf[currentId][users[i]] == 0) {
                require(players[currentId].length < MAX_PLAYERS, "Raffle: full");
                players[currentId].push(users[i]);
            }
            ticketsOf[currentId][users[i]] += counts[i];
            r.totalTickets += counts[i];
            emit Tickets(currentId, users[i], counts[i], ticketsOf[currentId][users[i]]);
        }
    }

    /// @notice After the round ends: fix the future block whose hash decides the winners.
    function close() external {
        Round storage r = rounds[currentId];
        require(block.timestamp >= r.end, "Raffle: not ended");
        require(r.drawBlock == 0, "Raffle: closed");
        r.drawBlock = uint64(block.number + 3);
        emit Closed(currentId, r.drawBlock);
    }

    function draw() external nonReentrant {
        uint256 id = currentId;
        Round storage r = rounds[id];
        require(r.drawBlock != 0 && block.number > r.drawBlock, "Raffle: not ready");
        bytes32 h = blockhash(r.drawBlock);
        if (h == bytes32(0)) {
            // the chosen block is too old to read: pick a new future block
            r.drawBlock = uint64(block.number + 3);
            emit Closed(id, r.drawBlock);
            return;
        }
        r.drawn = true;
        uint256 pot = kings.balanceOf(address(this));
        r.pot = pot;
        address[] storage ps = players[id];
        uint256 total = r.totalTickets;
        if (total > 0 && pot > 0) {
            uint256 picked;
            for (uint256 w; w < 3 && picked < ps.length; w++) {
                for (uint256 attempt; attempt < 12; attempt++) {
                    uint256 x = uint256(keccak256(abi.encode(h, id, w, attempt))) % total;
                    address who = _pick(ps, id, x);
                    if (who != r.winners[0] && who != r.winners[1] && who != r.winners[2]) {
                        r.winners[w] = who;
                        r.prizes[w] = pot * SHARES[w] / 10_000;
                        picked++;
                        break;
                    }
                }
            }
            for (uint256 w; w < 3; w++) if (r.winners[w] != address(0) && r.prizes[w] > 0) kings.safeTransfer(r.winners[w], r.prizes[w]);
        }
        emit Drawn(id, r.winners, r.prizes, pot);
        _open(id + 1);
    }

    function _pick(address[] storage ps, uint256 id, uint256 x) internal view returns (address) {
        uint256 acc;
        for (uint256 i; i < ps.length; i++) {
            acc += ticketsOf[id][ps[i]];
            if (x < acc) return ps[i];
        }
        return ps[ps.length - 1];
    }

    function _open(uint256 id) internal {
        currentId = id;
        Round storage r = rounds[id];
        r.start = uint64(block.timestamp);
        r.end = uint64(block.timestamp) + roundLength;
    }

    // ------------------------------------------------------------- views
    function current()
        external
        view
        returns (uint256 id, uint64 start, uint64 end, uint256 totalTickets, uint256 playerCount, uint256 pot, uint64 drawBlock)
    {
        Round storage r = rounds[currentId];
        return (currentId, r.start, r.end, r.totalTickets, players[currentId].length, kings.balanceOf(address(this)), r.drawBlock);
    }

    function getRound(uint256 id) external view returns (Round memory) {
        return rounds[id];
    }

    function playersOf(uint256 id) external view returns (address[] memory) {
        return players[id];
    }
}
