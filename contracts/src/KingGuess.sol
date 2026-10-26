// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CavFi "Guess the DOGE price": a free daily game
/// @notice Every UTC day, each wallet can make one free guess of the DOGE/USD price at 20:00 UTC that day.
///         Guesses close at 18:00 UTC. After 20:00 the oracle (the CavFi bot) reports the real price from a
///         public exchange, and the closest guess wins the day's KingS prize, paid by this contract from its
///         prize fund. A tie goes to whoever guessed first. Nothing is staked: playing only costs gas.
/// @dev The oracle is a trusted role, the same one that resolves CavFi Predict markets. If the oracle does not
///      settle a day within 7 days, that day's prize simply stays in the fund.
contract KingGuess is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant TARGET = 20 hours;     // 20:00 UTC
    uint64 public constant CLOSE = 18 hours;      // guesses accepted until 18:00 UTC
    uint256 public constant MAX_GUESSES = 1000;   // per day, keeps settle() within gas limits

    struct Guess {
        address who;
        uint64 price;   // USD, 8 decimals
        uint64 at;
    }

    struct Day {
        bool settled;
        uint64 price;   // reported price, 8 decimals
        address winner;
        uint64 winnerGuess;
        uint256 prize;  // paid prize (0 if nobody played)
    }

    IERC20 public immutable kings;
    address public oracle;
    uint256 public prize;   // prize for each new day, KingS (18 decimals)

    mapping(uint32 => Guess[]) internal _guesses;
    mapping(uint32 => mapping(address => uint256)) internal _slot;   // index + 1
    mapping(uint32 => Day) internal days_;

    event Guessed(uint32 indexed day, address indexed who, uint64 price);
    event Settled(uint32 indexed day, uint64 price, address indexed winner, uint64 winnerGuess, uint256 prize);
    event OracleSet(address oracle);
    event PrizeSet(uint256 prize);

    constructor(address owner_, IERC20 kings_, address oracle_, uint256 prize_) Ownable(owner_) {
        kings = kings_;
        oracle = oracle_;
        prize = prize_;
    }

    function setOracle(address o) external onlyOwner { oracle = o; emit OracleSet(o); }
    function setPrize(uint256 p) external onlyOwner { prize = p; emit PrizeSet(p); }

    /// @notice Owner can take back KingS that are not owed to anyone (prizes are paid at settle time).
    function withdraw(uint256 amount, address to) external onlyOwner { kings.safeTransfer(to, amount); }

    function today() public view returns (uint32) { return uint32(block.timestamp / 1 days); }
    function targetAt(uint32 day) public pure returns (uint64) { return uint64(day) * 1 days + TARGET; }
    function closeAt(uint32 day) public pure returns (uint64) { return uint64(day) * 1 days + CLOSE; }

    /// @param price your guess of DOGE/USD at 20:00 UTC today, with 8 decimals ($0.0773 = 7_730_000)
    function guess(uint64 price) external {
        uint32 d = today();
        require(block.timestamp < closeAt(d), "Guess: closed for today");
        require(price > 0, "Guess: price");
        require(_slot[d][msg.sender] == 0, "Guess: already guessed today");
        require(_guesses[d].length < MAX_GUESSES, "Guess: full");
        _guesses[d].push(Guess(msg.sender, price, uint64(block.timestamp)));
        _slot[d][msg.sender] = _guesses[d].length;
        emit Guessed(d, msg.sender, price);
    }

    /// @notice Oracle reports DOGE/USD at 20:00 UTC of `day`; the closest guess wins the prize.
    function settle(uint32 day, uint64 price) external nonReentrant {
        require(msg.sender == oracle || msg.sender == owner(), "Guess: not oracle");
        Day storage D = days_[day];
        require(!D.settled, "Guess: settled");
        require(block.timestamp >= targetAt(day), "Guess: too early");
        require(block.timestamp <= targetAt(day) + 7 days, "Guess: too late");
        require(price > 0, "Guess: price");
        D.settled = true;
        D.price = price;
        Guess[] storage g = _guesses[day];
        if (g.length == 0) { emit Settled(day, price, address(0), 0, 0); return; }
        uint256 best = type(uint256).max;
        uint256 bi;
        for (uint256 i; i < g.length; i++) {
            uint256 diff = g[i].price > price ? g[i].price - price : price - g[i].price;
            if (diff < best) { best = diff; bi = i; }   // strict: earlier guess wins a tie
        }
        uint256 p = prize;
        uint256 bal = kings.balanceOf(address(this));
        if (p > bal) p = bal;
        D.winner = g[bi].who;
        D.winnerGuess = g[bi].price;
        D.prize = p;
        if (p > 0) kings.safeTransfer(g[bi].who, p);
        emit Settled(day, price, g[bi].who, g[bi].price, p);
    }

    // ------------------------------------------------------------- views
    function count(uint32 day) external view returns (uint256) { return _guesses[day].length; }

    function guessOf(uint32 day, address who) external view returns (uint64 price, uint64 at) {
        uint256 s = _slot[day][who];
        if (s == 0) return (0, 0);
        Guess memory g = _guesses[day][s - 1];
        return (g.price, g.at);
    }

    function guesses(uint32 day, uint256 start, uint256 n) external view returns (Guess[] memory out) {
        Guess[] storage g = _guesses[day];
        if (start >= g.length) return new Guess[](0);
        if (n > g.length - start) n = g.length - start;
        out = new Guess[](n);
        for (uint256 i; i < n; i++) out[i] = g[start + i];
    }

    function dayInfo(uint32 d) external view returns (Day memory) { return days_[d]; }
}
