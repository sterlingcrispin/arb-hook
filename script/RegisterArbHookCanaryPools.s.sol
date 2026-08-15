// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ArbHook} from "../contracts/ArbHook.sol";
import {ArbUtils} from "../contracts/ArbUtils.sol";

interface IV3PoolManifestEntry {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

/// @notice Registers the reviewed first-stage Base canary pool book.
contract RegisterArbHookCanaryPools is Script {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant UNISWAP_WETH_USDC_500 = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    error WrongChain();
    error NotHookOwner();
    error InvalidPoolManifest();

    function run() external {
        if (block.chainid != 8453) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        if (hook.owner() != vm.addr(privateKey)) revert NotHookOwner();

        _attestPool(UNISWAP_WETH_USDC_500, UNISWAP_V3_FACTORY, 500);

        address[] memory pools = new address[](1);
        pools[0] = UNISWAP_WETH_USDC_500;

        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;

        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](1);
        types[0] = ArbUtils.PoolType.V3;

        vm.broadcast(privateKey);
        hook.addPools(WETH, pools, fees, types);

        console2.log("Registered WETH/USDC reference pools", pools.length);
        console2.log("Uniswap v3 reference", pools[0]);
    }

    function _attestPool(address poolAddress, address expectedFactory, uint24 expectedFee) private view {
        IV3PoolManifestEntry pool = IV3PoolManifestEntry(poolAddress);
        if (
            poolAddress.code.length == 0 || pool.factory() != expectedFactory || pool.token0() != WETH
                || pool.token1() != USDC || pool.fee() != expectedFee
        ) revert InvalidPoolManifest();
    }
}
