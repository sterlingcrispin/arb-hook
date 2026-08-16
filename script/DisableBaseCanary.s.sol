// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ArbHook} from "../contracts/ArbHook.sol";
import {BaseCanaryConfig as C} from "./BaseCanaryConfig.sol";

contract DisableBaseCanary is Script {
    error WrongChain();
    error InvalidHook();
    error DisableFailed();

    function run() external {
        if (block.chainid != C.CHAIN_ID) revert WrongChain();
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        if (address(hook).code.length == 0 || hook.owner() != vm.addr(privateKey)) revert InvalidHook();

        vm.startBroadcast(privateKey);
        hook.setHookMaxIterations(0);
        hook.setFlashPrincipalForToken(C.WETH, 0);
        hook.setFlashPrincipalForToken(C.USDC, 0);
        vm.stopBroadcast();

        (uint256 iterations,,,) = hook.getExecutionConfig();
        (, uint256 wethCap,,) = hook.getFlashConfig(C.WETH);
        (, uint256 usdcCap,,) = hook.getFlashConfig(C.USDC);
        if (iterations != 0 || wethCap != 0 || usdcCap != 0) revert DisableFailed();
        console2.log("Canary disabled", address(hook));
    }
}
