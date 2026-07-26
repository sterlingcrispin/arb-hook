// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {PoolManagerHarness} from "../../contracts/test/PoolManagerHarness.sol";
import {AaveV3ERC3156Adapter} from "../../contracts/AaveV3ERC3156Adapter.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../../contracts/interfaces/IWETH9.sol";
import {ISwapRouter02} from "../../contracts/interfaces/uniswap/ISwapRouter02.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract ArbHookFlashForkAaveTest is Test {
    // Base mainnet addresses from @bgd-labs/aave-address-book (AaveV3Base / AaveV3BaseAssets).
    address internal constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant USDC_WHALE = 0x0B0A5886664376F59C351ba3f598C8A8B4D0A6f3;
    address internal constant AAVE_USDC_A_TOKEN = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
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
        hook.setTrustedFlashLender(address(adapter), true);
        hook.setLenderForToken(USDC, address(adapter));
        hook.setMaxFlashFeeBpsForToken(USDC, 100); // 1% guardrail
    }

    function testForkAaveAdapterRoundTripRepaysPrincipalAndFee() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL"); return;
        }

        uint256 principal = TEST_FLASH_PRINCIPAL_USDC;
        hook.setFlashPrincipalForToken(USDC, principal);

        uint256 fee = adapter.flashFee(USDC, principal);
        deal(USDC, address(hook), fee); // cover flash fee when no arb profit

        uint256 aTokenLiquidityBefore = IERC20(USDC).balanceOf(AAVE_USDC_A_TOKEN);

        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(0xA1),
            address(0xB2),
            USDC,
            address(0xCAFE),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertFalse(success, "maxIterations=0 path should not report profitable trade");
        assertEq(profit, -int256(fee), "net should be negative by flash fee amount");
        assertEq(iterations, 0, "no iterations expected");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook should not retain USDC");
        assertEq(
            IERC20(USDC).balanceOf(AAVE_USDC_A_TOKEN),
            aTokenLiquidityBefore + fee,
            "aToken liquidity should increase by collected fee"
        );
    }

    function testForkAaveAdapterProfitablePathPaysBeneficiaryAndEmitsNetSettlement() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL"); return;
        }

        uint256 principal = TEST_FLASH_PRINCIPAL_USDC;
        hook.setFlashPrincipalForToken(USDC, principal);
        hook.setTestProfitBps(1); // enable harness test path for maxIterations=0

        address beneficiary = makeAddr("forkBeneficiary");
        hook.setDefaultProfitRecipient(beneficiary);

        uint256 fee = adapter.flashFee(USDC, principal);
        uint256 expectedGross = fee + 1e6; // fee + 1 USDC => guaranteed net-positive
        uint256 expectedNet = expectedGross - fee;
        assertGt(expectedNet, 0, "expected net must be positive");
        deal(USDC, address(this), expectedGross);
        IERC20(USDC).approve(address(hook), 0);
        IERC20(USDC).approve(address(hook), expectedGross);
        hook.setTestProfitTransfer(address(this), expectedGross);

        uint256 beneficiaryBefore = IERC20(USDC).balanceOf(beneficiary);
        vm.recordLogs();

        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(0xD1),
            address(0xD2),
            USDC,
            address(0xD3),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertTrue(success, "profitable flash path should succeed");
        assertEq(uint256(profit), expectedNet, "reported net profit mismatch");
        assertEq(iterations, 1, "harness profitable path should report one iteration");
        assertEq(
            IERC20(USDC).balanceOf(beneficiary),
            beneficiaryBefore + expectedNet,
            "beneficiary should receive net profit"
        );
        Settlement memory settled = _extractProfitableSettlement(
            vm.getRecordedLogs());
        assertEq(settled.buyPool, address(0xD2), "settled buy pool mismatch");
        assertEq(settled.sellPool, address(0xD1), "settled sell pool mismatch");
        assertEq(uint256(settled.netProfit), expectedNet, "settled net mismatch");
        assertEq(settled.beneficiary, beneficiary, "settled beneficiary mismatch");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook should not retain USDC");
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

    function testForkAaveAttemptAllTracksLegacyRoundSequenceFull() public {
        _runLegacyRoundSequence(PARITY_ROUNDS, true);
    }

    function testForkAaveAttemptAllTracksLegacyRoundSequenceSmokeFirst3() public {
        _runLegacyRoundSequence(PARITY_ROUNDS_SMOKE, false);
    }

    function testForkAaveAttemptAllTracksLegacyRoundSequenceShapePrefix() public {
        uint256 roundsToRun = vm.envOr("FLASH_PARITY_ROUNDS", PARITY_ROUNDS);
        _runLegacyRoundSequence(roundsToRun, roundsToRun > 1);
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
        }

        emit log("");
        emit log_named_uint("profitable rounds", profitableRounds);
        emit log("====================================================");

        assertEq(profitableRounds, roundsToRun, "all tested rounds should remain profitable");
        if (requirePrincipalVariance && roundsToRun > 1) {
            assertTrue(sawPrincipalVariance, "flash principal should adapt across rounds");
        }
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
        _pullToken(USDC, USDC_WHALE, totalSeedUsdc);

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
