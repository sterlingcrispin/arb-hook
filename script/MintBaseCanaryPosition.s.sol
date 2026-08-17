// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ArbHook} from "../contracts/ArbHook.sol";
import {IPancakeV3Pool} from "../contracts/interfaces/IPancakeV3Pool.sol";
import {IUniswapV4PositionManager} from "../contracts/interfaces/uniswap/IUniswapV4PositionManager.sol";
import {BaseCanaryConfig as C} from "./BaseCanaryConfig.sol";

interface IPermit2PositionAllowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract MintBaseCanaryPosition is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error WrongChain();
    error InvalidHook();
    error HookNotDisabled();
    error InvalidAmounts();
    error InvalidPrice();
    error ApprovalFailed();

    function run() external returns (uint256 tokenId, uint128 liquidity) {
        if (block.chainid != C.CHAIN_ID) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        uint256 wethMax = vm.envUint("WETH_LP_AMOUNT_WEI");
        uint256 usdcMax = vm.envUint("USDC_LP_AMOUNT_RAW");
        if (address(hook).code.length == 0 || hook.owner() != owner || address(hook.poolManager()) != C.POOL_MANAGER) {
            revert InvalidHook();
        }
        (uint256 iterations,,,) = hook.getExecutionConfig();
        if (iterations != 0) revert HookNotDisabled();
        if (
            wethMax == 0 || usdcMax == 0 || wethMax > type(uint128).max || usdcMax > type(uint128).max
                || IERC20(C.WETH).balanceOf(owner) < wethMax || IERC20(C.USDC).balanceOf(owner) < usdcMax
        ) revert InvalidAmounts();

        IPancakeV3Pool source = IPancakeV3Pool(C.PANCAKE_WETH_USDC_100);
        if (source.token0() != C.WETH || source.token1() != C.USDC || source.fee() != 100) revert InvalidPrice();
        (, int24 referenceTick,,,,,) = source.slot0();
        int24 tickLower = _floorToSpacing(referenceTick - C.HALF_RANGE_TICKS, C.TICK_SPACING);
        int24 tickUpper = _ceilToSpacing(referenceTick + C.HALF_RANGE_TICKS, C.TICK_SPACING);

        PoolKey memory key = C.poolKey(address(hook));
        (uint160 sqrtPriceX96,,,) = IPoolManager(C.POOL_MANAGER).getSlot0(key.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtLower || sqrtPriceX96 >= sqrtUpper) revert InvalidPrice();
        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLower, sqrtUpper, wethMax, usdcMax);
        if (liquidity == 0) revert InvalidAmounts();

        IUniswapV4PositionManager positionManager = IUniswapV4PositionManager(C.POSITION_MANAGER);
        tokenId = positionManager.nextTokenId();
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(key, tickLower, tickUpper, liquidity, uint128(wethMax), uint128(usdcMax), owner, bytes(""));
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.MINT_POSITION)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );

        uint256 wethBefore = IERC20(C.WETH).balanceOf(owner);
        uint256 usdcBefore = IERC20(C.USDC).balanceOf(owner);
        vm.startBroadcast(privateKey);
        if (!IERC20(C.WETH).approve(C.PERMIT2, wethMax) || !IERC20(C.USDC).approve(C.PERMIT2, usdcMax)) {
            revert ApprovalFailed();
        }
        IPermit2PositionAllowance(C.PERMIT2).approve(C.WETH, C.POSITION_MANAGER, uint160(wethMax), type(uint48).max);
        IPermit2PositionAllowance(C.PERMIT2).approve(C.USDC, C.POSITION_MANAGER, uint160(usdcMax), type(uint48).max);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 10 minutes);
        vm.stopBroadcast();

        console2.log("V4 LP token ID", tokenId);
        console2.log("Position liquidity", positionManager.getPositionLiquidity(tokenId));
        console2.log("Tick lower", tickLower);
        console2.log("Tick upper", tickUpper);
        console2.log("WETH deposited", wethBefore - IERC20(C.WETH).balanceOf(owner));
        console2.log("USDC deposited", usdcBefore - IERC20(C.USDC).balanceOf(owner));
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
}
