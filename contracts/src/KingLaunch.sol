// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MemeToken} from "./MemeToken.sol";

interface ILaunchFactory {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

interface ILaunchPair {
    function mint(address to) external returns (uint256);
}

interface IWDOGE {
    function deposit() external payable;
    function transfer(address, uint256) external returns (bool);
}

/// @title CavFi launchpad (bonding curve)
/// @notice Anyone can launch a meme token. 800M of the 1B supply is sold on a constant-product
///         bonding curve with virtual reserves (start: target/3 DOGE vs 1,066.67M tokens).
///         When all 800M are sold the curve has raised exactly `target` DOGE. The launchpad
///         then puts that DOGE and the remaining 200M tokens into a CavFi TOKEN/WDOGE pool at
///         the same price the curve ended on, and burns the LP tokens, so that liquidity is
///         locked forever. Trades on the curve pay a 1% fee to `feeTo`.
contract KingLaunch is Ownable, ReentrancyGuard {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE = 800_000_000 ether;
    uint256 public constant LP_TOKENS = SUPPLY - CURVE;
    uint256 public constant FEE_BPS = 100; // 1%
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Launch {
        address creator;
        uint64 createdAt;
        bool graduated;
        uint256 vDoge;      // virtual + real DOGE reserve
        uint256 vTok;       // virtual token reserve
        uint256 realDoge;   // DOGE actually held for this token
        uint256 tokensLeft; // tokens still for sale on the curve
        uint256 target;     // DOGE raised when the curve sells out
        address pair;
        string name;
        string symbol;
        string description;
        string image;
    }

    ILaunchFactory public immutable factory;
    address public immutable wdoge;
    bytes32 public immutable pairInitCodeHash; // 0 = create the pool up front instead of predicting it

    address public feeTo;
    uint256 public target;
    uint256 public createFee;

    address[] public tokens;
    mapping(address => Launch) internal launches;

    event Launched(address indexed token, address indexed creator, string name, string symbol, uint256 target);
    event Trade(address indexed token, address indexed trader, bool isBuy, uint256 doge, uint256 amount, uint256 fee, uint256 vDoge, uint256 vTok);
    event Graduated(address indexed token, address indexed pair, uint256 doge, uint256 amount, uint256 liquidity);
    event Params(address feeTo, uint256 target, uint256 createFee);

    constructor(address _factory, address _wdoge, bytes32 _initCodeHash, address _owner, address _feeTo, uint256 _target, uint256 _createFee) Ownable(_owner) {
        factory = ILaunchFactory(_factory);
        wdoge = _wdoge;
        pairInitCodeHash = _initCodeHash;
        _setParams(_feeTo, _target, _createFee);
    }

    // ------------------------------------------------------------------ admin
    function setParams(address _feeTo, uint256 _target, uint256 _createFee) external onlyOwner {
        _setParams(_feeTo, _target, _createFee);
    }

    function _setParams(address _feeTo, uint256 _target, uint256 _createFee) internal {
        require(_feeTo != address(0), "KingLaunch: ZERO_FEE_TO");
        require(_target >= 0.01 ether && _target <= 1e9 ether, "KingLaunch: BAD_TARGET");
        require(_createFee <= 100 ether, "KingLaunch: BAD_CREATE_FEE");
        feeTo = _feeTo;
        target = _target;
        createFee = _createFee;
        emit Params(_feeTo, _target, _createFee);
    }

    // ------------------------------------------------------------------ launch
    /// @notice Launch a token. Anything sent above `createFee` is used as the creator's first buy.
    function create(string calldata name, string calldata symbol, string calldata description, string calldata image, uint256 minOut)
        external payable nonReentrant returns (address token)
    {
        require(bytes(name).length > 0 && bytes(name).length <= 32, "KingLaunch: NAME");
        require(bytes(symbol).length > 0 && bytes(symbol).length <= 12, "KingLaunch: SYMBOL");
        require(bytes(description).length <= 280, "KingLaunch: DESCRIPTION");
        require(bytes(image).length <= 200, "KingLaunch: IMAGE");
        require(msg.value >= createFee, "KingLaunch: CREATE_FEE");

        // the token must know its future pool address before anyone can hold it
        MemeToken t = new MemeToken(name, symbol);
        token = address(t);
        address pair;
        if (pairInitCodeHash == bytes32(0)) {
            pair = factory.getPair(token, wdoge);
            if (pair == address(0)) pair = factory.createPair(token, wdoge);
        } else {
            pair = _pairFor(token);
        }
        t.setPair(pair);

        tokens.push(token);
        Launch storage L = launches[token];
        L.creator = msg.sender;
        L.createdAt = uint64(block.timestamp);
        L.target = target;
        L.vDoge = target / 3;
        L.vTok = CURVE * 4 / 3;
        L.tokensLeft = CURVE;
        L.pair = pair;
        L.name = name;
        L.symbol = symbol;
        L.description = description;
        L.image = image;
        emit Launched(token, msg.sender, name, symbol, target);

        if (createFee > 0) _send(feeTo, createFee);
        uint256 rest = msg.value - createFee;
        if (rest > 0) _buy(token, rest, minOut);
    }

    // ------------------------------------------------------------------ trading
    function buy(address token, uint256 minOut) external payable nonReentrant returns (uint256 out) {
        require(msg.value > 0, "KingLaunch: ZERO");
        out = _buy(token, msg.value, minOut);
    }

    function sell(address token, uint256 amount, uint256 minDoge) external nonReentrant returns (uint256 dogeOut) {
        Launch storage L = launches[token];
        require(L.creator != address(0), "KingLaunch: UNKNOWN");
        require(!L.graduated, "KingLaunch: GRADUATED");
        require(amount > 0, "KingLaunch: ZERO");
        uint256 gross = L.vDoge * amount / (L.vTok + amount);
        if (gross > L.realDoge) gross = L.realDoge;
        uint256 fee = gross * FEE_BPS / 10_000;
        dogeOut = gross - fee;
        require(dogeOut >= minDoge, "KingLaunch: SLIPPAGE");
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "KingLaunch: TRANSFER");
        L.vDoge -= gross;
        L.vTok += amount;
        L.realDoge -= gross;
        L.tokensLeft += amount;
        emit Trade(token, msg.sender, false, gross, amount, fee, L.vDoge, L.vTok);
        if (fee > 0) _send(feeTo, fee);
        _send(msg.sender, dogeOut);
    }

    function _buy(address token, uint256 value, uint256 minOut) internal returns (uint256 out) {
        Launch storage L = launches[token];
        require(L.creator != address(0), "KingLaunch: UNKNOWN");
        require(!L.graduated, "KingLaunch: GRADUATED");
        (uint256 o, uint256 used, uint256 fee, uint256 refund) = _quoteBuy(L, value);
        out = o;
        require(out > 0 && out >= minOut, "KingLaunch: SLIPPAGE");
        L.vDoge += used;
        L.vTok -= out;
        L.realDoge += used;
        L.tokensLeft -= out;
        emit Trade(token, msg.sender, true, used, out, fee, L.vDoge, L.vTok);
        require(IERC20(token).transfer(msg.sender, out), "KingLaunch: TRANSFER");
        if (fee > 0) _send(feeTo, fee);
        if (L.tokensLeft == 0) _graduate(token, L);
        if (refund > 0) _send(msg.sender, refund);
    }

    function _quoteBuy(Launch storage L, uint256 value) internal view returns (uint256 out, uint256 used, uint256 fee, uint256 refund) {
        fee = value * FEE_BPS / 10_000;
        used = value - fee;
        out = L.vTok * used / (L.vDoge + used);
        if (out >= L.tokensLeft) {
            out = L.tokensLeft;
            // DOGE needed to take exactly the rest of the curve, rounded up
            used = (L.vDoge * out + (L.vTok - out) - 1) / (L.vTok - out);
            fee = (used * FEE_BPS + (10_000 - FEE_BPS) - 1) / (10_000 - FEE_BPS);
            if (used + fee > value) fee = value - used; // rounding guard
            refund = value - used - fee;
        }
    }

    function _graduate(address token, Launch storage L) internal {
        L.graduated = true;
        address pair = factory.getPair(token, wdoge);
        if (pair == address(0)) pair = factory.createPair(token, wdoge);
        require(pair == L.pair, "KingLaunch: PAIR");
        uint256 doge = L.realDoge;
        uint256 amount = IERC20(token).balanceOf(address(this));
        L.realDoge = 0;
        IWDOGE(wdoge).deposit{value: doge}();
        require(IWDOGE(wdoge).transfer(pair, doge), "KingLaunch: WDOGE");
        require(IERC20(token).transfer(pair, amount), "KingLaunch: TOKEN");
        MemeToken(token).markGraduated();
        uint256 liq = ILaunchPair(pair).mint(DEAD);
        emit Graduated(token, pair, doge, amount, liq);
    }

    function _send(address to, uint256 v) internal {
        (bool ok, ) = to.call{value: v}("");
        require(ok, "KingLaunch: DOGE_SEND");
    }

    // ------------------------------------------------------------------ views
    function count() external view returns (uint256) { return tokens.length; }

    function info(address token) public view returns (Launch memory) { return launches[token]; }

    /// @notice Newest first: launches[count-1-start] ... up to n items.
    function page(uint256 start, uint256 n) external view returns (address[] memory addrs, Launch[] memory items) {
        uint256 len = tokens.length;
        if (start >= len) return (new address[](0), new Launch[](0));
        if (n > len - start) n = len - start;
        addrs = new address[](n);
        items = new Launch[](n);
        for (uint256 i; i < n; i++) {
            address a = tokens[len - 1 - start - i];
            addrs[i] = a;
            items[i] = launches[a];
        }
    }

    function quoteBuy(address token, uint256 value) external view returns (uint256 out, uint256 used, uint256 fee, uint256 refund) {
        Launch storage L = launches[token];
        if (L.creator == address(0) || L.graduated || value == 0) return (0, 0, 0, 0);
        return _quoteBuy(L, value);
    }

    function quoteSell(address token, uint256 amount) external view returns (uint256 dogeOut, uint256 fee) {
        Launch storage L = launches[token];
        if (L.creator == address(0) || L.graduated || amount == 0) return (0, 0);
        uint256 gross = L.vDoge * amount / (L.vTok + amount);
        if (gross > L.realDoge) gross = L.realDoge;
        fee = gross * FEE_BPS / 10_000;
        dogeOut = gross - fee;
    }

    // ------------------------------------------------------------------ addresses
    /// @notice CREATE2 address the CavFi factory will give the TOKEN/WDOGE pool.
    function _pairFor(address token) internal view returns (address) {
        (address t0, address t1) = token < wdoge ? (token, wdoge) : (wdoge, token);
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(factory), keccak256(abi.encodePacked(t0, t1)), pairInitCodeHash)))));
    }
}
