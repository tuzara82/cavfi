// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CavFi Predict: YES / NO markets on the real DOGE price
/// @notice "Will DOGE be above $0.20 at 20:00 UTC on Friday?" People back YES or NO with KingS until the
///         market closes. Everyone who backed the right side shares the whole pot in proportion to their
///         stake (minus a 2% fee). The pool sizes show the crowd's odds.
/// @dev The oracle (the CavFi bot) creates markets and reports the DOGE/USD price at resolve time, read from
///      a public exchange. That is a trusted role and the site says so. If one side has no stakes, or the
///      oracle does not resolve within 7 days of the resolve time, everyone gets their stake back.
contract KingPredict is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant FEE_BPS = 200;
    uint64 public constant RESOLVE_GRACE = 7 days;
    enum State { None, Open, Resolved, Refund }

    struct Market {
        string question;
        uint64 closeAt;    // no more stakes after this
        uint64 resolveAt;  // the moment whose price decides the market
        State state;
        bool yesWon;
        uint256 strike;    // USD price with 8 decimals: YES wins if price > strike
        uint256 price;     // reported price, 8 decimals
        uint256 yesPool;
        uint256 noPool;
    }

    IERC20 public immutable kings;
    address public oracle;
    address public feeTo;
    Market[] internal markets;
    mapping(uint256 => mapping(address => uint256)) public yesOf;
    mapping(uint256 => mapping(address => uint256)) public noOf;
    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(address => uint256[]) internal byUser;

    event Created(uint256 indexed id, string question, uint256 strike, uint64 closeAt, uint64 resolveAt);
    event Bet(uint256 indexed id, address indexed user, bool yes, uint256 amount);
    event Resolved(uint256 indexed id, uint256 price, bool yesWon, bool refund);
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);
    event OracleSet(address oracle);

    constructor(address owner_, IERC20 kings_, address oracle_) Ownable(owner_) {
        kings = kings_;
        oracle = oracle_;
        feeTo = owner_;
    }

    function setOracle(address o) external onlyOwner { oracle = o; emit OracleSet(o); }
    function setFeeTo(address f) external onlyOwner { feeTo = f; }

    modifier onlyOracle() {
        require(msg.sender == oracle || msg.sender == owner(), "Predict: not oracle");
        _;
    }

    function create(string calldata question, uint256 strike, uint64 closeAt, uint64 resolveAt) external onlyOracle returns (uint256 id) {
        require(bytes(question).length > 0 && bytes(question).length <= 200, "Predict: question");
        require(strike > 0, "Predict: strike");
        require(closeAt > block.timestamp && resolveAt >= closeAt && resolveAt <= block.timestamp + 60 days, "Predict: times");
        id = markets.length;
        Market storage m = markets.push();
        m.question = question;
        m.strike = strike;
        m.closeAt = closeAt;
        m.resolveAt = resolveAt;
        m.state = State.Open;
        emit Created(id, question, strike, closeAt, resolveAt);
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

    /// @param price DOGE/USD at resolveAt, 8 decimals, from a public exchange.
    function resolve(uint256 id, uint256 price) external onlyOracle nonReentrant {
        Market storage m = markets[id];
        require(m.state == State.Open, "Predict: not open");
        require(block.timestamp >= m.resolveAt, "Predict: too early");
        require(price > 0, "Predict: price");
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

    /// @notice If the oracle never resolves, anyone can turn the market into a full refund.
    function expire(uint256 id) external {
        Market storage m = markets[id];
        require(m.state == State.Open && block.timestamp > m.resolveAt + RESOLVE_GRACE, "Predict: not expired");
        m.state = State.Refund;
        emit Resolved(id, 0, false, true);
    }

    function cancel(uint256 id) external onlyOwner {
        Market storage m = markets[id];
        require(m.state == State.Open, "Predict: not open");
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
    function count() external view returns (uint256) { return markets.length; }

    function get(uint256 id) external view returns (Market memory) { return markets[id]; }

    /// @notice Newest first: markets[count-1-start] ... up to n items.
    function page(uint256 start, uint256 n) external view returns (uint256[] memory ids, Market[] memory items) {
        uint256 len = markets.length;
        if (start >= len) return (new uint256[](0), new Market[](0));
        if (n > len - start) n = len - start;
        ids = new uint256[](n);
        items = new Market[](n);
        for (uint256 i; i < n; i++) { ids[i] = len - 1 - start - i; items[i] = markets[ids[i]]; }
    }

    function idsOf(address user) external view returns (uint256[] memory) { return byUser[user]; }
}
