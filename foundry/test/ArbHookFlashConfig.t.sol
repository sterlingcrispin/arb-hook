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
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract ArbHookFlashConfigTest is Test {
    ArbHookHarness internal hook;

    address internal constant TOKEN = address(0x1234);
    address internal constant LENDER = address(0x9999);

    function setUp() public {
        PoolManagerHarness poolManager = new PoolManagerHarness(address(this));
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

    function testSetMinimumTriggerAmount() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        hook.setMinTriggerAmount(poolId, false, 49e6);
        assertEq(hook.getMinTriggerAmount(poolId, false), 49e6);
        assertEq(hook.getMinTriggerAmount(poolId, true), 0);
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

    function testProductionHookDeploysAtMinedAddress() public {
        PoolManagerHarness poolManager = new PoolManagerHarness(address(this));
        ArbitrageLogic logic = new ArbitrageLogic();
        bytes memory args = abi.encode(
            IPoolManager(address(poolManager)),
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
            IPoolManager(address(poolManager)),
            address(this),
            address(logic)
        );
        assertEq(address(deployed), expected);
    }
}
