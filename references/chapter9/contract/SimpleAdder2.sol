// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract SimpleAdder {
    function add(uint256 a, uint256 b) external pure returns (uint256) {
        unchecked {
            return a + b;
        }
    }
}
