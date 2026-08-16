// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbHook} from "../../contracts/ArbHook.sol";
import {ArbErrors} from "../../contracts/Errors.sol";

import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {PoolManagerHarness} from "../../contracts/test/PoolManagerHarness.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract ArbHookFlashConfigTest is Test {
    ArbHookHarness internal hook;
    PoolManagerHarness internal poolManager;

    address internal constant TOKEN = address(0x1234);
    address internal constant LENDER = address(0x9999);

    function setUp() public {
        poolManager = new PoolManagerHarness(address(this));
        ArbitrageLogic logic = new ArbitrageLogic();
        hook = new ArbHookHarness(
            IPoolManager(address(poolManager)),
            address(this),
            address(logic));
    }

    function testSetLenderForTokenOnlyOwner() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        hook.setLenderForToken(TOKEN, LENDER);
    }

    function testSetLenderForToken() public {
        hook.setLenderForToken(TOKEN, LENDER);
        (address configuredLender, , , ) = hook.getFlashConfig(
            TOKEN
        );
        assertEq(configuredLender, LENDER);
    }

    function testSetMaxFlashFeeBpsCap() public {
        vm.expectRevert(ArbErrors.FlashFeeBpsTooHigh.selector);
        hook.setMaxFlashFeeBpsForToken(TOKEN, 10001);
    }

    function testOnFlashLoanRejectsUnknownLender() public {
        vm.expectRevert(ArbErrors.InvalidFlashLender.selector);
        hook.onFlashLoan(address(this), TOKEN, 1, 0, hex"01");
    }

    function testAfterSwapRejectsNonPoolManager() public {
        PoolKey memory key;
        SwapParams memory params;

        vm.expectRevert(ArbHook.NotPoolManager.selector);
        hook.afterSwap(
            address(this),
            key,
            params,
            BalanceDelta.wrap(0),
            bytes("")
        );
    }

    function testEnabledSwapRejectsInsufficientAttemptGas() public {
        hook.setHookMaxIterations(1);

        (bool success, bytes memory reason) = address(poolManager).call{gas: 500_000}(
            abi.encodeCall(
                PoolManagerHarness.callAfterSwap,
                (IHooks(address(hook)), address(this), abi.encodePacked(address(this)))
            )
        );

        assertFalse(success, "eligible low-gas swap must not silently skip");
        assertEq(bytes4(reason), ArbErrors.InsufficientHookGas.selector);
    }

    function testProductionHookDeploysAtMinedAddress() public {
        PoolManagerHarness productionPoolManager = new PoolManagerHarness(address(this));
        ArbitrageLogic logic = new ArbitrageLogic();
        bytes memory args = abi.encode(
            IPoolManager(address(productionPoolManager)),
            address(this),
            address(logic)
        );
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.AFTER_SWAP_FLAG,
            type(ArbHook).creationCode,
            args
        );

        ArbHook deployed = new ArbHook{salt: salt}(
            IPoolManager(address(productionPoolManager)),
            address(this),
            address(logic)
        );
        assertEq(address(deployed), expected);
    }
}
