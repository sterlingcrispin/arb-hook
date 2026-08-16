// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ArbHook} from "../contracts/ArbHook.sol";
import {IUniswapV4PositionManager} from "../contracts/interfaces/uniswap/IUniswapV4PositionManager.sol";
import {BaseCanaryConfig as C} from "./BaseCanaryConfig.sol";

contract RemoveBaseCanaryLiquidity is Script {
    error WrongChain();
    error InvalidHook();
    error HookNotDisabled();
    error NotPositionOwner();

    function run() external {
        if (block.chainid != C.CHAIN_ID) revert WrongChain();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        uint256 tokenId = vm.envUint("POSITION_TOKEN_ID");

        if (address(hook).code.length == 0 || hook.owner() != owner) revert InvalidHook();
        (uint256 iterations,,,) = hook.getExecutionConfig();
        if (iterations != 0) revert HookNotDisabled();
        IUniswapV4PositionManager positionManager = IUniswapV4PositionManager(C.POSITION_MANAGER);
        if (positionManager.ownerOf(tokenId) != owner) revert NotPositionOwner();

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(C.poolKey(address(hook)).currency0, C.poolKey(address(hook)).currency1, owner);
        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.BURN_POSITION)), bytes1(uint8(Actions.TAKE_PAIR)));

        uint256 wethBefore = IERC20(C.WETH).balanceOf(owner);
        uint256 usdcBefore = IERC20(C.USDC).balanceOf(owner);
        vm.broadcast(privateKey);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 10 minutes);

        console2.log("WETH withdrawn", IERC20(C.WETH).balanceOf(owner) - wethBefore);
        console2.log("USDC withdrawn", IERC20(C.USDC).balanceOf(owner) - usdcBefore);
    }
}
