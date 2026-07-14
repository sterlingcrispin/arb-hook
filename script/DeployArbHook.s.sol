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
///         ArbHook. The broadcaster performs the initial wiring and may hand
///         ownership of both owner-controlled contracts to another address.
/// @dev Invoke with `--always-use-create-2-factory`; HookMiner targets Foundry's
///      canonical CREATE2 deployer at 0x4e59... so the deployed address carries
///      the required Uniswap v4 permission bits. Foundry automatically deploys
///      and links the external ArbMath library before this script runs.
contract DeployArbHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 public constant BASE_CHAIN_ID = 8453;
    address public constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    bytes32 public constant BASE_POOL_MANAGER_CODE_HASH =
        0x83b2af6e9f3158defc2811cbcb0db71ecf8b2ba2abea39c39e370ac5c6f43eb6;

    error InvalidPoolManager(address manager);
    error InvalidOwner(address owner);
    error UnexpectedPoolManager(uint256 chainId, address manager, address expected);
    error UnexpectedPoolManagerCodeHash(address manager, bytes32 actual, bytes32 expected);
    error UnverifiedPoolManagerOverrideRequired(uint256 chainId, address manager);
    error Create2FactoryNotAvailable(address factory);
    error HookAddressMismatch(address deployed, address predicted);

    /// @dev Required environment:
    ///      PRIVATE_KEY: broadcaster private key.
    ///      V4_POOL_MANAGER: deployed Uniswap v4 PoolManager address.
    ///      ARB_HOOK_OWNER: optional final owner; defaults to the broadcaster.
    ///      ALLOW_UNVERIFIED_POOL_MANAGER: must be true for non-Base local/test
    ///      deployments. It never bypasses Base's canonical manager checks.
    function run()
        external
        returns (ArbitrageLogic logic, DataStorage dataStorage, ArbExecutor executor, ArbHook hook)
    {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);
        address owner = vm.envOr("ARB_HOOK_OWNER", broadcaster);
        address managerAddress = vm.envAddress("V4_POOL_MANAGER");
        bool allowUnverifiedManager = vm.envOr("ALLOW_UNVERIFIED_POOL_MANAGER", false);

        validatePoolManager(managerAddress, allowUnverifiedManager);
        if (owner == address(0)) revert InvalidOwner(owner);
        if (CREATE2_DEPLOYER.code.length == 0) {
            revert Create2FactoryNotAvailable(CREATE2_DEPLOYER);
        }

        IPoolManager manager = IPoolManager(managerAddress);

        vm.startBroadcast(privateKey);
        logic = new ArbitrageLogic();
        dataStorage = new DataStorage(broadcaster);
        executor = new ArbExecutor();

        bytes memory constructorArgs =
            abi.encode(manager, broadcaster, address(logic), address(dataStorage), address(executor));
        (address predictedHook, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, uint160(Hooks.AFTER_SWAP_FLAG), type(ArbHook).creationCode, constructorArgs
        );

        hook = new ArbHook{salt: salt}(manager, broadcaster, address(logic), address(dataStorage), address(executor));
        if (address(hook) != predictedHook) {
            revert HookAddressMismatch(address(hook), predictedHook);
        }

        dataStorage.setWriter(address(hook));
        if (owner != broadcaster) {
            dataStorage.transferOwnership(owner);
            hook.transferOwnership(owner);
        }
        vm.stopBroadcast();
    }

    /// @notice Fails closed on Base unless the configured address and runtime
    ///         code exactly match Uniswap's canonical PoolManager deployment.
    /// @dev Local and test chains must opt in explicitly because an arbitrary
    ///      contract receives the hook's immutable callback authority.
    function validatePoolManager(address managerAddress, bool allowUnverifiedManager) public view {
        if (managerAddress == address(0) || managerAddress.code.length == 0) {
            revert InvalidPoolManager(managerAddress);
        }

        if (block.chainid == BASE_CHAIN_ID) {
            if (managerAddress != BASE_POOL_MANAGER) {
                revert UnexpectedPoolManager(block.chainid, managerAddress, BASE_POOL_MANAGER);
            }

            bytes32 actualCodeHash = managerAddress.codehash;
            if (actualCodeHash != BASE_POOL_MANAGER_CODE_HASH) {
                revert UnexpectedPoolManagerCodeHash(managerAddress, actualCodeHash, BASE_POOL_MANAGER_CODE_HASH);
            }
            return;
        }

        if (!allowUnverifiedManager) {
            revert UnverifiedPoolManagerOverrideRequired(block.chainid, managerAddress);
        }
    }
}
