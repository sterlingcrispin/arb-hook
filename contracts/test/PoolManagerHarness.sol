// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract PoolManagerHarness is PoolManager {
    constructor(address initialOwner) PoolManager(initialOwner) {}

    function callAfterSwap(
        IHooks hook,
        address sender,
        bytes calldata hookData
    ) external returns (bytes4 selector, int128 delta) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 1,
            hooks: hook
        });
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 1,
            sqrtPriceLimitX96: 0
        });
        return hook.afterSwap(sender, key, params, BalanceDelta.wrap(0), hookData);
    }
}
