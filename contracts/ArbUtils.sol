// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// --- External deps ──────────────────────────────────────────────────────
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IPancakeV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ArbErrors} from "./Errors.sol";
import {ArbitrageLogic} from "./ArbitrageLogic.sol";

/// @title ArbUtils
/// @notice Shared state and helper routines for pool registration, route discovery,
///         pricing support, and treasury operations used by ArbHook.
/// @dev Route planning is intentionally simple and deterministic:
///      `supportedTokens` (outer loop) -> `baseCounterList[base]` (inner loop).
///      Registration order therefore determines evaluation order in `attemptAllInternal`.
abstract contract ArbUtils {
    using SafeERC20 for IERC20;

    /// @notice Minimum tick‑spread (in basis points) required to start an iteration.
    uint16 public minSpreadBps = 10; // 0.10 %

    uint256 internal constant BPS_DIVISOR = 10_000;
    uint16 public CHUNK_SPREAD_CONSUMPTION_BPS = 1500;
    uint256 public _MAX_IMPACT_BPS = 500;
    uint24 internal constant V2_POOL_FEE_PPM = 3000;
    uint24 internal constant PANCAKESWAP_V2_POOL_FEE_PPM = 2500;

    enum PoolType {
        V3,
        V2,
        PANCAKESWAP_V2,
        PANCAKESWAP_V3
    }

    struct PoolInfo {
        address poolAddress;
        uint24 fee;
        PoolType poolType;
        address token0;
        address token1;
        uint8 token0Decimals;
        uint8 token1Decimals;
        int24 tickSpacing; // Only for V3 pools, 0 for V2
    }

    // Base token -> all pools registered under that base token.
    mapping(address => PoolInfo[]) internal tokenPools;
    // Distinct base tokens in insertion order. This order drives attemptAll traversal.
    address[] internal supportedTokens;

    // Base token -> unique counterpart tokens seen in registered pools.
    mapping(address => address[]) internal baseCounterList;
    // Dedupe guard for baseCounterList.
    mapping(address => mapping(address => bool)) internal isCounterKnown;

    // Stateless pricing/sizing engine shared by the hook execution paths.
    ArbitrageLogic internal arbLib;

    /* ---------------- Pool registration ---------------- */
    function _addPools(
        address token,
        address[] memory poolAddresses,
        uint24[] memory fees,
        ArbUtils.PoolType[] memory poolTypes
    ) internal {
        if (
            poolAddresses.length != fees.length ||
            poolAddresses.length != poolTypes.length
        ) revert ArbErrors.InputArrayLengthMismatch();

        // Preserve first-seen ordering for deterministic traversal in attemptAll.
        bool tokenIsNew = true;
        for (uint j; j < supportedTokens.length; ++j)
            if (supportedTokens[j] == token) {
                tokenIsNew = false;
                break;
            }
        if (tokenIsNew) supportedTokens.push(token);

        for (uint i; i < poolAddresses.length; ++i) {
            _getAndValidateAndAddPool(
                token,
                poolAddresses[i],
                fees[i],
                poolTypes[i]
            );
        }
    }

    function _getAndValidateAndAddPool(
        address token,
        address poolAddr,
        uint24 providedFee,
        PoolType poolType
    ) internal {
        address t0;
        address t1;
        uint8 dec0;
        uint8 dec1;
        int24 tickSpacing = 0;
        uint24 actualFee = providedFee;

        if (poolType == PoolType.V3 || poolType == PoolType.PANCAKESWAP_V3) {
            if (poolType == PoolType.V3) {
                IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);
                t0 = pool.token0();
                t1 = pool.token1();
                actualFee = pool.fee();
                tickSpacing = pool.tickSpacing();
            } else {
                // PANCAKESWAP_V3
                IPancakeV3Pool pool = IPancakeV3Pool(poolAddr);
                IUniswapV3Factory factory = IUniswapV3Factory(
                    0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865
                );
                t0 = pool.token0();
                t1 = pool.token1();
                actualFee = pool.fee();
                tickSpacing = factory.feeAmountTickSpacing(actualFee);
            }

            if (
                !((token == t0 && t1 != address(0)) ||
                    (token == t1 && t0 != address(0)))
            ) revert ArbErrors.AddPoolsInputTokenNotInPool();

            if (actualFee != providedFee)
                revert ArbErrors.AddPoolsProvidedFeeMismatch();
        } else if (poolType == PoolType.V2) {
            actualFee = V2_POOL_FEE_PPM;
            IUniswapV2Pair pair = IUniswapV2Pair(poolAddr);
            t0 = pair.token0();
            t1 = pair.token1();

            if (
                !((token == t0 && t1 != address(0)) ||
                    (token == t1 && t0 != address(0)))
            ) revert ArbErrors.AddPoolsInputTokenNotInPool();
        } else if (poolType == PoolType.PANCAKESWAP_V2) {
            actualFee = PANCAKESWAP_V2_POOL_FEE_PPM;
            IUniswapV2Pair pair = IUniswapV2Pair(poolAddr);
            t0 = pair.token0();
            t1 = pair.token1();

            if (
                !((token == t0 && t1 != address(0)) ||
                    (token == t1 && t0 != address(0)))
            ) revert ArbErrors.AddPoolsInputTokenNotInPool();
        } else {
            revert("Unsupported Pool Type");
        }

        dec0 = IERC20Metadata(t0).decimals();
        dec1 = IERC20Metadata(t1).decimals();

        tokenPools[token].push(
            PoolInfo(
                poolAddr,
                actualFee,
                poolType,
                t0,
                t1,
                dec0,
                dec1,
                tickSpacing
            )
        );

        // Build the base -> counter adjacency list used by attemptAll route scanning.
        address counter = (t0 == token) ? t1 : t0;
        if (!isCounterKnown[token][counter]) {
            isCounterKnown[token][counter] = true;
            baseCounterList[token].push(counter);
        }
    }

    /* ---------------- wallet / treasury helpers ---------------- */
    function _withdrawTokens(address token, address to, uint256 amt) internal {
        if (to == address(0)) revert ArbErrors.WithdrawToZeroAddress();
        if (token == address(0)) revert ArbErrors.WithdrawZeroAddressToken();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (amt > bal) revert ArbErrors.WithdrawAmountExceedsBalance(amt, bal);
        IERC20(token).safeTransfer(to, amt);
    }

    function _withdrawETH(address payable to, uint256 amt) internal {
        if (to == address(0)) revert ArbErrors.WithdrawETHToZeroAddress();
        uint256 bal = address(this).balance;
        if (amt > bal)
            revert ArbErrors.WithdrawETHAmountExceedsBalance(amt, bal);
        (bool ok, ) = to.call{value: amt}("");
        if (!ok) revert ArbErrors.ETHWithdrawalFailed(to, amt);
    }

    // -------------------------------------------------------------------
    //  Constants
    // -------------------------------------------------------------------
    /// @dev Minimum meaningful trade size: 1 × 10⁻⁴ of one whole token.
    function _minChunk(address token) internal view virtual returns (uint256) {
        uint8 d = IERC20Metadata(token).decimals();
        return d > 4 ? 10 ** (d - 4) : 1; // never below 1 wei
    }

    // -------------------------------------------------------------------
    //  Step 3.1 – swap helpers (V2)
    // -------------------------------------------------------------------

    /**
     * @dev Executes a single flash swap on a Uniswap V2 pool.
     * @param pair The IUniswapV2Pair contract instance.
     * @param tokenToReceive The token address we want to receive from the pool.
     * @param amountToReceive The amount of `tokenToReceive` we want to get.
     * @param tokenToPay The token address we will pay back in the callback.
     * @param amountToPay The amount of `tokenToPay` we will pay back.
     */
    function _executeV2FlashSwap(
        IUniswapV2Pair pair,
        address tokenToReceive,
        uint256 amountToReceive,
        address tokenToPay,
        uint256 amountToPay
    ) internal virtual returns (bool success) {
        if (tokenToReceive == tokenToPay || amountToReceive == 0)
            revert("Invalid V2 flash swap params");

        //console.log("... Executing V2 Flash Swap ...");
        //console.log("tokenToReceive:", tokenToReceive);
        //console.log("amountToReceive:", amountToReceive);
        //console.log("tokenToPay:", tokenToPay);
        //console.log("amountToPay:", amountToPay);

        // Encode the required input amount and the input token address into `data` for the callback
        bytes memory data = abi.encode(tokenToPay, amountToPay);

        uint256 amount0Out = 0;
        uint256 amount1Out = 0;

        if (tokenToReceive == pair.token0()) {
            amount0Out = amountToReceive;
        } else {
            amount1Out = amountToReceive;
        }
        //console.log("trying to swap");
        try pair.swap(amount0Out, amount1Out, address(this), data) {
            success = true;
        } catch (bytes memory reason) {
            //console.log("!!! V2 FLASH SWAP FAILED !!!");
            // console.logBytes(reason);
            success = false;
        }
    }
}
