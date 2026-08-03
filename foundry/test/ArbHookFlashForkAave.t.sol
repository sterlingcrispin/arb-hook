// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {PoolManagerHarness} from "../../contracts/test/PoolManagerHarness.sol";
import {PoolModifyLiquidityTestWrapper} from "../../contracts/test/PoolModifyLiquidityTestWrapper.sol";
import {TestToken} from "../../contracts/test/TestToken.sol";
import {AaveV3ERC3156Adapter} from "../../contracts/AaveV3ERC3156Adapter.sol";
import {MorphoERC3156Adapter} from "../../contracts/MorphoERC3156Adapter.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {IUniswapV2Pair} from "../../contracts/interfaces/IUniswapV2Pair.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../../contracts/interfaces/IWETH9.sol";
import {ISwapRouter02} from "../../contracts/interfaces/uniswap/ISwapRouter02.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract ArbHookFlashForkAaveTest is Test {
    // Base mainnet addresses from @bgd-labs/aave-address-book (AaveV3Base / AaveV3BaseAssets).
    address internal constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant USDC_WHALE = 0x0B0A5886664376F59C351ba3f598C8A8B4D0A6f3;
    address internal constant AAVE_USDC_A_TOKEN = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant UNISWAP_V2_WETH_USDC = 0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C;
    address internal constant PANCAKE_V2_WETH_USDC = 0x79474223AEdD0339780baCcE75aBDa0BE84dcBF9;
    address internal constant UNISWAP_V3_WETH_USDC = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    uint256 internal constant FORK_BLOCK = 33_942_262;
    uint256 internal constant TEST_FLASH_PRINCIPAL_USDC = 5_000e6;
    uint256 internal constant PARITY_MAX_ITER = 2;
    uint256 internal constant PARITY_FLASH_CAP_USDC = 100_000e6;
    uint256 internal constant PARITY_ROUNDS = 10;
    uint256 internal constant PARITY_ROUNDS_SMOKE = 3;
    bytes32 internal constant FLASH_SETTLED_TOPIC0 =
        keccak256("FlashLoanSettled(address,address,address,address,address,uint256,uint256,uint256,int256,uint256,address)");

    struct PoolSpec {
        address base;
        address pool;
        uint24 fee;
        ArbUtils.PoolType poolType;
    }

    struct RoundExpectation {
        address buyPool;
        address sellPool;
    }

    struct Settlement {
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
    PoolManagerHarness internal poolManager;
    ArbHookHarness internal hook;
    AaveV3ERC3156Adapter internal adapter;

    receive() external payable {}

    function setUp() public {
        bool runForkIntegration = vm.envOr("RUN_FLASH_FORK_INTEGRATION", false);
        if (!runForkIntegration) return;

        string memory baseRpcUrl;
        try vm.envString("BASE_RPC_URL") returns (string memory url) {
            baseRpcUrl = url;
        } catch {
            return;
        }
        if (bytes(baseRpcUrl).length == 0) return;

        // Cached Anvil already forks the fixed historical block, but its local block
        // numbers begin at zero. Do not ask Forge to fetch Base block FORK_BLOCK from
        // that local provider; direct-RPC runs retain explicit block pinning.
        bool usePinnedLocalFork = vm.envOr("FORK_ALREADY_PINNED", false);
        if (usePinnedLocalFork) {
            vm.createSelectFork(baseRpcUrl);
        } else {

        vm.createSelectFork(baseRpcUrl, FORK_BLOCK);
        }
        forkEnabled = true;

        poolManager = new PoolManagerHarness(address(this));
        ArbitrageLogic logic = new ArbitrageLogic();
        hook = new ArbHookHarness(
            IPoolManager(address(poolManager)),
            address(this),
            address(logic));

        adapter = new AaveV3ERC3156Adapter(AAVE_POOL, USDC, AAVE_USDC_A_TOKEN);
        hook.setLenderForToken(USDC, address(adapter));
        hook.setMaxFlashFeeBpsForToken(USDC, 100); // 1% guardrail
        hook.setMinNetProfitForToken(USDC, 1);
    }

    function testForkAaveRealArbPathExecutesAgainstParityPoolBook() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL"); return;
        }

        _configureParityPoolBook();
        _replicateParityFundingState();
        _seedCbBtcUsdcGap();

        uint256 principal = TEST_FLASH_PRINCIPAL_USDC;
        hook.setFlashPrincipalForToken(USDC, principal);

        ArbUtils.PoolInfo[] memory usdcPools = hook.getPoolsForToken(USDC);
        assertEq(usdcPools.length, 16, "must register parity USDC pool universe");
        assertEq(
            usdcPools[0].poolAddress,
            0x1C450D7d1FD98A0b04E30deCFc83497b33A4F608,
            "pool order should match parity fixture"
        );
        assertEq(
            usdcPools[15].poolAddress,
            0x36B4869995672DF7E3aFc36BE795Dbb998Bc639d,
            "pool order should match parity fixture"
        );
        assertEq(hook.getPoolsForToken(WETH).length, 0, "no WETH-base pool book in parity setup");

        uint256 fee = adapter.flashFee(USDC, principal);
        uint256 aTokenLiquidityBefore = IERC20(USDC).balanceOf(AAVE_USDC_A_TOKEN);

        (, int256 pairProfit, uint256 iterations) = hook.runFlashArbForTest(
            0xd0b53D9277642d899DF5C87A3966A349A798F224,
            0x72AB388E2E2F6FaceF59E3C3FA2C4E29011c2D38,
            USDC,
            WETH,
            PARITY_MAX_ITER,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.PANCAKESWAP_V3
        );

        assertGt(iterations, 0, "expected iterative arb loop to execute");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook should end with no retained USDC");
        uint256 paidFee = IERC20(USDC).balanceOf(AAVE_USDC_A_TOKEN) - aTokenLiquidityBefore;
        assertGe(paidFee, fee, "at least one flash fee payment expected");
        assertGt(pairProfit, -int256(paidFee), "arb path should generate non-zero gross result");
    }

    function testForkAaveV2V2UsesRouteSizedPrincipal() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL"); return;
        }

        address[] memory pools = new address[](2);
        pools[0] = PANCAKE_V2_WETH_USDC;
        pools[1] = UNISWAP_V2_WETH_USDC;
        uint24[] memory fees = new uint24[](2);
        fees[0] = 2500;
        fees[1] = 3000;
        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](2);
        types[0] = ArbUtils.PoolType.PANCAKESWAP_V2;
        types[1] = ArbUtils.PoolType.V2;
        hook.addPools(USDC, pools, fees, types);

        // Move the shallow Pancake pair away from the deeper Uniswap pair.
        vm.deal(address(this), 0.01 ether);
        IWETH9(WETH).deposit{value: 0.01 ether}();
        assertTrue(IERC20(WETH).transfer(PANCAKE_V2_WETH_USDC, 0.01 ether));
        IUniswapV2Pair(PANCAKE_V2_WETH_USDC).sync();

        uint256 principalCap = 100e6;
        hook.setFlashPrincipalForToken(USDC, principalCap);

        vm.recordLogs();
        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            PANCAKE_V2_WETH_USDC,
            UNISWAP_V2_WETH_USDC,
            USDC,
            WETH,
            1,
            ArbUtils.PoolType.PANCAKESWAP_V2,
            ArbUtils.PoolType.V2
        );
        Settlement memory settled = _extractProfitableSettlement(vm.getRecordedLogs());

        assertTrue(success, "V2/V2 flash route failed");
        assertGt(profit, 0, "V2/V2 route should settle net positive");
        assertEq(iterations, 1, "expected one V2/V2 iteration");
        assertLt(settled.principal, principalCap, "V2/V2 borrowed the full cap");
        assertEq(settled.principal, settled.totalAmountSwapped * 2, "principal did not preserve V2 half-balance sizing");
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0, "V2/V2 retained WETH");
    }

    function testForkAaveMixedV2V3UsesRouteSizedPrincipal() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL"); return;
        }

        address[] memory pools = new address[](2);
        pools[0] = PANCAKE_V2_WETH_USDC;
        pools[1] = UNISWAP_V3_WETH_USDC;
        uint24[] memory fees = new uint24[](2);
        fees[0] = 2500;
        fees[1] = 500;
        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](2);
        types[0] = ArbUtils.PoolType.PANCAKESWAP_V2;
        types[1] = ArbUtils.PoolType.V3;
        hook.addPools(USDC, pools, fees, types);

        vm.deal(address(this), 0.01 ether);
        IWETH9(WETH).deposit{value: 0.01 ether}();
        assertTrue(IERC20(WETH).transfer(PANCAKE_V2_WETH_USDC, 0.01 ether));
        IUniswapV2Pair(PANCAKE_V2_WETH_USDC).sync();

        uint256 principalCap = 100e6;
        hook.setFlashPrincipalForToken(USDC, principalCap);

        vm.recordLogs();
        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            PANCAKE_V2_WETH_USDC,
            UNISWAP_V3_WETH_USDC,
            USDC,
            WETH,
            1,
            ArbUtils.PoolType.PANCAKESWAP_V2,
            ArbUtils.PoolType.V3
        );
        Settlement memory settled = _extractProfitableSettlement(vm.getRecordedLogs());

        assertTrue(success, "mixed flash route failed");
        assertGt(profit, 0, "mixed route should settle net positive");
        assertEq(iterations, 1, "expected one mixed iteration");
        assertLt(settled.principal, principalCap, "mixed route borrowed the full cap");
        assertEq(settled.principal, settled.totalAmountSwapped * 2, "principal did not preserve mixed half-balance sizing");
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0, "V2/V3 retained WETH");
    }

    function testForkAaveMixedV3V2UsesRouteSizedPrincipal() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL"); return;
        }

        address[] memory pools = new address[](2);
        pools[0] = UNISWAP_V3_WETH_USDC;
        pools[1] = PANCAKE_V2_WETH_USDC;
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 2500;
        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](2);
        types[0] = ArbUtils.PoolType.V3;
        types[1] = ArbUtils.PoolType.PANCAKESWAP_V2;
        hook.addPools(USDC, pools, fees, types);

        _pullToken(USDC, USDC_WHALE, 50e6);
        assertTrue(IERC20(USDC).transfer(PANCAKE_V2_WETH_USDC, 50e6));
        IUniswapV2Pair(PANCAKE_V2_WETH_USDC).sync();

        uint256 principalCap = 100e6;
        hook.setFlashPrincipalForToken(USDC, principalCap);

        vm.recordLogs();
        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            UNISWAP_V3_WETH_USDC,
            PANCAKE_V2_WETH_USDC,
            USDC,
            WETH,
            1,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.PANCAKESWAP_V2
        );
        Settlement memory settled = _extractProfitableSettlement(vm.getRecordedLogs());

        assertTrue(success, "reverse mixed flash route failed");
        assertGt(profit, 0, "reverse mixed route should settle net positive");
        assertEq(iterations, 1, "expected one reverse mixed iteration");
        assertLt(settled.principal, principalCap, "reverse mixed route borrowed the full cap");
        assertEq(settled.principal, settled.totalAmountSwapped * 2, "principal did not preserve mixed half-balance sizing");
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0, "V3/V2 retained WETH");
    }

    function testForkAaveAttemptAllTracksLegacyRoundSequenceFull() public {
        _runLegacyRoundSequence(PARITY_ROUNDS, true);
    }

    function testForkAaveAttemptAllTracksLegacyRoundSequenceSmokeFirst3() public {
        _runLegacyRoundSequence(PARITY_ROUNDS_SMOKE, false);
    }

    function testCanonicalV4RouterPassesPackedBeneficiary() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL"); return;
        }

        IPoolManager manager = IPoolManager(V4_POOL_MANAGER);
        ArbitrageLogic logic = new ArbitrageLogic();
        bytes memory constructorArgs = abi.encode(
            manager,
            address(this),
            address(logic)
        );
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.AFTER_SWAP_FLAG,
            type(ArbHookHarness).creationCode,
            constructorArgs
        );
        hook = new ArbHookHarness{salt: salt}(
            manager,
            address(this),
            address(logic)
        );
        assertEq(address(hook), expected, "mined hook address mismatch");

        hook.setLenderForToken(USDC, address(adapter));
        hook.setFlashPrincipalForToken(USDC, PARITY_FLASH_CAP_USDC);
        hook.setMaxFlashFeeBpsForToken(USDC, 100);
        hook.setMinNetProfitForToken(USDC, 1);
        _configureParityPoolBook();
        _replicateParityFundingState();
        _seedCbBtcUsdcGap();

        TestToken triggerToken = new TestToken("Trigger Token", "TRIGGER", 0);
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(triggerToken)),
            3000,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, uint160(1 << 96));

        PoolModifyLiquidityTestWrapper liquidityRouter =
            new PoolModifyLiquidityTestWrapper(manager);
        triggerToken.mint(address(this), 1 ether);
        triggerToken.approve(address(liquidityRouter), type(uint256).max);
        vm.deal(address(this), 2 ether);
        liquidityRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams(-120, 120, 1 ether, 0),
            bytes("")
        );

        address beneficiary = makeAddr("v4 beneficiary");
        IV4Router.ExactInputSingleParams memory swapParams = IV4Router
            .ExactInputSingleParams(
                key,
                true,
                1e12,
                1,
                abi.encodePacked(beneficiary)
            );
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(swapParams);
        actionParams[1] = abi.encode(key.currency0, uint256(1e12));
        actionParams[2] = abi.encode(key.currency1, uint256(1));
        bytes[] memory commandInputs = new bytes[](1);
        commandInputs[0] = abi.encode(
            abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                bytes1(uint8(Actions.SETTLE_ALL)),
                bytes1(uint8(Actions.TAKE_ALL))
            ),
            actionParams
        );

        vm.recordLogs();
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: 1e12}(
            abi.encodePacked(bytes1(uint8(Commands.V4_SWAP))),
            commandInputs,
            block.timestamp
        );
        Settlement memory settled = _extractProfitableSettlement(
            vm.getRecordedLogs()
        );
        assertEq(settled.beneficiary, beneficiary);
        assertEq(IERC20(USDC).balanceOf(beneficiary), uint256(settled.netProfit));
    }

    function _runLegacyRoundSequence(
        uint256 roundsToRun,
        bool requirePrincipalVariance
    ) private {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL"); return;
        }
        assertLe(roundsToRun, PARITY_ROUNDS, "round cap exceeds legacy sequence");

        _configureParityPoolBook();
        _replicateParityFundingState();
        _seedCbBtcUsdcGap();

        hook.setFlashPrincipalForToken(USDC, PARITY_FLASH_CAP_USDC);
        RoundExpectation[PARITY_ROUNDS] memory expected = _legacyRoundExpectations();
        uint256 profitableRounds;
        uint256 lastPrincipal;
        bool sawPrincipalVariance;

        emit log("===== Flash AttemptAll vs Legacy Round Sequence =====");
        for (uint256 round = 0; round < roundsToRun; ++round) {
            vm.recordLogs();
            bool success = hook.attemptAllForTest(PARITY_MAX_ITER);
            assertTrue(success, "legacy-profitable round should remain profitable");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            Settlement memory settled = _extractProfitableSettlement(logs);
            uint256 principal = settled.principal;
            assertGt(principal, 0, "round should request flash principal");
            if (round > 0 && principal != lastPrincipal) {
                sawPrincipalVariance = true;
            }
            lastPrincipal = principal;
            address buyPool = settled.buyPool;
            address sellPool = settled.sellPool;
            uint256 totalAmountSwapped = settled.totalAmountSwapped;
            uint256 profit = uint256(settled.netProfit);

            uint256 fee =
                settled.fee;
            if (profit > 0) profitableRounds++;

            emit log("");
            emit log_named_uint("round", round + 1);
            emit log_named_address("expected buy", expected[round].buyPool);
            emit log_named_address("actual buy", buyPool);
            emit log_named_address("expected sell", expected[round].sellPool);
            emit log_named_address("actual sell", sellPool);
            emit log_named_uint("flash principal (raw usdc)", principal);
            emit log_named_uint("total amount swapped (raw usdc)", totalAmountSwapped);
            emit log_named_uint("Aave fee (raw usdc)", fee);
            emit log_named_uint("net profit (raw usdc)", profit);
            emit log_named_uint("iterations", settled.iterations);
            assertEq(buyPool, expected[round].buyPool, "buy route drifted from legacy");
            assertEq(sellPool, expected[round].sellPool, "sell route drifted from legacy");

            assertGt(profit, 0, "round should have positive net profit");
            assertEq(IERC20(WETH).balanceOf(address(hook)), 0, "hook retained intermediate WETH");
        }

        emit log("");
        emit log_named_uint("profitable rounds", profitableRounds);
        emit log("====================================================");

        assertEq(profitableRounds, roundsToRun, "all tested rounds should remain profitable");
        if (requirePrincipalVariance && roundsToRun > 1) {
            assertTrue(sawPrincipalVariance, "flash principal should adapt across rounds");
        }
    }

    /// @notice Replays the ten-round sequence funded by zero-fee Morpho Blue.
    /// @dev The Aave-funded gate is the historical baseline; this is the intended
    ///      canary configuration. Morpho Blue is deployed and USDC-funded at the
    ///      pinned block, so the two are directly comparable: same pool book, same
    ///      funding, same routes, with the 5 bps premium removed.
    function testForkMorphoAttemptAllBeatsAaveFundedSequence() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL");
            return;
        }

        MorphoERC3156Adapter morpho = new MorphoERC3156Adapter(MORPHO_BLUE, USDC);
        hook.setLenderForToken(USDC, address(morpho));

        _configureParityPoolBook();
        _replicateParityFundingState();
        _seedCbBtcUsdcGap();
        hook.setFlashPrincipalForToken(USDC, PARITY_FLASH_CAP_USDC);

        RoundExpectation[PARITY_ROUNDS] memory expected = _legacyRoundExpectations();
        uint256 totalNet;
        uint256 totalFees;

        emit log("===== Morpho-funded round sequence =====");
        for (uint256 round = 0; round < PARITY_ROUNDS; ++round) {
            vm.recordLogs();
            bool success = hook.attemptAllForTest(PARITY_MAX_ITER);
            assertTrue(success, "round should remain profitable with a zero-fee lender");
            Settlement memory settled = _extractProfitableSettlement(vm.getRecordedLogs());

            assertEq(settled.buyPool, expected[round].buyPool, "buy route drifted from legacy");
            assertEq(settled.sellPool, expected[round].sellPool, "sell route drifted from legacy");
            assertEq(settled.fee, 0, "morpho must charge no premium");
            assertGt(settled.netProfit, 0, "round should have positive net profit");
            assertEq(IERC20(WETH).balanceOf(address(hook)), 0, "hook retained intermediate WETH");

            totalNet += uint256(settled.netProfit);
            totalFees += settled.fee;

            emit log_named_uint("round", round + 1);
            emit log_named_uint("  net profit (raw usdc)", uint256(settled.netProfit));
        }

        emit log("");
        emit log_named_uint("total net profit (raw usdc)", totalNet);
        emit log_named_uint("total fees paid (raw usdc)", totalFees);
        emit log("========================================");

        assertEq(totalFees, 0, "zero-fee lender should pay no premium at all");
        // The Aave-funded sequence nets 8,365,681 raw USDC across the same rounds.
        assertGt(totalNet, 8_365_681, "morpho funding should beat the aave baseline");
    }

    /// @notice Sweeps `minSpreadBps` across the ten-round sequence and reports what
    ///         each threshold earns net of execution gas.
    /// @dev Opt-in via RUN_SPREAD_CALIBRATION=true because it replays the whole
    ///      sequence once per candidate. `minSpreadBps` is compared against a V3 tick
    ///      delta, so it gates V3/V3 routes only; V2/V2 and mixed routes are
    ///      unaffected by anything this measures.
    function testCalibrateMinSpreadBps() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL");
            return;
        }
        if (!vm.envOr("RUN_SPREAD_CALIBRATION", false)) {
            vm.skip(true, "set RUN_SPREAD_CALIBRATION=true");
            return;
        }

        // Convert measured gas for every trigger through the current-head reference
        // replay. This sweep compares fixture settings; production calibration still
        // requires the runbook's full swap-on/swap-off differential measurement.
        uint256 referenceGasCostRawUsdc = vm.envOr("GAS_COST_RAW_USDC", uint256(12324));
        uint256 referenceGasUnits = vm.envOr("GAS_COST_GAS_UNITS", uint256(1_076_889));

        uint16[9] memory candidates =
            [uint16(1), 5, 10, 20, 40, 60, 80, 120, 200];

        emit log("===== minSpreadBps calibration =====");
        emit log_named_uint("reference gas units", referenceGasUnits);
        emit log_named_uint("reference gas cost (raw usdc)", referenceGasCostRawUsdc);

        for (uint256 c = 0; c < candidates.length; ++c) {
            uint256 snapshot = vm.snapshotState();

            _configureParityPoolBook();
            hook.setMinSpreadBps(candidates[c]);
            _replicateParityFundingState();
            _seedCbBtcUsdcGap();
            hook.setFlashPrincipalForToken(USDC, PARITY_FLASH_CAP_USDC);

            uint256 executed;
            uint256 grossNet;
            uint256 attemptGas;
            for (uint256 round = 0; round < PARITY_ROUNDS; ++round) {
                vm.recordLogs();
                uint256 gasBefore = gasleft();
                bool success = hook.attemptAllForTest(PARITY_MAX_ITER);
                attemptGas += gasBefore - gasleft();
                if (!success) continue;

                Vm.Log[] memory logs = vm.getRecordedLogs();
                int256 profit = _findAnyProfit(logs);
                if (profit <= 0) continue;

                ++executed;
                grossNet += uint256(profit);
            }

            uint256 gasSpend = _scaleGasCost(
                attemptGas,
                referenceGasUnits,
                referenceGasCostRawUsdc
            );
            emit log("");
            emit log_named_uint("minSpreadBps", candidates[c]);
            emit log_named_uint("rounds executed", executed);
            emit log_named_uint("attempt gas across all triggers", attemptGas);
            emit log_named_uint("gross net profit (raw usdc)", grossNet);
            emit log_named_uint("gas spend (raw usdc)", gasSpend);
            if (grossNet >= gasSpend) {
                emit log_named_uint("PROFIT after gas (raw usdc)", grossNet - gasSpend);
            } else {
                emit log_named_uint("LOSS after gas (raw usdc)", gasSpend - grossNet);
            }

            vm.revertToState(snapshot);
        }
        emit log("====================================");
    }

    /// @notice Sweeps the absolute minimum-net-profit floor across the same sequence.
    /// @dev This is the economically meaningful filter: unlike `minSpreadBps` it is
    ///      denominated in the borrowed token, so it compares directly against the
    ///      gas cost of executing. Opt-in via RUN_SPREAD_CALIBRATION=true.
    function testCalibrateMinNetProfit() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL");
            return;
        }
        if (!vm.envOr("RUN_SPREAD_CALIBRATION", false)) {
            vm.skip(true, "set RUN_SPREAD_CALIBRATION=true");
            return;
        }

        uint256 referenceGasCostRawUsdc = vm.envOr("GAS_COST_RAW_USDC", uint256(12324));
        uint256 referenceGasUnits = vm.envOr("GAS_COST_GAS_UNITS", uint256(1_076_889));
        uint256[8] memory floors =
            [uint256(1), 2_000, 4_000, 6_162, 8_000, 10_000, 12_324, 24_648];

        emit log("===== minNetProfit calibration =====");
        emit log_named_uint("reference gas units", referenceGasUnits);
        emit log_named_uint("reference gas cost (raw usdc)", referenceGasCostRawUsdc);

        for (uint256 c = 0; c < floors.length; ++c) {
            uint256 snapshot = vm.snapshotState();

            _configureParityPoolBook();
            _replicateParityFundingState();
            _seedCbBtcUsdcGap();
            hook.setFlashPrincipalForToken(USDC, PARITY_FLASH_CAP_USDC);
            hook.setMinNetProfitForToken(USDC, floors[c]);

            uint256 executed;
            uint256 grossNet;
            uint256 attemptGas;
            for (uint256 round = 0; round < PARITY_ROUNDS; ++round) {
                vm.recordLogs();
                uint256 gasBefore = gasleft();
                bool success = hook.attemptAllForTest(PARITY_MAX_ITER);
                attemptGas += gasBefore - gasleft();
                if (!success) continue;

                int256 profit = _findAnyProfit(vm.getRecordedLogs());
                if (profit <= 0) continue;

                ++executed;
                grossNet += uint256(profit);
                emit log_named_uint("  executed round", round + 1);
                emit log_named_uint("    net profit (raw usdc)", uint256(profit));
            }

            uint256 gasSpend = _scaleGasCost(
                attemptGas,
                referenceGasUnits,
                referenceGasCostRawUsdc
            );
            emit log("");
            emit log_named_uint("minNetProfit floor (raw usdc)", floors[c]);
            emit log_named_uint("rounds executed", executed);
            emit log_named_uint("attempt gas across all triggers", attemptGas);
            emit log_named_uint("gross net profit (raw usdc)", grossNet);
            emit log_named_uint("gas spend (raw usdc)", gasSpend);
            if (grossNet >= gasSpend) {
                emit log_named_uint("PROFIT after gas (raw usdc)", grossNet - gasSpend);
            } else {
                emit log_named_uint("LOSS after gas (raw usdc)", gasSpend - grossNet);
            }

            vm.revertToState(snapshot);
        }
        emit log("====================================");
    }

    /// @notice Compares the V3 route-ranking score against what each round realizes.
    /// @dev The score is not currency and is never checked against `minNetProfit`;
    ///      this diagnostic guards against repurposing it as currency again.
    function testPreLoanEstimateVersusRealized() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL");
            return;
        }
        if (!vm.envOr("RUN_SPREAD_CALIBRATION", false)) {
            vm.skip(true, "set RUN_SPREAD_CALIBRATION=true");
            return;
        }

        _configureParityPoolBook();
        _replicateParityFundingState();
        _seedCbBtcUsdcGap();
        hook.setFlashPrincipalForToken(USDC, PARITY_FLASH_CAP_USDC);

        emit log("===== pre-loan estimate vs realized =====");
        for (uint256 round = 0; round < PARITY_ROUNDS; ++round) {
            vm.recordLogs();
            bool success = hook.attemptAllForTest(PARITY_MAX_ITER);
            if (!success) continue;
            Settlement memory settled = _extractProfitableSettlement(vm.getRecordedLogs());

            // Re-derive the estimate for the route that just executed. Pool state has
            // moved, so this is indicative of magnitude rather than the exact value
            // the gate saw, which is enough to show the scale of the gap.
            emit log("");
            emit log_named_uint("round", round + 1);
            emit log_named_uint("realized net (raw usdc)", uint256(settled.netProfit));
            try hook.previewV3RouteEstimate(
                settled.sellPool,
                settled.buyPool,
                USDC,
                WETH,
                ArbUtils.PoolType.V3,
                ArbUtils.PoolType.V3,
                PARITY_FLASH_CAP_USDC
            ) returns (uint256, uint256, uint256 estimate) {
                emit log_named_uint("post-trade edge score (not currency)", estimate);
            } catch {
                // Pancake V3 pools reject the Uniswap-typed slot0 read.
                emit log("post-trade estimate: n/a (pancake-typed pool)");
            }
        }
        emit log("=========================================");
    }

    /// @notice Tests whether the ten-round fixture is a cascade: does round N's
    ///         opportunity only exist because round N-1 executed?
    /// @dev If seeding round 1 at a floor of 1 lets later rounds clear a floor that
    ///      otherwise halts the sequence, the fixture cannot be used to calibrate
    ///      `minNetProfit`, because its rounds are not independent triggers the way
    ///      production swaps are.
    function testRoundSequenceIsACascade() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL");
            return;
        }
        if (!vm.envOr("RUN_SPREAD_CALIBRATION", false)) {
            vm.skip(true, "set RUN_SPREAD_CALIBRATION=true");
            return;
        }

        uint256 highFloor = 8_000;

        _configureParityPoolBook();
        _replicateParityFundingState();
        _seedCbBtcUsdcGap();
        hook.setFlashPrincipalForToken(USDC, PARITY_FLASH_CAP_USDC);

        // Round 1 runs with no meaningful floor, every later round with the floor
        // that halts the sequence outright when applied from the start.
        hook.setMinNetProfitForToken(USDC, 1);
        vm.recordLogs();
        bool seeded = hook.attemptAllForTest(PARITY_MAX_ITER);
        emit log_named_string("round 1 (floor=1) executed", seeded ? "yes" : "no");

        hook.setMinNetProfitForToken(USDC, highFloor);
        uint256 executed;
        uint256 grossNet;
        for (uint256 round = 1; round < PARITY_ROUNDS; ++round) {
            vm.recordLogs();
            if (!hook.attemptAllForTest(PARITY_MAX_ITER)) continue;
            int256 profit = _findAnyProfit(vm.getRecordedLogs());
            if (profit <= 0) continue;
            ++executed;
            grossNet += uint256(profit);
            emit log_named_uint("  executed round", round + 1);
            emit log_named_uint("    net profit (raw usdc)", uint256(profit));
        }

        emit log("");
        emit log_named_uint("floor applied from round 2 (raw usdc)", highFloor);
        emit log_named_uint("rounds executed after seeding", executed);
        emit log_named_uint("gross net after seeding (raw usdc)", grossNet);
        emit log("Compare: the same floor applied from round 1 executes 0 rounds.");
    }

    function _findAnyProfit(Vm.Log[] memory entries) private view returns (int256 best) {
        for (uint256 i = 0; i < entries.length; ++i) {
            if (
                entries[i].emitter == address(hook) && entries[i].topics.length > 0
                    && entries[i].topics[0] == FLASH_SETTLED_TOPIC0
            ) {
                (,,,,, int256 netProfit,,) = abi.decode(
                    entries[i].data,
                    (address, address, uint256, uint256, uint256, int256, uint256, address)
                );
                if (netProfit > best) best = netProfit;
            }
        }
    }

    function _scaleGasCost(
        uint256 measuredGas,
        uint256 referenceGas,
        uint256 referenceCost
    ) private pure returns (uint256) {
        require(referenceGas > 0, "reference gas=0");
        uint256 product = measuredGas * referenceCost;
        return product / referenceGas + (product % referenceGas == 0 ? 0 : 1);
    }

    function _configureParityPoolBook() private {
        PoolSpec[] memory specs = _parityPools();
        for (uint256 i = 0; i < specs.length; ++i) {
            address[] memory pools = new address[](1);
            pools[0] = specs[i].pool;
            uint24[] memory fees = new uint24[](1);
            fees[0] = specs[i].fee;
            ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](1);
            types[0] = specs[i].poolType;
            hook.addPools(specs[i].base, pools, fees, types);
        }

        address[] memory allPools = _collectPoolAddresses(specs);
        hook.approvePools(USDC, allPools, type(uint256).max);
        hook.approvePools(WETH, allPools, type(uint256).max);
        hook.approvePools(CBBTC, allPools, type(uint256).max);

        hook.setHookMaxIterations(PARITY_MAX_ITER);
        hook.setMinSpreadBps(10);
        hook.setChunkSpreadConsumptionBps(1500);
        hook.setMaxImpactBps(500);
    }

    function _replicateParityFundingState() private {
        uint256 wethPerSwap = 25 ether;
        uint256 numSwaps = 2;
        uint256 totalWeth = wethPerSwap * numSwaps;

        vm.deal(address(this), totalWeth);
        IWETH9 weth = IWETH9(WETH);
        weth.deposit{value: totalWeth}();
        IERC20(WETH).approve(SWAP_ROUTER, totalWeth);

        ISwapRouter02 router = ISwapRouter02(SWAP_ROUTER);
        for (uint256 i = 0; i < numSwaps; ++i) {
            ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02
                .ExactInputSingleParams({
                    tokenIn: WETH,
                    tokenOut: USDC,
                    fee: 500,
                    recipient: address(this),
                    amountIn: wethPerSwap,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                });
            router.exactInputSingle(params);
        }
    }

    function _seedCbBtcUsdcGap() private {
        uint256 chunkCount = 5;
        uint256 usdcChunk = 400e6;
        uint256 totalSeedUsdc = usdcChunk * chunkCount;
        address source = IERC20(USDC).balanceOf(USDC_WHALE) >= totalSeedUsdc
            ? USDC_WHALE
            : AAVE_USDC_A_TOKEN;
        _pullToken(USDC, source, totalSeedUsdc);

        IERC20(USDC).approve(SWAP_ROUTER, totalSeedUsdc);
        ISwapRouter02 router = ISwapRouter02(SWAP_ROUTER);

        for (uint256 i = 0; i < chunkCount; ++i) {
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
            router.exactInputSingle(params);
        }

        uint256 cbBtcBalance = IERC20(CBBTC).balanceOf(address(this));
        if (cbBtcBalance == 0) return;

        IERC20(CBBTC).approve(SWAP_ROUTER, cbBtcBalance);
        uint256 cbChunks = chunkCount;
        uint256 cbChunkSize = cbBtcBalance / cbChunks;
        for (uint256 j = 0; j < cbChunks; ++j) {
            uint256 remaining = IERC20(CBBTC).balanceOf(address(this));
            uint256 amountIn = j == cbChunks - 1 ? remaining : cbChunkSize;
            if (amountIn == 0) break;

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
            router.exactInputSingle(params);
        }
    }

    function _pullToken(address token, address whale, uint256 amount) private {
        vm.deal(whale, 10 ether);
        vm.startPrank(whale);
        IERC20(token).transfer(address(this), amount);
        vm.stopPrank();
    }

    function _collectPoolAddresses(
        PoolSpec[] memory specs
    ) private pure returns (address[] memory pools) {
        pools = new address[](specs.length);
        for (uint256 i = 0; i < specs.length; ++i) {
            pools[i] = specs[i].pool;
        }
    }

    function _parityPools() private pure returns (PoolSpec[] memory specs) {
        specs = new PoolSpec[](16);
        uint256 idx;
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

    function _legacyRoundExpectations() private pure returns (RoundExpectation[PARITY_ROUNDS] memory rounds) {
        rounds[0] = RoundExpectation({
            buyPool: 0x56C8989222ed293E3c4a22628d8BCA633cE1eb99,
            sellPool: 0x1C450D7d1FD98A0b04E30deCFc83497b33A4F608
        });
        rounds[1] = RoundExpectation({
            buyPool: 0x56C8989222ed293E3c4a22628d8BCA633cE1eb99,
            sellPool: 0x1C450D7d1FD98A0b04E30deCFc83497b33A4F608
        });
        rounds[2] = RoundExpectation({
            buyPool: 0x56C8989222ed293E3c4a22628d8BCA633cE1eb99,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224
        });
        rounds[3] = RoundExpectation({
            buyPool: 0xb4CB800910B228ED3d0834cF79D697127BBB00e5,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224
        });
        rounds[4] = RoundExpectation({
            buyPool: 0xB775272E537cc670C65DC852908aD47015244EaF,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224
        });
        rounds[5] = RoundExpectation({
            buyPool: 0x72AB388E2E2F6FaceF59E3C3FA2C4E29011c2D38,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224
        });
        rounds[6] = RoundExpectation({
            buyPool: 0x56C8989222ed293E3c4a22628d8BCA633cE1eb99,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224
        });
        rounds[7] = RoundExpectation({
            buyPool: 0xb4CB800910B228ED3d0834cF79D697127BBB00e5,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224
        });
        rounds[8] = RoundExpectation({
            buyPool: 0x56C8989222ed293E3c4a22628d8BCA633cE1eb99,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224
        });
        rounds[9] = RoundExpectation({
            buyPool: 0xB775272E537cc670C65DC852908aD47015244EaF,
            sellPool: 0xd0b53D9277642d899DF5C87A3966A349A798F224
        });
    }

    function _extractProfitableSettlement(
        Vm.Log[] memory entries
    ) private view returns (Settlement memory settled) {
        for (uint256 i = 0; i < entries.length; ++i) {
            if (
                entries[i].emitter == address(hook) &&
                entries[i].topics.length > 0 &&
                entries[i].topics[0] == FLASH_SETTLED_TOPIC0
            ) {
                Settlement memory candidate;
                (
                    candidate.buyPool,
                    candidate.sellPool,
                    candidate.principal,
                    candidate.totalAmountSwapped,
                    candidate.fee,
                    candidate.netProfit,
                    candidate.iterations,
                    candidate.beneficiary ) = abi.decode(entries[i].data, (address, address, uint256, uint256, uint256, int256,uint256, address));
                if (candidate.netProfit > 0)
                return candidate;
            }
        }
        revert("profitable settlement event missing");
    }
}
