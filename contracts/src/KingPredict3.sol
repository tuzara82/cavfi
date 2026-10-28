// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PrimaryProdDataServiceConsumerBase} from
    "@redstone-finance/evm-connector/contracts/data-services/PrimaryProdDataServiceConsumerBase.sol";

/// RedStone push feed on DogeOS (Chainlink-style interface), e.g. DOGE/USD with 8 decimals.
interface IRedStoneFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/// @title CavFi Predict v3: YES / NO markets on DOGE, decided by RedStone
/// @notice "Will DOGE be above $0.20 at 20:00 UTC on Friday?" People back YES or NO with KingS until the
///         market closes. Everyone who backed the right side shares the whole pot in proportion to their
///         stake (minus a 2% fee).
///         Each market has exactly one price source, fixed when it is created, so nobody can pick the source
///         that suits them:
///         - Markets with a fixed line (daily, weekly) are decided by RedStone's DOGE/USD push feed on DogeOS.
///           After the resolve time anyone can call resolve(): if the feed's last update is at or before the
///           resolve time, that value is RedStone's on-chain price at that moment and decides the market. If the
///           feed has updated since (it updates on a 0.5% move or every 24 hours), the price at that moment
///           can no longer be read and the market refunds after RESOLVE_GRACE.
///         - "Up or down" markets (hourly) use RedStone's signed price for the exact second (pull model): the
///           line at the start time and the result at the resolve time, checked on chain (3 of 5 signers).
///         Nobody, including CavFi, can choose the price. If nobody resolves a market within 1 day of its
///         resolve time, anyone can turn it into a full refund.
/// @dev Market ids continue from CavFi Predict v2 (`firstId`), so ids stay unique across all versions.
contract KingPredict3 is Ownable, ReentrancyGuard, PrimaryProdDataServiceConsumerBase {
    using SafeERC20 for IERC20;

    uint16 public constant FEE_BPS = 200;
    uint64 public constant RESOLVE_GRACE = 1 days;
    bytes32 public constant FEED = bytes32("DOGE");
    enum State { None, Open, Resolved, Refund }

    struct Market {
        string question;
        uint64 closeAt;    // no more stakes after this
        uint64 resolveAt;  // the moment whose RedStone price decides the market
        State state;
        bool yesWon;
        uint256 strike;    // USD price with 8 decimals: YES wins if price > strike
        uint256 price;     // RedStone DOGE/USD at resolveAt, 8 decimals
        uint256 yesPool;
        uint256 noPool;
    }

    uint64 public constant FEED_MAX_AGE = 25 hours;   // the feed updates at least every 24 hours

    IERC20 public immutable kings;
    IRedStoneFeed public immutable feed;
    uint256 public immutable firstId;
    address public oracle;   // may create markets; it has no say over prices
    address public feeTo;
    mapping(uint256 => Market) internal markets;
    uint256 internal nextId;
    mapping(uint256 => uint64) public startOf;   // "up or down" markets: the moment whose price is the line
    mapping(uint256 => bool) public byPull;      // true: RedStone signed data for the exact second; false: the push feed
    mapping(uint256 => mapping(address => uint256)) public yesOf;
    mapping(uint256 => mapping(address => uint256)) public noOf;
    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(address => uint256[]) internal byUser;

    event Created(uint256 indexed id, string question, uint256 strike, uint64 closeAt, uint64 resolveAt);
    event UpDown(uint256 indexed id, uint64 startAt, uint256 line);
    event Bet(uint256 indexed id, address indexed user, bool yes, uint256 amount);
    event Resolved(uint256 indexed id, uint256 price, bool yesWon, bool refund);
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);
    event OracleSet(address oracle);

    constructor(address owner_, IERC20 kings_, address oracle_, uint256 firstId_, IRedStoneFeed feed_) Ownable(owner_) {
        require(feed_.decimals() == 8, "Predict: feed decimals");
        feed = feed_;
        kings = kings_;
        oracle = oracle_;
        feeTo = owner_;
        firstId = firstId_;
        nextId = firstId_;
    }

    function setOracle(address o) external onlyOwner { oracle = o; emit OracleSet(o); }
    function setFeeTo(address f) external onlyOwner { feeTo = f; }

    modifier onlyOracle() {
        require(msg.sender == oracle || msg.sender == owner(), "Predict: not oracle");
        _;
    }

    /// @dev RedStone DOGE/USD signed at exactly `at` (seconds), from the payload appended to calldata.
    function _redstonePrice(uint64 at) internal view returns (uint256) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED;
        (uint256[] memory values, uint256 tsMs) = getOracleNumericValuesAndTimestampFromTxMsg(ids);
        require(tsMs == uint256(at) * 1000, "Predict: RedStone data is not from that moment");
        require(values[0] > 0, "Predict: price");
        return values[0];
    }

    /// @dev RedStone's on-chain DOGE/USD at `at`: the feed's value, if its last update is not after `at`.
    function _feedPrice(uint64 at) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        require(answer > 0, "Predict: feed price");
        require(updatedAt <= at, "Predict: feed updated after that moment");
        require(updatedAt + FEED_MAX_AGE >= at, "Predict: feed too old");
        return uint256(answer);
    }

    function _new(string calldata question, uint256 strike, uint64 closeAt, uint64 resolveAt) internal returns (uint256 id) {
        require(bytes(question).length > 0 && bytes(question).length <= 200, "Predict: question");
        require(strike > 0, "Predict: strike");
        require(closeAt > block.timestamp && resolveAt >= closeAt && resolveAt <= block.timestamp + 60 days, "Predict: times");
        id = nextId++;
        Market storage m = markets[id];
        m.question = question;
        m.strike = strike;
        m.closeAt = closeAt;
        m.resolveAt = resolveAt;
        m.state = State.Open;
        emit Created(id, question, strike, closeAt, resolveAt);
    }

    /// @notice A market with a fixed line, e.g. "above $0.20?".
    function create(string calldata question, uint256 strike, uint64 closeAt, uint64 resolveAt) external onlyOracle returns (uint256) {
        return _new(question, strike, closeAt, resolveAt);
    }

    /// @notice An "up or down" market: the line is RedStone's DOGE/USD at `startAt` (in the past).
    ///         Append RedStone's signed data for `startAt` to the calldata.
    function createUpDown(string calldata question, uint64 startAt, uint64 closeAt, uint64 resolveAt) external onlyOracle returns (uint256 id) {
        require(startAt <= block.timestamp && startAt % 10 == 0, "Predict: start");
        uint256 line = _redstonePrice(startAt);
        id = _new(question, line, closeAt, resolveAt);
        startOf[id] = startAt;
        byPull[id] = true;
        emit UpDown(id, startAt, line);
    }

    function bet(uint256 id, bool yes, uint256 amount) external nonReentrant {
        Market storage m = markets[id];
        require(m.state == State.Open && block.timestamp < m.closeAt, "Predict: closed");
        require(amount > 0, "Predict: amount");
        kings.safeTransferFrom(msg.sender, address(this), amount);
        if (yesOf[id][msg.sender] == 0 && noOf[id][msg.sender] == 0) byUser[msg.sender].push(id);
        if (yes) { yesOf[id][msg.sender] += amount; m.yesPool += amount; }
        else { noOf[id][msg.sender] += amount; m.noPool += amount; }
        emit Bet(id, msg.sender, yes, amount);
    }

    /// @notice Anyone can resolve once the resolve time has passed. Fixed-line markets read RedStone's push feed;
    ///         "up or down" markets need RedStone's signed DOGE data for exactly `resolveAt` appended to the
    ///         calldata (cavfi.com and the CavFi bot do this for you).
    function resolve(uint256 id) external nonReentrant {
        Market storage m = markets[id];
        require(m.state == State.Open, "Predict: not open");
        require(block.timestamp >= m.resolveAt, "Predict: too early");
        uint256 price = byPull[id] ? _redstonePrice(m.resolveAt) : _feedPrice(m.resolveAt);
        m.price = price;
        m.yesWon = price > m.strike;
        uint256 win = m.yesWon ? m.yesPool : m.noPool;
        uint256 lose = m.yesWon ? m.noPool : m.yesPool;
        if (win == 0 || lose == 0) {
            m.state = State.Refund; // nobody to pay, or nobody to pay from: everyone gets their stake back
        } else {
            m.state = State.Resolved;
            uint256 fee = (win + lose) * FEE_BPS / 10_000;
            if (fee > 0) kings.safeTransfer(feeTo, fee);
        }
        emit Resolved(id, price, m.yesWon, m.state == State.Refund);
    }

    /// @notice If nobody resolved the market within RESOLVE_GRACE, anyone can turn it into a full refund.
    function expire(uint256 id) external {
        Market storage m = markets[id];
        require(m.state == State.Open && block.timestamp > m.resolveAt + RESOLVE_GRACE, "Predict: not expired");
        m.state = State.Refund;
        emit Resolved(id, 0, false, true);
    }

    /// @notice Owner can withdraw a market (full refund) only before betting closes, e.g. a wrong question.
    function cancel(uint256 id) external onlyOwner {
        Market storage m = markets[id];
        require(m.state == State.Open && block.timestamp < m.closeAt, "Predict: not cancellable");
        m.state = State.Refund;
        emit Resolved(id, 0, false, true);
    }

    function claimable(uint256 id, address user) public view returns (uint256) {
        Market storage m = markets[id];
        if (claimed[id][user]) return 0;
        if (m.state == State.Refund) return yesOf[id][user] + noOf[id][user];
        if (m.state != State.Resolved) return 0;
        uint256 stake = m.yesWon ? yesOf[id][user] : noOf[id][user];
        if (stake == 0) return 0;
        uint256 win = m.yesWon ? m.yesPool : m.noPool;
        uint256 total = m.yesPool + m.noPool;
        uint256 net = total - total * FEE_BPS / 10_000;
        return stake * net / win;
    }

    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        amount = claimable(id, msg.sender);
        require(amount > 0, "Predict: nothing to claim");
        claimed[id][msg.sender] = true;
        kings.safeTransfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    // ------------------------------------------------------------- views
    /// @notice One past the newest id (ids run from firstId to count()-1), same meaning as in v1.
    function count() external view returns (uint256) { return nextId; }

    function get(uint256 id) external view returns (Market memory) {
        require(id >= firstId && id < nextId, "Predict: no market");
        return markets[id];
    }

    /// @notice Newest first, up to n items, skipping `start` newest.
    function page(uint256 start, uint256 n) external view returns (uint256[] memory ids, Market[] memory items) {
        uint256 len = nextId - firstId;
        if (start >= len) return (new uint256[](0), new Market[](0));
        if (n > len - start) n = len - start;
        ids = new uint256[](n);
        items = new Market[](n);
        for (uint256 i; i < n; i++) { ids[i] = nextId - 1 - start - i; items[i] = markets[ids[i]]; }
    }

    function idsOf(address user) external view returns (uint256[] memory) { return byUser[user]; }
}
