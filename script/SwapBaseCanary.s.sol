// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {ArbHook} from "../contracts/ArbHook.sol";
import {BaseCanaryConfig as C} from "./BaseCanaryConfig.sol";

interface IPermit2SwapAllowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract SwapBaseCanary is Script {
    error WrongChain();
    error InvalidHook();
    error HookNotEnabled();
    error InvalidSwap();
    error ApprovalFailed();

    function run() external returns (uint256 amountReceived) {
        if (block.chainid != C.CHAIN_ID) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address payer = vm.addr(privateKey);
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        bool zeroForOne = vm.envBool("ZERO_FOR_ONE");
        uint256 amountIn = vm.envUint("SWAP_AMOUNT_IN");
        uint256 amountOutMinimum = vm.envUint("SWAP_AMOUNT_OUT_MINIMUM");
        address tokenIn = zeroForOne ? C.WETH : C.USDC;
        address tokenOut = zeroForOne ? C.USDC : C.WETH;

        if (address(hook).code.length == 0 || address(hook.poolManager()) != C.POOL_MANAGER) revert InvalidHook();
        (uint256 iterations,,,) = hook.getExecutionConfig();
        if (iterations != C.MAX_ITERATIONS) revert HookNotEnabled();
        if (
            amountIn == 0 || amountOutMinimum == 0 || amountIn > type(uint128).max
                || amountOutMinimum > type(uint128).max || IERC20(tokenIn).balanceOf(payer) < amountIn
        ) revert InvalidSwap();

        IV4Router.ExactInputSingleParams memory swapParams = IV4Router.ExactInputSingleParams({
            poolKey: C.poolKey(address(hook)),
            zeroForOne: zeroForOne,
            amountIn: uint128(amountIn),
            amountOutMinimum: uint128(amountOutMinimum),
            hookData: bytes("")
        });
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(swapParams);
        actionParams[1] = abi.encode(zeroForOne ? swapParams.poolKey.currency0 : swapParams.poolKey.currency1, amountIn);
        actionParams[2] =
            abi.encode(zeroForOne ? swapParams.poolKey.currency1 : swapParams.poolKey.currency0, amountOutMinimum);
        bytes[] memory commandInputs = new bytes[](1);
        commandInputs[0] = abi.encode(
            abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                bytes1(uint8(Actions.SETTLE_ALL)),
                bytes1(uint8(Actions.TAKE_ALL))
            ),
            actionParams
        );

        uint256 beforeBalance = IERC20(tokenOut).balanceOf(payer);
        vm.startBroadcast(privateKey);
        if (!IERC20(tokenIn).approve(C.PERMIT2, amountIn)) revert ApprovalFailed();
        IPermit2SwapAllowance(C.PERMIT2).approve(tokenIn, C.UNIVERSAL_ROUTER, uint160(amountIn), type(uint48).max);
        IUniversalRouter(C.UNIVERSAL_ROUTER)
            .execute(abi.encodePacked(bytes1(uint8(Commands.V4_SWAP))), commandInputs, block.timestamp + 10 minutes);
        vm.stopBroadcast();

        amountReceived = IERC20(tokenOut).balanceOf(payer) - beforeBalance;
        console2.log("Token received", tokenOut);
        console2.log("Swap output received", amountReceived);
    }
}
