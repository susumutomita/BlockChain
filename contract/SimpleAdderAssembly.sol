// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract SimpleAdderAssembly {
    fallback() external payable {
        assembly {
            // Check if we have at least 68 bytes of calldata (4 bytes selector + 64 bytes for two uint256 arguments)
            if lt(calldatasize(), 68) {
                revert(0, 0)
            }

            // Load function selector from first 4 bytes
            let selector := shr(224, calldataload(0))

            // Check if selector matches add function (0x771602f7)
            if eq(selector, 0x771602f7) {
                // Load first argument from calldata (offset 4, skip selector)
                let a := calldataload(4)

                // Load second argument from calldata (offset 36, skip selector + first arg)
                let b := calldataload(36)

                // Add the two numbers
                let result := add(a, b)

                // Store result in memory at position 0
                mstore(0, result)

                // Return the result (32 bytes from memory position 0)
                return(0, 32)
            }

            // If selector doesn't match, revert
            revert(0, 0)
        }
    }
}
