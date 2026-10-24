// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IDuelArena {
    struct Round {
        uint64 start;
        uint64 end;
        uint16 feeBps;
        uint8 winnerMask;
        bool settled;
        uint256 staked;
        uint256 rollover;
        uint256 winnerStake;
        uint256 payout;
    }

    function currentRound()
        external
        view
        returns (uint256 id, uint64 start, uint64 end, uint64 stakingEndsAt, uint256 secondsLeft, uint256 pot, uint16 feeBps, bool live);
    function getRound(uint256 id) external view returns (Round memory);
    function roundTokens(uint256 id) external view returns (address[] memory tokens, address[] memory pairs);
    function board(uint256 id)
        external
        view
        returns (uint256[] memory pots, uint256[] memory startAvg, uint256[] memory endAvg, uint32[] memory startCnt, uint32[] memory endCnt);
}

/// @title CavFi Arena duels
/// @notice One-on-one bets on the current Arena round: "RPUP beats KingS this hour, 1,000 KingS?".
///         The maker picks two of the round's tokens and a stake; whoever accepts takes the other token
///         with the same stake. When the Arena round is settled, the token whose price rose more against
///         DOGE (using the Arena's own start and end averages) wins, and its backer gets both stakes.
/// @dev No fee and no owner. A duel can be accepted only while Arena staking is open for that round,
///      the same rule as Arena bets. If either token lacks enough price samples, or both rose exactly the
///      same, both players get their stake back. An open duel can be cancelled by its maker, or by anyone
///      once accepting is no longer possible (the stake goes back to the maker).
contract KingDuel is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint32 public constant MIN_SAMPLES = 3;
    enum State { None, Open, Matched, Done, Cancelled }

    struct Duel {
        address maker;
        address taker;
        address invited;  // 0 = anyone may accept
        address winner;   // 0 after Done = refund
        uint64 roundId;
        uint8 makerIdx;
        uint8 takerIdx;
        State state;
        uint256 stake;
    }

    IDuelArena public immutable arena;
    IERC20 public immutable kings;
    Duel[] internal duels;
    mapping(address => uint256[]) internal byUser;

    event Created(uint256 indexed id, address indexed maker, uint256 indexed roundId, uint8 makerIdx, uint8 takerIdx, uint256 stake, address invited);
    event Accepted(uint256 indexed id, address indexed taker);
    event Settled(uint256 indexed id, address winner, uint256 paid);
    event Cancelled(uint256 indexed id);

    constructor(address arena_, IERC20 kings_) {
        arena = IDuelArena(arena_);
        kings = kings_;
    }

    function _stakingEnd() internal view returns (uint256 id, uint64 stakingEndsAt) {
        (id,,, stakingEndsAt,,,, ) = arena.currentRound();
    }

    function create(uint8 makerIdx, uint8 takerIdx, uint256 stake, address invited) external nonReentrant returns (uint256 id) {
        (uint256 roundId, uint64 stakingEndsAt) = _stakingEnd();
        require(roundId != 0 && block.timestamp < stakingEndsAt, "Duel: staking closed");
        (address[] memory toks,) = arena.roundTokens(roundId);
        require(makerIdx < toks.length && takerIdx < toks.length && makerIdx != takerIdx, "Duel: tokens");
        require(stake > 0, "Duel: stake");
        require(invited != msg.sender, "Duel: yourself");
        kings.safeTransferFrom(msg.sender, address(this), stake);
        id = duels.length;
        duels.push(Duel(msg.sender, address(0), invited, address(0), uint64(roundId), makerIdx, takerIdx, State.Open, stake));
        byUser[msg.sender].push(id);
        emit Created(id, msg.sender, roundId, makerIdx, takerIdx, stake, invited);
    }

    function accept(uint256 id) external nonReentrant {
        Duel storage d = duels[id];
        require(d.state == State.Open, "Duel: not open");
        require(msg.sender != d.maker, "Duel: yourself");
        require(d.invited == address(0) || d.invited == msg.sender, "Duel: not invited");
        (uint256 roundId, uint64 stakingEndsAt) = _stakingEnd();
        require(roundId == d.roundId && block.timestamp < stakingEndsAt, "Duel: staking closed");
        kings.safeTransferFrom(msg.sender, address(this), d.stake);
        d.taker = msg.sender;
        d.state = State.Matched;
        byUser[msg.sender].push(id);
        emit Accepted(id, msg.sender);
    }

    function cancel(uint256 id) external nonReentrant {
        Duel storage d = duels[id];
        require(d.state == State.Open, "Duel: not open");
        if (msg.sender != d.maker) {
            (uint256 roundId, uint64 stakingEndsAt) = _stakingEnd();
            require(roundId != d.roundId || block.timestamp >= stakingEndsAt, "Duel: still open");
        }
        d.state = State.Cancelled;
        kings.safeTransfer(d.maker, d.stake);
        emit Cancelled(id);
    }

    /// @notice Anyone can settle a matched duel once its Arena round is settled.
    function settle(uint256 id) external nonReentrant {
        Duel storage d = duels[id];
        require(d.state == State.Matched, "Duel: not matched");
        require(arena.getRound(d.roundId).settled, "Duel: round not settled");
        d.state = State.Done;
        uint8 r = winnerOf(d.roundId, d.makerIdx, d.takerIdx);
        address w = r == 1 ? d.maker : r == 2 ? d.taker : address(0);
        d.winner = w;
        if (w == address(0)) {
            kings.safeTransfer(d.maker, d.stake);
            kings.safeTransfer(d.taker, d.stake);
            emit Settled(id, address(0), 0);
        } else {
            kings.safeTransfer(w, d.stake * 2);
            emit Settled(id, w, d.stake * 2);
        }
    }

    /// @return 1 = token a rose more, 2 = token b rose more, 0 = tie or not enough samples (refund)
    function winnerOf(uint256 roundId, uint8 a, uint8 b) public view returns (uint8) {
        (, uint256[] memory s, uint256[] memory e, uint32[] memory sc, uint32[] memory ec) = arena.board(roundId);
        if (sc[a] < MIN_SAMPLES || ec[a] < MIN_SAMPLES || sc[b] < MIN_SAMPLES || ec[b] < MIN_SAMPLES) return 0;
        if (s[a] == 0 || s[b] == 0) return 0;
        // compare e[a]/s[a] with e[b]/s[b] without division
        uint256 left = e[a] * s[b];
        uint256 right = e[b] * s[a];
        return left > right ? 1 : right > left ? 2 : 0;
    }

    // ------------------------------------------------------------- views
    function count() external view returns (uint256) { return duels.length; }

    function get(uint256 id) external view returns (Duel memory) { return duels[id]; }

    function idsOf(address user) external view returns (uint256[] memory) { return byUser[user]; }

    /// @notice Newest first: duels[count-1-start] ... up to n items.
    function page(uint256 start, uint256 n) external view returns (uint256[] memory ids, Duel[] memory items) {
        uint256 len = duels.length;
        if (start >= len) return (new uint256[](0), new Duel[](0));
        if (n > len - start) n = len - start;
        ids = new uint256[](n);
        items = new Duel[](n);
        for (uint256 i; i < n; i++) { ids[i] = len - 1 - start - i; items[i] = duels[ids[i]]; }
    }
}
