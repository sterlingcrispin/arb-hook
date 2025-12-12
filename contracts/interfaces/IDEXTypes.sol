// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDEXTypes
 * @dev Interface defining DEX types used across multiple contracts
 */
interface IDEXTypes {
    // DEX types supported by the contracts
    enum DEXType {
        UNISWAP_V2,
        UNISWAP_V3,
        UNISWAP_V4,
        PANCAKESWAP,
        AERODROME
    }
}
