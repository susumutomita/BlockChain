// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Adder {
    function add(uint256 a, uint256 b) public pure returns (uint256) {
        return a + b;
    }

    function sub(uint256 a, uint256 b) public pure returns (uint256) {
        require(b <= a, "underflow");
        return a - b;
    }

    function mul(uint256 a, uint256 b) public pure returns (uint256) {
        return a * b;
    }

    function div(uint256 a, uint256 b) public pure returns (uint256) {
        require(b != 0, "division by zero");
        return a / b;
    }
}
