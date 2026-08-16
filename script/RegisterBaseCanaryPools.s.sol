// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ArbHook} from "../contracts/ArbHook.sol";
import {ArbUtils} from "../contracts/ArbUtils.sol";
import {BaseCanaryConfig as C} from "./BaseCanaryConfig.sol";

interface IV3PoolManifestEntry {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

contract RegisterBaseCanaryPools is Script {
    error WrongChain();
    error InvalidHook();
    error InvalidPoolManifest();

    function run() external {
        if (block.chainid != C.CHAIN_ID) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        if (
            address(hook).code.length == 0 || hook.owner() != vm.addr(privateKey)
                || address(hook.poolManager()) != C.POOL_MANAGER
        ) revert InvalidHook();

        _attestPool(C.PANCAKE_WETH_USDC_100, C.PANCAKE_V3_FACTORY);
        _attestPool(C.UNISWAP_WETH_USDC_100, C.UNISWAP_V3_FACTORY);

        address[] memory pools = new address[](2);
        pools[0] = C.PANCAKE_WETH_USDC_100;
        pools[1] = C.UNISWAP_WETH_USDC_100;
        uint24[] memory fees = new uint24[](2);
        fees[0] = 100;
        fees[1] = 100;
        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](2);
        types[0] = ArbUtils.PoolType.PANCAKESWAP_V3;
        types[1] = ArbUtils.PoolType.V3;

        vm.startBroadcast(privateKey);
        hook.addPools(C.WETH, pools, fees, types);
        hook.addPools(C.USDC, pools, fees, types);
        vm.stopBroadcast();

        console2.log("Registered two WETH/USDC references for both loan directions");
    }

    function _attestPool(address poolAddress, address factory) private view {
        IV3PoolManifestEntry pool = IV3PoolManifestEntry(poolAddress);
        if (
            poolAddress.code.length == 0 || pool.factory() != factory || pool.token0() != C.WETH
                || pool.token1() != C.USDC || pool.fee() != 100
        ) revert InvalidPoolManifest();
    }
}
