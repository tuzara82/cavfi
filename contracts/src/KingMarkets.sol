// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CavFi Markets: predictions on anything (football, crypto prices, DogeOS events)
/// @notice A market is a question with 2 to 6 outcomes ("Arsenal / Draw / Chelsea"). People back an outcome with
///         KingS until the market closes. Everyone who backed the right outcome shares the whole pot in proportion
///         to their stake (minus a 2% fee).
///         How a result is decided, in the open:
///         1. After the event the resolver (the CavFi bot) PROPOSES the result on chain, with the public source it
///            read it from (e.g. the final score page). It can also propose "void" (match cancelled...) = refund.
///         2. For DISPUTE_WINDOW (24 h) anyone who thinks the result is wrong can DISPUTE it by locking a bond.
///         3. No dispute: after the window anyone can FINALIZE and winners claim.
///            Disputed: the owner rules. If the ruling changes the result, the disputer gets the bond back; if
///            not, the bond goes to the fee wallet. If the owner does not rule within 7 days, everyone is refunded
///            and the disputer gets the bond back.
///         If nobody proposes a result within 3 days of the event, anyone can turn the market into a full refund.
contract KingMarkets is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant FEE_BPS = 200;
    uint64 public constant DISPUTE_WINDOW = 1 days;
    uint64 public constant PROPOSE_GRACE = 3 days;
    uint64 public constant RULING_GRACE = 7 days;
    uint8 public constant MAX_OUTCOMES = 6;
    uint8 public constant VOID = 255;            // the "refund everyone" result

    enum State { None, Open, Proposed, Disputed, Resolved, Refund }

    struct Market {
        string question;
        string category;     // "football", "crypto", "dogeos"...
        string rules;        // how it is decided and from which source
        string[] outcomes;
        uint64 closeAt;      // no more stakes after this
        uint64 resolveAt;    // the result can be proposed from this moment
        State state;
        uint8 proposed;      // proposed outcome (VOID = refund)
        uint8 winner;        // final outcome once Resolved
        uint64 proposedAt;
        string evidence;     // where the proposed result can be checked
        address disputer;
        uint256 total;
    }

    IERC20 public immutable kings;
    address public resolver;
    address public feeTo;
    uint256 public disputeBond = 1_000 ether;
    Market[] internal markets;
    mapping(uint256 => uint256[MAX_OUTCOMES]) internal pools;
    mapping(uint256 => mapping(address => uint256[MAX_OUTCOMES])) internal stakes;
    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(address => uint256[]) internal byUser;
    mapping(uint256 => uint256) public bondOf;   // the bond the disputer locked

    event Created(uint256 indexed id, string category, string question, string[] outcomes, uint64 closeAt, uint64 resolveAt);
    event Bet(uint256 indexed id, address indexed user, uint8 outcome, uint256 amount);
    event Proposed(uint256 indexed id, uint8 outcome, string evidence);
    event Disputed(uint256 indexed id, address indexed by);
    event Finalized(uint256 indexed id, uint8 outcome, bool refund);
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);
    event ResolverSet(address resolver);

    constructor(address owner_, IERC20 kings_, address resolver_) Ownable(owner_) {
        kings = kings_;
        resolver = resolver_;
        feeTo = owner_;
    }

    modifier onlyResolver() {
        require(msg.sender == resolver || msg.sender == owner(), "Markets: not resolver");
        _;
    }

    function setResolver(address r) external onlyOwner { resolver = r; emit ResolverSet(r); }
    function setFeeTo(address f) external onlyOwner { feeTo = f; }
    function setDisputeBond(uint256 b) external onlyOwner { disputeBond = b; }

    // ------------------------------------------------------------- markets
    function create(string calldata category, string calldata question, string[] calldata outcomes, string calldata rules,
        uint64 closeAt, uint64 resolveAt) external onlyResolver returns (uint256 id)
    {
        require(bytes(question).length > 0 && bytes(question).length <= 200, "Markets: question");
        require(bytes(category).length <= 24 && bytes(rules).length <= 400, "Markets: text");
        require(outcomes.length >= 2 && outcomes.length <= MAX_OUTCOMES, "Markets: outcomes");
        for (uint256 i; i < outcomes.length; i++) require(bytes(outcomes[i]).length > 0 && bytes(outcomes[i]).length <= 40, "Markets: outcome");
        require(closeAt > block.timestamp && resolveAt >= closeAt && resolveAt <= block.timestamp + 120 days, "Markets: times");
        id = markets.length;
        Market storage m = markets.push();
        m.question = question;
        m.category = category;
        m.rules = rules;
        m.outcomes = outcomes;
        m.closeAt = closeAt;
        m.resolveAt = resolveAt;
        m.state = State.Open;
        emit Created(id, category, question, outcomes, closeAt, resolveAt);
    }

    function bet(uint256 id, uint8 outcome, uint256 amount) external nonReentrant {
        Market storage m = markets[id];
        require(m.state == State.Open && block.timestamp < m.closeAt, "Markets: closed");
        require(outcome < m.outcomes.length, "Markets: outcome");
        require(amount > 0, "Markets: amount");
        kings.safeTransferFrom(msg.sender, address(this), amount);
        uint256[MAX_OUTCOMES] storage s = stakes[id][msg.sender];
        bool fresh = true;
        for (uint256 i; i < MAX_OUTCOMES; i++) if (s[i] > 0) { fresh = false; break; }
        if (fresh) byUser[msg.sender].push(id);
        s[outcome] += amount;
        pools[id][outcome] += amount;
        m.total += amount;
        emit Bet(id, msg.sender, outcome, amount);
    }

    // ------------------------------------------------------------- results
    /// @notice The resolver proposes the result (or VOID) after the event, with where to check it.
    function propose(uint256 id, uint8 outcome, string calldata evidence) external onlyResolver {
        Market storage m = markets[id];
        require(m.state == State.Open, "Markets: not open");
        require(block.timestamp >= m.resolveAt, "Markets: too early");
        require(outcome < m.outcomes.length || outcome == VOID, "Markets: outcome");
        require(bytes(evidence).length <= 300, "Markets: evidence");
        m.state = State.Proposed;
        m.proposed = outcome;
        m.proposedAt = uint64(block.timestamp);
        m.evidence = evidence;
        emit Proposed(id, outcome, evidence);
    }

    /// @notice Anyone can dispute a proposed result within DISPUTE_WINDOW by locking `disputeBond` KingS.
    function dispute(uint256 id) external nonReentrant {
        Market storage m = markets[id];
        require(m.state == State.Proposed && block.timestamp < m.proposedAt + DISPUTE_WINDOW, "Markets: no dispute now");
        uint256 b = disputeBond;
        if (b > 0) kings.safeTransferFrom(msg.sender, address(this), b);
        bondOf[id] = b;
        m.state = State.Disputed;
        m.disputer = msg.sender;
        emit Disputed(id, msg.sender);
    }

    /// @notice After the dispute window, anyone makes an undisputed result final.
    function finalize(uint256 id) external nonReentrant {
        Market storage m = markets[id];
        require(m.state == State.Proposed && block.timestamp >= m.proposedAt + DISPUTE_WINDOW, "Markets: not final yet");
        _settle(id, m.proposed);
    }

    /// @notice The owner rules on a disputed market (any outcome, or VOID).
    function rule(uint256 id, uint8 outcome) external onlyOwner nonReentrant {
        Market storage m = markets[id];
        require(m.state == State.Disputed, "Markets: not disputed");
        require(outcome < m.outcomes.length || outcome == VOID, "Markets: outcome");
        uint256 bond = bondOf[id];
        address who = m.disputer;
        _settle(id, outcome);
        if (bond > 0) kings.safeTransfer(outcome != m.proposed ? who : feeTo, bond);
    }

    /// @notice Refunds a market nobody decided in time: no proposal within PROPOSE_GRACE of the event, or a dispute
    ///         the owner left unruled for RULING_GRACE (the disputer gets the bond back).
    function expire(uint256 id) external nonReentrant {
        Market storage m = markets[id];
        if (m.state == State.Open) {
            require(block.timestamp > m.resolveAt + PROPOSE_GRACE, "Markets: not expired");
            _settle(id, VOID);
        } else {
            require(m.state == State.Disputed && block.timestamp > m.proposedAt + RULING_GRACE, "Markets: not expired");
            address who = m.disputer;
            _settle(id, VOID);
            if (bondOf[id] > 0) kings.safeTransfer(who, bondOf[id]);
        }
    }

    /// @notice The owner can withdraw a market (full refund) only before betting closes, e.g. a wrong question.
    function cancel(uint256 id) external onlyOwner {
        Market storage m = markets[id];
        require(m.state == State.Open && block.timestamp < m.closeAt, "Markets: not cancellable");
        _settle(id, VOID);
    }

    function _settle(uint256 id, uint8 outcome) internal {
        Market storage m = markets[id];
        uint256 win = outcome == VOID ? 0 : pools[id][outcome];
        if (outcome == VOID || win == 0 || win == m.total) {
            m.state = State.Refund;   // void, nobody to pay, or nobody to pay from: everyone gets their stake back
            m.winner = VOID;
        } else {
            m.state = State.Resolved;
            m.winner = outcome;
            uint256 fee = m.total * FEE_BPS / 10_000;
            if (fee > 0) kings.safeTransfer(feeTo, fee);
        }
        emit Finalized(id, outcome, m.state == State.Refund);
    }

    // ------------------------------------------------------------- claims
    function claimable(uint256 id, address user) public view returns (uint256) {
        Market storage m = markets[id];
        if (claimed[id][user]) return 0;
        uint256[MAX_OUTCOMES] storage s = stakes[id][user];
        if (m.state == State.Refund) { uint256 t; for (uint256 i; i < MAX_OUTCOMES; i++) t += s[i]; return t; }
        if (m.state != State.Resolved) return 0;
        uint256 stake = s[m.winner];
        if (stake == 0) return 0;
        uint256 net = m.total - m.total * FEE_BPS / 10_000;
        return stake * net / pools[id][m.winner];
    }

    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        amount = claimable(id, msg.sender);
        require(amount > 0, "Markets: nothing to claim");
        claimed[id][msg.sender] = true;
        kings.safeTransfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    // ------------------------------------------------------------- views
    function count() external view returns (uint256) { return markets.length; }

    function get(uint256 id) external view returns (Market memory m, uint256[] memory pool) {
        m = markets[id];
        pool = new uint256[](m.outcomes.length);
        for (uint256 i; i < pool.length; i++) pool[i] = pools[id][i];
    }

    function stakesOf(uint256 id, address user) external view returns (uint256[] memory s) {
        s = new uint256[](markets[id].outcomes.length);
        for (uint256 i; i < s.length; i++) s[i] = stakes[id][user][i];
    }

    /// @notice Newest first, up to n items, skipping `start` newest.
    function page(uint256 start, uint256 n) external view returns (uint256[] memory ids, Market[] memory items, uint256[][] memory pool) {
        uint256 len = markets.length;
        if (start >= len) return (new uint256[](0), new Market[](0), new uint256[][](0));
        if (n > len - start) n = len - start;
        ids = new uint256[](n);
        items = new Market[](n);
        pool = new uint256[][](n);
        for (uint256 i; i < n; i++) {
            uint256 id = len - 1 - start - i;
            ids[i] = id;
            items[i] = markets[id];
            pool[i] = new uint256[](items[i].outcomes.length);
            for (uint256 j; j < pool[i].length; j++) pool[i][j] = pools[id][j];
        }
    }

    function idsOf(address user) external view returns (uint256[] memory) { return byUser[user]; }
}
