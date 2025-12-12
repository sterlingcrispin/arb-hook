// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract PoolSwapTestWrapper is PoolSwapTest {
    constructor(IPoolManager manager) PoolSwapTest(manager) {}
}
