// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ArbHook} from "../ArbHook.sol";

/// @notice Helper contract to deploy ArbHook instances with the proper hook flag encoded in the address.
contract HookDeployer {

    /// @notice Deploys ArbHook via CREATE2 so the resulting address encodes the desired permissions.
    /// @param poolManager PoolManager reference
    /// @param owner Owner of the hook
    /// @param arbLib ArbitrageLogic implementation
    /// @param dataStorage Trade data sink
    /// @param flags Hook permission bitmask (e.g. Hooks.AFTER_SWAP_FLAG)
    function deployArbHook(
        IPoolManager poolManager,
        address owner,
        address arbLib,
        address dataStorage,
        uint160 flags
    ) external returns (address hookAddress) {
        bytes memory constructorArgs = abi.encode(poolManager, owner, arbLib, dataStorage);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ArbHook).creationCode, constructorArgs);

        ArbHook hook = new ArbHook{salt: salt}(poolManager, owner, arbLib, dataStorage);
        require(address(hook) == predicted, "HookDeployer: address mismatch");
        return address(hook);
    }
}
