// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ArbHook} from "../contracts/ArbHook.sol";
import {ArbitrageLogic} from "../contracts/ArbitrageLogic.sol";
import {MorphoERC3156Adapter} from "../contracts/MorphoERC3156Adapter.sol";
import {BaseCanaryConfig as C} from "./BaseCanaryConfig.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract DeployArbHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    error WrongChain();

    function run()
        external
        returns (ArbHook hook, ArbitrageLogic logic, MorphoERC3156Adapter wethAdapter, MorphoERC3156Adapter usdcAdapter)
    {
        if (block.chainid != C.CHAIN_ID) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envOr("OWNER", vm.addr(privateKey));

        vm.startBroadcast(privateKey);
        logic = new ArbitrageLogic();
        wethAdapter = new MorphoERC3156Adapter(C.MORPHO_BLUE, C.WETH);
        usdcAdapter = new MorphoERC3156Adapter(C.MORPHO_BLUE, C.USDC);
        vm.stopBroadcast();

        bytes memory args = abi.encode(IPoolManager(C.POOL_MANAGER), owner, address(logic));
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, Hooks.AFTER_SWAP_FLAG, type(ArbHook).creationCode, args);

        vm.broadcast(privateKey);
        hook = new ArbHook{salt: salt}(IPoolManager(C.POOL_MANAGER), owner, address(logic));
        require(address(hook) == expected, "hook address mismatch");

        console2.log("ArbitrageLogic", address(logic));
        console2.log("WETH MorphoAdapter", address(wethAdapter));
        console2.log("USDC MorphoAdapter", address(usdcAdapter));
        console2.log("ArbHook", address(hook));
        console2.logBytes32(salt);
    }
}
