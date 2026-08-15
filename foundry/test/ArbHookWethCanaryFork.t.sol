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
import {IUniswapV4PositionManager} from "../../contracts/interfaces/uniswap/IUniswapV4PositionManager.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract ArbHookWethCanaryForkTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant AAVE_USDC_A_TOKEN = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant V4_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant UNISWAP_WETH_USDC_500 = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    uint256 internal constant PRINCIPAL_CAP = 1 ether;
    uint256 internal constant MIN_NET_PROFIT = 0.0001 ether;
    uint256 internal constant MIN_TRIGGER_USDC = 49e6;
    bytes32 internal constant FLASH_SETTLED_TOPIC0 = keccak256(
        "FlashLoanSettled(address,address,address,address,address,uint256,uint256,uint256,int256,uint256,address)"
    );

    struct Settlement {
        address tokenA;
        address tokenB;
        address buyPool;
        address sellPool;
        uint256 principal;
        uint256 totalAmountSwapped;
        uint256 fee;
        int256 netProfit;
        uint256 iterations;
        address beneficiary;
    }

    bool internal forkEnabled;
    ArbHook internal hook;
    MorphoERC3156Adapter internal adapter;
    PoolKey internal triggerKey;
    uint256 internal triggerPositionTokenId;
    uint256 internal v4WethDeposited;
    uint256 internal v4UsdcDeposited;

    function setUp() public {
        if (!vm.envOr("RUN_WETH_CANARY_FORK", false)) return;

        string memory rpcUrl;
        try vm.envString("BASE_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {
            return;
        }
        if (bytes(rpcUrl).length == 0) return;

        uint256 forkBlock = vm.envOr("WETH_CANARY_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpcUrl);
        else vm.createSelectFork(rpcUrl, forkBlock);
        forkEnabled = true;

        IPoolManager manager = IPoolManager(V4_POOL_MANAGER);
        ArbitrageLogic logic = new ArbitrageLogic();
        bytes memory constructorArgs = abi.encode(manager, address(this), address(logic));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), Hooks.AFTER_SWAP_FLAG, type(ArbHook).creationCode, constructorArgs);
        hook = new ArbHook{salt: salt}(manager, address(this), address(logic));
        assertEq(address(hook), expected, "mined hook address mismatch");

        adapter = new MorphoERC3156Adapter(MORPHO_BLUE, WETH);
        hook.setLenderForToken(WETH, address(adapter));
        hook.setFlashPrincipalForToken(WETH, PRINCIPAL_CAP);
        hook.setMaxFlashFeeBpsForToken(WETH, 1);
        hook.setMinNetProfitForToken(WETH, MIN_NET_PROFIT);
        hook.setHookMaxIterations(1);

        _registerExternalWethUsdcPool();
        _initializeTriggerPool();
        hook.setMinTriggerAmount(triggerKey.toId(), false, MIN_TRIGGER_USDC);
    }

    function testSwapCreatesAndCapturesItsOwnWethArbitrage() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_WETH_CANARY_FORK=true and BASE_RPC_URL");
            return;
        }

        uint256 lenderBalanceBefore = IERC20(WETH).balanceOf(MORPHO_BLUE);
        assertGt(lenderBalanceBefore, PRINCIPAL_CAP, "insufficient Morpho WETH liquidity");

        address beneficiary = makeAddr("WETH canary beneficiary");
        uint256 snapshot = vm.snapshotState();
        hook.setHookMaxIterations(0);
        uint256 baselineGasBefore = gasleft();
        _swapTriggerPool(100e6, beneficiary);
        uint256 baselineGasUsed = baselineGasBefore - gasleft();
        vm.revertToState(snapshot);

        uint256 swapOutputBefore = IERC20(WETH).balanceOf(address(this));
        vm.recordLogs();
        uint256 gasBefore = gasleft();
        _swapTriggerPool(100e6, beneficiary);
        uint256 gasUsed = gasBefore - gasleft();
        assertGt(gasUsed, baselineGasUsed, "enabled hook used no incremental gas");

        Settlement memory settled = _extractSettlement(vm.getRecordedLogs());
        assertEq(settled.tokenA, WETH, "flash principal must be WETH");
        assertEq(settled.tokenB, USDC, "wrong arbitrage market");
        assertEq(settled.buyPool, UNISWAP_WETH_USDC_500, "wrong external pool");
        assertEq(settled.sellPool, V4_POOL_MANAGER, "triggering v4 pool was not traded");
        assertGt(settled.principal, 0, "adaptive sizing returned zero");
        assertLe(settled.principal, PRINCIPAL_CAP, "principal exceeded canary cap");
        assertGt(settled.totalAmountSwapped, 0, "no arbitrage input was swapped");
        assertEq(settled.fee, 0, "Morpho charged a fee");
        assertGt(settled.netProfit, 0, "arbitrage was not profitable");
        assertEq(settled.beneficiary, beneficiary, "profit recipient mismatch");
        assertEq(IERC20(WETH).balanceOf(beneficiary), uint256(settled.netProfit), "beneficiary WETH mismatch");
        assertGt(IERC20(WETH).balanceOf(address(this)), swapOutputBefore, "trigger swap returned no WETH");
        assertEq(IERC20(WETH).balanceOf(MORPHO_BLUE), lenderBalanceBefore, "Morpho was not repaid");
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0, "hook retained WETH");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook retained USDC");

        _removeTriggerLiquidity();

        emit log_named_uint("Base fork block", block.number);
        emit log_named_decimal_uint("borrowed WETH", settled.principal, 18);
        emit log_named_decimal_uint("beneficiary profit WETH", uint256(settled.netProfit), 18);
        emit log_named_uint("disabled trigger gas", baselineGasUsed);
        emit log_named_uint("trigger transaction gas", gasUsed);
        emit log_named_uint("incremental arbitrage gas", gasUsed - baselineGasUsed);
    }

    /// @notice Measures whether the CANARY OPERATOR is net ahead, not just whether
    ///         the hook settles. In the real canary one wallet is the liquidity
    ///         provider, the swapper and the beneficiary, so the arbitrage profit
    ///         and the liquidity it is extracted from land in the same pocket.
    /// @dev Runs the identical add/swap/remove sequence twice from one snapshot,
    ///      with the hook disabled and then enabled with the operator as
    ///      beneficiary, and compares the operator's whole token position.
    function testSelfContainedOperatorNetPosition() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_WETH_CANARY_FORK=true and BASE_RPC_URL");
            return;
        }

        uint256 snapshot = vm.snapshotState();

        hook.setHookMaxIterations(0);
        _swapTriggerPool(100e6, address(this));
        _removeTriggerLiquidity();
        uint256 disabledWeth = IERC20(WETH).balanceOf(address(this));
        uint256 disabledUsdc = IERC20(USDC).balanceOf(address(this));

        vm.revertToState(snapshot);

        hook.setHookMaxIterations(1);
        _swapTriggerPool(100e6, address(this));
        _removeTriggerLiquidity();
        uint256 enabledWeth = IERC20(WETH).balanceOf(address(this));
        uint256 enabledUsdc = IERC20(USDC).balanceOf(address(this));

        emit log("--- operator position after add, swap, remove ---");
        emit log_named_decimal_uint("hook disabled: WETH", disabledWeth, 18);
        emit log_named_uint("hook disabled: USDC", disabledUsdc);
        emit log_named_decimal_uint("hook enabled : WETH", enabledWeth, 18);
        emit log_named_uint("hook enabled : USDC", enabledUsdc);

        // The counter-swap changes the pool composition returned on withdrawal, so
        // both legs move. Value them together at the external reference price.
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(UNISWAP_WETH_USDC_500).slot0();
        // WETH is token0 in this pool: raw USDC per raw WETH = sqrtP^2 / 2^192.
        uint256 usdcPerWeth = FullMath.mulDiv(
            FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96),
            1e18,
            1 << 96
        );
        emit log_named_uint("reference price: raw USDC per 1e18 WETH", usdcPerWeth);

        uint256 disabledValue = disabledUsdc + FullMath.mulDiv(disabledWeth, usdcPerWeth, 1e18);
        uint256 enabledValue = enabledUsdc + FullMath.mulDiv(enabledWeth, usdcPerWeth, 1e18);
        emit log_named_uint("hook disabled: total value (raw USDC)", disabledValue);
        emit log_named_uint("hook enabled : total value (raw USDC)", enabledValue);

        if (enabledValue >= disabledValue) {
            emit log_named_uint("operator NET GAIN (raw USDC)", enabledValue - disabledValue);
        } else {
            emit log_named_uint("operator NET LOSS (raw USDC)", disabledValue - enabledValue);
        }
        emit log("Gas is excluded. The arbitrage is funded by the v4 pool the operator");
        emit log("also owns, so this difference, not the settlement event, is the result.");
    }

    function testSweepSwapSizeAgainstLiveReference() public {
        if (!vm.envOr("RUN_WETH_CANARY_SWEEP", false)) {
            vm.skip(true, "set RUN_WETH_CANARY_FORK=true and RUN_WETH_CANARY_SWEEP=true");
            return;
        }
        if (!forkEnabled) revert("set RUN_WETH_CANARY_FORK=true and BASE_RPC_URL");

        uint256 sweepMinProfit = vm.envOr("WETH_CANARY_SWEEP_MIN_PROFIT_WEI", uint256(1));
        uint256 sweepMinTrigger = vm.envOr("WETH_CANARY_SWEEP_MIN_TRIGGER_AMOUNT_RAW", uint256(0));
        hook.setMinNetProfitForToken(WETH, sweepMinProfit);
        hook.setMinTriggerAmount(triggerKey.toId(), false, sweepMinTrigger);
        uint256 gasPriceWei = vm.envOr("WETH_CANARY_SIM_GAS_PRICE_WEI", uint256(0));
        uint128[23] memory amounts = [
            uint128(1e6),
            2e6,
            2_250_000,
            2_500_000,
            2_750_000,
            3e6,
            4e6,
            5e6,
            6e6,
            8e6,
            8_500_000,
            9e6,
            9_500_000,
            10e6,
            15e6,
            20e6,
            30e6,
            40e6,
            48e6,
            49e6,
            50e6,
            75e6,
            100e6
        ];

        emit log_named_uint("Base fork block", block.number);
        emit log_named_uint("sweep minimum profit wei", sweepMinProfit);
        emit log_named_uint("sweep minimum trigger amount raw", sweepMinTrigger);
        emit log_named_uint("execution gas price wei", gasPriceWei);
        emit log_named_decimal_uint("v4 WETH deposited", v4WethDeposited, 18);
        emit log_named_decimal_uint("v4 USDC deposited", v4UsdcDeposited, 6);
        for (uint256 i; i < amounts.length; ++i) {
            (bool settled, Settlement memory result, uint256 disabledGas, uint256 enabledGas) =
                _simulateTriggerSize(amounts[i]);
            uint256 incrementalGas = enabledGas > disabledGas ? enabledGas - disabledGas : 0;

            if (sweepMinTrigger != 0 && amounts[i] < sweepMinTrigger) {
                assertFalse(settled, "below-minimum trigger settled");
                assertLt(incrementalGas, 10_000, "below-minimum trigger entered arb path");
            }

            emit log_string("---");
            emit log_named_decimal_uint("trigger USDC", amounts[i], 6);
            emit log_named_uint("disabled gas", disabledGas);
            emit log_named_uint("enabled gas", enabledGas);
            emit log_named_uint("incremental gas", incrementalGas);
            if (!settled) {
                emit log_string("no profitable settlement");
                continue;
            }

            uint256 profit = uint256(result.netProfit);
            uint256 incrementalCost = incrementalGas * gasPriceWei;
            emit log_named_decimal_uint("borrowed WETH", result.principal, 18);
            emit log_named_decimal_uint("profit WETH", profit, 18);
            emit log_named_decimal_uint("incremental execution cost WETH", incrementalCost, 18);
            emit log_named_decimal_uint(
                "profit after incremental execution cost WETH",
                profit > incrementalCost ? profit - incrementalCost : 0,
                18
            );
            emit log_named_uint("clears 0.0001 WETH canary floor", profit >= MIN_NET_PROFIT ? 1 : 0);
        }
    }

    function _simulateTriggerSize(uint128 amountIn)
        private
        returns (bool settled, Settlement memory result, uint256 disabledGas, uint256 enabledGas)
    {
        address beneficiary = makeAddr("WETH canary sweep beneficiary");
        uint256 disabledSnapshot = vm.snapshotState();
        hook.setHookMaxIterations(0);
        uint256 gasBefore = gasleft();
        _swapTriggerPool(amountIn, beneficiary);
        disabledGas = gasBefore - gasleft();
        vm.revertToState(disabledSnapshot);

        uint256 enabledSnapshot = vm.snapshotState();
        vm.recordLogs();
        gasBefore = gasleft();
        _swapTriggerPool(amountIn, beneficiary);
        enabledGas = gasBefore - gasleft();
        (settled, result) = _tryExtractSettlement(vm.getRecordedLogs());
        vm.revertToState(enabledSnapshot);
    }

    function _registerExternalWethUsdcPool() private {
        address[] memory pools = new address[](1);
        pools[0] = UNISWAP_WETH_USDC_500;

        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;

        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](1);
        types[0] = ArbUtils.PoolType.V3;
        hook.addPools(WETH, pools, fees, types);
    }

    function _initializeTriggerPool() private {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(UNISWAP_WETH_USDC_500).slot0();
        triggerKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        vm.deal(address(this), 200 ether);
        IWETH9(WETH).deposit{value: 200 ether}();
        _pullUsdc(50_000e6);

        uint256 wethMax = 2 ether;
        uint256 usdcMax = 5_000e6;
        int24 tickLower = TickMath.minUsableTick(triggerKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(triggerKey.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            wethMax,
            usdcMax
        );

        IERC20(WETH).approve(PERMIT2, wethMax);
        IERC20(USDC).approve(PERMIT2, usdcMax);
        IPermit2Allowance(PERMIT2).approve(WETH, V4_POSITION_MANAGER, uint160(wethMax), type(uint48).max);
        IPermit2Allowance(PERMIT2).approve(USDC, V4_POSITION_MANAGER, uint160(usdcMax), type(uint48).max);

        IUniswapV4PositionManager positionManager = IUniswapV4PositionManager(V4_POSITION_MANAGER);
        triggerPositionTokenId = positionManager.nextTokenId();
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(triggerKey, tickLower, tickUpper, liquidity, wethMax, usdcMax, address(this), bytes(""));
        params[1] = abi.encode(triggerKey.currency0);
        params[2] = abi.encode(triggerKey.currency1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IUniswapV4PositionManager.initializePool, (triggerKey, sqrtPriceX96));
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
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        positionManager.multicall(calls);
        v4WethDeposited = wethBefore - IERC20(WETH).balanceOf(address(this));
        v4UsdcDeposited = usdcBefore - IERC20(USDC).balanceOf(address(this));
        assertEq(
            positionManager.ownerOf(triggerPositionTokenId), address(this), "canonical PositionManager mint failed"
        );
    }

    function _removeTriggerLiquidity() private {
        IUniswapV4PositionManager positionManager = IUniswapV4PositionManager(V4_POSITION_MANAGER);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(triggerPositionTokenId, uint128(1), uint128(1), bytes(""));
        params[1] = abi.encode(triggerKey.currency0);
        params[2] = abi.encode(triggerKey.currency1);
        positionManager.modifyLiquidities(
            abi.encode(
                abi.encodePacked(
                    bytes1(uint8(Actions.BURN_POSITION)),
                    bytes1(uint8(Actions.CLOSE_CURRENCY)),
                    bytes1(uint8(Actions.CLOSE_CURRENCY))
                ),
                params
            ),
            block.timestamp
        );

        assertGt(IERC20(WETH).balanceOf(address(this)), wethBefore, "LP WETH was not returned");
        assertGt(IERC20(USDC).balanceOf(address(this)), usdcBefore, "LP USDC was not returned");
    }

    function _swapTriggerPool(uint128 amountIn, address beneficiary) private {
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        IPermit2Allowance(PERMIT2).approve(USDC, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);

        IV4Router.ExactInputSingleParams memory swapParams =
            IV4Router.ExactInputSingleParams(triggerKey, false, amountIn, 1, abi.encodePacked(beneficiary));
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(swapParams);
        actionParams[1] = abi.encode(triggerKey.currency1, uint256(amountIn));
        actionParams[2] = abi.encode(triggerKey.currency0, uint256(1));

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
    }

    function _pullUsdc(uint256 amount) private {
        vm.startPrank(AAVE_USDC_A_TOKEN);
        assertTrue(IERC20(USDC).transfer(address(this), amount), "USDC funding failed");
        vm.stopPrank();
    }

    function _extractSettlement(Vm.Log[] memory entries) private pure returns (Settlement memory settled) {
        (bool found, Settlement memory result) = _tryExtractSettlement(entries);
        if (!found) revert("FlashLoanSettled not emitted");
        return result;
    }

    function _tryExtractSettlement(Vm.Log[] memory entries)
        private
        pure
        returns (bool found, Settlement memory settled)
    {
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length == 4 && entries[i].topics[0] == FLASH_SETTLED_TOPIC0) {
                settled.tokenA = address(uint160(uint256(entries[i].topics[2])));
                settled.tokenB = address(uint160(uint256(entries[i].topics[3])));
                (
                    settled.buyPool,
                    settled.sellPool,
                    settled.principal,
                    settled.totalAmountSwapped,
                    settled.fee,
                    settled.netProfit,
                    settled.iterations,
                    settled.beneficiary
                ) = abi.decode(entries[i].data, (address, address, uint256, uint256, uint256, int256, uint256, address));
                return (true, settled);
            }
        }
    }
}
