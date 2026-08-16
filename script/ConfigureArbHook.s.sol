// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ArbHook} from "../contracts/ArbHook.sol";

contract ConfigureArbHook is Script {
    error WrongChain();
    error InvalidEconomicConfig();
    error NotHookOwner();

    function run() external {
        if (block.chainid != 8453) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        address token = vm.envAddress("FLASH_TOKEN");
        address adapter = vm.envAddress("LENDER_ADAPTER");
        uint256 principalCap = vm.envUint("FLASH_PRINCIPAL_CAP");
        uint256 maxFeeBps = vm.envUint("MAX_FLASH_FEE_BPS");
        uint256 minNetProfit = vm.envUint("MIN_NET_PROFIT");

        if (
            token == address(0) ||
            adapter == address(0) ||
            principalCap == 0 ||
            maxFeeBps == 0 ||
            minNetProfit == 0
        ) {
            revert InvalidEconomicConfig();
        }
        if (hook.owner() != vm.addr(privateKey)) revert NotHookOwner();

        vm.startBroadcast(privateKey);
        hook.setLenderForToken(token, adapter);
        hook.setMaxFlashFeeBpsForToken(token, maxFeeBps);
        hook.setMinNetProfitForToken(token, minNetProfit);
        hook.setFlashPrincipalForToken(token, principalCap);
        vm.stopBroadcast();

        console2.log("Flash token", token);
        console2.log("Principal cap", principalCap);
        console2.log("Maximum flash fee bps", maxFeeBps);
        console2.log("Minimum net profit", minNetProfit);
    }
}
