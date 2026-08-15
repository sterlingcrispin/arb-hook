// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ArbHook} from "../contracts/ArbHook.sol";
import {IUniswapV4PositionManager} from "../contracts/interfaces/uniswap/IUniswapV4PositionManager.sol";

/// @notice Burns the first-stage canary position and returns its WETH and USDC.
contract RemoveArbHookCanaryLiquidity is Script {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;

    error WrongChain();
    error InvalidHook();
    error InvalidWithdrawal();
    error NotPositionOwner();

    function run() external {
        if (block.chainid != 8453) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        uint256 tokenId = vm.envUint("POSITION_TOKEN_ID");
        uint256 amount0Min = vm.envUint("MIN_WETH_WITHDRAW_WEI");
        uint256 amount1Min = vm.envUint("MIN_USDC_WITHDRAW_RAW");

        if (address(hook).code.length == 0 || address(hook.poolManager()) != POOL_MANAGER) revert InvalidHook();
        if ((amount0Min == 0 && amount1Min == 0) || amount0Min > type(uint128).max || amount1Min > type(uint128).max) {
            revert InvalidWithdrawal();
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
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, uint128(amount0Min), uint128(amount1Min), bytes(""));
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.BURN_POSITION)),
            bytes1(uint8(Actions.CLOSE_CURRENCY)),
            bytes1(uint8(Actions.CLOSE_CURRENCY))
        );

        uint256 wethBefore = IERC20(WETH).balanceOf(owner);
        uint256 usdcBefore = IERC20(USDC).balanceOf(owner);
        vm.broadcast(privateKey);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 10 minutes);

        console2.log("WETH withdrawn", IERC20(WETH).balanceOf(owner) - wethBefore);
        console2.log("USDC withdrawn", IERC20(USDC).balanceOf(owner) - usdcBefore);
    }
}
