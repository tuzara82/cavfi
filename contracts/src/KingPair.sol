// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IKingFactoryFee {
    function feeTo() external view returns (address);
}

/// @title KingSwap constant-product pair (Uniswap V2 math)
/// @notice Swap fee is 0.30%. When the factory's feeTo is set, 1/6 of it (0.05%) goes to
///         KingSwap as newly minted LP tokens; the remaining 0.25% stays with liquidity providers.
contract KingPair is ERC20 {
    using SafeERC20 for IERC20;

    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    /// @notice reserve0 * reserve1 as of the last liquidity event, used to measure fee growth
    uint256 public kLast;

    uint256 private unlocked = 1;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address indexed to);
    event Sync(uint112 reserve0, uint112 reserve1);

    modifier lock() {
        require(unlocked == 1, "KingPair: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    constructor() ERC20("KingSwap LP", "KING-LP") {
        factory = msg.sender;
    }

    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "KingPair: FORBIDDEN");
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() public view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function _update(uint256 bal0, uint256 bal1) private {
        require(bal0 <= type(uint112).max && bal1 <= type(uint112).max, "KingPair: OVERFLOW");
        reserve0 = uint112(bal0);
        reserve1 = uint112(bal1);
        blockTimestampLast = uint32(block.timestamp);
        emit Sync(reserve0, reserve1);
    }

    /// @dev Mints the protocol's share of fee growth since the last liquidity event (Uniswap V2 formula).
    function _mintFee(uint112 r0, uint112 r1) private returns (bool feeOn) {
        address feeTo = IKingFactoryFee(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(uint256(r0) * r1);
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 liquidity = totalSupply() * (rootK - rootKLast) / (rootK * 5 + rootKLast);
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 r0, uint112 r1,) = getReserves();
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 a0 = bal0 - r0;
        uint256 a1 = bal1 - r1;
        bool feeOn = _mintFee(r0, r1);
        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = Math.sqrt(a0 * a1) - MINIMUM_LIQUIDITY;
            _mint(DEAD, MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(a0 * supply / r0, a1 * supply / r1);
        }
        require(liquidity > 0, "KingPair: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        _update(bal0, bal1);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Mint(msg.sender, a0, a1);
    }

    function burn(address to) external lock returns (uint256 a0, uint256 a1) {
        address t0 = token0;
        address t1 = token1;
        uint256 bal0 = IERC20(t0).balanceOf(address(this));
        uint256 bal1 = IERC20(t1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));
        bool feeOn = _mintFee(reserve0, reserve1);
        uint256 supply = totalSupply();
        a0 = liquidity * bal0 / supply;
        a1 = liquidity * bal1 / supply;
        require(a0 > 0 && a1 > 0, "KingPair: INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);
        IERC20(t0).safeTransfer(to, a0);
        IERC20(t1).safeTransfer(to, a1);
        _update(IERC20(t0).balanceOf(address(this)), IERC20(t1).balanceOf(address(this)));
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Burn(msg.sender, a0, a1, to);
    }

    function swap(uint256 out0, uint256 out1, address to) external lock {
        require(out0 > 0 || out1 > 0, "KingPair: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 r0, uint112 r1,) = getReserves();
        require(out0 < r0 && out1 < r1, "KingPair: INSUFFICIENT_LIQUIDITY");
        require(to != token0 && to != token1, "KingPair: INVALID_TO");

        if (out0 > 0) IERC20(token0).safeTransfer(to, out0);
        if (out1 > 0) IERC20(token1).safeTransfer(to, out1);
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));

        uint256 in0 = bal0 > r0 - out0 ? bal0 - (r0 - out0) : 0;
        uint256 in1 = bal1 > r1 - out1 ? bal1 - (r1 - out1) : 0;
        require(in0 > 0 || in1 > 0, "KingPair: INSUFFICIENT_INPUT_AMOUNT");

        uint256 adj0 = bal0 * 1000 - in0 * 3;
        uint256 adj1 = bal1 * 1000 - in1 * 3;
        require(adj0 * adj1 >= uint256(r0) * uint256(r1) * 1_000_000, "KingPair: K");

        _update(bal0, bal1);
        emit Swap(msg.sender, in0, in1, out0, out1, to);
    }

    function skim(address to) external lock {
        IERC20(token0).safeTransfer(to, IERC20(token0).balanceOf(address(this)) - reserve0);
        IERC20(token1).safeTransfer(to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }

    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }
}
