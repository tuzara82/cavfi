// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CavFi Games: Coin Flip and Dice with DOGE stakes
/// @notice Randomness is a commit-reveal hash chain held by the house (the CavFi bot):
///         - The house publishes an anchor A = keccak^N(secret). Time is cut into 30-second rounds.
///         - A bet joins the round that is open when it lands. The round's seed is the hash-chain element that
///           was fixed (committed) long before the bet: seed(r) satisfies keccak^(r - last)(seed(r)) == seed(last).
///         - When a round has closed, the house reveals its seed and every bet of the round is settled at once.
///           roll = keccak256(seed, betId) % 100.
///         Neither side can pick the result: the player cannot know the seed, and the house cannot change it.
///         Rounds are revealed strictly in order, so the house cannot skip a round it does not like. If the house
///         does not reveal within 1 hour after the round closed, each bet of that round can be claimed as a win.
///         While the house is behind by more than 10 minutes, new bets are refused.
///         House edge: 2% (a winning bet pays stake x 98 / winning outcomes out of 100; Coin Flip pays 1.96x).
contract KingGames is Ownable, ReentrancyGuard {
    uint256 public constant ROUND = 30;           // seconds
    uint256 public constant OFFLINE = 10 minutes; // house this far behind: no new bets
    uint256 public constant TIMEOUT = 1 hours;    // house this late: the bet can be claimed as a win
    uint256 public constant MAX_BETS = 40;        // per round, so one reveal settles the whole round
    uint8 public constant COIN = 0;
    uint8 public constant DICE = 1;

    enum Status { None, Pending, Won, Lost, TimeoutWon }

    struct Bet {
        address player;
        uint96 stake;
        uint32 round;
        uint8 game;       // COIN or DICE
        uint8 pick;       // COIN: 0 heads, 1 tails. DICE: the target 2..99
        bool over;        // DICE: true = roll above target, false = roll below target
        uint8 roll;       // 1..100 once settled (COIN: 1..50 heads, 51..100 tails)
        Status status;
        uint96 payout;    // paid if won
        uint40 placedAt;
    }

    address public house;
    uint256 public minBet = 0.1 ether;
    uint256 public maxBet = 50 ether;
    uint256 public reserved;          // payouts of pending bets
    uint256 public anchors;           // how many anchors the house has set (it derives each chain from this)

    uint256 public lastRound;         // last revealed round (or the round the current anchor was set in)
    bytes32 public lastSeed;
    uint256 public chainLeft;         // hash-chain elements still unused below lastSeed

    Bet[] internal bets;
    mapping(uint256 => uint256[]) internal roundBets;
    mapping(uint256 => bytes32) public roundSeed;
    uint256[] internal queue;         // rounds with bets, in order; queue[head] is the next to reveal
    uint256 public head;
    mapping(address => uint256[]) internal byPlayer;
    mapping(address => uint256) public owed;   // payouts that could not be sent (e.g. a contract wallet)

    uint256 public totalBets;
    uint256 public totalStaked;
    uint256 public totalPaid;

    event Placed(uint256 indexed id, address indexed player, uint8 game, uint8 pick, bool over, uint256 stake, uint256 payout, uint256 round);
    event Settled(uint256 indexed id, address indexed player, uint8 roll, bool won, uint256 paid);
    event Revealed(uint256 indexed round, bytes32 seed, uint256 bets);
    event Anchored(uint256 indexed n, bytes32 anchor, uint256 round, uint256 length);
    event HouseSet(address house);
    event LimitsSet(uint256 minBet, uint256 maxBet);

    constructor(address owner_, address house_) Ownable(owner_) {
        house = house_;
    }

    receive() external payable {}

    modifier onlyHouse() {
        require(msg.sender == house || msg.sender == owner(), "Games: not house");
        _;
    }

    // ------------------------------------------------------------- admin
    function setHouse(address h) external onlyOwner { house = h; emit HouseSet(h); }

    function setLimits(uint256 min_, uint256 max_) external onlyOwner {
        require(min_ > 0 && max_ >= min_ && max_ < type(uint96).max, "Games: limits");
        minBet = min_; maxBet = max_;
        emit LimitsSet(min_, max_);
    }

    /// @notice Only DOGE not owed to pending bets can leave.
    function withdraw(uint256 amount, address payable to) external onlyOwner nonReentrant {
        require(amount <= free(), "Games: reserved");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "Games: send");
    }

    /// @notice A new hash chain: anchor = keccak^length(secret). Only when no round waits for a reveal.
    function setAnchor(bytes32 anchor, uint256 length) external onlyHouse {
        require(head == queue.length, "Games: rounds pending");
        require(anchor != bytes32(0) && length > 0, "Games: anchor");
        lastRound = currentRound();
        lastSeed = anchor;
        chainLeft = length;
        anchors++;
        emit Anchored(anchors, anchor, lastRound, length);
    }

    // ------------------------------------------------------------- play
    function currentRound() public view returns (uint256) { return block.timestamp / ROUND; }

    function free() public view returns (uint256) {
        uint256 b = address(this).balance;
        return b > reserved ? b - reserved : 0;
    }

    /// @notice Winning outcomes out of 100 for a bet (0 = invalid).
    function winsOf(uint8 game, uint8 pick, bool over) public pure returns (uint256) {
        if (game == COIN) return pick <= 1 ? 50 : 0;
        if (game != DICE || pick < 2 || pick > 99) return 0;
        uint256 w = over ? 100 - pick : uint256(pick) - 1;
        return (w >= 2 && w <= 95) ? w : 0;
    }

    function payoutOf(uint256 stake, uint8 game, uint8 pick, bool over) public pure returns (uint256) {
        uint256 w = winsOf(game, pick, over);
        return w == 0 ? 0 : stake * 98 / w;
    }

    /// @notice The largest stake the bankroll can cover for this bet right now.
    function maxStakeFor(uint8 game, uint8 pick, bool over) external view returns (uint256) {
        uint256 w = winsOf(game, pick, over);
        if (w == 0) return 0;
        // the house's net risk (payout - stake) may be at most 5% of the free bankroll
        uint256 risk = free() / 20;
        uint256 m = risk * w / (98 - w);   // stake*(98-w)/w <= risk
        return m < maxBet ? m : maxBet;
    }

    function houseOnline() public view returns (bool) {
        if (lastSeed == bytes32(0)) return false;
        if (head < queue.length && block.timestamp > (queue[head] + 1) * ROUND + OFFLINE) return false;
        return chainLeft > currentRound() - lastRound + 1;
    }

    function play(uint8 game, uint8 pick, bool over) external payable nonReentrant returns (uint256 id) {
        require(houseOnline(), "Games: house offline");
        uint256 stake = msg.value;
        require(stake >= minBet && stake <= maxBet, "Games: stake");
        uint256 payout = payoutOf(stake, game, pick, over);
        require(payout > 0, "Games: bet");
        uint256 freeBefore = address(this).balance - stake;
        freeBefore = freeBefore > reserved ? freeBefore - reserved : 0;
        require(payout - stake <= freeBefore / 20, "Games: bankroll");
        uint256 r = currentRound();
        require(r > lastRound, "Games: round");
        uint256[] storage rb = roundBets[r];
        require(rb.length < MAX_BETS, "Games: round full");
        if (rb.length == 0) queue.push(r);
        id = bets.length;
        bets.push(Bet(msg.sender, uint96(stake), uint32(r), game, pick, over, 0, Status.Pending, uint96(payout), uint40(block.timestamp)));
        rb.push(id);
        byPlayer[msg.sender].push(id);
        reserved += payout;
        totalBets++;
        totalStaked += stake;
        emit Placed(id, msg.sender, game, pick, over, stake, payout, r);
    }

    /// @notice The house reveals the seed of the next round in the queue and settles its bets.
    ///         Anyone may call it: the seed is checked against the chain.
    function reveal(bytes32 seed) external nonReentrant {
        require(head < queue.length, "Games: nothing to reveal");
        uint256 r = queue[head];
        require(block.timestamp >= (r + 1) * ROUND, "Games: round open");
        uint256 k = r - lastRound;
        require(k < chainLeft, "Games: chain used up");
        bytes32 h = seed;
        for (uint256 i; i < k; i++) h = keccak256(abi.encodePacked(h));
        require(h == lastSeed, "Games: bad seed");
        lastRound = r;
        lastSeed = seed;
        chainLeft -= k;
        roundSeed[r] = seed;
        head++;
        uint256[] storage rb = roundBets[r];
        for (uint256 i; i < rb.length; i++) _settle(rb[i], seed);
        emit Revealed(r, seed, rb.length);
    }

    /// @notice The house is more than an hour late with this bet's round: the bet is paid as a win.
    function claimTimeout(uint256 id) external nonReentrant {
        Bet storage b = bets[id];
        require(b.status == Status.Pending, "Games: not pending");
        require(roundSeed[b.round] == bytes32(0), "Games: revealed");
        require(block.timestamp > (uint256(b.round) + 1) * ROUND + TIMEOUT, "Games: not late");
        b.status = Status.TimeoutWon;
        reserved -= b.payout;
        _pay(b.player, b.payout);
        emit Settled(id, b.player, 0, true, b.payout);
    }

    function withdrawOwed() external nonReentrant {
        uint256 a = owed[msg.sender];
        require(a > 0, "Games: nothing owed");
        owed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "Games: send");
    }

    function _settle(uint256 id, bytes32 seed) internal {
        Bet storage b = bets[id];
        if (b.status != Status.Pending) return;   // already claimed after a timeout
        uint8 roll = uint8(uint256(keccak256(abi.encodePacked(seed, id))) % 100 + 1);
        bool won;
        if (b.game == COIN) won = (roll <= 50) == (b.pick == 0);
        else won = b.over ? roll > b.pick : roll < b.pick;
        b.roll = roll;
        b.status = won ? Status.Won : Status.Lost;
        reserved -= b.payout;
        if (won) _pay(b.player, b.payout);
        emit Settled(id, b.player, roll, won, won ? b.payout : 0);
    }

    function _pay(address to, uint256 amount) internal {
        totalPaid += amount;
        (bool ok,) = to.call{value: amount, gas: 30000}("");
        if (!ok) owed[to] += amount;
    }

    // ------------------------------------------------------------- views
    function count() external view returns (uint256) { return bets.length; }
    function get(uint256 id) external view returns (Bet memory) { return bets[id]; }
    function idsOf(address who) external view returns (uint256[] memory) { return byPlayer[who]; }
    function betsOfRound(uint256 r) external view returns (uint256[] memory) { return roundBets[r]; }
    function pendingRounds() external view returns (uint256[] memory out) {
        out = new uint256[](queue.length - head);
        for (uint256 i; i < out.length; i++) out[i] = queue[head + i];
    }

    /// @notice Newest first.
    function page(uint256 start, uint256 n) external view returns (uint256[] memory ids, Bet[] memory items) {
        uint256 len = bets.length;
        if (start >= len) return (new uint256[](0), new Bet[](0));
        if (n > len - start) n = len - start;
        ids = new uint256[](n);
        items = new Bet[](n);
        for (uint256 i; i < n; i++) { ids[i] = len - 1 - start - i; items[i] = bets[ids[i]]; }
    }

    /// @notice A player's bets, newest first.
    function pageOf(address who, uint256 start, uint256 n) external view returns (uint256[] memory ids, Bet[] memory items) {
        uint256[] storage all = byPlayer[who];
        uint256 len = all.length;
        if (start >= len) return (new uint256[](0), new Bet[](0));
        if (n > len - start) n = len - start;
        ids = new uint256[](n);
        items = new Bet[](n);
        for (uint256 i; i < n; i++) { ids[i] = all[len - 1 - start - i]; items[i] = bets[ids[i]]; }
    }

    function stats() external view returns (uint256 bankroll, uint256 freeNow, uint256 betsCount, uint256 staked, uint256 paid, bool online, uint256 roundNow) {
        return (address(this).balance, free(), totalBets, totalStaked, totalPaid, houseOnline(), currentRound());
    }
}
