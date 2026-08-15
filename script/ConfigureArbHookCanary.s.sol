// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ArbHook} from "../contracts/ArbHook.sol";

contract ConfigureArbHookCanary is Script {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

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

        if (adapter == address(0) || principalCap == 0 || maxFeeBps == 0 || minNetProfit == 0) {
            revert InvalidEconomicConfig();
        }
        if (hook.owner() != vm.addr(privateKey)) revert NotHookOwner();

        vm.startBroadcast(privateKey);
        hook.setLenderForToken(WETH, adapter);
        hook.setMaxFlashFeeBpsForToken(WETH, maxFeeBps);
        hook.setMinNetProfitForToken(WETH, minNetProfit);
        hook.setFlashPrincipalForToken(WETH, principalCap);
        vm.stopBroadcast();

        console2.log("WETH principal cap (wei)", principalCap);
        console2.log("WETH max flash fee bps", maxFeeBps);
        console2.log("WETH minimum net profit (wei)", minNetProfit);
    }
}
