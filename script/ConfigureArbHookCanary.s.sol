// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ArbHook} from "../contracts/ArbHook.sol";

contract ConfigureArbHookCanary is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    error WrongChain();
    error InvalidEconomicConfig();
    error NotHookOwner();

    function run() external {
        if (block.chainid != 8453) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        // LENDER_ADAPTER selects which deployed ERC-3156 adapter goes live.
        // AAVE_ADAPTER remains accepted so existing runbook invocations still work.
        address adapter = vm.envOr("LENDER_ADAPTER", address(0));
        if (adapter == address(0)) adapter = vm.envAddress("AAVE_ADAPTER");
        uint256 principalCap = vm.envUint("WETH_FLASH_PRINCIPAL_CAP_WEI");
        uint256 maxFeeBps = vm.envUint("WETH_MAX_FLASH_FEE_BPS");
        uint256 minNetProfit = vm.envUint("WETH_MIN_NET_PROFIT_WEI");
        uint256 minTriggerAmount = vm.envUint("USDC_MIN_TRIGGER_AMOUNT_RAW");

        if (
            adapter == address(0) || principalCap == 0 || maxFeeBps == 0 || minNetProfit == 0
                || minTriggerAmount == 0
        ) {
            revert InvalidEconomicConfig();
        }
        if (hook.owner() != vm.addr(privateKey)) revert NotHookOwner();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        vm.startBroadcast(privateKey);
        hook.setLenderForToken(WETH, adapter);
        hook.setMaxFlashFeeBpsForToken(WETH, maxFeeBps);
        hook.setMinNetProfitForToken(WETH, minNetProfit);
        hook.setFlashPrincipalForToken(WETH, principalCap);
        hook.setMinTriggerAmount(key.toId(), false, minTriggerAmount);
        vm.stopBroadcast();

        console2.log("WETH principal cap (wei)", principalCap);
        console2.log("WETH max flash fee bps", maxFeeBps);
        console2.log("WETH minimum net profit (wei)", minNetProfit);
        console2.log("USDC minimum trigger amount (raw)", minTriggerAmount);
        console2.log("V4 trigger PoolId");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }
}
