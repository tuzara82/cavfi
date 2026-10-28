// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KingLaunch} from "./KingLaunch.sol";

interface ICalloutPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

/// @title CavFi Callouts: put your name on a Launchpad token at today's price
/// @notice "I called $BLADE at a $4K market cap." Anyone can call a token launched on the CavFi Launchpad.
///         The contract records the token's price at that moment: the bonding-curve price, or the CavFi pool
///         price once the token has graduated. Anyone can then see how many times the token has grown since
///         each call. Each wallet can call a token once, and make at most 3 calls per UTC day.
///         Nothing is staked or paid: it is a public, on-chain record of who spotted a token early.
contract KingCallouts {
    uint256 public constant PER_DAY = 3;

    struct Call {
        address caller;
        address token;
        uint64 at;
        uint256 price;   // DOGE per token at the call, scaled by 1e18
    }

    KingLaunch public immutable launch;
    address public immutable wdoge;
    Call[] internal calls;
    mapping(address => mapping(address => bool)) public called;     // caller => token => already called
    mapping(address => mapping(uint32 => uint256)) public perDay;   // caller => UTC day => calls made
    mapping(address => uint256[]) internal byCaller;
    mapping(address => uint256[]) internal byToken;

    event Called(uint256 indexed id, address indexed caller, address indexed token, uint256 price);

    constructor(KingLaunch launch_) {
        launch = launch_;
        wdoge = launch_.wdoge();
    }

    /// @notice DOGE per token (1e18 scale) right now: the curve price, or the CavFi pool price after graduation.
    function priceOf(address token) public view returns (uint256) {
        KingLaunch.Launch memory L = launch.info(token);
        if (L.creator == address(0)) return 0;
        if (!L.graduated) return L.vTok == 0 ? 0 : L.vDoge * 1e18 / L.vTok;
        (uint112 r0, uint112 r1,) = ICalloutPair(L.pair).getReserves();
        bool tokenIs0 = ICalloutPair(L.pair).token0() == token;
        uint256 rTok = tokenIs0 ? r0 : r1;
        uint256 rDoge = tokenIs0 ? r1 : r0;
        return rTok == 0 ? 0 : rDoge * 1e18 / rTok;
    }

    function call(address token) external returns (uint256 id) {
        require(!called[msg.sender][token], "Callouts: already called");
        uint32 day = uint32(block.timestamp / 1 days);
        require(perDay[msg.sender][day] < PER_DAY, "Callouts: 3 calls a day");
        uint256 p = priceOf(token);
        require(p > 0, "Callouts: not a CavFi launch");
        called[msg.sender][token] = true;
        perDay[msg.sender][day]++;
        id = calls.length;
        calls.push(Call(msg.sender, token, uint64(block.timestamp), p));
        byCaller[msg.sender].push(id);
        byToken[token].push(id);
        emit Called(id, msg.sender, token, p);
    }

    // ------------------------------------------------------------- views
    function count() external view returns (uint256) { return calls.length; }

    function get(uint256 id) external view returns (Call memory) { return calls[id]; }

    /// @notice Newest first, with each token's price now (same scale), so a page shows every multiple at once.
    function page(uint256 start, uint256 n) external view returns (uint256[] memory ids, Call[] memory items, uint256[] memory nowPrices) {
        uint256 len = calls.length;
        if (start >= len) return (new uint256[](0), new Call[](0), new uint256[](0));
        if (n > len - start) n = len - start;
        ids = new uint256[](n);
        items = new Call[](n);
        nowPrices = new uint256[](n);
        for (uint256 i; i < n; i++) {
            ids[i] = len - 1 - start - i;
            items[i] = calls[ids[i]];
            nowPrices[i] = priceOf(items[i].token);
        }
    }

    function idsOfCaller(address who) external view returns (uint256[] memory) { return byCaller[who]; }
    function idsOfToken(address token) external view returns (uint256[] memory) { return byToken[token]; }
    function callsLeftToday(address who) external view returns (uint256) {
        uint256 used = perDay[who][uint32(block.timestamp / 1 days)];
        return used >= PER_DAY ? 0 : PER_DAY - used;
    }
}
