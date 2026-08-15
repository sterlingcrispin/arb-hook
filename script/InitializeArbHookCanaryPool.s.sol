// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ArbHook} from "../contracts/ArbHook.sol";
import {IUniswapV3Pool} from "../contracts/interfaces/uniswap/IUniswapV3Pool.sol";
import {IUniswapV4PositionManager} from "../contracts/interfaces/uniswap/IUniswapV4PositionManager.sol";

interface IPermit2CanaryAllowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Atomically initializes the hooked WETH/USDC pool and mints its first full-range position.
contract InitializeArbHookCanaryPool is Script {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant UNISWAP_WETH_USDC_500 = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    uint24 internal constant LP_FEE = 500;
    int24 internal constant TICK_SPACING = 10;

    error WrongChain();
    error InvalidHook();
    error InvalidAmounts();
    error InvalidPriceSource();
    error ApprovalFailed();

    function run() external returns (uint256 tokenId, uint128 liquidity) {
        if (block.chainid != 8453) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address payer = vm.addr(privateKey);
        address recipient = vm.envOr("LP_RECIPIENT", payer);
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        uint256 amount0Max = vm.envUint("WETH_LP_AMOUNT_WEI");
        uint256 amount1Max = vm.envUint("USDC_LP_AMOUNT_RAW");

        if (address(hook).code.length == 0 || address(hook.poolManager()) != POOL_MANAGER) revert InvalidHook();
        if (amount0Max == 0 || amount1Max == 0 || amount0Max > type(uint160).max || amount1Max > type(uint160).max) {
            revert InvalidAmounts();
        }

        IUniswapV3Pool priceSource = IUniswapV3Pool(UNISWAP_WETH_USDC_500);
        if (priceSource.token0() != WETH || priceSource.token1() != USDC || priceSource.fee() != LP_FEE) {
            revert InvalidPriceSource();
        }
        (uint160 sqrtPriceX96,,,,,,) = priceSource.slot0();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );
        if (liquidity == 0) revert InvalidAmounts();

        IUniswapV4PositionManager positionManager = IUniswapV4PositionManager(POSITION_MANAGER);
        tokenId = positionManager.nextTokenId();

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, bytes(""));
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.MINT_POSITION)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IUniswapV4PositionManager.initializePool, (key, sqrtPriceX96));
        calls[1] = abi.encodeCall(
            IUniswapV4PositionManager.modifyLiquidities, (abi.encode(actions, params), block.timestamp + 10 minutes)
        );

        vm.startBroadcast(privateKey);
        if (!IERC20(WETH).approve(PERMIT2, amount0Max) || !IERC20(USDC).approve(PERMIT2, amount1Max)) {
            revert ApprovalFailed();
        }
        IPermit2CanaryAllowance(PERMIT2).approve(WETH, POSITION_MANAGER, uint160(amount0Max), type(uint48).max);
        IPermit2CanaryAllowance(PERMIT2).approve(USDC, POSITION_MANAGER, uint160(amount1Max), type(uint48).max);
        positionManager.multicall(calls);
        vm.stopBroadcast();

        console2.log("V4 LP token ID", tokenId);
        console2.log("V4 LP recipient", recipient);
        console2.log("V4 full-range liquidity", uint256(liquidity));
        console2.log("Opening sqrtPriceX96", uint256(sqrtPriceX96));
    }
}
