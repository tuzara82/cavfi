// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IDcaRouter {
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external returns (uint256[] memory amounts);
}

interface IDcaWDOGE {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title CavFi auto-buy (DCA)
/// @notice Split a buy into equal parts over time: "buy KingS for 1 DOGE every hour, 24 times".
///         The whole amount is held here up front; a keeper (the CavFi bot) runs each part through the
///         CavFi router when it is due and earns 0.1% of that part as a tip. Each part can carry a
///         minimum output (a price floor); a part that would get less waits instead. The owner of a
///         plan can cancel it any time and gets every part that has not run yet back.
/// @dev Only keepers chosen by the owner of this contract may run parts, so nobody can push a pool
///      around and then trigger someone else's buy into it. DOGE is held as WDOGE.
contract KingDCA is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant TIP_BPS = 10; // 0.1% of each part to the keeper
    uint32 public constant MAX_BUYS = 1000;
    uint32 public constant MIN_INTERVAL = 5 minutes;

    struct Plan {
        address owner;
        bool active;
        bool nativeIn;
        bool nativeOut;
        uint32 buysTotal;
        uint32 buysLeft;
        uint32 interval;
        uint64 nextAt;
        address tokenIn;
        address tokenOut;
        uint256 perBuy;
        uint256 minOutPerBuy;
        uint256 spent;    // tokenIn used so far (tips included)
        uint256 received; // tokenOut paid to the owner so far
    }

    IDcaRouter public immutable router;
    address public immutable wdoge;
    mapping(address => bool) public keeper;

    Plan[] internal plans;
    mapping(address => uint256[]) internal byOwner;

    event Created(uint256 indexed id, address indexed owner, address tokenIn, address tokenOut, uint256 perBuy, uint32 buys, uint32 interval);
    event Bought(uint256 indexed id, address indexed owner, address indexed keeper, uint256 amountIn, uint256 amountOut, uint32 buysLeft);
    event Cancelled(uint256 indexed id, address indexed owner, uint256 refund);
    event KeeperSet(address indexed keeper, bool allowed);

    constructor(address owner_, address _router, address _wdoge) Ownable(owner_) {
        router = IDcaRouter(_router);
        wdoge = _wdoge;
    }

    receive() external payable {
        require(msg.sender == wdoge, "KingDCA: DOGE");
    }

    function setKeeper(address k, bool allowed) external onlyOwner {
        keeper[k] = allowed;
        emit KeeperSet(k, allowed);
    }

    // ------------------------------------------------------------- create
    function create(address tokenIn, address tokenOut, uint256 perBuy, uint32 buys, uint32 interval, uint256 minOutPerBuy, bool nativeOut)
        external nonReentrant returns (uint256 id)
    {
        uint256 total = _check(perBuy, buys, interval);
        uint256 b0 = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), total);
        require(IERC20(tokenIn).balanceOf(address(this)) - b0 == total, "KingDCA: FEE_TOKEN");
        id = _store(tokenIn, tokenOut, perBuy, buys, interval, minOutPerBuy, false, nativeOut);
    }

    /// @notice Pay in DOGE: send exactly perBuy * buys.
    function createNative(address tokenOut, uint256 perBuy, uint32 buys, uint32 interval, uint256 minOutPerBuy)
        external payable nonReentrant returns (uint256 id)
    {
        uint256 total = _check(perBuy, buys, interval);
        require(msg.value == total, "KingDCA: VALUE");
        IDcaWDOGE(wdoge).deposit{value: msg.value}();
        id = _store(wdoge, tokenOut, perBuy, buys, interval, minOutPerBuy, true, false);
    }

    function _check(uint256 perBuy, uint32 buys, uint32 interval) internal pure returns (uint256) {
        require(perBuy > 0 && buys > 0 && buys <= MAX_BUYS, "KingDCA: SIZE");
        require(interval >= MIN_INTERVAL && interval <= 30 days, "KingDCA: INTERVAL");
        return perBuy * buys;
    }

    function _store(address tokenIn, address tokenOut, uint256 perBuy, uint32 buys, uint32 interval, uint256 minOut, bool nativeIn, bool nativeOut)
        internal returns (uint256 id)
    {
        require(tokenIn != tokenOut, "KingDCA: SAME_TOKEN");
        require(!nativeOut || tokenOut == wdoge, "KingDCA: NATIVE_OUT");
        id = plans.length;
        plans.push(Plan(msg.sender, true, nativeIn, nativeOut, buys, buys, interval, uint64(block.timestamp), tokenIn, tokenOut, perBuy, minOut, 0, 0));
        byOwner[msg.sender].push(id);
        emit Created(id, msg.sender, tokenIn, tokenOut, perBuy, buys, interval);
    }

    // ------------------------------------------------------------- run one part
    /// @param path CavFi route from tokenIn to tokenOut (the keeper picks the best one).
    function execute(uint256 id, address[] calldata path) external nonReentrant returns (uint256 out) {
        require(keeper[msg.sender], "KingDCA: NOT_KEEPER");
        Plan storage p = plans[id];
        require(p.active && p.buysLeft > 0, "KingDCA: NOT_ACTIVE");
        require(block.timestamp >= p.nextAt, "KingDCA: NOT_DUE");
        require(path.length >= 2 && path[0] == p.tokenIn && path[path.length - 1] == p.tokenOut, "KingDCA: PATH");

        uint256 tip = p.perBuy * TIP_BPS / 10_000;
        uint256 swapIn = p.perBuy - tip;
        IERC20(p.tokenIn).forceApprove(address(router), swapIn);
        uint256 b0 = IERC20(p.tokenOut).balanceOf(address(this));
        router.swapExactTokensForTokens(swapIn, p.minOutPerBuy, path, address(this), block.timestamp);
        out = IERC20(p.tokenOut).balanceOf(address(this)) - b0;
        require(out >= p.minOutPerBuy, "KingDCA: PRICE");

        p.buysLeft -= 1;
        p.spent += p.perBuy;
        p.received += out;
        // never catch up with a burst of buys after a pause: the next part is one interval from now at the earliest
        uint64 next = p.nextAt + p.interval;
        if (next < block.timestamp) next = uint64(block.timestamp) + p.interval;
        p.nextAt = next;
        if (p.buysLeft == 0) p.active = false;

        _pay(p.tokenOut, p.owner, out, p.nativeOut);
        if (tip > 0) IERC20(p.tokenIn).safeTransfer(msg.sender, tip);
        emit Bought(id, p.owner, msg.sender, p.perBuy, out, p.buysLeft);
    }

    // ------------------------------------------------------------- cancel
    function cancel(uint256 id) external nonReentrant {
        Plan storage p = plans[id];
        require(msg.sender == p.owner, "KingDCA: NOT_OWNER");
        require(p.active, "KingDCA: NOT_ACTIVE");
        uint256 refund = p.perBuy * p.buysLeft;
        p.active = false;
        p.buysLeft = 0;
        if (refund > 0) _pay(p.tokenIn, p.owner, refund, p.nativeIn);
        emit Cancelled(id, p.owner, refund);
    }

    function _pay(address token, address to, uint256 amount, bool native) internal {
        if (native && token == wdoge) {
            IDcaWDOGE(wdoge).withdraw(amount);
            (bool ok,) = to.call{value: amount}("");
            require(ok, "KingDCA: DOGE_SEND");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ------------------------------------------------------------- views
    function count() external view returns (uint256) { return plans.length; }

    function get(uint256 id) external view returns (Plan memory) { return plans[id]; }

    function plansOf(address who) external view returns (uint256[] memory ids, Plan[] memory items) {
        ids = byOwner[who];
        items = new Plan[](ids.length);
        for (uint256 i; i < ids.length; i++) items[i] = plans[ids[i]];
    }

    /// @notice Active plans in [start, start + n) whose next part is due now (for keepers).
    function due(uint256 start, uint256 n) external view returns (uint256[] memory ids) {
        uint256 end = start + n > plans.length ? plans.length : start + n;
        uint256 k;
        uint256[] memory tmp = new uint256[](end > start ? end - start : 0);
        for (uint256 i = start; i < end; i++) {
            Plan storage p = plans[i];
            if (p.active && p.buysLeft > 0 && block.timestamp >= p.nextAt) tmp[k++] = i;
        }
        ids = new uint256[](k);
        for (uint256 i; i < k; i++) ids[i] = tmp[i];
    }
}
