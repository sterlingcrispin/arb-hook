// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {ArbHook} from "../contracts/ArbHook.sol";
import {ArbitrageLogic} from "../contracts/ArbitrageLogic.sol";
import {ArbExecutor} from "../contracts/ArbExecutor.sol";
import {DataStorage} from "../contracts/DataStorage.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Deploys the arbitrage execution components and a permission-mined
///         ArbHook. The hook owner is deliberately the broadcasting account so
///         the script can atomically authorize the hook as DataStorage writer.
/// @dev Invoke with `--always-use-create-2-factory`; HookMiner targets Foundry's
///      canonical CREATE2 deployer at 0x4e59... so the deployed address carries
///      the required Uniswap v4 permission bits. Foundry automatically deploys
///      and links the external ArbMath library before this script runs.
contract DeployArbHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    error InvalidPoolManager(address manager);
    error OwnerMustMatchBroadcaster(address owner, address broadcaster);
    error Create2FactoryNotAvailable(address factory);
    error HookAddressMismatch(address deployed, address predicted);

    event ArbHookDeployment(
        address indexed hook, address indexed executor, address indexed logic, address dataStorage, bytes32 salt
    );

    /// @dev Required environment:
    ///      PRIVATE_KEY: broadcaster and hook owner private key.
    ///      V4_POOL_MANAGER: deployed Uniswap v4 PoolManager address.
    ///      ARB_HOOK_OWNER is optional and, if supplied, must be the broadcaster.
    function run()
        external
        returns (ArbitrageLogic logic, DataStorage dataStorage, ArbExecutor executor, ArbHook hook)
    {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);
        address owner = vm.envOr("ARB_HOOK_OWNER", broadcaster);
        address managerAddress = vm.envAddress("V4_POOL_MANAGER");

        if (managerAddress == address(0) || managerAddress.code.length == 0) {
            revert InvalidPoolManager(managerAddress);
        }
        if (owner != broadcaster) {
            revert OwnerMustMatchBroadcaster(owner, broadcaster);
        }
        if (CREATE2_DEPLOYER.code.length == 0) {
            revert Create2FactoryNotAvailable(CREATE2_DEPLOYER);
        }

        IPoolManager manager = IPoolManager(managerAddress);

        vm.startBroadcast(privateKey);
        logic = new ArbitrageLogic();
        dataStorage = new DataStorage(owner);
        executor = new ArbExecutor();

        bytes memory constructorArgs =
            abi.encode(manager, owner, address(logic), address(dataStorage), address(executor));
        (address predictedHook, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, uint160(Hooks.AFTER_SWAP_FLAG), type(ArbHook).creationCode, constructorArgs
        );

        hook = new ArbHook{salt: salt}(manager, owner, address(logic), address(dataStorage), address(executor));
        if (address(hook) != predictedHook) {
            revert HookAddressMismatch(address(hook), predictedHook);
        }

        dataStorage.setWriter(address(hook));
        vm.stopBroadcast();

        emit ArbHookDeployment(address(hook), address(executor), address(logic), address(dataStorage), salt);
    }
}
