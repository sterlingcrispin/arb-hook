// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter02} from "../contracts/interfaces/uniswap/ISwapRouter02.sol";
import {BaseCanaryConfig as C} from "./BaseCanaryConfig.sol";

interface IWETHCanary is IERC20 {
    function deposit() external payable;
}

contract RebalanceBaseCanaryWallet is Script {
    error WrongChain();
    error InvalidRouter();
    error InvalidAmounts();
    error ApprovalFailed();

    function run() external returns (uint256 amountOut) {
        if (block.chainid != C.CHAIN_ID) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        uint256 nativeToWrap = vm.envUint("NATIVE_WRAP_WEI");
        uint256 wethToSwap = vm.envUint("WETH_SWAP_WEI");
        uint256 minUsdcOut = vm.envUint("MIN_USDC_OUT_RAW");
        uint256 nativeReserve = vm.envUint("MIN_NATIVE_RESERVE_WEI");
        ISwapRouter02 router = ISwapRouter02(C.UNISWAP_V3_ROUTER);

        if (router.WETH9() != C.WETH) revert InvalidRouter();
        if (
            wethToSwap == 0 || minUsdcOut == 0 || owner.balance < nativeToWrap + nativeReserve
                || IERC20(C.WETH).balanceOf(owner) + nativeToWrap < wethToSwap
        ) revert InvalidAmounts();

        uint256 wethBefore = IERC20(C.WETH).balanceOf(owner);
        uint256 usdcBefore = IERC20(C.USDC).balanceOf(owner);
        vm.startBroadcast(privateKey);
        if (nativeToWrap != 0) IWETHCanary(C.WETH).deposit{value: nativeToWrap}();
        if (!IERC20(C.WETH).approve(C.UNISWAP_V3_ROUTER, wethToSwap)) revert ApprovalFailed();
        amountOut = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: C.WETH,
                tokenOut: C.USDC,
                fee: 100,
                recipient: owner,
                amountIn: wethToSwap,
                amountOutMinimum: minUsdcOut,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopBroadcast();

        console2.log("Native ETH wrapped", nativeToWrap);
        console2.log("WETH swapped", wethBefore + nativeToWrap - IERC20(C.WETH).balanceOf(owner));
        console2.log("USDC received", IERC20(C.USDC).balanceOf(owner) - usdcBefore);
        console2.log("Router amount out", amountOut);
    }
}
