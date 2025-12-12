// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

contract PoolManagerHarness is PoolManager {
    constructor(address initialOwner) PoolManager(initialOwner) {}
}
