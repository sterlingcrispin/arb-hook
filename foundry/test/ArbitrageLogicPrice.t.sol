// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";

contract StaticV3PricePool {
    uint160 private immutable sqrtPriceX96;

    constructor(uint160 sqrtPriceX96_) {
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }
}

contract ArbitrageLogicPriceTest is Test {
    address private constant TOKEN0 = address(0x1000);
    address private constant TOKEN1 = address(0x2000);

    ArbitrageLogic private logic;

    function setUp() public {
        logic = new ArbitrageLogic();
    }

    function testDirectPricePreservesRemainderBeforeDecimalScaling() public {
        assertEq(_price(uint160(1 << 47), true, 18, 6), 3);
    }

    function testReciprocalPriceIsExactNearMinimumSqrtRatio() public {
        assertEq(
            _price(4_295_128_740, false, 18, 18),
            340256786540325221128184995839410440609792047863013514991
        );
    }

    function testDirectPriceHandlesMaximumUint160SqrtRatio() public {
        assertEq(
            _price(type(uint160).max, true, 18, 18),
            340282366920938463463374607431768211455999999999534338712
        );
    }

    function testWethPriceInCbBtcUsesHumanDecimalRatio() public {
        uint160 sqrtPriceX96 = 136935305154961840000000;
        assertEq(_price(sqrtPriceX96, true, 18, 8), 29872508983204182);
    }

    function testCbBtcPriceInWethUsesHumanDecimalRatio() public {
        uint160 sqrtPriceX96 = 136935305154961840000000;
        assertEq(_price(sqrtPriceX96, false, 18, 8), 33475594586388775216);
    }

    function _price(
        uint160 sqrtPriceX96,
        bool tokenAIsToken0,
        uint8 decimals0,
        uint8 decimals1
    ) private returns (uint256) {
        StaticV3PricePool pool = new StaticV3PricePool(sqrtPriceX96);
        ArbUtils.PoolInfo memory info = ArbUtils.PoolInfo({
            poolAddress: address(pool),
            fee: 0,
            poolType: ArbUtils.PoolType.V3,
            token0: TOKEN0,
            token1: TOKEN1,
            token0Decimals: decimals0,
            token1Decimals: decimals1,
            tickSpacing: 1
        });

        (uint256 buyPrice, uint256 sellPrice, bool ok) = logic
            ._getSinglePoolPrices(
                tokenAIsToken0 ? TOKEN0 : TOKEN1,
                tokenAIsToken0 ? TOKEN1 : TOKEN0,
                info
            );
        assertTrue(ok);
        assertEq(sellPrice, buyPrice);
        return buyPrice;
    }
}
