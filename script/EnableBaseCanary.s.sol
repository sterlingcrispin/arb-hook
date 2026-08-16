// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ArbHook} from "../contracts/ArbHook.sol";
import {IUniswapV4PositionManager} from "../contracts/interfaces/uniswap/IUniswapV4PositionManager.sol";
import {BaseCanaryConfig as C} from "./BaseCanaryConfig.sol";

contract EnableBaseCanary is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error WrongChain();
    error InvalidConfiguration();

    function run() external {
        if (block.chainid != C.CHAIN_ID) revert WrongChain();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        uint256 tokenId = vm.envUint("POSITION_TOKEN_ID");
        if (address(hook).code.length == 0 || hook.owner() != owner) revert InvalidConfiguration();
        (uint256 iterations, uint16 spread, uint16 consumption, uint256 impact) = hook.getExecutionConfig();
        (uint32 reserve, uint32 limit) = hook.getGasBounds();
        if (
            iterations != 0 || spread != C.MIN_SPREAD_BPS || consumption != C.CHUNK_SPREAD_CONSUMPTION_BPS
                || impact != C.MAX_IMPACT_BPS || reserve != C.HOOK_GAS_RESERVE || limit != C.HOOK_GAS_LIMIT
        ) revert InvalidConfiguration();
        _verifyToken(hook, C.WETH, C.WETH_PRINCIPAL_CAP, C.WETH_MIN_NET_PROFIT);
        _verifyToken(hook, C.USDC, C.USDC_PRINCIPAL_CAP, C.USDC_MIN_NET_PROFIT);
        IUniswapV4PositionManager positionManager = IUniswapV4PositionManager(C.POSITION_MANAGER);
        if (positionManager.ownerOf(tokenId) != owner || positionManager.getPositionLiquidity(tokenId) == 0) {
            revert InvalidConfiguration();
        }
        (uint160 sqrtPriceX96,,,) = IPoolManager(C.POOL_MANAGER).getSlot0(C.poolKey(address(hook)).toId());
        if (sqrtPriceX96 == 0) revert InvalidConfiguration();

        vm.broadcast(privateKey);
        hook.setHookMaxIterations(C.MAX_ITERATIONS);

        (iterations,,,) = hook.getExecutionConfig();
        if (iterations != C.MAX_ITERATIONS) revert InvalidConfiguration();
        console2.log("Canary enabled with iterations", iterations);
    }

    function _verifyToken(ArbHook hook, address token, uint256 expectedCap, uint256 expectedProfit) private view {
        (address lender, uint256 cap, uint256 maxFee, uint256 minProfit) = hook.getFlashConfig(token);
        if (
            lender.code.length == 0 || cap != expectedCap || maxFee != C.MAX_FLASH_FEE_BPS
                || minProfit != expectedProfit
        ) revert InvalidConfiguration();
    }
}
