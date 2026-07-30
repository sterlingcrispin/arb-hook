// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ArbHook} from "../contracts/ArbHook.sol";
import {ArbitrageLogic} from "../contracts/ArbitrageLogic.sol";
import {AaveV3ERC3156Adapter} from "../contracts/AaveV3ERC3156Adapter.sol";
import {MorphoERC3156Adapter} from "../contracts/MorphoERC3156Adapter.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract DeployArbHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AAVE_USDC_A_TOKEN = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    error WrongChain();

    /// @notice Deploys both lender adapters. Only the one bound with
    ///         `setLenderForToken` is live; the other is inert. Aave charges a
    ///         5 bps premium, Morpho Blue charges nothing, so the Morpho adapter is
    ///         the default choice unless a rehearsal shows a reason otherwise.
    function run()
        external
        returns (
            ArbHook hook,
            ArbitrageLogic logic,
            AaveV3ERC3156Adapter aaveAdapter,
            MorphoERC3156Adapter morphoAdapter
        )
    {
        if (block.chainid != 8453) revert WrongChain();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envOr("OWNER", vm.addr(privateKey));

        vm.startBroadcast(privateKey);
        logic = new ArbitrageLogic();
        aaveAdapter = new AaveV3ERC3156Adapter(AAVE_POOL, USDC, AAVE_USDC_A_TOKEN);
        morphoAdapter = new MorphoERC3156Adapter(MORPHO_BLUE, USDC);
        vm.stopBroadcast();

        bytes memory args = abi.encode(IPoolManager(POOL_MANAGER), owner, address(logic));
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, Hooks.AFTER_SWAP_FLAG, type(ArbHook).creationCode, args);

        vm.broadcast(privateKey);
        hook = new ArbHook{salt: salt}(IPoolManager(POOL_MANAGER), owner, address(logic));
        require(address(hook) == expected, "hook address mismatch");

        console2.log("ArbitrageLogic", address(logic));
        console2.log("AaveAdapter (5 bps)", address(aaveAdapter));
        console2.log("MorphoAdapter (0 bps)", address(morphoAdapter));
        console2.log("ArbHook", address(hook));
        console2.logBytes32(salt);
    }
}
