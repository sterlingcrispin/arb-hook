// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract PoolModifyLiquidityTestWrapper is PoolModifyLiquidityTest {
    constructor(IPoolManager manager) PoolModifyLiquidityTest(manager) {}
}
