// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PrimaryProdDataServiceConsumerBase} from
    "@redstone-finance/evm-connector/contracts/data-services/PrimaryProdDataServiceConsumerBase.sol";

/// @title CavFi "Guess the DOGE price" v2: a free daily game, decided by RedStone
/// @notice Every UTC day, each wallet can make one free guess of the DOGE/USD price at 20:00 UTC that day.
///         Guesses close at 18:00 UTC. The answer is RedStone's DOGE/USD price signed at exactly 20:00:00 UTC
///         by its primary-prod oracle nodes. Anyone can settle a day after 20:00: the transaction carries
///         RedStone's signed data and this contract checks the signatures (3 of 5 signers) and the time.
///         The closest guess wins the day's KingS prize from the prize fund. A tie goes to whoever guessed
///         first. Nothing is staked: playing only costs gas.
/// @dev If a day is not settled within 1 day (RedStone's gateways keep signed history for a limited time),
///      it can no longer be settled and its prize stays in the fund.
contract KingGuess2 is Ownable, ReentrancyGuard, PrimaryProdDataServiceConsumerBase {
    using SafeERC20 for IERC20;

    uint64 public constant TARGET = 20 hours;     // 20:00 UTC
    uint64 public constant CLOSE = 18 hours;      // guesses accepted until 18:00 UTC
    uint64 public constant SETTLE_WINDOW = 1 days;
    uint256 public constant MAX_GUESSES = 1000;   // per day, keeps settle() within gas limits
    bytes32 public constant FEED = bytes32("DOGE");

    struct Guess {
        address who;
        uint64 price;   // USD, 8 decimals
        uint64 at;
    }

    struct Day {
        bool settled;
        uint64 price;   // RedStone DOGE/USD at 20:00 UTC, 8 decimals
        address winner;
        uint64 winnerGuess;
        uint256 prize;  // paid prize (0 if nobody played)
    }

    IERC20 public immutable kings;
    uint256 public prize;   // prize for each new day, KingS (18 decimals)

    mapping(uint32 => Guess[]) internal _guesses;
    mapping(uint32 => mapping(address => uint256)) internal _slot;   // index + 1
    mapping(uint32 => Day) internal days_;

    event Guessed(uint32 indexed day, address indexed who, uint64 price);
    event Settled(uint32 indexed day, uint64 price, address indexed winner, uint64 winnerGuess, uint256 prize);
    event PrizeSet(uint256 prize);

    constructor(address owner_, IERC20 kings_, uint256 prize_) Ownable(owner_) {
        kings = kings_;
        prize = prize_;
    }

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

    /// @notice Anyone can settle a day after 20:00 UTC. Append RedStone's signed DOGE data for exactly
    ///         20:00:00 UTC of that day to the calldata (cavfi.com and the CavFi bot do this for you).
    function settle(uint32 day) external nonReentrant {
        Day storage D = days_[day];
        require(!D.settled, "Guess: settled");
        uint64 t = targetAt(day);
        require(block.timestamp >= t, "Guess: too early");
        require(block.timestamp <= t + SETTLE_WINDOW, "Guess: too late");
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED;
        (uint256[] memory values, uint256 tsMs) = getOracleNumericValuesAndTimestampFromTxMsg(ids);
        require(tsMs == uint256(t) * 1000, "Guess: RedStone data is not from 20:00 UTC");
        require(values[0] > 0 && values[0] <= type(uint64).max, "Guess: price");
        uint64 price = uint64(values[0]);
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
