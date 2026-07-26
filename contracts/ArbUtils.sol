// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ArbErrors} from "./Errors.sol";
import {ArbitrageLogic} from "./ArbitrageLogic.sol";

/// @title ArbUtils
/// @notice Shared state and helper routines for pool registration, route discovery,
///         pricing support, and V2 swap execution used by ArbHook.
/// @dev Route planning is intentionally simple and deterministic:
///      `supportedTokens` (outer loop) -> `baseCounterList[base]` (inner loop).
///      Registration order therefore determines evaluation order in `attemptAllInternal`.
abstract contract ArbUtils {
    /// @notice Minimum tick‑spread (in basis points) required to start an iteration.
    uint16 internal minSpreadBps = 10; // 0.10 %

    uint256 internal constant BPS_DIVISOR = 10_000;
    uint16 internal CHUNK_SPREAD_CONSUMPTION_BPS = 1500;
    uint256 internal _MAX_IMPACT_BPS = 500;
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
    // Nonzero only while a registered pool swap is synchronously awaiting repayment.
    bytes32 internal activeSwapContextHash;

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
        PoolInfo memory info = arbLib.getValidatedPoolInfo(
            token,
            poolAddr,
            providedFee,
            poolType
        );
        tokenPools[token].push(info);

        // Build the base -> counter adjacency list used by attemptAll route scanning.
        address counter = info.token0 == token ? info.token1 : info.token0;
        if (!isCounterKnown[token][counter]) {
            isCounterKnown[token][counter] = true;
            baseCounterList[token].push(counter);
        }
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
            revert ArbErrors.InvalidV2FlashSwapParams();

        // Encode the required input amount and the input token address into `data` for the callback
        bytes memory data = abi.encode(tokenToPay, amountToPay);

        uint256 amount0Out = 0;
        uint256 amount1Out = 0;

        if (tokenToReceive == pair.token0()) {
            amount0Out = amountToReceive;
        } else {
            amount1Out = amountToReceive;
        }
        activeSwapContextHash = keccak256(abi.encode(address(pair), data));
        try pair.swap(amount0Out, amount1Out, address(this), data) {
            success = true;
        } catch {
            success = false;
        }
        activeSwapContextHash = bytes32(0);
    }
}
