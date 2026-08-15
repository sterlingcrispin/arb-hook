// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

contract StaticV3RoutePool {
    uint160 internal immutable sqrtPriceX96;
    int24 internal immutable currentTick;
    uint128 public immutable liquidity;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    constructor(address token0_, address token1_, uint24 fee_, int24 tick_, uint128 liquidity_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        currentTick = tick_;
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick_);
        liquidity = liquidity_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, currentTick, 0, 0, 0, 0, true);
    }
}

contract ArbitrageLogicV4RouteTest is Test {
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    uint128 internal constant LIQUIDITY = 1e18;

    ArbitrageLogic internal logic;

    function setUp() public {
        logic = new ArbitrageLogic();
    }

    function testSizesToken0CounterSwapTowardExternalPrice() public {
        (ArbitrageLogic.V4V3RouteParams memory route,) = _route(100, 0, TOKEN0, LIQUIDITY, 500, 10);

        assertGt(route.principal, 0);
        assertEq(route.spread, 100);
        assertLt(route.sqrtPriceLimitX96, TickMath.getSqrtRatioAtTick(100));
        assertGt(route.externalSqrtPriceLimitX96, TickMath.getSqrtRatioAtTick(0));
    }

    function testSizesToken1CounterSwapTowardExternalPrice() public {
        (ArbitrageLogic.V4V3RouteParams memory route,) = _route(-100, 0, TOKEN1, LIQUIDITY, 500, 10);

        assertGt(route.principal, 0);
        assertEq(route.spread, 100);
        assertGt(route.sqrtPriceLimitX96, TickMath.getSqrtRatioAtTick(-100));
        assertLt(route.externalSqrtPriceLimitX96, TickMath.getSqrtRatioAtTick(0));
    }

    function testRejectsSpreadInWrongDirection() public {
        (ArbitrageLogic.V4V3RouteParams memory route,) = _route(-100, 0, TOKEN0, LIQUIDITY, 500, 10);
        assertEq(route.principal, 0);
    }

    function testExternalLiquidityCapsPrincipal() public {
        (ArbitrageLogic.V4V3RouteParams memory deepRoute,) = _route(100, 0, TOKEN0, LIQUIDITY, 500, 10);
        (ArbitrageLogic.V4V3RouteParams memory thinRoute,) = _route(100, 0, TOKEN0, LIQUIDITY / 10, 500, 10);

        assertGt(thinRoute.principal, 0);
        assertLt(thinRoute.principal, deepRoute.principal);
    }

    function testRejectsEdgeThatDoesNotClearPoolFees() public {
        (ArbitrageLogic.V4V3RouteParams memory route,) = _route(5, 0, TOKEN0, LIQUIDITY, 500, 1);
        assertEq(route.principal, 0);
    }

    function _route(
        int24 v4Tick,
        int24 externalTick,
        address startToken,
        uint128 externalLiquidity,
        uint24 externalFee,
        uint16 minimumSpread
    ) private returns (ArbitrageLogic.V4V3RouteParams memory route, StaticV3RoutePool pool) {
        pool = new StaticV3RoutePool(TOKEN0, TOKEN1, externalFee, externalTick, externalLiquidity);
        ArbUtils.PoolInfo memory info = ArbUtils.PoolInfo({
            poolAddress: address(pool),
            fee: externalFee,
            poolType: ArbUtils.PoolType.V3,
            token0: TOKEN0,
            token1: TOKEN1,
            token0Decimals: 18,
            token1Decimals: 18,
            tickSpacing: 10
        });
        ArbitrageLogic.IterationConfig memory config = ArbitrageLogic.IterationConfig({
            minSpreadBps: minimumSpread,
            chunkSpreadConsumptionBps: 1500,
            bpsDivisor: 10_000,
            maxImpactBps: 500,
            minChunkForStartToken: 1,
            currentStartTokenBalance: 100 ether,
            initialAbsSpread: v4Tick > externalTick ? v4Tick - externalTick : externalTick - v4Tick
        });
        ArbitrageLogic.PoolStatesForIteration memory v4State = ArbitrageLogic.PoolStatesForIteration({
            sqrtPrice: TickMath.getSqrtRatioAtTick(v4Tick), tick: v4Tick, liquidity: LIQUIDITY, token0: TOKEN0
        });

        route = logic.getV4V3RouteParams(v4State, 500, startToken, startToken == TOKEN0 ? TOKEN1 : TOKEN0, info, config);
    }
}
