// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {PoolManagerHarness} from "../../contracts/test/PoolManagerHarness.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {DataStorage} from "../../contracts/DataStorage.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower} from "../../contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "../../contracts/interfaces/IERC3156FlashLender.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

interface IAaveV3Pool {
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IAaveFlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

/// @notice Test-only ERC3156 adapter over Aave V3 flashLoanSimple.
contract AaveV3ERC3156Adapter is IERC3156FlashLender, IAaveFlashLoanSimpleReceiver {
    using SafeERC20 for IERC20;

    IAaveV3Pool public immutable pool;
    address public immutable supportedToken;
    address public immutable liquidityToken;

    bytes32 private constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    constructor(address pool_, address token_, address liquidityToken_) {
        pool = IAaveV3Pool(pool_);
        supportedToken = token_;
        liquidityToken = liquidityToken_;
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        if (token != supportedToken) return 0;
        return IERC20(token).balanceOf(liquidityToken);
    }

    function flashFee(address token, uint256 amount) external view returns (uint256) {
        require(token == supportedToken, "unsupported token");
        uint256 premiumBps = uint256(pool.FLASHLOAN_PREMIUM_TOTAL());
        return (amount * premiumBps) / 10_000;
    }

    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        require(token == supportedToken, "unsupported token");
        bytes memory params = abi.encode(receiver, msg.sender, data);
        pool.flashLoanSimple(address(this), token, amount, params, 0);
        return true;
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(pool), "invalid pool caller");
        require(initiator == address(this), "invalid aave initiator");

        (address receiver, address flashInitiator, bytes memory data) = abi.decode(
            params,
            (address, address, bytes)
        );
        require(asset == supportedToken, "unexpected asset");

        IERC20(asset).safeTransfer(receiver, amount);
        bytes32 response = IERC3156FlashBorrower(receiver).onFlashLoan(
            flashInitiator,
            asset,
            amount,
            premium,
            data
        );
        require(response == CALLBACK_SUCCESS, "bad borrower callback");

        uint256 repay = amount + premium;
        IERC20(asset).safeTransferFrom(receiver, address(this), repay);
        IERC20(asset).forceApprove(address(pool), repay);
        return true;
    }
}

contract ArbHookFlashForkAaveTest is Test {
    // Base mainnet addresses from @bgd-labs/aave-address-book (AaveV3Base / AaveV3BaseAssets).
    address internal constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AAVE_USDC_A_TOKEN = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    uint256 internal constant FORK_BLOCK = 33_942_262;

    bool internal forkEnabled;
    PoolManagerHarness internal poolManager;
    ArbHookHarness internal hook;
    DataStorage internal dataStorage;
    AaveV3ERC3156Adapter internal adapter;

    function setUp() public {
        bool runForkIntegration = vm.envOr("RUN_FLASH_FORK_INTEGRATION", false);
        if (!runForkIntegration) return;

        string memory baseRpcUrl;
        try vm.envString("BASE_RPC_URL") returns (string memory url) {
            baseRpcUrl = url;
        } catch {
            return;
        }
        if (bytes(baseRpcUrl).length == 0) return;

        vm.createSelectFork(baseRpcUrl, FORK_BLOCK);
        forkEnabled = true;

        poolManager = new PoolManagerHarness(address(this));
        ArbitrageLogic logic = new ArbitrageLogic();
        dataStorage = new DataStorage(address(this));
        hook = new ArbHookHarness(
            IPoolManager(address(poolManager)),
            address(this),
            address(logic),
            address(dataStorage)
        );
        dataStorage.setWriter(address(hook));

        adapter = new AaveV3ERC3156Adapter(AAVE_POOL, USDC, AAVE_USDC_A_TOKEN);
        hook.setTrustedFlashLender(address(adapter), true);
        hook.setLenderForToken(USDC, address(adapter));
        hook.setMaxFlashFeeBpsForToken(USDC, 100); // 1% guardrail
    }

    function testForkAaveAdapterRoundTripRepaysPrincipalAndFee() public {
        if (!forkEnabled) return;

        uint256 principal = 50_000e6;
        hook.setFlashPrincipalForToken(USDC, principal);

        uint256 fee = adapter.flashFee(USDC, principal);
        deal(USDC, address(hook), fee); // cover flash fee when no arb profit

        uint256 aTokenLiquidityBefore = IERC20(USDC).balanceOf(AAVE_USDC_A_TOKEN);

        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(0xA1),
            address(0xB2),
            USDC,
            address(0xCAFE),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertFalse(success, "maxIterations=0 path should not report profitable trade");
        assertEq(profit, -int256(fee), "net should be negative by flash fee amount");
        assertEq(iterations, 0, "no iterations expected");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook should not retain USDC");
        assertEq(
            IERC20(USDC).balanceOf(AAVE_USDC_A_TOKEN),
            aTokenLiquidityBefore + fee,
            "aToken liquidity should increase by collected fee"
        );
    }

    function testForkAaveAdapterProfitablePathPaysBeneficiaryAndStoresNet() public {
        if (!forkEnabled) return;

        uint256 principal = 50_000e6;
        hook.setFlashPrincipalForToken(USDC, principal);
        hook.setMinProfitToEmit(1);
        hook.setTestProfitBps(1); // enable harness test path for maxIterations=0

        address beneficiary = makeAddr("forkBeneficiary");
        hook.setDefaultProfitRecipient(beneficiary);

        uint256 fee = adapter.flashFee(USDC, principal);
        uint256 expectedGross = fee + 1e6; // fee + 1 USDC => guaranteed net-positive
        uint256 expectedNet = expectedGross - fee;
        assertGt(expectedNet, 0, "expected net must be positive");
        deal(USDC, address(this), expectedGross);
        IERC20(USDC).approve(address(hook), 0);
        IERC20(USDC).approve(address(hook), expectedGross);
        hook.setTestProfitTransfer(address(this), expectedGross);

        uint256 beneficiaryBefore = IERC20(USDC).balanceOf(beneficiary);
        uint256 tradesBefore = dataStorage.getTradeCount();

        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(0xD1),
            address(0xD2),
            USDC,
            address(0xD3),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertTrue(success, "profitable flash path should succeed");
        assertEq(uint256(profit), expectedNet, "reported net profit mismatch");
        assertEq(iterations, 1, "harness profitable path should report one iteration");
        assertEq(
            IERC20(USDC).balanceOf(beneficiary),
            beneficiaryBefore + expectedNet,
            "beneficiary should receive net profit"
        );
        assertEq(
            dataStorage.getTradeCount(),
            tradesBefore + 1,
            "profitable fork flash trade should be stored"
        );

        uint256[] memory stored = dataStorage.fetchTradeData(tradesBefore);
        assertEq(stored[5], expectedNet, "stored profit should be net");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook should not retain USDC");
    }
}
