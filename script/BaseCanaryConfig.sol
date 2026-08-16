// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

library BaseCanaryConfig {
    uint256 internal constant CHAIN_ID = 8453;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant PANCAKE_WETH_USDC_100 = 0x72AB388E2E2F6FaceF59E3C3FA2C4E29011c2D38;
    address internal constant UNISWAP_WETH_USDC_100 = 0xb4CB800910B228ED3d0834cF79D697127BBB00e5;

    uint24 internal constant POOL_FEE = 1_000;
    int24 internal constant TICK_SPACING = 10;
    int24 internal constant HALF_RANGE_TICKS = 300;

    uint256 internal constant MAX_ITERATIONS = 10;
    uint256 internal constant WETH_PRINCIPAL_CAP = 2_700_000_000_000_000;
    uint256 internal constant USDC_PRINCIPAL_CAP = 5_000_000;
    uint256 internal constant WETH_MIN_NET_PROFIT = 27_000_000_000_000;
    uint256 internal constant USDC_MIN_NET_PROFIT = 50_000;
    uint256 internal constant MAX_FLASH_FEE_BPS = 1;

    uint16 internal constant MIN_SPREAD_BPS = 10;
    uint16 internal constant CHUNK_SPREAD_CONSUMPTION_BPS = 1_500;
    uint256 internal constant MAX_IMPACT_BPS = 500;
    uint32 internal constant HOOK_GAS_RESERVE = 200_000;
    uint32 internal constant HOOK_GAS_LIMIT = 3_000_000;

    function poolKey(address hook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }
}
