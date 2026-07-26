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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

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

    function testSetTrustedFlashLenderOnlyOwner() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                stranger
            )
        );
        hook.setTrustedFlashLender(LENDER, true);
    }

    function testSetLenderForTokenRequiresTrustedLender() public {
        vm.expectRevert(ArbErrors.UntrustedFlashLender.selector);
        hook.setLenderForToken(TOKEN, LENDER);

        hook.setTrustedFlashLender(LENDER, true);
        hook.setLenderForToken(TOKEN, LENDER);
        assertEq(hook.lenderByToken(TOKEN), LENDER);
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

    function testProductionHookRejectsUnminedAddress() public {
        PoolManagerHarness poolManager = new PoolManagerHarness(address(this));
        ArbitrageLogic logic = new ArbitrageLogic();

        uint256 nonce = vm.getNonce(address(this));
        address nextDeployment = vm.computeCreateAddress(address(this), nonce);
        uint160 permissionBits = uint160(nextDeployment) & uint160((1 << 14) - 1);
        assertNotEq(permissionBits, uint160(1 << 6), "test deployment unexpectedly has exact afterSwap permission bits");

        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, nextDeployment));
        new ArbHook(IPoolManager(address(poolManager)), address(this), address(logic));
    }
}
