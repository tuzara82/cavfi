// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KingPair} from "./KingPair.sol";

/// @title KingSwap factory — one pair per token pair, plus the protocol fee switch
contract KingFactory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    /// @notice Receives the protocol fee (0.05% of swaps, as LP tokens). address(0) = fee off.
    address public feeTo;
    /// @notice The only address allowed to change feeTo and feeToSetter.
    address public feeToSetter;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 index);
    event FeeToChanged(address indexed feeTo);
    event FeeToSetterChanged(address indexed feeToSetter);

    constructor(address _feeToSetter, address _feeTo) {
        feeToSetter = _feeToSetter;
        feeTo = _feeTo;
        emit FeeToSetterChanged(_feeToSetter);
        emit FeeToChanged(_feeTo);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "KingFactory: FORBIDDEN");
        feeTo = _feeTo;
        emit FeeToChanged(_feeTo);
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "KingFactory: FORBIDDEN");
        require(_feeToSetter != address(0), "KingFactory: ZERO_ADDRESS");
        feeToSetter = _feeToSetter;
        emit FeeToSetterChanged(_feeToSetter);
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "KingFactory: IDENTICAL_ADDRESSES");
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(t0 != address(0), "KingFactory: ZERO_ADDRESS");
        require(getPair[t0][t1] == address(0), "KingFactory: PAIR_EXISTS");
        pair = address(new KingPair{salt: keccak256(abi.encodePacked(t0, t1))}());
        KingPair(pair).initialize(t0, t1);
        getPair[t0][t1] = pair;
        getPair[t1][t0] = pair;
        allPairs.push(pair);
        emit PairCreated(t0, t1, pair, allPairs.length);
    }
}
