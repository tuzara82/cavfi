// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CavFi Games v2: Coin Flip, Dice, Limbo, Royal Wheel, Plinko and Higher or Lower, with DOGE stakes
/// @notice Same fairness as v1: the house (the CavFi bot) commits a hash chain, anchor A = keccak^N(secret).
///         Time is cut into 30-second rounds; a bet joins the round open when it lands, and once that round has
///         closed the house reveals its seed, which must hash forward to the previous one, and every bet of the
///         round is settled with r = keccak256(seed, betId). Rounds are revealed strictly in order; if the house is
///         an hour late the bet is paid at its maximum; while it is 10 minutes behind, new bets are refused.
///         Every game returns about 98% of stakes on average (the Wheel 97.5%):
///         - COIN   pick 0 heads / 1 tails, 1.96x. roll = r % 100 + 1, 1-50 heads.
///         - DICE   roll = r % 100 + 1 under / over a target, pays 98 / winning numbers.
///         - LIMBO  pick a target multiplier T (x100, 1.01x-100x). result = 98e6 / (r % 1e6 + 1) (x100, capped at
///                  10,000x); you win T if result >= T, a chance of 98/T percent.
///         - WHEEL  20 segments: 9 x 0, 5 x 1.2, 3 x 1.5, 2 x 2, 1 x 5. result = r % 20.
///         - PLINKO 8 rows, the ball goes right on each set bit of the lowest 8 bits of r: bin = popcount. pick is the
///                  risk (0 low, 1 medium, 2 high), each with its own 9 multipliers.
///         - HILO   your card (1-13) is shown before you bet; the next card is r % 13 + 1. Higher or lower (a tie
///                  loses) pays 12.74 / winning cards. The drawn card becomes your next card.
contract KingGames2 is Ownable, ReentrancyGuard {
    uint256 public constant ROUND = 30;
    uint256 public constant OFFLINE = 10 minutes;
    uint256 public constant TIMEOUT = 1 hours;
    uint256 public constant MAX_BETS = 40;
    uint256 public constant VERSION = 2;
    uint8 public constant COIN = 0;
    uint8 public constant DICE = 1;
    uint8 public constant LIMBO = 2;
    uint8 public constant WHEEL = 3;
    uint8 public constant PLINKO = 4;
    uint8 public constant HILO = 5;

    enum Status { None, Pending, Won, Lost, TimeoutWon }

    struct Bet {
        address player;
        uint96 stake;
        uint32 round;
        uint8 game;
        uint16 pick;      // COIN side, DICE target, LIMBO target x100, PLINKO risk, HILO 1 = higher / 0 = lower
        bool over;        // DICE: roll above the target
        uint8 card;       // HILO: the card shown when betting
        uint32 result;    // COIN/DICE roll, LIMBO multiplier x100, WHEEL segment, PLINKO bin, HILO next card
        Status status;
        uint96 payout;    // reserved maximum while pending; the amount paid once settled
        uint40 placedAt;
    }

    address public house;
    uint256 public minBet = 0.1 ether;
    uint256 public maxBet = 50 ether;
    uint256 public riskBps = 1000;    // the house's worst-case loss on one bet: at most 10% of the free bankroll
    uint256 public reserved;
    uint256 public anchors;
    uint256 public lastRound;
    bytes32 public lastSeed;
    uint256 public chainLeft;

    Bet[] internal bets;
    mapping(uint256 => uint256[]) internal roundBets;
    mapping(uint256 => bytes32) public roundSeed;
    uint256[] internal queue;
    uint256 public head;
    mapping(address => uint256[]) internal byPlayer;
    mapping(address => uint256) public owed;
    mapping(address => uint8) internal hiloCard;

    uint256 public totalBets;
    uint256 public totalStaked;
    uint256 public totalPaid;

    event Placed(uint256 indexed id, address indexed player, uint8 game, uint16 pick, bool over, uint256 stake, uint256 maxPayout, uint256 round);
    event Settled(uint256 indexed id, address indexed player, uint8 game, uint32 result, uint256 paid);
    event Revealed(uint256 indexed round, bytes32 seed, uint256 bets);
    event Anchored(uint256 indexed n, bytes32 anchor, uint256 round, uint256 length);
    event HouseSet(address house);
    event LimitsSet(uint256 minBet, uint256 maxBet, uint256 riskBps);

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

    function setLimits(uint256 min_, uint256 max_, uint256 riskBps_) external onlyOwner {
        require(min_ > 0 && max_ >= min_ && max_ < type(uint96).max && riskBps_ > 0 && riskBps_ <= 2500, "Games: limits");
        minBet = min_; maxBet = max_; riskBps = riskBps_;
        emit LimitsSet(min_, max_, riskBps_);
    }

    function withdraw(uint256 amount, address payable to) external onlyOwner nonReentrant {
        require(amount <= free(), "Games: reserved");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "Games: send");
    }

    function setAnchor(bytes32 anchor, uint256 length) external onlyHouse {
        require(head == queue.length, "Games: rounds pending");
        require(anchor != bytes32(0) && length > 0, "Games: anchor");
        lastRound = currentRound();
        lastSeed = anchor;
        chainLeft = length;
        anchors++;
        emit Anchored(anchors, anchor, lastRound, length);
    }

    // ------------------------------------------------------------- tables
    function wheel(uint256 i) public pure returns (uint256) {
        // 20 segments, x100: 5 x 1.2, 3 x 1.5, 2 x 2, 1 x 5 and 9 blanks
        uint16[20] memory w = [uint16(120), 0, 150, 0, 120, 0, 200, 0, 120, 0, 500, 0, 120, 0, 150, 0, 200, 0, 120, 150];
        return w[i];
    }

    function plinko(uint256 risk, uint256 bin) public pure returns (uint256) {
        uint16[9] memory t;
        if (risk == 0) t = [uint16(560), 210, 110, 100, 46, 100, 110, 210, 560];
        else if (risk == 1) t = [uint16(1300), 300, 126, 70, 40, 70, 126, 300, 1300];
        else t = [uint16(2900), 400, 145, 30, 20, 30, 145, 400, 2900];
        return t[bin];
    }

    function cardOf(address player) public view returns (uint8) {
        uint8 c = hiloCard[player];
        return c == 0 ? uint8(uint256(keccak256(abi.encodePacked(player, address(this)))) % 13 + 1) : c;
    }

    /// @notice The most a bet can pay (0 = not a valid bet).
    function maxPayoutOf(uint256 stake, uint8 game, uint16 pick, bool over, address player) public view returns (uint256) {
        if (game == COIN) return pick <= 1 ? stake * 98 / 50 : 0;
        if (game == DICE) {
            if (pick < 2 || pick > 99) return 0;
            uint256 w = over ? 100 - pick : uint256(pick) - 1;
            return (w >= 2 && w <= 95) ? stake * 98 / w : 0;
        }
        if (game == LIMBO) return (pick >= 101 && pick <= 10000) ? stake * pick / 100 : 0;
        if (game == WHEEL) return stake * 5;
        if (game == PLINKO) return pick <= 2 ? stake * plinko(pick, 0) / 100 : 0;
        if (game == HILO) {
            uint256 c = cardOf(player);
            uint256 w = pick == 1 ? 13 - c : c - 1;
            return w == 0 ? 0 : stake * 1274 / (100 * w);
        }
        return 0;
    }

    // ------------------------------------------------------------- play
    function currentRound() public view returns (uint256) { return block.timestamp / ROUND; }

    function free() public view returns (uint256) {
        uint256 b = address(this).balance;
        return b > reserved ? b - reserved : 0;
    }

    function houseOnline() public view returns (bool) {
        if (lastSeed == bytes32(0)) return false;
        if (head < queue.length && block.timestamp > (queue[head] + 1) * ROUND + OFFLINE) return false;
        return chainLeft > currentRound() - lastRound + 1;
    }

    /// @notice The largest stake the bankroll covers for this bet right now.
    function maxStakeFor(uint8 game, uint16 pick, bool over, address player) external view returns (uint256) {
        uint256 m1 = maxPayoutOf(1 ether, game, pick, over, player);
        if (m1 <= 1 ether) return m1 == 0 ? 0 : maxBet;
        uint256 m = free() * riskBps / 10000 * 1 ether / (m1 - 1 ether);
        return m < maxBet ? m : maxBet;
    }

    function play(uint8 game, uint16 pick, bool over) external payable nonReentrant returns (uint256 id) {
        require(houseOnline(), "Games: house offline");
        uint256 stake = msg.value;
        require(stake >= minBet && stake <= maxBet, "Games: stake");
        uint256 maxPay = maxPayoutOf(stake, game, pick, over, msg.sender);
        require(maxPay > 0, "Games: bet");
        uint256 freeBefore = address(this).balance - stake;
        freeBefore = freeBefore > reserved ? freeBefore - reserved : 0;
        require(maxPay <= stake || maxPay - stake <= freeBefore * riskBps / 10000, "Games: bankroll");
        uint256 r = currentRound();
        require(r > lastRound, "Games: round");
        uint256[] storage rb = roundBets[r];
        require(rb.length < MAX_BETS, "Games: round full");
        if (rb.length == 0) queue.push(r);
        id = bets.length;
        bets.push(Bet(msg.sender, uint96(stake), uint32(r), game, pick, over, game == HILO ? cardOf(msg.sender) : 0, 0, Status.Pending, uint96(maxPay), uint40(block.timestamp)));
        rb.push(id);
        byPlayer[msg.sender].push(id);
        reserved += maxPay;
        totalBets++;
        totalStaked += stake;
        emit Placed(id, msg.sender, game, pick, over, stake, maxPay, r);
    }

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

    function claimTimeout(uint256 id) external nonReentrant {
        Bet storage b = bets[id];
        require(b.status == Status.Pending, "Games: not pending");
        require(roundSeed[b.round] == bytes32(0), "Games: revealed");
        require(block.timestamp > (uint256(b.round) + 1) * ROUND + TIMEOUT, "Games: not late");
        b.status = Status.TimeoutWon;
        reserved -= b.payout;
        _pay(b.player, b.payout);
        emit Settled(id, b.player, b.game, 0, b.payout);
    }

    function withdrawOwed() external nonReentrant {
        uint256 a = owed[msg.sender];
        require(a > 0, "Games: nothing owed");
        owed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "Games: send");
    }

    /// @notice What a bet pays for a given random number (also used by the page to show past results).
    function outcome(Bet memory b, uint256 rnd) public pure returns (uint32 result, uint256 paid) {
        uint256 s = b.stake;
        if (b.game == COIN || b.game == DICE) {
            uint256 roll = rnd % 100 + 1;
            result = uint32(roll);
            bool won = b.game == COIN ? ((roll <= 50) == (b.pick == 0)) : (b.over ? roll > b.pick : roll < b.pick);
            paid = won ? b.payout : 0;
        } else if (b.game == LIMBO) {
            uint256 m = 98e6 / (rnd % 1e6 + 1);
            if (m > 1e6) m = 1e6;
            result = uint32(m);
            paid = m >= b.pick ? s * b.pick / 100 : 0;
        } else if (b.game == WHEEL) {
            uint256 seg = rnd % 20;
            result = uint32(seg);
            paid = s * wheel(seg) / 100;
        } else if (b.game == PLINKO) {
            uint256 x = rnd & 0xff;
            uint256 bin;
            for (; x != 0; x >>= 1) bin += x & 1;
            result = uint32(bin);
            paid = s * plinko(b.pick, bin) / 100;
        } else {
            uint256 next = rnd % 13 + 1;
            result = uint32(next);
            bool won = b.pick == 1 ? next > b.card : next < b.card;
            paid = won ? b.payout : 0;
        }
    }

    function _settle(uint256 id, bytes32 seed) internal {
        Bet storage b = bets[id];
        if (b.status != Status.Pending) return;
        (uint32 result, uint256 paid) = outcome(b, uint256(keccak256(abi.encodePacked(seed, id))));
        if (b.game == HILO) hiloCard[b.player] = uint8(result);
        reserved -= b.payout;
        b.result = result;
        b.status = paid > 0 ? Status.Won : Status.Lost;
        b.payout = uint96(paid);
        if (paid > 0) _pay(b.player, paid);
        emit Settled(id, b.player, b.game, result, paid);
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

    function page(uint256 start, uint256 n) external view returns (uint256[] memory ids, Bet[] memory items) {
        uint256 len = bets.length;
        if (start >= len) return (new uint256[](0), new Bet[](0));
        if (n > len - start) n = len - start;
        ids = new uint256[](n);
        items = new Bet[](n);
        for (uint256 i; i < n; i++) { ids[i] = len - 1 - start - i; items[i] = bets[ids[i]]; }
    }

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
