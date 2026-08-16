// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ArbHook} from "../contracts/ArbHook.sol";
import {MorphoERC3156Adapter} from "../contracts/MorphoERC3156Adapter.sol";
import {BaseCanaryConfig as C} from "./BaseCanaryConfig.sol";

contract ConfigureBaseCanary is Script {
    error WrongChain();
    error InvalidHook();
    error InvalidAdapter();
    error UnexpectedDefaults();
    error ConfigurationMismatch();

    function run() external {
        if (block.chainid != C.CHAIN_ID) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privateKey);
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        address wethAdapter = vm.envAddress("WETH_ADAPTER");
        address usdcAdapter = vm.envAddress("USDC_ADAPTER");

        if (address(hook).code.length == 0 || hook.owner() != owner || address(hook.poolManager()) != C.POOL_MANAGER) {
            revert InvalidHook();
        }
        _attestAdapter(wethAdapter, C.WETH);
        _attestAdapter(usdcAdapter, C.USDC);

        (uint256 iterations, uint16 spread, uint16 consumption, uint256 impact) = hook.getExecutionConfig();
        (uint32 reserve, uint32 limit) = hook.getGasBounds();
        if (
            iterations != 0 || spread != C.MIN_SPREAD_BPS || consumption != C.CHUNK_SPREAD_CONSUMPTION_BPS
                || impact != C.MAX_IMPACT_BPS || reserve != C.HOOK_GAS_RESERVE || limit != C.HOOK_GAS_LIMIT
        ) revert UnexpectedDefaults();

        vm.startBroadcast(privateKey);
        _configureToken(hook, C.WETH, wethAdapter, C.WETH_PRINCIPAL_CAP, C.WETH_MIN_NET_PROFIT);
        _configureToken(hook, C.USDC, usdcAdapter, C.USDC_PRINCIPAL_CAP, C.USDC_MIN_NET_PROFIT);
        vm.stopBroadcast();

        _verifyToken(hook, C.WETH, wethAdapter, C.WETH_PRINCIPAL_CAP, C.WETH_MIN_NET_PROFIT);
        _verifyToken(hook, C.USDC, usdcAdapter, C.USDC_PRINCIPAL_CAP, C.USDC_MIN_NET_PROFIT);
        console2.log("Hook configured and disabled", address(hook));
    }

    function _attestAdapter(address adapter, address token) private view {
        if (
            adapter.code.length == 0 || address(MorphoERC3156Adapter(adapter).morpho()) != C.MORPHO_BLUE
                || MorphoERC3156Adapter(adapter).supportedToken() != token
        ) revert InvalidAdapter();
    }

    function _configureToken(ArbHook hook, address token, address adapter, uint256 principalCap, uint256 minNetProfit)
        private
    {
        hook.setLenderForToken(token, adapter);
        hook.setMaxFlashFeeBpsForToken(token, C.MAX_FLASH_FEE_BPS);
        hook.setMinNetProfitForToken(token, minNetProfit);
        hook.setFlashPrincipalForToken(token, principalCap);
    }

    function _verifyToken(ArbHook hook, address token, address adapter, uint256 principalCap, uint256 minNetProfit)
        private
        view
    {
        (address lender, uint256 cap, uint256 feeBps, uint256 profit) = hook.getFlashConfig(token);
        if (lender != adapter || cap != principalCap || feeBps != C.MAX_FLASH_FEE_BPS || profit != minNetProfit) {
            revert ConfigurationMismatch();
        }
    }
}
