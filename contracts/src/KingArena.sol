// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IArenaPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IArenaFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

/// @title CavFi Arena: hourly "which token rises most against DOGE" prediction game
/// @notice Users stake KingS on one of up to 8 tokens. When the round ends, the token whose DOGE price
///         rose the most wins, and its backers share the pot pro rata (minus the round's fee).
///         If several tokens tie for the best gain, backers of all of them share the pot. If nobody
///         backed a winner (or no token had enough price samples), the whole pot rolls into the next round.
///
///         Price measurement (sampled TWAP). CavFi pairs have no cumulative price accumulators, so the
///         contract samples spot prices itself. poke() (also run by stake() and settle(), and by the
///         CavFi bot every minute) records each pair's price at most once per block. A round's start
///         price is the average of the samples taken in its first WINDOW, and its end price the average
///         of those taken in its last WINDOW. A token needs MIN_SAMPLES in both windows to win.
///
///         Same-block manipulation guard: if a pair's reserves were already changed in the current block
///         (blockTimestampLast == block.timestamp), its spot price could come from a swap made in this
///         very transaction or block, so it is ignored. The sample then uses the pair's last clean price
///         (seen in an earlier block, at most WINDOW old), or no sample at all. To move a sample, a
///         manipulator has to hold a skewed price across a block boundary, where it can be arbitraged.
///         Each sample also counts for only one of at least MIN_SAMPLES in a window.
///
///         Custody: the owner can't touch staked KingS, pots or the tip reserve. The only rescue path
///         is for other tokens sent by mistake. Round length, token list and fee are snapshotted when a
///         round opens, so owner changes always apply from the next round.
contract KingArena is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants

    uint256 public constant MAX_TOKENS = 8;
    uint256 public constant WINDOW = 10 minutes;
    uint256 public constant MIN_SAMPLES = 3;
    uint16 public constant MAX_FEE_BPS = 500;
    uint64 public constant MIN_DURATION = 30 minutes;
    uint64 public constant MAX_DURATION = 1 days;
    uint256 private constant PRICE_ONE = 1e18;
    uint256 private constant BPS = 10_000;

    IERC20 public immutable kings;
    address public immutable wdoge;
    IArenaFactory public immutable factory;

    // ------------------------------------------------------------------ types

    struct Slot {
        address token;
        address pair;
        bool wdogeIs0;
    }

    struct Round {
        uint64 start;
        uint64 end;
        uint16 feeBps;
        uint8 winnerMask; // bit i set = token i won (several bits on a tie)
        bool settled;
        uint256 staked; // KingS staked in this round
        uint256 rollover; // KingS rolled in from earlier rounds
        uint256 winnerStake; // total stake on the winning token(s); 0 = pot rolled over
        uint256 payout; // pot minus fee, shared by winnerStake
    }

    struct Obs {
        uint256 startSum;
        uint256 endSum;
        uint32 startCnt;
        uint32 endCnt;
    }

    struct Clean {
        uint192 price;
        uint64 at;
    }

    // ------------------------------------------------------------------ config

    address public feeTo;
    uint16 public nextFeeBps = 200;
    uint64 public nextDuration = 1 hours;
    uint256 public minStake = 1_000 ether;
    uint256 public settleTip = 10 ether;
    uint256 public tipReserve;

    // ------------------------------------------------------------------ state

    uint256 public currentId;
    uint256 public lastSettled;
    uint256 public lastPokeBlock;

    Slot[] private _next;
    mapping(uint256 => Slot[]) private _slots;
    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => mapping(uint256 => Obs)) private _obs;

    /// round => token index => total staked on it
    mapping(uint256 => mapping(uint256 => uint256)) public tokenPot;
    /// round => user => token index => amount
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public stakeOf;
    /// round => user => total staked by the user in the round
    mapping(uint256 => mapping(address => uint256)) public userStaked;
    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(address => uint256[]) private _userRounds;
    /// pair => last price observed in a block where the pair had not been touched yet
    mapping(address => Clean) public lastClean;

    // ------------------------------------------------------------------ events

    event RoundOpened(uint256 indexed id, uint64 start, uint64 end, uint16 feeBps, address[] tokens);
    event Staked(uint256 indexed id, address indexed user, uint256 indexed idx, uint256 amount);
    event Settled(
        uint256 indexed id, uint8 winnerMask, uint256 pot, uint256 fee, bool rolledOver, address settler, uint256 tip
    );
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);
    event TipsFunded(address indexed from, uint256 amount);
    event NextTokensSet(address[] tokens);
    event NextDurationSet(uint64 duration);
    event NextFeeSet(uint16 feeBps);
    event FeeToSet(address feeTo);
    event MinStakeSet(uint256 amount);
    event SettleTipSet(uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    constructor(address owner_, address kings_, address wdoge_, address factory_, address feeTo_) Ownable(owner_) {
        require(
            kings_ != address(0) && wdoge_ != address(0) && factory_ != address(0) && feeTo_ != address(0),
            "KingArena: ZERO_ADDRESS"
        );
        kings = IERC20(kings_);
        wdoge = wdoge_;
        factory = IArenaFactory(factory_);
        feeTo = feeTo_;
    }

    // ================================================================== owner

    /// @notice Sets the eligible tokens (2..8) for the next round. Each needs a CavFi pair with WDOGE.
    function setTokens(address[] calldata list) external onlyOwner {
        uint256 n = list.length;
        require(n >= 2 && n <= MAX_TOKENS, "KingArena: TOKEN_COUNT");
        delete _next;
        for (uint256 i; i < n; ++i) {
            address t = list[i];
            require(t != address(0) && t != wdoge, "KingArena: BAD_TOKEN");
            for (uint256 j; j < i; ++j) require(list[j] != t, "KingArena: DUPLICATE");
            address pair = factory.getPair(t, wdoge);
            require(pair != address(0), "KingArena: NO_PAIR");
            _next.push(Slot({token: t, pair: pair, wdogeIs0: IArenaPair(pair).token0() == wdoge}));
        }
        emit NextTokensSet(list);
    }

    /// @notice Round length for rounds opened from now on.
    function setRoundDuration(uint64 duration) external onlyOwner {
        require(duration >= MIN_DURATION && duration <= MAX_DURATION, "KingArena: BAD_DURATION");
        nextDuration = duration;
        emit NextDurationSet(duration);
    }

    /// @notice Fee for rounds opened from now on, capped at 5%.
    function setFeeBps(uint16 feeBps) external onlyOwner {
        require(feeBps <= MAX_FEE_BPS, "KingArena: FEE_TOO_HIGH");
        nextFeeBps = feeBps;
        emit NextFeeSet(feeBps);
    }

    function setFeeTo(address to) external onlyOwner {
        require(to != address(0), "KingArena: ZERO_ADDRESS");
        feeTo = to;
        emit FeeToSet(to);
    }

    function setMinStake(uint256 amount) external onlyOwner {
        require(amount > 0, "KingArena: ZERO_AMOUNT");
        minStake = amount;
        emit MinStakeSet(amount);
    }

    function setSettleTip(uint256 amount) external onlyOwner {
        settleTip = amount;
        emit SettleTipSet(amount);
    }

    /// @notice Recovers tokens sent here by mistake. KingS can never be withdrawn.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(kings), "KingArena: KINGS_LOCKED");
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ================================================================== public actions

    /// @notice Adds KingS to the settle-tip reserve. Anyone can fund it; nobody can take it back out.
    function fundTips(uint256 amount) external nonReentrant {
        require(amount > 0, "KingArena: ZERO_AMOUNT");
        kings.safeTransferFrom(msg.sender, address(this), amount);
        tipReserve += amount;
        emit TipsFunded(msg.sender, amount);
    }

    /// @notice Opens the next round if due, then samples every eligible pair (once per block).
    function poke() external {
        _poke();
    }

    /// @notice Stakes `amount` KingS on token `idx` of the current round. Closes WINDOW before the end.
    function stake(uint256 idx, uint256 amount) external nonReentrant {
        _poke();
        uint256 id = currentId;
        require(id != 0, "KingArena: NOT_STARTED");
        Round storage R = _rounds[id];
        require(block.timestamp + WINDOW < R.end, "KingArena: STAKING_CLOSED");
        require(idx < _slots[id].length, "KingArena: BAD_TOKEN");
        require(amount >= minStake, "KingArena: MIN_STAKE");

        kings.safeTransferFrom(msg.sender, address(this), amount);

        if (userStaked[id][msg.sender] == 0) _userRounds[msg.sender].push(id);
        userStaked[id][msg.sender] += amount;
        stakeOf[id][msg.sender][idx] += amount;
        tokenPot[id][idx] += amount;
        R.staked += amount;
        emit Staked(id, msg.sender, idx, amount);
    }

    /// @notice Settles the oldest unsettled round once it has ended, and pays the caller the tip
    ///         (or whatever is left in the reserve, possibly nothing).
    function settle() external nonReentrant returns (uint256 id) {
        _poke();
        id = lastSettled + 1;
        Round storage R = _rounds[id];
        require(R.end != 0 && block.timestamp >= R.end, "KingArena: TOO_EARLY");
        require(currentId > id, "KingArena: NO_NEXT_ROUND");

        uint8 mask = _winners(id);
        uint256 winStake;
        uint256 n = _slots[id].length;
        for (uint256 i; i < n; ++i) {
            if (_isWinner(mask, i)) winStake += tokenPot[id][i];
        }

        uint256 pot = R.staked + R.rollover;
        R.settled = true;
        R.winnerMask = mask;
        lastSettled = id;

        uint256 fee;
        bool rolled = winStake == 0;
        if (rolled) {
            if (pot != 0) _rounds[id + 1].rollover += pot;
        } else {
            fee = pot * R.feeBps / BPS;
            R.winnerStake = winStake;
            R.payout = pot - fee;
            if (fee != 0) kings.safeTransfer(feeTo, fee);
        }

        uint256 tip = settleTip < tipReserve ? settleTip : tipReserve;
        if (tip != 0) {
            tipReserve -= tip;
            kings.safeTransfer(msg.sender, tip);
        }
        emit Settled(id, mask, pot, fee, rolled, msg.sender, tip);
    }

    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        require(_rounds[id].settled, "KingArena: NOT_SETTLED");
        require(!claimed[id][msg.sender], "KingArena: ALREADY_CLAIMED");
        amount = claimable(id, msg.sender);
        require(amount != 0, "KingArena: NOTHING_TO_CLAIM");
        claimed[id][msg.sender] = true;
        kings.safeTransfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    /// @notice Claims several rounds at once. Rounds with nothing to claim are skipped.
    function claimMany(uint256[] calldata ids) external nonReentrant returns (uint256 total) {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint256 amount = claimable(id, msg.sender);
            if (amount == 0) continue;
            claimed[id][msg.sender] = true;
            total += amount;
            emit Claimed(id, msg.sender, amount);
        }
        require(total != 0, "KingArena: NOTHING_TO_CLAIM");
        kings.safeTransfer(msg.sender, total);
    }

    // ================================================================== views

    function getRound(uint256 id) external view returns (Round memory) {
        return _rounds[id];
    }

    /// @notice The latest opened round. `live` is false once it has ended; the next round opens on
    ///         the next poke/stake/settle.
    function currentRound()
        external
        view
        returns (
            uint256 id,
            uint64 start,
            uint64 end,
            uint64 stakingEndsAt,
            uint256 secondsLeft,
            uint256 pot,
            uint16 feeBps,
            bool live
        )
    {
        id = currentId;
        if (id == 0) return (0, 0, 0, 0, 0, 0, nextFeeBps, false);
        Round storage R = _rounds[id];
        start = R.start;
        end = R.end;
        stakingEndsAt = end - uint64(WINDOW);
        secondsLeft = block.timestamp < end ? end - block.timestamp : 0;
        pot = R.staked + R.rollover;
        feeBps = R.feeBps;
        live = block.timestamp < end;
    }

    function timeLeft() external view returns (uint256) {
        uint256 id = currentId;
        if (id == 0) return 0;
        uint256 end = _rounds[id].end;
        return block.timestamp < end ? end - block.timestamp : 0;
    }

    /// @notice Whether the oldest unsettled round can be settled now, and its id.
    function settleable() external view returns (bool ready, uint256 id) {
        id = lastSettled + 1;
        uint256 end = _rounds[id].end;
        ready = end != 0 && block.timestamp >= end;
    }

    function roundTokens(uint256 id) external view returns (address[] memory tokens, address[] memory pairs) {
        return _list(_slots[id]);
    }

    /// @notice Tokens that the next round will use.
    function nextTokens() external view returns (address[] memory tokens, address[] memory pairs) {
        return _list(_next);
    }

    /// @notice Per-token pots and price samples of a round (averages in DOGE per token, 1e18-scaled).
    function board(uint256 id)
        external
        view
        returns (
            uint256[] memory pots,
            uint256[] memory startAvg,
            uint256[] memory endAvg,
            uint32[] memory startCnt,
            uint32[] memory endCnt
        )
    {
        uint256 n = _slots[id].length;
        pots = new uint256[](n);
        startAvg = new uint256[](n);
        endAvg = new uint256[](n);
        startCnt = new uint32[](n);
        endCnt = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            Obs storage o = _obs[id][i];
            pots[i] = tokenPot[id][i];
            startCnt[i] = o.startCnt;
            endCnt[i] = o.endCnt;
            if (o.startCnt != 0) startAvg[i] = o.startSum / o.startCnt;
            if (o.endCnt != 0) endAvg[i] = o.endSum / o.endCnt;
        }
    }

    /// @notice Current spot prices (DOGE per token, 1e18-scaled) of a round's tokens. Display only.
    function spotPrices(uint256 id) external view returns (uint256[] memory prices) {
        Slot[] storage S = _slots[id];
        uint256 n = S.length;
        prices = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (uint256 p,) = _spot(S[i]);
            prices[i] = p;
        }
    }

    function myStakes(uint256 id, address user) public view returns (uint256[] memory stakes) {
        uint256 n = _slots[id].length;
        stakes = new uint256[](n);
        for (uint256 i; i < n; ++i) stakes[i] = stakeOf[id][user][i];
    }

    function claimable(uint256 id, address user) public view returns (uint256) {
        Round storage R = _rounds[id];
        if (!R.settled || R.winnerStake == 0 || claimed[id][user]) return 0;
        uint8 mask = R.winnerMask;
        uint256 n = _slots[id].length;
        uint256 w;
        for (uint256 i; i < n; ++i) {
            if (_isWinner(mask, i)) w += stakeOf[id][user][i];
        }
        return w == 0 ? 0 : Math.mulDiv(w, R.payout, R.winnerStake);
    }

    /// @notice Everything the frontend needs about one of a user's bets, in one call.
    function betInfo(uint256 id, address user)
        external
        view
        returns (Round memory round, uint256[] memory stakes, uint256 claimableAmount, bool hasClaimed)
    {
        round = _rounds[id];
        stakes = myStakes(id, user);
        claimableAmount = claimable(id, user);
        hasClaimed = claimed[id][user];
    }

    function userRoundCount(address user) external view returns (uint256) {
        return _userRounds[user].length;
    }

    function userRounds(address user, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage list = _userRounds[user];
        (uint256 from, uint256 to) = _page(list.length, offset, limit);
        ids = new uint256[](to - from);
        for (uint256 i = from; i < to; ++i) ids[i - from] = list[i];
    }

    /// @notice A user's rounds (from the paged slice) that have KingS waiting to be claimed.
    function claimableRounds(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256[] memory amounts)
    {
        uint256[] storage list = _userRounds[user];
        (uint256 from, uint256 to) = _page(list.length, offset, limit);
        uint256 count;
        for (uint256 i = from; i < to; ++i) {
            if (claimable(list[i], user) != 0) ++count;
        }
        ids = new uint256[](count);
        amounts = new uint256[](count);
        uint256 k;
        for (uint256 i = from; i < to; ++i) {
            uint256 a = claimable(list[i], user);
            if (a != 0) {
                ids[k] = list[i];
                amounts[k] = a;
                ++k;
            }
        }
    }

    // ================================================================== internals

    function _poke() private {
        _advance();
        _sample();
    }

    /// @dev Opens the next round once the current one has ended. Rounds sit on a grid that starts at
    ///      the previous round's end, so idle hours are skipped rather than opened as dead rounds.
    function _advance() private {
        uint256 id = currentId;
        if (id == 0) {
            if (_next.length >= 2) _open(1, uint64(block.timestamp));
            return;
        }
        uint64 end = _rounds[id].end;
        if (block.timestamp < end) return;
        uint64 dur = nextDuration;
        uint64 start = end + ((uint64(block.timestamp) - end) / dur) * dur;
        _open(id + 1, start);
    }

    function _open(uint256 id, uint64 start) private {
        Round storage R = _rounds[id];
        R.start = start;
        R.end = start + nextDuration;
        R.feeBps = nextFeeBps;
        Slot[] storage S = _slots[id];
        uint256 n = _next.length;
        address[] memory list = new address[](n);
        for (uint256 i; i < n; ++i) {
            Slot memory s = _next[i];
            S.push(s);
            list[i] = s.token;
        }
        currentId = id;
        emit RoundOpened(id, start, R.end, R.feeBps, list);
    }

    function _sample() private {
        if (lastPokeBlock == block.number) return;
        uint256 id = currentId;
        if (id == 0) return;
        lastPokeBlock = block.number;

        Round storage R = _rounds[id];
        bool inStart = block.timestamp < uint256(R.start) + WINDOW;
        bool inEnd = block.timestamp + WINDOW >= R.end;
        Slot[] storage S = _slots[id];
        uint256 n = S.length;
        for (uint256 i; i < n; ++i) {
            uint256 p = _observe(S[i]);
            if (p == 0) continue;
            if (inStart) {
                Obs storage o = _obs[id][i];
                o.startSum += p;
                ++o.startCnt;
            } else if (inEnd) {
                Obs storage o = _obs[id][i];
                o.endSum += p;
                ++o.endCnt;
            }
        }
    }

    /// @dev Price to record for a pair in this block. Untouched pair: its spot price (also cached).
    ///      Pair already changed in this block: the cached clean price if it is at most WINDOW old.
    function _observe(Slot storage s) private returns (uint256) {
        (uint256 p, bool fresh) = _spot(s);
        if (fresh) {
            if (p != 0) lastClean[s.pair] = Clean(uint192(p), uint64(block.timestamp));
            return p;
        }
        Clean memory c = lastClean[s.pair];
        if (c.price != 0 && uint256(c.at) + WINDOW >= block.timestamp) return c.price;
        return 0;
    }

    /// @return p    DOGE per token, 1e18-scaled (0 if a reserve is empty)
    /// @return fresh true if the pair hasn't been touched in the current block
    function _spot(Slot storage s) private view returns (uint256 p, bool fresh) {
        (uint112 r0, uint112 r1, uint32 last) = IArenaPair(s.pair).getReserves();
        (uint256 rW, uint256 rT) = s.wdogeIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (rT != 0) p = rW * PRICE_ONE / rT;
        fresh = last != uint32(block.timestamp);
    }

    /// @dev Bitmask of the token(s) with the highest end/start ratio among tokens with enough samples.
    function _winners(uint256 id) private view returns (uint8 mask) {
        uint256 n = _slots[id].length;
        uint256 best;
        for (uint256 i; i < n; ++i) {
            Obs storage o = _obs[id][i];
            if (o.startCnt < MIN_SAMPLES || o.endCnt < MIN_SAMPLES) continue;
            uint256 ratio = Math.mulDiv(o.endSum / o.endCnt, PRICE_ONE, o.startSum / o.startCnt);
            uint8 bit = uint8(uint256(1) << i);
            if (mask == 0 || ratio > best) {
                best = ratio;
                mask = bit;
            } else if (ratio == best) {
                mask |= bit;
            }
        }
    }

    function _isWinner(uint8 mask, uint256 i) private pure returns (bool) {
        return (uint256(mask) >> i) & 1 == 1;
    }

    function _list(Slot[] storage S) private view returns (address[] memory tokens, address[] memory pairs) {
        uint256 n = S.length;
        tokens = new address[](n);
        pairs = new address[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = S[i].token;
            pairs[i] = S[i].pair;
        }
    }

    function _page(uint256 len, uint256 offset, uint256 limit) private pure returns (uint256 from, uint256 to) {
        if (offset >= len) return (len, len);
        from = offset;
        to = len - offset < limit ? len : offset + limit;
    }
}
