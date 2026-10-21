// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ILimitRouter {
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external returns (uint256[] memory amounts);
}

interface ILimitWDOGE {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title CavFi limit orders
/// @notice Park tokens with a minimum price. Anyone may fill the order through the CavFi router
///         as soon as the pools pay at least `minOut`; the maker receives everything the swap
///         returns (never less than `minOut`). Whoever fills it earns 0.1% of the input as a tip.
///         Makers can cancel any time; after expiry anyone may send the tokens back to the maker.
///         DOGE is held as WDOGE and paid out as DOGE when the maker asked for it.
contract KingLimit is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TIP_BPS = 10; // 0.1% to the filler

    enum Status { None, Open, Filled, Cancelled }

    struct Order {
        address maker;
        uint64 expiry;
        Status status;
        bool nativeIn;
        bool nativeOut;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minOut;
        uint256 amountOut; // set when filled
    }

    ILimitRouter public immutable router;
    address public immutable wdoge;

    Order[] internal orders;
    mapping(address => uint256[]) internal byMaker;

    event Placed(uint256 indexed id, address indexed maker, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint64 expiry);
    event Filled(uint256 indexed id, address indexed maker, address indexed filler, uint256 amountOut, uint256 tip);
    event Cancelled(uint256 indexed id, address indexed maker, bool expired);

    constructor(address _router, address _wdoge) {
        router = ILimitRouter(_router);
        wdoge = _wdoge;
    }

    receive() external payable {
        require(msg.sender == wdoge, "KingLimit: DOGE");
    }

    // ------------------------------------------------------------- place
    function place(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint64 expiry, bool nativeOut)
        external nonReentrant returns (uint256 id)
    {
        require(amountIn > 0, "KingLimit: ZERO");
        uint256 b0 = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 got = IERC20(tokenIn).balanceOf(address(this)) - b0; // fee-on-transfer safe
        id = _store(tokenIn, tokenOut, got, minOut, expiry, false, nativeOut);
    }

    function placeNative(address tokenOut, uint256 minOut, uint64 expiry) external payable nonReentrant returns (uint256 id) {
        require(msg.value > 0, "KingLimit: ZERO");
        ILimitWDOGE(wdoge).deposit{value: msg.value}();
        id = _store(wdoge, tokenOut, msg.value, minOut, expiry, true, false);
    }

    function _store(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint64 expiry, bool nativeIn, bool nativeOut)
        internal returns (uint256 id)
    {
        require(tokenIn != tokenOut, "KingLimit: SAME_TOKEN");
        require(minOut > 0, "KingLimit: MIN_OUT");
        require(expiry > block.timestamp && expiry <= block.timestamp + 365 days, "KingLimit: EXPIRY");
        require(!nativeOut || tokenOut == wdoge, "KingLimit: NATIVE_OUT");
        id = orders.length;
        orders.push(Order(msg.sender, expiry, Status.Open, nativeIn, nativeOut, tokenIn, tokenOut, amountIn, minOut, 0));
        byMaker[msg.sender].push(id);
        emit Placed(id, msg.sender, tokenIn, tokenOut, amountIn, minOut, expiry);
    }

    // ------------------------------------------------------------- fill
    /// @param path CavFi route from tokenIn to tokenOut (the filler picks the best one).
    function fill(uint256 id, address[] calldata path) external nonReentrant returns (uint256 out) {
        Order storage o = orders[id];
        require(o.status == Status.Open, "KingLimit: NOT_OPEN");
        require(block.timestamp <= o.expiry, "KingLimit: EXPIRED");
        require(path.length >= 2 && path[0] == o.tokenIn && path[path.length - 1] == o.tokenOut, "KingLimit: PATH");
        o.status = Status.Filled;

        uint256 tip = o.amountIn * TIP_BPS / 10_000;
        uint256 swapIn = o.amountIn - tip;
        IERC20(o.tokenIn).forceApprove(address(router), swapIn);
        uint256 b0 = IERC20(o.tokenOut).balanceOf(address(this));
        router.swapExactTokensForTokens(swapIn, o.minOut, path, address(this), block.timestamp);
        out = IERC20(o.tokenOut).balanceOf(address(this)) - b0;
        require(out >= o.minOut, "KingLimit: PRICE");
        o.amountOut = out;

        _pay(o.tokenOut, o.maker, out, o.nativeOut);
        if (tip > 0) IERC20(o.tokenIn).safeTransfer(msg.sender, tip);
        emit Filled(id, o.maker, msg.sender, out, tip);
    }

    // ------------------------------------------------------------- cancel
    function cancel(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        require(o.status == Status.Open, "KingLimit: NOT_OPEN");
        bool expired = block.timestamp > o.expiry;
        require(msg.sender == o.maker || expired, "KingLimit: NOT_MAKER");
        o.status = Status.Cancelled;
        _pay(o.tokenIn, o.maker, o.amountIn, o.nativeIn);
        emit Cancelled(id, o.maker, expired);
    }

    function _pay(address token, address to, uint256 amount, bool native) internal {
        if (native && token == wdoge) {
            ILimitWDOGE(wdoge).withdraw(amount);
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "KingLimit: DOGE_SEND");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ------------------------------------------------------------- views
    function count() external view returns (uint256) { return orders.length; }

    function get(uint256 id) external view returns (Order memory) { return orders[id]; }

    function idsOf(address maker) external view returns (uint256[] memory) { return byMaker[maker]; }

    /// @notice Orders [start, start+n) with their ids; the keeper walks this to find open ones.
    function range(uint256 start, uint256 n) external view returns (uint256[] memory ids, Order[] memory items) {
        uint256 len = orders.length;
        if (start >= len) return (new uint256[](0), new Order[](0));
        if (n > len - start) n = len - start;
        ids = new uint256[](n);
        items = new Order[](n);
        for (uint256 i; i < n; i++) { ids[i] = start + i; items[i] = orders[start + i]; }
    }
}
