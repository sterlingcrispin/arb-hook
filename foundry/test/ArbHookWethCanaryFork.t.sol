// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbHook} from "../../contracts/ArbHook.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {MorphoERC3156Adapter} from "../../contracts/MorphoERC3156Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../../contracts/interfaces/IWETH9.sol";
import {ISwapRouter02} from "../../contracts/interfaces/uniswap/ISwapRouter02.sol";
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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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

    struct EconomicOutcome {
        uint256 lpValue;
        uint256 swapperValue;
        uint256 beneficiaryValue;
        uint256 searcherValue;
        uint256 triggerGas;
        uint256 backrunGas;
    }

    bool internal forkEnabled;
    ArbHook internal hook;
    MorphoERC3156Adapter internal adapter;
    PoolKey internal triggerKey;
    uint256 internal triggerPositionTokenId;
    uint256 internal v4WethDeposited;
    uint256 internal v4UsdcDeposited;
    uint256 internal principalCap;

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
        principalCap = vm.envOr("WETH_FLASH_PRINCIPAL_CAP_WEI", uint256(PRINCIPAL_CAP));
        hook.setLenderForToken(WETH, address(adapter));
        hook.setFlashPrincipalForToken(WETH, principalCap);
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
        assertGt(lenderBalanceBefore, principalCap, "insufficient Morpho WETH liquidity");

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
        assertLe(settled.principal, principalCap, "principal exceeded canary cap");
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

    function testCanonicalRouterEmptyHookDataPaysOriginalCaller() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_WETH_CANARY_FORK=true and BASE_RPC_URL");
            return;
        }

        address swapper = makeAddr("empty hook data swapper");
        assertTrue(IERC20(USDC).transfer(swapper, 100e6), "swapper funding failed");
        uint256 lenderBalanceBefore = IERC20(WETH).balanceOf(MORPHO_BLUE);
        vm.recordLogs();
        _swapTriggerPoolWithHookData(100e6, bytes(""), swapper);
        Settlement memory settled = _extractSettlement(vm.getRecordedLogs());

        assertGt(settled.netProfit, 0, "arbitrage was not profitable");
        assertEq(settled.beneficiary, swapper, "router did not expose original caller");
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0, "hook retained caller profit");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook retained USDC");
        assertEq(IERC20(WETH).balanceOf(MORPHO_BLUE), lenderBalanceBefore, "Morpho was not repaid");
    }

    function testCanIncreaseAndRemoveCanaryLiquidity() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_WETH_CANARY_FORK=true and BASE_RPC_URL");
            return;
        }

        IUniswapV4PositionManager positionManager = IUniswapV4PositionManager(V4_POSITION_MANAGER);
        uint128 liquidityBefore = positionManager.getPositionLiquidity(triggerPositionTokenId);
        _increaseTriggerLiquidity(0.05 ether, 100e6);
        assertGt(
            positionManager.getPositionLiquidity(triggerPositionTokenId), liquidityBefore, "liquidity did not increase"
        );
        _removeTriggerLiquidity();
    }

    /// @notice Compares leaving the swap-created edge open, paying it to an
    ///         external backrunner, and returning it through the hook.
    /// @dev Every case starts from identical state and uses distinct LP, swapper,
    ///      beneficiary, and searcher accounts. The external backrunner trades the
    ///      same realized WETH amount as the hook.
    function testHookRedistributesExternalBackrunnerValue() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_WETH_CANARY_FORK=true and BASE_RPC_URL");
            return;
        }

        address swapper = makeAddr("economic comparison swapper");
        address beneficiary = makeAddr("economic comparison beneficiary");
        address searcher = makeAddr("economic comparison searcher");
        assertTrue(IERC20(USDC).transfer(swapper, 100e6), "swapper funding failed");
        assertTrue(IERC20(WETH).transfer(searcher, 1 ether), "searcher funding failed");

        uint256 usdcPerWeth = _referenceUsdcPerWeth();
        uint256 initialSnapshot = vm.snapshotState();

        vm.recordLogs();
        uint256 gasBefore = gasleft();
        _swapTriggerPoolFrom(100e6, beneficiary, swapper);
        uint256 hookGas = gasBefore - gasleft();
        Settlement memory settled = _extractSettlement(vm.getRecordedLogs());
        assertEq(settled.fee, 0, "matched backrun assumes zero lender fee");
        _removeTriggerLiquidity();
        EconomicOutcome memory hookCase =
            _captureEconomicOutcome(swapper, beneficiary, searcher, usdcPerWeth, hookGas, 0);

        vm.revertToState(initialSnapshot);
        uint256 noBackrunSnapshot = vm.snapshotState();

        hook.setHookMaxIterations(0);
        gasBefore = gasleft();
        _swapTriggerPoolFrom(100e6, beneficiary, swapper);
        uint256 noBackrunGas = gasBefore - gasleft();
        _removeTriggerLiquidity();
        EconomicOutcome memory noBackrun =
            _captureEconomicOutcome(swapper, beneficiary, searcher, usdcPerWeth, noBackrunGas, 0);

        vm.revertToState(noBackrunSnapshot);

        hook.setHookMaxIterations(0);
        gasBefore = gasleft();
        _swapTriggerPoolFrom(100e6, beneficiary, swapper);
        uint256 externalTriggerGas = gasBefore - gasleft();
        assertLe(settled.totalAmountSwapped, type(uint128).max, "backrun size exceeds router type");
        uint256 backrunGas = _externalBackrun(searcher, uint128(settled.totalAmountSwapped));
        _removeTriggerLiquidity();
        EconomicOutcome memory externalCase = _captureEconomicOutcome(
            swapper, beneficiary, searcher, usdcPerWeth, externalTriggerGas, backrunGas
        );

        uint256 rebate = hookCase.beneficiaryValue - noBackrun.beneficiaryValue;
        uint256 searcherProfit = externalCase.searcherValue - noBackrun.searcherValue;
        uint256 noBackrunTotal = _combinedValue(noBackrun);
        uint256 hookTotal = _combinedValue(hookCase);
        uint256 externalTotal = _combinedValue(externalCase);

        assertEq(hookCase.swapperValue, noBackrun.swapperValue, "hook changed normal swap output");
        assertEq(externalCase.swapperValue, noBackrun.swapperValue, "backrun changed settled swap output");
        assertLt(hookCase.lpValue, noBackrun.lpValue, "hook did not draw value from LP");
        assertLt(externalCase.lpValue, noBackrun.lpValue, "backrunner did not draw value from LP");
        assertGt(rebate, 0, "hook paid no beneficiary rebate");
        assertGt(searcherProfit, 0, "external backrunner made no profit");
        assertApproxEqAbs(rebate, searcherProfit, 10, "hook and backrunner captured different edges");
        assertApproxEqAbs(hookCase.lpValue, externalCase.lpValue, 10, "LP outcomes diverged");
        assertLt(hookTotal, noBackrunTotal, "hook created value without external cost");
        assertLt(externalTotal, noBackrunTotal, "backrun created value without external cost");
        assertApproxEqAbs(hookTotal, externalTotal, 10, "route-level outcomes diverged");

        emit log("--- no backrun vs external backrun vs hook rebate ---");
        emit log_named_decimal_uint("reference USDC per WETH", usdcPerWeth, 6);
        _logEconomicOutcome("no backrun", noBackrun);
        _logEconomicOutcome("external backrun", externalCase);
        _logEconomicOutcome("hook rebate", hookCase);
        emit log_named_decimal_uint("beneficiary rebate USDC", rebate, 6);
        emit log_named_decimal_uint("external searcher profit USDC", searcherProfit, 6);
        emit log_named_decimal_uint("hook tracked-party external cost USDC", noBackrunTotal - hookTotal, 6);
        emit log_named_decimal_uint(
            "backrun tracked-party external cost USDC", noBackrunTotal - externalTotal, 6
        );
        emit log_named_decimal_uint("hook borrowed WETH", settled.principal, 18);
        emit log_named_decimal_uint("matched V4 input WETH", settled.totalAmountSwapped, 18);
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

    function _captureEconomicOutcome(
        address swapper,
        address beneficiary,
        address searcher,
        uint256 usdcPerWeth,
        uint256 triggerGas,
        uint256 backrunGas
    ) private view returns (EconomicOutcome memory outcome) {
        outcome.lpValue = _accountValue(address(this), usdcPerWeth);
        outcome.swapperValue = _accountValue(swapper, usdcPerWeth);
        outcome.beneficiaryValue = _accountValue(beneficiary, usdcPerWeth);
        outcome.searcherValue = _accountValue(searcher, usdcPerWeth);
        outcome.triggerGas = triggerGas;
        outcome.backrunGas = backrunGas;
    }

    function _accountValue(address account, uint256 usdcPerWeth) private view returns (uint256) {
        return IERC20(USDC).balanceOf(account)
            + FullMath.mulDiv(IERC20(WETH).balanceOf(account), usdcPerWeth, 1e18);
    }

    function _referenceUsdcPerWeth() private view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(UNISWAP_WETH_USDC_500).slot0();
        return FullMath.mulDiv(
            FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), 1e18, 1 << 96
        );
    }

    function _combinedValue(EconomicOutcome memory outcome) private pure returns (uint256) {
        return outcome.lpValue + outcome.swapperValue + outcome.beneficiaryValue + outcome.searcherValue;
    }

    function _logEconomicOutcome(string memory label, EconomicOutcome memory outcome) private {
        emit log_string(label);
        emit log_named_decimal_uint("  LP value USDC", outcome.lpValue, 6);
        emit log_named_decimal_uint("  swapper value USDC", outcome.swapperValue, 6);
        emit log_named_decimal_uint("  beneficiary value USDC", outcome.beneficiaryValue, 6);
        emit log_named_decimal_uint("  searcher value USDC", outcome.searcherValue, 6);
        emit log_named_decimal_uint("  combined tracked value USDC", _combinedValue(outcome), 6);
        emit log_named_uint("  trigger gas", outcome.triggerGas);
        emit log_named_uint("  backrun gas", outcome.backrunGas);
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

        uint256 wethMax = vm.envOr("WETH_LP_AMOUNT_WEI", uint256(2 ether));
        uint256 usdcMax = vm.envOr("USDC_LP_AMOUNT_RAW", uint256(5_000e6));
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

    function _increaseTriggerLiquidity(uint256 wethMax, uint256 usdcMax) private {
        (uint160 sqrtPriceX96,,,) = IPoolManager(V4_POOL_MANAGER).getSlot0(triggerKey.toId());
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

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(triggerPositionTokenId, liquidity, uint128(wethMax), uint128(usdcMax), bytes(""));
        params[1] = abi.encode(triggerKey.currency0);
        params[2] = abi.encode(triggerKey.currency1);
        IUniswapV4PositionManager(V4_POSITION_MANAGER)
            .modifyLiquidities(
                abi.encode(
                    abi.encodePacked(
                        bytes1(uint8(Actions.INCREASE_LIQUIDITY)),
                        bytes1(uint8(Actions.CLOSE_CURRENCY)),
                        bytes1(uint8(Actions.CLOSE_CURRENCY))
                    ),
                    params
                ),
                block.timestamp
            );
    }

    function _swapTriggerPool(uint128 amountIn, address beneficiary) private {
        _swapTriggerPoolFrom(amountIn, beneficiary, address(this));
    }

    function _swapTriggerPoolFrom(uint128 amountIn, address beneficiary, address payer) private {
        _swapTriggerPoolWithHookData(amountIn, abi.encodePacked(beneficiary), payer);
    }

    function _swapTriggerPoolWithHookData(uint128 amountIn, bytes memory hookData, address payer) private {
        vm.startPrank(payer);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        IPermit2Allowance(PERMIT2).approve(USDC, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);

        IV4Router.ExactInputSingleParams memory swapParams =
            IV4Router.ExactInputSingleParams(triggerKey, false, amountIn, 1, hookData);
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
        vm.stopPrank();
    }

    function _externalBackrun(address searcher, uint128 wethIn) private returns (uint256 gasUsed) {
        vm.startPrank(searcher);
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IPermit2Allowance(PERMIT2).approve(WETH, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        IERC20(USDC).approve(SWAP_ROUTER, type(uint256).max);

        IV4Router.ExactInputSingleParams memory swapParams =
            IV4Router.ExactInputSingleParams(triggerKey, true, wethIn, 1, bytes(""));
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(swapParams);
        actionParams[1] = abi.encode(triggerKey.currency0, uint256(wethIn));
        actionParams[2] = abi.encode(triggerKey.currency1, uint256(1));
        bytes[] memory commandInputs = new bytes[](1);
        commandInputs[0] = abi.encode(
            abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                bytes1(uint8(Actions.SETTLE_ALL)),
                bytes1(uint8(Actions.TAKE_ALL))
            ),
            actionParams
        );

        uint256 usdcBefore = IERC20(USDC).balanceOf(searcher);
        uint256 gasBefore = gasleft();
        IUniversalRouter(UNIVERSAL_ROUTER)
            .execute(abi.encodePacked(bytes1(uint8(Commands.V4_SWAP))), commandInputs, block.timestamp);
        uint256 usdcReceived = IERC20(USDC).balanceOf(searcher) - usdcBefore;
        assertGt(usdcReceived, 0, "backrunner received no USDC");

        ISwapRouter02(SWAP_ROUTER).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: WETH,
                fee: 500,
                recipient: searcher,
                amountIn: usdcReceived,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        gasUsed = gasBefore - gasleft();
        vm.stopPrank();
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
