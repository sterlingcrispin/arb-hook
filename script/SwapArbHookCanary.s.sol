// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {ArbHook} from "../contracts/ArbHook.sol";

interface IPermit2SwapAllowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Sends a protected USDC-to-WETH swap through the hooked canary pool.
contract SwapArbHookCanary is Script {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    error WrongChain();
    error InvalidHook();
    error InvalidSwap();
    error ApprovalFailed();

    function run() external {
        if (block.chainid != 8453) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address payer = vm.addr(privateKey);
        address beneficiary = vm.envOr("BENEFICIARY", payer);
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        uint256 amountIn = vm.envUint("USDC_SWAP_AMOUNT_RAW");
        uint256 amountOutMinimum = vm.envUint("MIN_WETH_OUT_WEI");

        if (address(hook).code.length == 0 || address(hook.poolManager()) != POOL_MANAGER) revert InvalidHook();
        if (
            beneficiary == address(0) || amountIn == 0 || amountIn > type(uint128).max || amountOutMinimum == 0
                || amountOutMinimum > type(uint128).max || IERC20(USDC).balanceOf(payer) < amountIn
        ) revert InvalidSwap();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        IV4Router.ExactInputSingleParams memory swapParams = IV4Router.ExactInputSingleParams({
            poolKey: key,
            zeroForOne: false,
            amountIn: uint128(amountIn),
            amountOutMinimum: uint128(amountOutMinimum),
            hookData: abi.encodePacked(beneficiary)
        });

        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(swapParams);
        actionParams[1] = abi.encode(key.currency1, amountIn);
        actionParams[2] = abi.encode(key.currency0, amountOutMinimum);
        bytes[] memory commandInputs = new bytes[](1);
        commandInputs[0] = abi.encode(
            abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                bytes1(uint8(Actions.SETTLE_ALL)),
                bytes1(uint8(Actions.TAKE_ALL))
            ),
            actionParams
        );

        uint256 payerWethBefore = IERC20(WETH).balanceOf(payer);
        uint256 beneficiaryWethBefore = IERC20(WETH).balanceOf(beneficiary);
        vm.startBroadcast(privateKey);
        if (!IERC20(USDC).approve(PERMIT2, amountIn)) revert ApprovalFailed();
        IPermit2SwapAllowance(PERMIT2).approve(USDC, UNIVERSAL_ROUTER, uint160(amountIn), type(uint48).max);
        IUniversalRouter(UNIVERSAL_ROUTER)
            .execute(abi.encodePacked(bytes1(uint8(Commands.V4_SWAP))), commandInputs, block.timestamp + 10 minutes);
        vm.stopBroadcast();

        console2.log("Payer WETH increase", IERC20(WETH).balanceOf(payer) - payerWethBefore);
        console2.log("Beneficiary WETH increase", IERC20(WETH).balanceOf(beneficiary) - beneficiaryWethBefore);
    }
}
