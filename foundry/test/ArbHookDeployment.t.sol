// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {ArbHook} from "../../contracts/ArbHook.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbExecutor} from "../../contracts/ArbExecutor.sol";
import {DataStorage} from "../../contracts/DataStorage.sol";
import {ArbErrors} from "../../contracts/Errors.sol";
import {PoolManagerHarness} from "../../contracts/test/PoolManagerHarness.sol";
import {PoolModifyLiquidityTestWrapper} from "../../contracts/test/PoolModifyLiquidityTestWrapper.sol";
import {PoolSwapTestWrapper} from "../../contracts/test/PoolSwapTestWrapper.sol";
import {TestToken} from "../../contracts/test/TestToken.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Vm} from "forge-std/Vm.sol";

contract ArbHookDeploymentTest is Test {
    uint160 private constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 private constant MIN_SQRT_PRICE_PLUS_ONE = 4_295_128_740;
    uint256 private constant EIP170_RUNTIME_CODE_SIZE_LIMIT = 24_576;
    bytes32 private constant HOOK_ATTEMPT_ALL_TOPIC = keccak256("HookAttemptAll(uint256,bool,bool)");

    struct V4Fixture {
        ArbHook hook;
        PoolManagerHarness manager;
        PoolModifyLiquidityTestWrapper modifyLiquidityRouter;
        PoolSwapTestWrapper swapRouter;
        TestToken token0;
        TestToken token1;
        PoolKey key;
    }

    function testHarnessBypassesPermissionAddressValidation() public {
        ArbitrageLogic logic = new ArbitrageLogic();
        ArbExecutor executor = new ArbExecutor();
        DataStorage dataStorage = new DataStorage(address(this));

        ArbHookHarness hook = new ArbHookHarness(
            IPoolManager(address(1)), address(this), address(logic), address(dataStorage), address(executor)
        );

        assertEq(address(hook.poolManager()), address(1));
    }

    function testExecutorRejectsDirectCalls() public {
        ArbExecutor executor = new ArbExecutor();

        vm.expectRevert(ArbErrors.ExecutorOnlyDelegateCall.selector);
        executor.attemptAllInternal(1);
    }

    function testHarnessRejectsExecutorWithoutCode() public {
        ArbitrageLogic logic = new ArbitrageLogic();
        DataStorage dataStorage = new DataStorage(address(this));

        vm.expectRevert(ArbErrors.ExecutorAddressInvalid.selector);
        new ArbHookHarness(
            IPoolManager(address(1)), address(this), address(logic), address(dataStorage), makeAddr("no-code-executor")
        );
    }

    function testHarnessRejectsLogicAndStorageWithoutCode() public {
        ArbExecutor executor = new ArbExecutor();
        DataStorage dataStorage = new DataStorage(address(this));

        vm.expectRevert(ArbErrors.InvalidArbitrageLogicAddress.selector);
        new ArbHookHarness(
            IPoolManager(address(1)), address(this), makeAddr("no-code-logic"), address(dataStorage), address(executor)
        );

        ArbitrageLogic logic = new ArbitrageLogic();
        vm.expectRevert(ArbErrors.InvalidDataStorageAddress.selector);
        new ArbHookHarness(
            IPoolManager(address(1)), address(this), address(logic), makeAddr("no-code-storage"), address(executor)
        );
    }

    function testHookIterationCapIsBounded() public {
        ArbitrageLogic logic = new ArbitrageLogic();
        ArbExecutor executor = new ArbExecutor();
        DataStorage dataStorage = new DataStorage(address(this));
        ArbHookHarness hook = new ArbHookHarness(
            IPoolManager(address(1)), address(this), address(logic), address(dataStorage), address(executor)
        );

        uint256 maximum = hook.MAX_HOOK_ITERATIONS();
        uint256 requested = maximum + 1;
        vm.expectRevert(abi.encodeWithSelector(ArbErrors.HookMaxIterationsExceeded.selector, requested, maximum));
        hook.setHookMaxIterations(requested);

        hook.setHookMaxIterations(0);
        assertEq(hook.hookMaxIterations(), 0, "zero must disable callback execution");
    }

    function testProductionHookDeploysAtMinedAfterSwapAddress() public {
        ArbitrageLogic logic = new ArbitrageLogic();
        ArbExecutor executor = new ArbExecutor();
        DataStorage dataStorage = new DataStorage(address(this));
        IPoolManager manager = IPoolManager(address(1));

        bytes memory constructorArgs =
            abi.encode(manager, address(this), address(logic), address(dataStorage), address(executor));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), uint160(Hooks.AFTER_SWAP_FLAG), type(ArbHook).creationCode, constructorArgs);

        ArbHook hook =
            new ArbHook{salt: salt}(manager, address(this), address(logic), address(dataStorage), address(executor));

        assertEq(address(hook), predicted);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, uint160(Hooks.AFTER_SWAP_FLAG));
        assertEq(address(hook.arbExecutor()), address(executor));
    }

    function testRuntimeBytecodeFitsEip170Limit() public {
        ArbitrageLogic logic = new ArbitrageLogic();
        ArbExecutor executor = new ArbExecutor();
        DataStorage dataStorage = new DataStorage(address(this));
        ArbHook hook = _deployMinedHook(IPoolManager(address(1)), logic, dataStorage, executor);

        assertLe(address(hook).code.length, EIP170_RUNTIME_CODE_SIZE_LIMIT, "ArbHook runtime exceeds EIP-170");
        assertLe(address(executor).code.length, EIP170_RUNTIME_CODE_SIZE_LIMIT, "ArbExecutor runtime exceeds EIP-170");
        assertLe(address(logic).code.length, EIP170_RUNTIME_CODE_SIZE_LIMIT, "ArbitrageLogic runtime exceeds EIP-170");
    }

    function testV4AfterSwapAllowlistAndBestEffortExecution() public {
        V4Fixture memory fixture = _deployV4Fixture();

        // A real PoolManager invokes the mined hook, but unlisted pools must
        // avoid all arbitrage work and return the normal afterSwap selector.
        vm.recordLogs();
        _swapExactInput(fixture);
        assertFalse(_hasHookAttemptAll(vm.getRecordedLogs(), address(fixture.hook)), "unlisted pool ran hook execution");

        fixture.hook.setHookPoolEnabled(fixture.key, true);

        // There are intentionally no external pools registered here. The
        // callback still reaches the hook and gracefully completes its bounded
        // best-effort scan rather than affecting swap settlement.
        vm.recordLogs();
        _swapExactInput(fixture);
        assertTrue(_hasHookAttemptAll(vm.getRecordedLogs(), address(fixture.hook)), "enabled pool did not call hook");
    }

    function _deployV4Fixture() private returns (V4Fixture memory fixture) {
        fixture.manager = new PoolManagerHarness(address(this));
        ArbitrageLogic logic = new ArbitrageLogic();
        ArbExecutor executor = new ArbExecutor();
        DataStorage dataStorage = new DataStorage(address(this));
        fixture.hook = _deployMinedHook(IPoolManager(address(fixture.manager)), logic, dataStorage, executor);
        dataStorage.setWriter(address(fixture.hook));

        fixture.modifyLiquidityRouter = new PoolModifyLiquidityTestWrapper(IPoolManager(address(fixture.manager)));
        fixture.swapRouter = new PoolSwapTestWrapper(IPoolManager(address(fixture.manager)));

        TestToken first = new TestToken("First", "FIRST", 1e36);
        TestToken second = new TestToken("Second", "SECOND", 1e36);
        if (address(first) < address(second)) {
            fixture.token0 = first;
            fixture.token1 = second;
        } else {
            fixture.token0 = second;
            fixture.token1 = first;
        }

        fixture.key = PoolKey({
            currency0: Currency.wrap(address(fixture.token0)),
            currency1: Currency.wrap(address(fixture.token1)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(fixture.hook))
        });

        fixture.token0.approve(address(fixture.modifyLiquidityRouter), type(uint256).max);
        fixture.token1.approve(address(fixture.modifyLiquidityRouter), type(uint256).max);
        fixture.token0.approve(address(fixture.swapRouter), type(uint256).max);
        fixture.token1.approve(address(fixture.swapRouter), type(uint256).max);

        fixture.manager.initialize(fixture.key, SQRT_PRICE_1_1);
        fixture.modifyLiquidityRouter
            .modifyLiquidity(
                fixture.key,
                ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: bytes32(0)}),
                bytes("")
            );
    }

    function _deployMinedHook(IPoolManager manager, ArbitrageLogic logic, DataStorage dataStorage, ArbExecutor executor)
        private
        returns (ArbHook hook)
    {
        bytes memory constructorArgs =
            abi.encode(manager, address(this), address(logic), address(dataStorage), address(executor));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), uint160(Hooks.AFTER_SWAP_FLAG), type(ArbHook).creationCode, constructorArgs);

        hook = new ArbHook{salt: salt}(manager, address(this), address(logic), address(dataStorage), address(executor));
        assertEq(address(hook), predicted, "mined hook address mismatch");
    }

    function _swapExactInput(V4Fixture memory fixture) private {
        fixture.swapRouter
            .swap(
                fixture.key,
                SwapParams({
                    zeroForOne: true, amountSpecified: -int256(1e15), sqrtPriceLimitX96: MIN_SQRT_PRICE_PLUS_ONE
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                bytes("")
            );
    }

    function _hasHookAttemptAll(Vm.Log[] memory logs, address hook) private pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == hook && logs[i].topics.length > 0 && logs[i].topics[0] == HOOK_ATTEMPT_ALL_TOPIC) {
                return true;
            }
        }
        return false;
    }
}
