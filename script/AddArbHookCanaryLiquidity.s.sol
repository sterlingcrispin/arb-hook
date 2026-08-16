// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ArbHook} from "../contracts/ArbHook.sol";
import {IUniswapV4PositionManager} from "../contracts/interfaces/uniswap/IUniswapV4PositionManager.sol";

interface IPermit2IncreaseAllowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Adds full-range WETH/USDC liquidity to the existing canary position.
contract AddArbHookCanaryLiquidity is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    error WrongChain();
    error InvalidHook();
    error InvalidAmounts();
    error NotPositionOwner();
    error ApprovalFailed();

    function run() external returns (uint128 liquidity) {
        if (block.chainid != 8453) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        uint256 tokenId = vm.envUint("POSITION_TOKEN_ID");
        uint256 amount0Max = vm.envUint("WETH_LP_AMOUNT_WEI");
        uint256 amount1Max = vm.envUint("USDC_LP_AMOUNT_RAW");

        if (address(hook).code.length == 0 || address(hook.poolManager()) != POOL_MANAGER) revert InvalidHook();
        if (amount0Max == 0 || amount1Max == 0 || amount0Max > type(uint128).max || amount1Max > type(uint128).max) {
            revert InvalidAmounts();
        }

        IUniswapV4PositionManager positionManager = IUniswapV4PositionManager(POSITION_MANAGER);
        if (positionManager.ownerOf(tokenId) != owner) revert NotPositionOwner();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );
        if (liquidity == 0) revert InvalidAmounts();

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, liquidity, uint128(amount0Max), uint128(amount1Max), bytes(""));
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.INCREASE_LIQUIDITY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );

        uint256 wethBefore = IERC20(WETH).balanceOf(owner);
        uint256 usdcBefore = IERC20(USDC).balanceOf(owner);
        vm.startBroadcast(privateKey);
        if (!IERC20(WETH).approve(PERMIT2, amount0Max) || !IERC20(USDC).approve(PERMIT2, amount1Max)) {
            revert ApprovalFailed();
        }
        IPermit2IncreaseAllowance(PERMIT2).approve(WETH, POSITION_MANAGER, uint160(amount0Max), type(uint48).max);
        IPermit2IncreaseAllowance(PERMIT2).approve(USDC, POSITION_MANAGER, uint160(amount1Max), type(uint48).max);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 10 minutes);
        vm.stopBroadcast();

        console2.log("Liquidity added", uint256(liquidity));
        console2.log("WETH deposited", wethBefore - IERC20(WETH).balanceOf(owner));
        console2.log("USDC deposited", usdcBefore - IERC20(USDC).balanceOf(owner));
    }
}
