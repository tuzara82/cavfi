// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KingFactory} from "./KingFactory.sol";
import {KingPair} from "./KingPair.sol";

interface IWDOGE {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
}

/// @title KingSwap router — Uniswap V2 Router02-compatible subset
/// @dev Uses the factory's getPair lookup instead of a CREATE2 init-code hash.
///      `WETH()` returns WDOGE so existing V2 tooling works unchanged.
contract KingRouter {
    using SafeERC20 for IERC20;

    KingFactory public immutable factoryContract;
    address public immutable WETH;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "KingRouter: EXPIRED");
        _;
    }

    constructor(address _factory, address _wdoge) {
        factoryContract = KingFactory(_factory);
        WETH = _wdoge;
    }

    receive() external payable {
        require(msg.sender == WETH, "KingRouter: ONLY_WDOGE");
    }

    function factory() external view returns (address) {
        return address(factoryContract);
    }

    /* ---------------- library ---------------- */

    function _sort(address a, address b) internal pure returns (address t0, address t1) {
        (t0, t1) = a < b ? (a, b) : (b, a);
    }

    function _pair(address a, address b) internal view returns (address p) {
        p = factoryContract.getPair(a, b);
        require(p != address(0), "KingRouter: NO_PAIR");
    }

    function getReserves(address a, address b) public view returns (uint256 ra, uint256 rb) {
        (address t0,) = _sort(a, b);
        (uint112 r0, uint112 r1,) = KingPair(_pair(a, b)).getReserves();
        (ra, rb) = a == t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256) {
        require(amountA > 0, "KingRouter: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "KingRouter: INSUFFICIENT_LIQUIDITY");
        return amountA * reserveB / reserveA;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        require(amountIn > 0, "KingRouter: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "KingRouter: INSUFFICIENT_LIQUIDITY");
        uint256 inWithFee = amountIn * 997;
        return inWithFee * reserveOut / (reserveIn * 1000 + inWithFee);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        require(amountOut > 0, "KingRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > amountOut, "KingRouter: INSUFFICIENT_LIQUIDITY");
        return reserveIn * amountOut * 1000 / ((reserveOut - amountOut) * 997) + 1;
    }

    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        require(path.length >= 2, "KingRouter: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 rIn, uint256 rOut) = getReserves(path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], rIn, rOut);
        }
    }

    function getAmountsIn(uint256 amountOut, address[] memory path) public view returns (uint256[] memory amounts) {
        require(path.length >= 2, "KingRouter: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 rIn, uint256 rOut) = getReserves(path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], rIn, rOut);
        }
    }

    /* ---------------- liquidity ---------------- */

    function _addLiquidity(address a, address b, uint256 desA, uint256 desB, uint256 minA, uint256 minB)
        internal returns (uint256 amtA, uint256 amtB)
    {
        if (factoryContract.getPair(a, b) == address(0)) factoryContract.createPair(a, b);
        (uint256 rA, uint256 rB) = getReserves(a, b);
        if (rA == 0 && rB == 0) {
            (amtA, amtB) = (desA, desB);
        } else {
            uint256 optB = quote(desA, rA, rB);
            if (optB <= desB) {
                require(optB >= minB, "KingRouter: INSUFFICIENT_B_AMOUNT");
                (amtA, amtB) = (desA, optB);
            } else {
                uint256 optA = quote(desB, rB, rA);
                require(optA <= desA && optA >= minA, "KingRouter: INSUFFICIENT_A_AMOUNT");
                (amtA, amtB) = (optA, desB);
            }
        }
    }

    function addLiquidity(
        address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = _pair(tokenA, tokenB);
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = KingPair(pair).mint(to);
    }

    function addLiquidityETH(
        address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        (amountToken, amountETH) = _addLiquidity(token, WETH, amountTokenDesired, msg.value, amountTokenMin, amountETHMin);
        address pair = _pair(token, WETH);
        IERC20(token).safeTransferFrom(msg.sender, pair, amountToken);
        IWDOGE(WETH).deposit{value: amountETH}();
        require(IWDOGE(WETH).transfer(pair, amountETH), "KingRouter: WDOGE_TRANSFER");
        liquidity = KingPair(pair).mint(to);
        if (msg.value > amountETH) _sendDoge(msg.sender, msg.value - amountETH);
    }

    function removeLiquidity(
        address tokenA, address tokenB, uint256 liquidity, uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) public ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = _pair(tokenA, tokenB);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 a0, uint256 a1) = KingPair(pair).burn(to);
        (address t0,) = _sort(tokenA, tokenB);
        (amountA, amountB) = tokenA == t0 ? (a0, a1) : (a1, a0);
        require(amountA >= amountAMin, "KingRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "KingRouter: INSUFFICIENT_B_AMOUNT");
    }

    function removeLiquidityETH(
        address token, uint256 liquidity, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline
    ) external ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) =
            removeLiquidity(token, WETH, liquidity, amountTokenMin, amountETHMin, address(this), deadline);
        IERC20(token).safeTransfer(to, amountToken);
        IWDOGE(WETH).withdraw(amountETH);
        _sendDoge(to, amountETH);
    }

    /* ---------------- swaps ---------------- */

    function _swap(uint256[] memory amounts, address[] memory path, address _to) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address t0,) = _sort(input, output);
            uint256 out = amounts[i + 1];
            (uint256 o0, uint256 o1) = input == t0 ? (uint256(0), out) : (out, uint256(0));
            address to = i < path.length - 2 ? _pair(output, path[i + 2]) : _to;
            KingPair(_pair(input, output)).swap(o0, o1, to);
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "KingRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, _pair(path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external payable ensure(deadline) returns (uint256[] memory amounts)
    {
        require(path[0] == WETH, "KingRouter: INVALID_PATH");
        amounts = getAmountsOut(msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "KingRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IWDOGE(WETH).deposit{value: amounts[0]}();
        require(IWDOGE(WETH).transfer(_pair(path[0], path[1]), amounts[0]), "KingRouter: WDOGE_TRANSFER");
        _swap(amounts, path, to);
    }

    function swapExactTokensForETH(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "KingRouter: INVALID_PATH");
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "KingRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, _pair(path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWDOGE(WETH).withdraw(amounts[amounts.length - 1]);
        _sendDoge(to, amounts[amounts.length - 1]);
    }

    function _sendDoge(address to, uint256 v) internal {
        (bool ok,) = to.call{value: v}("");
        require(ok, "KingRouter: DOGE_TRANSFER_FAILED");
    }
}
