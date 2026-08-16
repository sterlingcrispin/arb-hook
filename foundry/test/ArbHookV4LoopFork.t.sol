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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

interface IPermit2LoopAllowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract ArbHookV4LoopForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant AAVE_USDC_A_TOKEN = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant V4_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant UNISWAP_WETH_USDC_500 = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    uint256 internal constant FORK_BLOCK = 50_018_808;
    uint256 internal constant PRINCIPAL_CAP = 1 ether;
    uint256 internal constant MULTI_ROUND_LIMIT = 10;
    uint128 internal constant TRIGGER_AMOUNT = 100e6;
    bytes32 internal constant FLASH_SETTLED_TOPIC0 = keccak256(
        "FlashLoanSettled(address,address,address,address,address,uint256,uint256,uint256,int256,uint256,address)"
    );

    struct Settlement {
        uint256 principal;
        uint256 totalAmountSwapped;
        int256 netProfit;
        uint256 iterations;
    }

    bool internal forkEnabled;
    ArbHook internal hook;
    PoolKey internal triggerKey;

    function setUp() public {
        if (!vm.envOr("RUN_V4_LOOP_FORK", false)) return;

        string memory rpcUrl;
        try vm.envString("BASE_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {
            return;
        }
        if (bytes(rpcUrl).length == 0) return;

        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        forkEnabled = true;

        IPoolManager manager = IPoolManager(V4_POOL_MANAGER);
        ArbitrageLogic logic = new ArbitrageLogic();
        bytes memory constructorArgs = abi.encode(manager, address(this), address(logic));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), Hooks.AFTER_SWAP_FLAG, type(ArbHook).creationCode, constructorArgs);
        hook = new ArbHook{salt: salt}(manager, address(this), address(logic));
        assertEq(address(hook), expected, "mined hook address mismatch");

        MorphoERC3156Adapter adapter = new MorphoERC3156Adapter(MORPHO_BLUE, WETH);
        hook.setLenderForToken(WETH, address(adapter));
        hook.setFlashPrincipalForToken(WETH, PRINCIPAL_CAP);
        hook.setMaxFlashFeeBpsForToken(WETH, 1);
        hook.setMinNetProfitForToken(WETH, 1);

        _registerReferencePool();
        _initializeTriggerPool();
    }

    function testMultipleRoundsCaptureMoreOfSameTriggerEdge() public {
        if (!forkEnabled) {
            vm.skip(true, "set RUN_V4_LOOP_FORK=true and BASE_RPC_URL");
            return;
        }

        uint256 lenderBalanceBefore = IERC20(WETH).balanceOf(MORPHO_BLUE);
        uint256 snapshot = vm.snapshotState();

        hook.setHookMaxIterations(1);
        vm.recordLogs();
        _swapTriggerPool(makeAddr("one-round beneficiary"));
        Settlement memory oneRound = _extractSettlement(vm.getRecordedLogs());
        uint256 oneRoundSpread = _remainingSpread();

        assertTrue(vm.revertToState(snapshot), "snapshot restore failed");

        hook.setHookMaxIterations(MULTI_ROUND_LIMIT);
        vm.recordLogs();
        _swapTriggerPool(makeAddr("multi-round beneficiary"));
        Settlement memory multiRound = _extractSettlement(vm.getRecordedLogs());
        uint256 multiRoundSpread = _remainingSpread();

        assertEq(oneRound.iterations, 1, "one-round control did not stop at one");
        assertGt(multiRound.iterations, 1, "loop completed only one round");
        assertLe(multiRound.iterations, MULTI_ROUND_LIMIT, "loop exceeded configured bound");
        assertEq(multiRound.principal, oneRound.principal, "initial sizing changed");
        assertGt(multiRound.totalAmountSwapped, oneRound.totalAmountSwapped, "loop did not counter-trade more WETH");
        assertGt(multiRound.netProfit, oneRound.netProfit, "loop left profitable rounds unused");
        assertLt(multiRoundSpread, oneRoundSpread, "loop did not close more of the price gap");
        assertEq(IERC20(WETH).balanceOf(MORPHO_BLUE), lenderBalanceBefore, "Morpho was not repaid");
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0, "hook retained WETH");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook retained USDC");

        emit log_named_uint("Base fork block", block.number);
        emit log_named_decimal_uint("one-round WETH principal", oneRound.principal, 18);
        emit log_named_decimal_uint("one-round WETH traded", oneRound.totalAmountSwapped, 18);
        emit log_named_decimal_uint("one-round WETH profit", uint256(oneRound.netProfit), 18);
        emit log_named_uint("one-round residual ticks", oneRoundSpread);
        emit log_named_uint("multi-round iterations", multiRound.iterations);
        emit log_named_decimal_uint("multi-round WETH traded", multiRound.totalAmountSwapped, 18);
        emit log_named_decimal_uint("multi-round WETH profit", uint256(multiRound.netProfit), 18);
        emit log_named_uint("multi-round residual ticks", multiRoundSpread);
    }

    function _registerReferencePool() private {
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
        IPermit2LoopAllowance(PERMIT2).approve(WETH, V4_POSITION_MANAGER, uint160(wethMax), type(uint48).max);
        IPermit2LoopAllowance(PERMIT2).approve(USDC, V4_POSITION_MANAGER, uint160(usdcMax), type(uint48).max);

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
        IUniswapV4PositionManager(V4_POSITION_MANAGER).multicall(calls);
    }

    function _swapTriggerPool(address beneficiary) private {
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        IPermit2LoopAllowance(PERMIT2).approve(USDC, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);

        IV4Router.ExactInputSingleParams memory swapParams =
            IV4Router.ExactInputSingleParams(triggerKey, false, TRIGGER_AMOUNT, 1, abi.encodePacked(beneficiary));
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(swapParams);
        actionParams[1] = abi.encode(triggerKey.currency1, uint256(TRIGGER_AMOUNT));
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

    function _remainingSpread() private view returns (uint256) {
        (, int24 v4Tick,,) = IPoolManager(V4_POOL_MANAGER).getSlot0(triggerKey.toId());
        (, int24 externalTick,,,,,) = IUniswapV3Pool(UNISWAP_WETH_USDC_500).slot0();
        int256 spread = int256(v4Tick) - int256(externalTick);
        return uint256(spread < 0 ? -spread : spread);
    }

    function _pullUsdc(uint256 amount) private {
        vm.prank(AAVE_USDC_A_TOKEN);
        assertTrue(IERC20(USDC).transfer(address(this), amount), "USDC funding failed");
    }

    function _extractSettlement(Vm.Log[] memory entries) private pure returns (Settlement memory settled) {
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length == 4 && entries[i].topics[0] == FLASH_SETTLED_TOPIC0) {
                (,, settled.principal, settled.totalAmountSwapped,, settled.netProfit, settled.iterations,) = abi.decode(
                    entries[i].data, (address, address, uint256, uint256, uint256, int256, uint256, address)
                );
                return settled;
            }
        }
        revert("FlashLoanSettled not emitted");
    }
}
