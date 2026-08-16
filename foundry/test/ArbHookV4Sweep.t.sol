// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbHook} from "../../contracts/ArbHook.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {MorphoERC3156Adapter} from "../../contracts/MorphoERC3156Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../../contracts/interfaces/IWETH9.sol";
import {IUniswapV3Pool} from "../../contracts/interfaces/uniswap/IUniswapV3Pool.sol";
import {ISwapRouter02} from "../../contracts/interfaces/uniswap/ISwapRouter02.sol";
import {IUniswapV4PositionManager} from "../../contracts/interfaces/uniswap/IUniswapV4PositionManager.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

interface IPermit2SweepAllowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract ArbHookV4SweepTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant AAVE_USDC_A_TOKEN = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant V4_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant BENCHMARK_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    uint24 internal constant BENCHMARK_FEE = 500;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q192 = uint256(1) << 192;
    uint256 internal constant SEARCH_POINTS = 8;

    bytes32 internal constant FLASH_SETTLED_TOPIC0 = keccak256(
        "FlashLoanSettled(address,address,address,address,address,uint256,uint256,uint256,int256,uint256,address)"
    );

    struct Config {
        uint256 id;
        address referencePool;
        uint24 referenceFee;
        uint24 poolFee;
        int24 tickSpacing;
        uint256 lpUsdcPerSide;
        uint256 halfRangeTicks;
        uint256 tradeUsdc;
        uint256 maxIterations;
        uint256 principalCapBps;
    }

    struct Batch {
        uint256[] ids;
        address[] referencePools;
        uint256[] referenceFees;
        uint256[] poolFees;
        uint256[] tickSpacings;
        uint256[] lpUsdcPerSide;
        uint256[] halfRangeTicks;
        uint256[] tradeUsdc;
        uint256[] maxIterations;
        uint256[] principalCapBps;
    }

    struct Settlement {
        uint256 principal;
        uint256 totalAmountSwapped;
        uint256 netProfit;
        uint256 iterations;
    }

    struct Backrun {
        address venue;
        uint256 amountIn;
        uint256 profit;
    }

    struct Result {
        uint256 success;
        uint256 errorSelector;
        uint256 id;
        address referencePool;
        uint256 referenceFee;
        uint256 referenceLiquidity;
        uint256 poolFee;
        uint256 tickSpacing;
        uint256 lpUsdcPerSide;
        uint256 halfRangeTicks;
        uint256 tradeUsdc;
        uint256 maxIterations;
        uint256 principalCapBps;
        uint256 v4Liquidity;
        uint256 initialLpWeth;
        uint256 initialLpUsdc;
        uint256 benchmarkWethOut;
        uint256 userWethOut;
        uint256 baselineSwapGas;
        uint256 hookSwapGas;
        uint256 principal;
        uint256 totalAmountSwapped;
        uint256 hookProfit;
        uint256 actualIterations;
        uint256 residualTicksBeforeBackrun;
        address baselineBackrunVenue;
        uint256 baselineBackrunInput;
        uint256 baselineBackrunProfit;
        address residualBackrunVenue;
        uint256 residualBackrunInput;
        uint256 residualBackrunProfit;
        uint256 baselineLpWeth;
        uint256 baselineLpUsdc;
        uint256 hookLpWeth;
        uint256 hookLpUsdc;
        uint256 initialPriceX18;
        uint256 baselineFinalPriceX18;
        uint256 hookFinalPriceX18;
    }

    bool internal forkEnabled;
    ArbHook internal hook;
    ArbitrageLogic internal logic;

    function setUp() public {
        if (!vm.envOr("RUN_V4_SWEEP", false)) return;
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        vm.createSelectFork(rpcUrl, vm.envUint("SWEEP_FORK_BLOCK"));
        forkEnabled = true;

        IPoolManager manager = IPoolManager(V4_POOL_MANAGER);
        logic = new ArbitrageLogic();
        bytes memory constructorArgs = abi.encode(manager, address(this), address(logic));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), Hooks.AFTER_SWAP_FLAG, type(ArbHook).creationCode, constructorArgs);
        hook = new ArbHook{salt: salt}(manager, address(this), address(logic));
        assertEq(address(hook), expected, "mined hook address mismatch");

        MorphoERC3156Adapter adapter = new MorphoERC3156Adapter(MORPHO_BLUE, WETH);
        hook.setLenderForToken(WETH, address(adapter));
        hook.setMaxFlashFeeBpsForToken(WETH, 1);
        hook.setMinNetProfitForToken(WETH, 1);

        vm.deal(address(this), 1_000 ether);
        IWETH9(WETH).deposit{value: 1_000 ether}();
        vm.prank(AAVE_USDC_A_TOKEN);
        assertTrue(IERC20(USDC).transfer(address(this), 2_000_000e6), "USDC funding failed");

        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        IPermit2SweepAllowance(PERMIT2).approve(WETH, V4_POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IPermit2SweepAllowance(PERMIT2).approve(USDC, V4_POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IPermit2SweepAllowance(PERMIT2).approve(WETH, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        IPermit2SweepAllowance(PERMIT2).approve(USDC, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        IERC20(WETH).approve(SWAP_ROUTER, type(uint256).max);
        IERC20(USDC).approve(SWAP_ROUTER, type(uint256).max);
    }

    function testParameterSweep() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_V4_SWEEP=true, SWEEP_FORK_BLOCK, and BASE_RPC_URL");
            return;
        }

        Batch memory batch = _loadBatch();
        uint256 count = batch.ids.length;
        Result[] memory results = new Result[](count);
        uint256 cleanState = vm.snapshotState();

        for (uint256 i; i < count; ++i) {
            if (i != 0) assertTrue(vm.revertToState(cleanState), "clean snapshot restore failed");
            Config memory config = _configAt(batch, i);
            (bool ok, bytes memory data) = address(this).call(abi.encodeCall(this.runScenario, (config)));
            if (ok) {
                results[i] = abi.decode(data, (Result));
            } else {
                results[i].id = config.id;
                results[i].referencePool = config.referencePool;
                results[i].errorSelector = uint256(_revertWord(data));
            }
        }

        assertTrue(vm.revertToState(cleanState), "final clean snapshot restore failed");
        for (uint256 i; i < count; ++i) {
            _emitResult(results[i]);
        }
    }

    function runScenario(Config calldata config) external returns (Result memory result) {
        require(msg.sender == address(this), "self only");
        _validateConfig(config);
        _registerReference(config.referencePool, config.referenceFee);

        (PoolKey memory key, uint256 tokenId, uint256 lpWeth, uint256 lpUsdc, uint256 v4Liquidity) =
            _initializePool(config);
        hook.setFlashPrincipalForToken(WETH, lpWeth * config.principalCapBps / BPS);

        result.success = 1;
        result.id = config.id;
        result.referencePool = config.referencePool;
        result.referenceFee = config.referenceFee;
        result.referenceLiquidity = IUniswapV3Pool(config.referencePool).liquidity();
        result.poolFee = config.poolFee;
        result.tickSpacing = uint24(config.tickSpacing);
        result.lpUsdcPerSide = config.lpUsdcPerSide;
        result.halfRangeTicks = config.halfRangeTicks;
        result.tradeUsdc = config.tradeUsdc;
        result.maxIterations = config.maxIterations;
        result.principalCapBps = config.principalCapBps;
        result.v4Liquidity = v4Liquidity;
        result.initialLpWeth = lpWeth;
        result.initialLpUsdc = lpUsdc;
        result.initialPriceX18 = _wethPriceX18(BENCHMARK_POOL);

        uint256 initialState = vm.snapshotState();
        result.benchmarkWethOut = _swapV3(BENCHMARK_FEE, USDC, WETH, config.tradeUsdc);
        assertTrue(vm.revertToState(initialState), "quote snapshot restore failed");

        hook.setHookMaxIterations(0);
        (result.userWethOut, result.baselineSwapGas) = _swapV4(key, false, config.tradeUsdc, address(0));
        Backrun memory baseline = _bestBackrun(key, config, lpWeth / 2);
        if (baseline.amountIn != 0) baseline.profit = _executeBackrun(key, baseline.venue, baseline.amountIn);
        result.baselineBackrunVenue = baseline.venue;
        result.baselineBackrunInput = baseline.amountIn;
        result.baselineBackrunProfit = baseline.profit;
        result.baselineFinalPriceX18 = _wethPriceX18(BENCHMARK_POOL);
        (result.baselineLpWeth, result.baselineLpUsdc) = _burnPosition(key, tokenId);

        assertTrue(vm.revertToState(initialState), "hook snapshot restore failed");
        hook.setHookMaxIterations(config.maxIterations);
        vm.recordLogs();
        (, result.hookSwapGas) = _swapV4(key, false, config.tradeUsdc, makeAddr("sweep beneficiary"));
        Settlement memory settlement = _extractSettlement(vm.getRecordedLogs());
        result.principal = settlement.principal;
        result.totalAmountSwapped = settlement.totalAmountSwapped;
        result.hookProfit = settlement.netProfit;
        result.actualIterations = settlement.iterations;
        result.residualTicksBeforeBackrun = _remainingSpread(key, config.referencePool);

        hook.setHookMaxIterations(0);
        Backrun memory residual = _bestBackrun(key, config, lpWeth / 2);
        if (residual.amountIn != 0) residual.profit = _executeBackrun(key, residual.venue, residual.amountIn);
        result.residualBackrunVenue = residual.venue;
        result.residualBackrunInput = residual.amountIn;
        result.residualBackrunProfit = residual.profit;
        result.hookFinalPriceX18 = _wethPriceX18(BENCHMARK_POOL);
        (result.hookLpWeth, result.hookLpUsdc) = _burnPosition(key, tokenId);
    }

    function executeBackrunForSweep(PoolKey calldata key, address venue, uint256 wethIn) external returns (uint256) {
        require(msg.sender == address(this), "self only");
        return _executeBackrun(key, venue, wethIn);
    }

    function _initializePool(Config calldata config)
        private
        returns (PoolKey memory key, uint256 tokenId, uint256 lpWeth, uint256 lpUsdc, uint256 liquidity)
    {
        (uint160 sqrtPriceX96, int24 referenceTick,,,,,) = IUniswapV3Pool(config.referencePool).slot0();
        key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: config.poolFee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(hook))
        });

        (int24 tickLower, int24 tickUpper) = _range(referenceTick, config.tickSpacing, config.halfRangeTicks);
        uint256 usdcMax = config.lpUsdcPerSide;
        uint256 wethMax = FullMath.mulDiv(usdcMax, 1e30, _priceFromSqrtX18(sqrtPriceX96));
        uint128 positionLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            wethMax,
            usdcMax
        );
        require(positionLiquidity != 0, "zero position liquidity");

        tokenId = IUniswapV4PositionManager(V4_POSITION_MANAGER).nextTokenId();
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key, tickLower, tickUpper, positionLiquidity, uint128(wethMax), uint128(usdcMax), address(this), bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IUniswapV4PositionManager.initializePool, (key, sqrtPriceX96));
        calls[1] = abi.encodeCall(
            IUniswapV4PositionManager.modifyLiquidities,
            (
                abi.encode(
                    abi.encodePacked(
                        bytes1(uint8(Actions.MINT_POSITION)),
                        bytes1(uint8(Actions.CLOSE_CURRENCY)),
                        bytes1(uint8(Actions.CLOSE_CURRENCY))
                    ),
                    params
                ),
                block.timestamp
            )
        );
        IUniswapV4PositionManager(V4_POSITION_MANAGER).multicall(calls);

        lpWeth = wethBefore - IERC20(WETH).balanceOf(address(this));
        lpUsdc = usdcBefore - IERC20(USDC).balanceOf(address(this));
        liquidity = positionLiquidity;
    }

    function _swapV4(PoolKey memory key, bool zeroForOne, uint256 amountIn, address beneficiary)
        private
        returns (uint256 amountOut, uint256 gasUsed)
    {
        address output = zeroForOne ? USDC : WETH;
        uint256 balanceBefore = IERC20(output).balanceOf(address(this));
        bytes memory hookData = beneficiary == address(0) ? bytes("") : abi.encodePacked(beneficiary);
        IV4Router.ExactInputSingleParams memory swapParams =
            IV4Router.ExactInputSingleParams(key, zeroForOne, uint128(amountIn), 1, hookData);
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(swapParams);
        actionParams[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1, amountIn);
        actionParams[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, uint256(1));

        bytes[] memory commandInputs = new bytes[](1);
        commandInputs[0] = abi.encode(
            abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                bytes1(uint8(Actions.SETTLE_ALL)),
                bytes1(uint8(Actions.TAKE_ALL))
            ),
            actionParams
        );
        IUniversalRouter(UNIVERSAL_ROUTER)
            .execute(abi.encodePacked(bytes1(uint8(Commands.V4_SWAP))), commandInputs, block.timestamp);
        gasUsed = vm.lastCallGas().gasTotalUsed;
        amountOut = IERC20(output).balanceOf(address(this)) - balanceBefore;
    }

    function _swapV3(uint24 fee, address tokenIn, address tokenOut, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        amountOut = ISwapRouter02(SWAP_ROUTER)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    function _bestBackrun(PoolKey memory key, Config calldata config, uint256 maxAmount)
        private
        returns (Backrun memory best)
    {
        best = _bestBackrunAtVenue(key, config.referencePool, maxAmount);
        if (config.referencePool != BENCHMARK_POOL) {
            Backrun memory benchmark = _bestBackrunAtVenue(key, BENCHMARK_POOL, maxAmount);
            if (benchmark.profit > best.profit) best = benchmark;
        }
    }

    function _bestBackrunAtVenue(PoolKey memory key, address venue, uint256 maxAmount)
        private
        returns (Backrun memory best)
    {
        if (maxAmount == 0) return best;
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i <= SEARCH_POINTS; ++i) {
            uint256 candidate = maxAmount >> i;
            if (candidate == 0) break;
            uint256 profit = _probeBackrun(snapshot, key, venue, candidate);
            if (profit > best.profit) {
                best = Backrun({venue: venue, amountIn: candidate, profit: profit});
            }
        }
        if (best.amountIn == 0) return best;

        uint256 lower = best.amountIn / 2;
        uint256 upper = best.amountIn * 2 < maxAmount ? best.amountIn * 2 : maxAmount;
        for (uint256 round; round < 2; ++round) {
            uint256 step = (upper - lower) / SEARCH_POINTS;
            if (step == 0) break;
            for (uint256 i; i <= SEARCH_POINTS; ++i) {
                uint256 candidate = lower + step * i;
                uint256 profit = _probeBackrun(snapshot, key, venue, candidate);
                if (profit > best.profit) {
                    best = Backrun({venue: venue, amountIn: candidate, profit: profit});
                }
            }
            lower = best.amountIn > step ? best.amountIn - step : 1;
            upper = best.amountIn + step < maxAmount ? best.amountIn + step : maxAmount;
        }
    }

    function _probeBackrun(uint256 snapshot, PoolKey memory key, address venue, uint256 wethIn)
        private
        returns (uint256 profit)
    {
        (bool ok, bytes memory data) =
            address(this).call(abi.encodeCall(this.executeBackrunForSweep, (key, venue, wethIn)));
        if (ok) profit = abi.decode(data, (uint256));
        assertTrue(vm.revertToState(snapshot), "backrun snapshot restore failed");
    }

    function _executeBackrun(PoolKey memory key, address venue, uint256 wethIn) private returns (uint256 profit) {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        (uint256 usdcOut,) = _swapV4(key, true, wethIn, address(0));
        uint24 venueFee = IUniswapV3Pool(venue).fee();
        _swapV3(venueFee, USDC, WETH, usdcOut);
        uint256 wethAfter = IERC20(WETH).balanceOf(address(this));
        if (wethAfter > wethBefore) profit = wethAfter - wethBefore;
    }

    function _burnPosition(PoolKey memory key, uint256 tokenId) private returns (uint256 wethOut, uint256 usdcOut) {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        IUniswapV4PositionManager(V4_POSITION_MANAGER)
            .modifyLiquidities(
                abi.encode(
                    abi.encodePacked(bytes1(uint8(Actions.BURN_POSITION)), bytes1(uint8(Actions.TAKE_PAIR))), params
                ),
                block.timestamp
            );
        wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
        usdcOut = IERC20(USDC).balanceOf(address(this)) - usdcBefore;
    }

    function _registerReference(address referencePool, uint24 referenceFee) private {
        address[] memory pools = new address[](1);
        pools[0] = referencePool;
        uint24[] memory fees = new uint24[](1);
        fees[0] = referenceFee;
        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](1);
        types[0] = ArbUtils.PoolType.V3;
        hook.addPools(WETH, pools, fees, types);
    }

    function _range(int24 center, int24 spacing, uint256 halfRangeTicks)
        private
        pure
        returns (int24 lower, int24 upper)
    {
        if (halfRangeTicks == 0) {
            return (TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing));
        }
        int24 width = int24(int256(halfRangeTicks));
        lower = _floorToSpacing(center - width, spacing);
        upper = _ceilToSpacing(center + width, spacing);
        require(lower < center && upper > center, "range misses current tick");
    }

    function _floorToSpacing(int24 tick, int24 spacing) private pure returns (int24 aligned) {
        int24 remainder = tick % spacing;
        aligned = tick - remainder;
        if (remainder < 0) aligned -= spacing;
    }

    function _ceilToSpacing(int24 tick, int24 spacing) private pure returns (int24 aligned) {
        int24 remainder = tick % spacing;
        aligned = tick - remainder;
        if (remainder > 0) aligned += spacing;
    }

    function _remainingSpread(PoolKey memory key, address referencePool) private view returns (uint256) {
        (, int24 v4Tick,,) = IPoolManager(V4_POOL_MANAGER).getSlot0(key.toId());
        (, int24 externalTick,,,,,) = IUniswapV3Pool(referencePool).slot0();
        int256 spread = int256(v4Tick) - int256(externalTick);
        return uint256(spread < 0 ? -spread : spread);
    }

    function _wethPriceX18(address pool) private view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        return _priceFromSqrtX18(sqrtPriceX96);
    }

    function _priceFromSqrtX18(uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        uint256 quotient = FullMath.mulDiv(sqrtPrice, sqrtPrice, Q192);
        uint256 remainder = mulmod(sqrtPrice, sqrtPrice, Q192);
        return quotient * 1e30 + FullMath.mulDiv(remainder, 1e30, Q192);
    }

    function _extractSettlement(Vm.Log[] memory entries) private pure returns (Settlement memory settled) {
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length == 4 && entries[i].topics[0] == FLASH_SETTLED_TOPIC0) {
                int256 netProfit;
                (,, settled.principal, settled.totalAmountSwapped,, netProfit, settled.iterations,) = abi.decode(
                    entries[i].data, (address, address, uint256, uint256, uint256, int256, uint256, address)
                );
                if (netProfit > 0) settled.netProfit = uint256(netProfit);
                return settled;
            }
        }
    }

    function _loadBatch() private view returns (Batch memory batch) {
        batch.ids = vm.envUint("SWEEP_IDS", ",");
        batch.referencePools = vm.envAddress("SWEEP_REFERENCE_POOLS", ",");
        batch.referenceFees = vm.envUint("SWEEP_REFERENCE_FEES", ",");
        batch.poolFees = vm.envUint("SWEEP_POOL_FEES", ",");
        batch.tickSpacings = vm.envUint("SWEEP_TICK_SPACINGS", ",");
        batch.lpUsdcPerSide = vm.envUint("SWEEP_LP_USDC_PER_SIDE", ",");
        batch.halfRangeTicks = vm.envUint("SWEEP_HALF_RANGE_TICKS", ",");
        batch.tradeUsdc = vm.envUint("SWEEP_TRADE_USDC", ",");
        batch.maxIterations = vm.envUint("SWEEP_MAX_ITERATIONS", ",");
        batch.principalCapBps = vm.envUint("SWEEP_PRINCIPAL_CAP_BPS", ",");

        uint256 count = batch.ids.length;
        require(count > 0, "empty sweep");
        require(batch.referencePools.length == count, "referencePools length");
        require(batch.referenceFees.length == count, "referenceFees length");
        require(batch.poolFees.length == count, "poolFees length");
        require(batch.tickSpacings.length == count, "tickSpacings length");
        require(batch.lpUsdcPerSide.length == count, "lpUsdcPerSide length");
        require(batch.halfRangeTicks.length == count, "halfRangeTicks length");
        require(batch.tradeUsdc.length == count, "tradeUsdc length");
        require(batch.maxIterations.length == count, "maxIterations length");
        require(batch.principalCapBps.length == count, "principalCapBps length");
    }

    function _configAt(Batch memory batch, uint256 i) private pure returns (Config memory config) {
        config = Config({
            id: batch.ids[i],
            referencePool: batch.referencePools[i],
            referenceFee: uint24(batch.referenceFees[i]),
            poolFee: uint24(batch.poolFees[i]),
            tickSpacing: int24(int256(batch.tickSpacings[i])),
            lpUsdcPerSide: batch.lpUsdcPerSide[i],
            halfRangeTicks: batch.halfRangeTicks[i],
            tradeUsdc: batch.tradeUsdc[i],
            maxIterations: batch.maxIterations[i],
            principalCapBps: batch.principalCapBps[i]
        });
    }

    function _validateConfig(Config calldata config) private view {
        IUniswapV3Pool referencePool = IUniswapV3Pool(config.referencePool);
        require(referencePool.token0() == WETH && referencePool.token1() == USDC, "reference pair");
        require(referencePool.fee() == config.referenceFee, "reference fee");
        require(config.poolFee > 0 && config.poolFee < 1_000_000, "pool fee");
        require(config.tickSpacing > 0 && config.tickSpacing <= 16_383, "tick spacing");
        require(config.lpUsdcPerSide > 0 && config.tradeUsdc > 0, "zero amount");
        require(config.maxIterations > 0 && config.principalCapBps > 0 && config.principalCapBps <= BPS, "execution");
        require(config.halfRangeTicks <= uint256(uint24(type(int24).max)), "range width");
    }

    function _emitResult(Result memory result) private {
        bytes memory line = abi.encodePacked("SWEEP_RESULT|", vm.toString(result.success));
        line = _append(line, result.errorSelector);
        line = _append(line, result.id);
        line = _append(line, result.referencePool);
        line = _append(line, result.referenceFee);
        line = _append(line, result.referenceLiquidity);
        line = _append(line, result.poolFee);
        line = _append(line, result.tickSpacing);
        line = _append(line, result.lpUsdcPerSide);
        line = _append(line, result.halfRangeTicks);
        line = _append(line, result.tradeUsdc);
        line = _append(line, result.maxIterations);
        line = _append(line, result.principalCapBps);
        line = _append(line, result.v4Liquidity);
        line = _append(line, result.initialLpWeth);
        line = _append(line, result.initialLpUsdc);
        line = _append(line, result.benchmarkWethOut);
        line = _append(line, result.userWethOut);
        line = _append(line, result.baselineSwapGas);
        line = _append(line, result.hookSwapGas);
        line = _append(line, result.principal);
        line = _append(line, result.totalAmountSwapped);
        line = _append(line, result.hookProfit);
        line = _append(line, result.actualIterations);
        line = _append(line, result.residualTicksBeforeBackrun);
        line = _append(line, result.baselineBackrunVenue);
        line = _append(line, result.baselineBackrunInput);
        line = _append(line, result.baselineBackrunProfit);
        line = _append(line, result.residualBackrunVenue);
        line = _append(line, result.residualBackrunInput);
        line = _append(line, result.residualBackrunProfit);
        line = _append(line, result.baselineLpWeth);
        line = _append(line, result.baselineLpUsdc);
        line = _append(line, result.hookLpWeth);
        line = _append(line, result.hookLpUsdc);
        line = _append(line, result.initialPriceX18);
        line = _append(line, result.baselineFinalPriceX18);
        line = _append(line, result.hookFinalPriceX18);
        emit log_string(string(line));
    }

    function _append(bytes memory line, uint256 value) private pure returns (bytes memory) {
        return abi.encodePacked(line, "|", vm.toString(value));
    }

    function _append(bytes memory line, address value) private pure returns (bytes memory) {
        return abi.encodePacked(line, "|", vm.toString(value));
    }

    function _revertWord(bytes memory data) private pure returns (bytes32 word) {
        if (data.length < 4) return bytes32(0);
        assembly ("memory-safe") {
            word := mload(add(data, 0x20))
        }
    }
}
