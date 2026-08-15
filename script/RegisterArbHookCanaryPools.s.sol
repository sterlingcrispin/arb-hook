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
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    address internal constant PANCAKE_CBBTC_WETH_100 = 0xC211e1f853A898Bd1302385CCdE55f33a8C4B3f3;
    address internal constant UNISWAP_CBBTC_WETH_500 = 0x7AeA2E8A3843516afa07293a10Ac8E49906dabD1;

    error WrongChain();
    error NotHookOwner();
    error InvalidPoolManifest();

    function run() external {
        if (block.chainid != 8453) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        ArbHook hook = ArbHook(payable(vm.envAddress("HOOK")));
        if (hook.owner() != vm.addr(privateKey)) revert NotHookOwner();

        _attestPool(PANCAKE_CBBTC_WETH_100, PANCAKE_V3_FACTORY, 100);
        _attestPool(UNISWAP_CBBTC_WETH_500, UNISWAP_V3_FACTORY, 500);

        address[] memory pools = new address[](2);
        pools[0] = PANCAKE_CBBTC_WETH_100;
        pools[1] = UNISWAP_CBBTC_WETH_500;

        uint24[] memory fees = new uint24[](2);
        fees[0] = 100;
        fees[1] = 500;

        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](2);
        types[0] = ArbUtils.PoolType.PANCAKESWAP_V3;
        types[1] = ArbUtils.PoolType.V3;

        vm.broadcast(privateKey);
        hook.addPools(WETH, pools, fees, types);

        console2.log("Registered WETH/cbBTC pools", pools.length);
        console2.log("PancakeSwap v3", pools[0]);
        console2.log("Uniswap v3", pools[1]);
    }

    function _attestPool(address poolAddress, address expectedFactory, uint24 expectedFee) private view {
        IV3PoolManifestEntry pool = IV3PoolManifestEntry(poolAddress);
        if (
            poolAddress.code.length == 0 || pool.factory() != expectedFactory || pool.token0() != WETH
                || pool.token1() != CBBTC || pool.fee() != expectedFee
        ) revert InvalidPoolManifest();
    }
}
