// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {PoolManagerHarness} from "../../contracts/test/PoolManagerHarness.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {DataStorage} from "../../contracts/DataStorage.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {IDataStorage} from "../../contracts/interfaces/IDataStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../../contracts/interfaces/IWETH9.sol";
import {IUniswapV2Pair} from "../../contracts/interfaces/IUniswapV2Pair.sol";
import {IPancakeV3Pool} from "../../contracts/interfaces/IPancakeV3Pool.sol";
import {ISwapRouter02} from "../../contracts/interfaces/uniswap/ISwapRouter02.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

contract ArbHookParityTest is Test {
    // Reference JS harness forks at 33942332 - 70 = 33942262
    // (see ExampleTests/ArbLightweight.attemptAll.js line 12)
    uint256 internal constant FOCUS_BLOCK = 33942262;
    uint256 internal constant FORK_START_BLOCK = FOCUS_BLOCK;
    uint256 internal constant MAX_ITER = 2;
    uint256 internal constant MAX_ROUNDS = 10;
    uint256 internal constant DEBUG_ROUND_LIMIT = MAX_ROUNDS;
    uint256 internal constant USDC_DECIMALS = 6;
    uint16 internal constant MIN_SPREAD_BPS = 10; // Mirrors ArbLightweight default
    uint16 internal constant CHUNK_SPREAD_CONSUMPTION_BPS = 1500;
    uint256 internal constant MAX_IMPACT_BPS = 500;
    uint256 internal constant MIN_PROFIT_TO_EMIT = 0;
    bool internal constant ENFORCE_PARITY = true;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_WHALE = 0x0B0A5886664376F59C351ba3f598C8A8B4D0A6f3;
    address internal constant V3_POOL_LOW = 0xE9e25E35aa99A2A60155010802b81A25C45bA185;
    address internal constant V3_POOL_HIGH = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;
    address internal constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    string internal baseRpcUrl;

    struct DeployContext {
        ArbHookHarness hook;
        ArbitrageLogic logic;
        DataStorage storageContract;
        PoolManagerHarness poolManager;
    }

    struct PoolSpec {
        address base;
        address pool;
        uint24 fee;
        ArbUtils.PoolType poolType;
    }

    struct RoundResult {
        address tokenA;
        address tokenB;
        address buyPool;
        address sellPool;
        uint256 totalAmountSwapped;
        int256 cumulativeProfit;
        uint256 iterations;
    }

    struct RoundExpectation {
        address buyPool;
        address sellPool;
        int256 profit;
    }

    bytes32 private constant ARB_EVENT_TOPIC = keccak256(
        "ArbitrageAttempted(address,address,address,address,uint256,int256,uint256)"
    );

    function setUp() public {
        baseRpcUrl = vm.envString("BASE_RPC_URL");
    }

    function testOwnerOnlyAccessParity() public {
        vm.createSelectFork(baseRpcUrl, FORK_START_BLOCK);
        DeployContext memory ctx = _deploySystem();
        address stranger = makeAddr("stranger");

        vm.startPrank(stranger);
        _expectOwnableRevert(stranger);
        ctx.hook.setHookMaxIterations(1);

        address[] memory pools;
        uint24[] memory fees;
        ArbUtils.PoolType[] memory types;

        pools = new address[](1);
        pools[0] = V3_POOL_LOW;
        fees = new uint24[](1);
        fees[0] = 100;
        types = new ArbUtils.PoolType[](1);
        types[0] = ArbUtils.PoolType.V3;
        _expectOwnableRevert(stranger);
        ctx.hook.addPools(USDC, pools, fees, types);

        pools = new address[](0);
        fees = new uint24[](0);
        types = new ArbUtils.PoolType[](0);
        _expectOwnableRevert(stranger);
        ctx.hook.approvePools(USDC, pools, type(uint256).max);

        _expectOwnableRevert(stranger);
        ctx.hook.setMinSpreadBps(5);

        _expectOwnableRevert(stranger);
        ctx.hook.setChunkSpreadConsumptionBps(5);

        _expectOwnableRevert(stranger);
        ctx.hook.setMaxImpactBps(100);

        _expectOwnableRevert(stranger);
        ctx.hook.setMinProfitToEmit(1 ether);

        _expectOwnableRevert(stranger);
        ctx.hook.setDataStorage(address(0));

        _expectOwnableRevert(stranger);
        ctx.hook.attemptAllForTest(MAX_ITER);
        vm.stopPrank();
    }

    function testAttemptAllOnForkMatchesArbLightweightFlow() public {
        vm.createSelectFork(baseRpcUrl, FORK_START_BLOCK);
        vm.deal(address(this), 100 ether);

        DeployContext memory ctx = _deploySystem();
        PoolSpec[] memory pools = _parityPools();
        _registerParityPools(ctx, pools);
        _approveParityPools(ctx, pools);
        _fundBot(ctx);
        _logPoolState(pools, "pool state before seeding");
        _seedCbBtcUsdcGap();
        _logPoolState(pools, "pool state after seeding");
        _logPoolInventory(ctx, WETH, "WETH pool book");
        _logPoolInventory(ctx, USDC, "USDC pool book");

        RoundExpectation[] memory expected = _expectedRounds();
        RoundResult[] memory actual = new RoundResult[](MAX_ROUNDS);
        uint256 successfulRounds;
        for (uint256 round = 0; round < MAX_ROUNDS; ++round) {
            emit log(
                string.concat(
                    "[block] pre-attempt number=",
                    vm.toString(block.number),
                    " ts=",
                    vm.toString(block.timestamp)
                )
            );
            _logBestSpread(ctx, USDC, WETH, "pre-attempt best spread (USDC/WETH)");
            vm.recordLogs();
            bool success = ctx.hook.attemptAllForTest(MAX_ITER);
            emit log(
                string.concat(
                    "[block] post-attempt number=",
                    vm.toString(block.number),
                    " ts=",
                    vm.toString(block.timestamp)
                )
            );
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (!success) {
                emit log_named_uint("attemptAll returned false on round", round + 1);
                emit log(
                    "no ArbitrageAttempted event emitted; inspect hook console output"
                );
            }
            assertTrue(success, "attemptAll should execute successfully");
            actual[round] = _decodeAttempt(logs);
            _logRound(round + 1, actual[round], expected[round]);
            if (actual[round].cumulativeProfit > 0) {
                successfulRounds++;
            }
            if (ENFORCE_PARITY) {
                _assertRoundMatches(actual[round], expected[round], round);
            }
            _logBestSpread(ctx, USDC, WETH, "post-attempt best spread (USDC/WETH)");

            // No debug break once full parity is required
        }

        assertGt(successfulRounds, 0, "at least one profitable round expected");
        uint256 tradeCount = ctx.storageContract.getTradeCount();
        if (ENFORCE_PARITY) {
            assertEq(
                tradeCount,
                MAX_ROUNDS,
                "each round should record a trade while parity enforced"
            );
        } else {
            assertGt(tradeCount, 0, "trades should be recorded");
        }

        // Print summary similar to JS harness
        _logSummary(actual, expected, successfulRounds);
    }

    function _logSummary(
        RoundResult[] memory actual,
        RoundExpectation[] memory expected,
        uint256 profitableRounds
    ) private {
        emit log("");
        emit log("===== ArbHook Parity Test Summary =====");
        emit log_named_uint("Rounds executed", MAX_ROUNDS);
        emit log_named_uint("Profitable rounds", profitableRounds);

        int256 totalProfit = 0;
        uint256 totalIterations = 0;
        for (uint256 i = 0; i < MAX_ROUNDS; ++i) {
            totalProfit += actual[i].cumulativeProfit;
            totalIterations += actual[i].iterations;
        }

        emit log_named_uint("Total iterations", totalIterations);
        emit log_named_int("Total profit (raw USDC units)", totalProfit);

        // Convert to human-readable USDC (6 decimals)
        uint256 profitWhole = uint256(totalProfit) / 1e6;
        uint256 profitFrac = uint256(totalProfit) % 1e6;
        emit log(string.concat(
            "Total USDC profit: ",
            vm.toString(profitWhole),
            ".",
            _padZeros(profitFrac, 6),
            " USDC"
        ));

        emit log("");
        emit log("Per-round details:");
        for (uint256 i = 0; i < MAX_ROUNDS; ++i) {
            uint256 pWhole = uint256(actual[i].cumulativeProfit) / 1e6;
            uint256 pFrac = uint256(actual[i].cumulativeProfit) % 1e6;
            string memory profitStr = string.concat(
                vm.toString(pWhole),
                ".",
                _padZeros(pFrac, 6)
            );

            bool matches = actual[i].cumulativeProfit == expected[i].profit &&
                          actual[i].buyPool == expected[i].buyPool &&
                          actual[i].sellPool == expected[i].sellPool;

            emit log(string.concat(
                "  Round ",
                vm.toString(i + 1),
                ": USDC profit=",
                profitStr,
                ", iters=",
                vm.toString(actual[i].iterations),
                matches ? " [MATCH]" : " [MISMATCH]"
            ));
        }
        emit log("=======================================");
    }

    function _padZeros(uint256 value, uint256 width) private pure returns (string memory) {
        bytes memory result = bytes(vm.toString(value));
        if (result.length >= width) return string(result);

        bytes memory padded = new bytes(width);
        uint256 padding = width - result.length;
        for (uint256 i = 0; i < padding; ++i) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < result.length; ++i) {
            padded[padding + i] = result[i];
        }
        return string(padded);
    }

    function testPerBlockReplayParity() public {
        uint256[] memory blocks = new uint256[](3);
        blocks[0] = FORK_START_BLOCK - 1;
        blocks[1] = FORK_START_BLOCK;
        blocks[2] = FORK_START_BLOCK + 1;

        for (uint256 i = 0; i < blocks.length; ++i) {
            vm.createSelectFork(baseRpcUrl, blocks[i]);
            vm.deal(address(this), 100 ether);
            DeployContext memory ctx = _deploySystem();
            PoolSpec[] memory pools = _parityPools();
            _registerParityPools(ctx, pools);
            _approveParityPools(ctx, pools);
            _fundBot(ctx);
            _logPoolState(pools, "pool state before seeding");
            _seedCbBtcUsdcGap();
            _logPoolState(pools, "pool state after seeding");

            vm.recordLogs();
            bool success = ctx.hook.attemptAllForTest(MAX_ITER);
            assertTrue(success, "attemptAll should not revert in replay");
            RoundResult memory result = _decodeAttempt(vm.getRecordedLogs());
            emit log_named_int("replay profit", _toUsdcUnits(result.cumulativeProfit));
            assertEq(
                ctx.storageContract.getTradeCount(),
                1,
                "storage should increment per replay"
            );
        }
    }

    /* --------------------------------------------------------------------- */
    /* Helpers                                                               */
    /* --------------------------------------------------------------------- */

    function _deploySystem() private returns (DeployContext memory ctx) {
        ctx.poolManager = new PoolManagerHarness(address(this));
        ctx.logic = new ArbitrageLogic();
        ctx.storageContract = new DataStorage(address(this));
        ctx.hook = new ArbHookHarness(
            IPoolManager(address(ctx.poolManager)),
            address(this),
            address(ctx.logic),
            address(ctx.storageContract)
        );
        ctx.storageContract.setWriter(address(ctx.hook));
        ctx.hook.setHookMaxIterations(MAX_ITER);
        ctx.hook.setMinSpreadBps(MIN_SPREAD_BPS);
        ctx.hook.setChunkSpreadConsumptionBps(
            CHUNK_SPREAD_CONSUMPTION_BPS
        );
        ctx.hook.setMaxImpactBps(MAX_IMPACT_BPS);
        ctx.hook.setMinProfitToEmit(MIN_PROFIT_TO_EMIT);
    }

    function _registerParityPools(
        DeployContext memory ctx,
        PoolSpec[] memory specs
    ) private {
        for (uint256 i = 0; i < specs.length; ++i) {
            address[] memory poolAddresses = new address[](1);
            poolAddresses[0] = specs[i].pool;
            uint24[] memory fees = new uint24[](1);
            fees[0] = specs[i].fee;
            ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](1);
            types[0] = specs[i].poolType;
            try ctx.hook.addPools(specs[i].base, poolAddresses, fees, types) {}
            catch {} // Ignore duplicates just like JS harness
        }
    }

    function _approveParityPools(
        DeployContext memory ctx,
        PoolSpec[] memory specs
    ) private {
        address[] memory pools = _collectPoolAddresses(specs);
        ctx.hook.approvePools(WETH, pools, type(uint256).max);
        ctx.hook.approvePools(USDC, pools, type(uint256).max);
        ctx.hook.approvePools(CBBTC, pools, type(uint256).max);
    }

    function _fundBot(DeployContext memory ctx) private {
        // Replicate JS funding behavior: swap WETH→USDC through fee=500 pool
        // JS does 2 swaps of 25 WETH each to acquire ~200k USDC
        // This changes pool prices, which affects arbitrage discovery

        uint256 wethPerSwap = 25 ether;
        uint256 numSwaps = 2;
        uint256 totalWeth = wethPerSwap * numSwaps;

        // Wrap ETH to WETH for funding swaps
        vm.deal(address(this), totalWeth + 10 ether); // extra for bot
        IWETH9 weth = IWETH9(WETH);
        weth.deposit{value: totalWeth}();

        // Approve router
        IERC20(WETH).approve(SWAP_ROUTER, totalWeth);
        ISwapRouter02 router = ISwapRouter02(SWAP_ROUTER);

        // Swap WETH→USDC through fee=500 pool (same as JS)
        emit log("funding: swapping WETH->USDC to replicate JS behavior");
        for (uint256 i = 0; i < numSwaps; ++i) {
            emit log_named_uint("funding: WETH->USDC swap", i + 1);
            ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02
                .ExactInputSingleParams({
                    tokenIn: WETH,
                    tokenOut: USDC,
                    fee: 500,  // fee=500 pool 0xd0b5...
                    recipient: address(this),
                    amountIn: wethPerSwap,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                });
            uint256 amountOut = router.exactInputSingle(params);
            emit log_named_uint("funding: USDC received", amountOut);
        }

        // Transfer 100k USDC to bot
        uint256 botUsdcAmount = 100_000 * (10 ** USDC_DECIMALS);
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        emit log_named_uint("funding: total USDC after swaps", usdcBalance);
        require(usdcBalance >= botUsdcAmount, "insufficient USDC from swaps");
        IERC20(USDC).transfer(address(ctx.hook), botUsdcAmount);

        // Wrap and transfer 10 WETH to bot
        _topUpWeth(ctx, 10 ether);
    }

    function _topUpWeth(DeployContext memory ctx, uint256 amount) private {
        if (amount == 0) return;
        if (address(this).balance < amount) {
            vm.deal(address(this), amount);
        }
        IWETH9 weth = IWETH9(WETH);
        weth.deposit{value: amount}();
        weth.transfer(address(ctx.hook), amount);
    }

    function _pullToken(
        address token,
        address whale,
        uint256 amount
    ) private {
        vm.deal(whale, 10 ether);
        vm.startPrank(whale);
        IERC20(token).transfer(address(this), amount);
        vm.stopPrank();
    }

    function _expectOwnableRevert(address caller) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                caller
            )
        );
    }

    function _collectPoolAddresses(
        PoolSpec[] memory specs
    ) private pure returns (address[] memory pools) {
        pools = new address[](specs.length);
        for (uint256 i = 0; i < specs.length; ++i) {
            pools[i] = specs[i].pool;
        }
    }

    function _logBestSpread(
        DeployContext memory ctx,
        address tokenA,
        address tokenB,
        string memory label
    ) private {
        ArbUtils.PoolInfo[] memory pools = ctx.hook.getPoolsForToken(tokenA);
        address bestBuy;
        address bestSell;
        uint256 bestBuyPrice = type(uint256).max;
        uint256 bestSellPrice;
        for (uint256 i = 0; i < pools.length; ++i) {
            ArbUtils.PoolInfo memory info = pools[i];
            if (info.poolAddress == address(0)) continue;
            bool matches =
                (info.token0 == tokenA && info.token1 == tokenB) ||
                (info.token0 == tokenB && info.token1 == tokenA);
            if (!matches) continue;
            if (info.poolType == ArbUtils.PoolType.V3) {
                try IUniswapV3Pool(info.poolAddress).slot0() returns (
                    uint160,
                    int24,
                    uint16,
                    uint16,
                    uint16,
                    uint8,
                    bool
                ) {
                    // direct read ok
                } catch {
                    emit log_named_address(
                        "direct slot0 failed",
                        info.poolAddress
                    );
                }
            }
            (uint256 buyPrice, uint256 sellPrice, bool ok) = ctx
                .logic
                ._getSinglePoolPrices(tokenA, tokenB, info);
            if (!ok) {
                emit log_named_address("price fetch failed", info.poolAddress);
                emit log_named_uint(
                    "pool type",
                    uint256(uint8(info.poolType))
                );
                continue;
            }
            if (buyPrice < bestBuyPrice) {
                bestBuyPrice = buyPrice;
                bestBuy = info.poolAddress;
            }
            if (sellPrice > bestSellPrice) {
                bestSellPrice = sellPrice;
                bestSell = info.poolAddress;
            }
        }
        emit log(label);
        emit log_named_address("best buy pool", bestBuy);
        emit log_named_uint("best buy eff price", bestBuyPrice);
        emit log_named_address("best sell pool", bestSell);
        emit log_named_uint("best sell eff price", bestSellPrice);
    }

    function _logPoolInventory(
        DeployContext memory ctx,
        address token,
        string memory label
    ) private {
        ArbUtils.PoolInfo[] memory pools = ctx.hook.getPoolsForToken(token);
        emit log(label);
        for (uint256 i = 0; i < pools.length; ++i) {
            ArbUtils.PoolInfo memory info = pools[i];
            emit log_named_address("pool", info.poolAddress);
            emit log_named_address("token0", info.token0);
            emit log_named_address("token1", info.token1);
            emit log_named_uint("token0Decimals", info.token0Decimals);
            emit log_named_uint("token1Decimals", info.token1Decimals);
            emit log_named_int("tickSpacing", info.tickSpacing);
            emit log_named_uint("poolType", uint256(uint8(info.poolType)));
        }
    }

    function _logPoolState(
        PoolSpec[] memory specs,
        string memory label
    ) private {
        emit log(label);
        emit log_named_uint("block number", block.number);
        emit log_named_uint("timestamp", block.timestamp);
        for (uint256 i = 0; i < specs.length; ++i) {
            PoolSpec memory spec = specs[i];
            emit log_named_address("pool", spec.pool);
            emit log_named_uint("poolType", uint256(uint8(spec.poolType)));
            if (spec.poolType == ArbUtils.PoolType.V3) {
                IUniswapV3Pool pool = IUniswapV3Pool(spec.pool);
                (uint160 sqrtPriceX96, int24 tick, , , , , ) = pool.slot0();
                emit log_named_uint("sqrtPriceX96", sqrtPriceX96);
                emit log_named_int("tick", tick);
                emit log_named_uint("liquidity", pool.liquidity());
            } else if (spec.poolType == ArbUtils.PoolType.PANCAKESWAP_V3) {
                IPancakeV3Pool pool = IPancakeV3Pool(spec.pool);
                (uint160 sqrtPriceX96, int24 tick, , , , , ) = pool.slot0();
                emit log_named_uint("sqrtPriceX96", sqrtPriceX96);
                emit log_named_int("tick", tick);
                // Pancake V3 interface we use doesnt expose liquidity; skip.
            } else {
                IUniswapV2Pair pair = IUniswapV2Pair(spec.pool);
                (uint112 r0, uint112 r1, uint32 lastTs) = pair.getReserves();
                emit log_named_uint("reserve0", r0);
                emit log_named_uint("reserve1", r1);
                emit log_named_uint("lastTimestamp", lastTs);
            }
        }
    }

    function _seedCbBtcUsdcGap() private {
        uint256 chunkCount = 5;
        uint256 usdcChunk = 400 * (10 ** USDC_DECIMALS);
        uint256 totalSeedUsdc = usdcChunk * chunkCount;
        emit log("seeding cbBTC/USDC pools via router chunks");
        emit log_named_address("seed USDC whale", USDC_WHALE);
        emit log_named_uint("seed chunk count", chunkCount);
        emit log_named_uint("seed chunk size (USDC)", usdcChunk);
        _pullToken(USDC, USDC_WHALE, totalSeedUsdc);
        emit log_named_uint(
            "seed USDC balance after pull",
            IERC20(USDC).balanceOf(address(this))
        );
        IERC20(USDC).approve(SWAP_ROUTER, totalSeedUsdc);
        ISwapRouter02 router = ISwapRouter02(SWAP_ROUTER);

        for (uint256 i = 0; i < chunkCount; ++i) {
            emit log_named_uint("seed USDC->cbBTC chunk", i + 1);
            ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02
                .ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: CBBTC,
                fee: 100,
                recipient: address(this),
                amountIn: usdcChunk,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            uint256 beforeCb = IERC20(CBBTC).balanceOf(address(this));
            uint256 amountOut = router.exactInputSingle(params);
            uint256 afterCb = IERC20(CBBTC).balanceOf(address(this));
            emit log_named_uint("seed chunk amountOut", amountOut);
            emit log_named_uint("seed cbBTC delta", afterCb - beforeCb);
        }

        uint256 cbBtcBalance = IERC20(CBBTC).balanceOf(address(this));
        if (cbBtcBalance == 0) {
            emit log("seeding skipped: cbBTC balance zero after USDC legs");
            return;
        }
        emit log_named_uint("seed cbBTC balance before sells", cbBtcBalance);

        IERC20(CBBTC).approve(SWAP_ROUTER, cbBtcBalance);
        uint256 cbChunks = chunkCount;
        uint256 cbChunkSize = cbBtcBalance / cbChunks;
        for (uint256 j = 0; j < cbChunks; ++j) {
            uint256 remaining = IERC20(CBBTC).balanceOf(address(this));
            uint256 amountIn = j == cbChunks - 1 ? remaining : cbChunkSize;
            if (amountIn == 0) {
                break;
            }
            emit log_named_uint("seed cbBTC->USDC chunk", j + 1);
            emit log_named_uint("seed chunk amountIn", amountIn);
            ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02
                .ExactInputSingleParams({
                tokenIn: CBBTC,
                tokenOut: USDC,
                fee: 500,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            uint256 beforeUsdc = IERC20(USDC).balanceOf(address(this));
            uint256 amountOut = router.exactInputSingle(params);
            uint256 afterUsdc = IERC20(USDC).balanceOf(address(this));
            emit log_named_uint("seed chunk amountOut", amountOut);
            emit log_named_uint("seed USDC delta", afterUsdc - beforeUsdc);
        }
        emit log_named_uint(
            "seed final USDC balance",
            IERC20(USDC).balanceOf(address(this))
        );
        emit log_named_uint(
            "seed final cbBTC balance",
            IERC20(CBBTC).balanceOf(address(this))
        );
    }

    function _parityPools() private pure returns (PoolSpec[] memory specs) {
        // IMPORTANT: Only register pools with USDC as base token.
        // The JS harness NEVER uses WETH as tokenA in _getSinglePoolPrices
        // (confirmed by grep - no "tokenA 0x4200" in attemptAllOutput.txt).
        // When WETH is tokenA, the price math underflows to zero due to
        // decimal scaling issues in _calculatePrice1e18_corrected.
        specs = new PoolSpec[](16);
        uint256 idx;

        // USDC-based pools only (matches JS harness behavior)
        specs[idx++] = PoolSpec({base: USDC, pool: 0x1C450D7d1FD98A0b04E30deCFc83497b33A4F608, fee: 200, poolType: ArbUtils.PoolType.V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0xd0b53D9277642d899DF5C87A3966A349A798F224, fee: 500, poolType: ArbUtils.PoolType.V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0x72AB388E2E2F6FaceF59E3C3FA2C4E29011c2D38, fee: 100, poolType: ArbUtils.PoolType.PANCAKESWAP_V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0xB775272E537cc670C65DC852908aD47015244EaF, fee: 500, poolType: ArbUtils.PoolType.PANCAKESWAP_V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0x6c561B446416E1A00E8E93E221854d6eA4171372, fee: 3000, poolType: ArbUtils.PoolType.V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0xb4CB800910B228ED3d0834cF79D697127BBB00e5, fee: 100, poolType: ArbUtils.PoolType.V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0x56C8989222ed293E3c4a22628d8BCA633cE1eb99, fee: 400, poolType: ArbUtils.PoolType.V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0xE9d76696f8A35e2E2520e3125875C3af23f1E69c, fee: 2500, poolType: ArbUtils.PoolType.PANCAKESWAP_V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0x0b1C2DCbBfA744ebD3fC17fF1A96A1E1Eb4B2d69, fee: 10000, poolType: ArbUtils.PoolType.V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef, fee: 500, poolType: ArbUtils.PoolType.V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0xb94b22332ABf5f89877A14Cc88f2aBC48c34B3Df, fee: 100, poolType: ArbUtils.PoolType.PANCAKESWAP_V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0x3e7586D52A9D07F8611B8ecf6CCc8a689c34a659, fee: 10000, poolType: ArbUtils.PoolType.V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0xE9e25E35aa99A2A60155010802b81A25C45bA185, fee: 100, poolType: ArbUtils.PoolType.V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0xeC558e484cC9f2210714E345298fdc53B253c27D, fee: 3000, poolType: ArbUtils.PoolType.V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0xEdc625B74537eE3a10874f53D170E9c17A906B9c, fee: 3000, poolType: ArbUtils.PoolType.V3});
        specs[idx++] = PoolSpec({base: USDC, pool: 0x36B4869995672DF7E3aFc36BE795Dbb998Bc639d, fee: 10000, poolType: ArbUtils.PoolType.V3});
    }

    function _expectedRounds()
        private
        pure
        returns (RoundExpectation[] memory rounds)
    {
        rounds = new RoundExpectation[](MAX_ROUNDS);
        rounds[0] = RoundExpectation({
            buyPool: 0x56C8989222ed293E3c4a22628d8BCA633cE1eb99,
            sellPool: 0x1C450D7d1FD98A0b04E30deCFc83497b33A4F608,
            profit: 521
        });
        rounds[1] = RoundExpectation({
            buyPool: 0x56C8989222ed293E3c4a22628d8BCA633cE1eb99,
            sellPool: 0x1C450D7d1FD98A0b04E30deCFc83497b33A4F608,
            profit: 301
        });
        rounds[2] = RoundExpectation({
            buyPool: 0x56C8989222ed293E3c4a22628d8BCA633cE1eb99,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224,
            profit: 13_268
        });
        rounds[3] = RoundExpectation({
            buyPool: 0xb4CB800910B228ED3d0834cF79D697127BBB00e5,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224,
            profit: 124_048
        });
        rounds[4] = RoundExpectation({
            buyPool: 0xB775272E537cc670C65DC852908aD47015244EaF,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224,
            profit: 5_391_960
        });
        rounds[5] = RoundExpectation({
            buyPool: 0x72AB388E2E2F6FaceF59E3C3FA2C4E29011c2D38,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224,
            profit: 11_373_898
        });
        rounds[6] = RoundExpectation({
            buyPool: 0x56C8989222ed293E3c4a22628d8BCA633cE1eb99,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224,
            profit: 4_842
        });
        rounds[7] = RoundExpectation({
            buyPool: 0xb4CB800910B228ED3d0834cF79D697127BBB00e5,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224,
            profit: 52_775
        });
        rounds[8] = RoundExpectation({
            buyPool: 0x56C8989222ed293E3c4a22628d8BCA633cE1eb99,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224,
            profit: 2_828
        });
        rounds[9] = RoundExpectation({
            buyPool: 0xB775272E537cc670C65DC852908aD47015244EaF,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224,
            profit: 1_715_161
        });
    }

    function _decodeAttempt(Vm.Log[] memory logs)
        private
        pure
        returns (RoundResult memory result)
    {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == ARB_EVENT_TOPIC) {
                result.tokenA = address(uint160(uint256(logs[i].topics[1])));
                result.tokenB = address(uint160(uint256(logs[i].topics[2])));
                result.buyPool = address(uint160(uint256(logs[i].topics[3])));
                (
                    result.sellPool,
                    result.totalAmountSwapped,
                    result.cumulativeProfit,
                    result.iterations
                ) = abi.decode(logs[i].data, (address, uint256, int256, uint256));
                return result;
            }
        }
        revert("ArbitrageAttempted event missing");
    }

    function _logRound(
        uint256 round,
        RoundResult memory actual,
        RoundExpectation memory expected
    ) private {
        emit log_named_uint("round", round);
        emit log_named_address("tokenA", actual.tokenA);
        emit log_named_address("buyPool", actual.buyPool);
        emit log_named_address("sellPool", actual.sellPool);
        emit log_named_int("profit (raw)", actual.cumulativeProfit);
        emit log_named_int("expected profit", expected.profit);
        emit log_named_uint("iterations (event)", actual.iterations);
        emit log_named_uint("totalAmountSwapped", actual.totalAmountSwapped);
        int256 delta = actual.cumulativeProfit - expected.profit;
        emit log_named_int("profit delta", delta);
        if (actual.buyPool != expected.buyPool) {
            emit log("buyPool mismatch vs expected");
            emit log_named_address("expected buyPool", expected.buyPool);
        }
        if (actual.sellPool != expected.sellPool) {
            emit log("sellPool mismatch vs expected");
            emit log_named_address("expected sellPool", expected.sellPool);
        }
    }

    function _assertRoundMatches(
        RoundResult memory actual,
        RoundExpectation memory expected,
        uint256 round
    ) private pure {
        require(actual.buyPool == expected.buyPool, "buyPool mismatch");
        require(actual.sellPool == expected.sellPool, "sellPool mismatch");
        require(actual.cumulativeProfit == expected.profit, "profit mismatch");
        require(actual.tokenA == USDC, "tokenA mismatch");
    }

    function _toUsdcUnits(int256 amount) private pure returns (int256) {
        return amount;
    }
}
