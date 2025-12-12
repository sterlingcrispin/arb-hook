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
// import "hardhat/console.sol";
import {ArbErrors} from "./Errors.sol";
import {ArbitrageLogic} from "./ArbitrageLogic.sol";
import {IDataStorage} from "./interfaces/IDataStorage.sol";

/// @title ArbUtils
/// @notice Shared pure/view helpers extracted from IterativeArbBot.
///         Keeping them `internal` preserves the original gas profile while
///         shrinking the main contract's byte-code.
abstract contract ArbUtils {
    using SafeERC20 for IERC20;

    IDataStorage public dataStorage;

    /// @notice Minimum tick‑spread (in basis points) required to start an iteration.
    uint16 public minSpreadBps = 10; // 0.10 %

    uint256 public BPS_DIVISOR = 10000;
    uint16 public CHUNK_SPREAD_CONSUMPTION_BPS = 1500;
    uint256 public _MAX_IMPACT_BPS = 500;
    uint24 public constant V2_POOL_FEE_PPM = 3000;
    uint24 public constant PANCAKESWAP_V2_POOL_FEE_PPM = 2500;

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

    // ↓ Made internal – eliminates two public getters, saving bytecode.
    mapping(address => PoolInfo[]) internal tokenPools;
    address[] internal supportedTokens;

    mapping(address => address[]) internal baseCounterList;
    mapping(address => mapping(address => bool)) internal isCounterKnown;

    // To be shared by both IterativeArbBot and the ephemeral Worker
    ArbitrageLogic internal arbLib;

    IDataStorage.TradeData public lastTradeData;

    // [NEW] "Mailbox" for the worker to report profit back to the main contract,
    // bypassing the fragile delegatecall returndata.
    int256 public lastExecutionProfit;

    struct FailedQuote {
        uint128 qBuy;
        uint128 qSell;
    }
    mapping(bytes32 => FailedQuote) internal lastFailedQuote;

    // [NEW] More detailed struct for the pair-based failure cache
    struct FailedAttempt {
        address buyPool;
        address sellPool;
        uint128 qBuy;
        uint128 qSell;
    }
    mapping(bytes32 => FailedAttempt) internal lastFailedAttemptForPair;

    mapping(address => uint256) internal poolActivityCache;

    /* ---------------- Pool-list helpers ---------------- */
    function _clearCountersForBase(address base) internal {
        address[] storage ctrs = baseCounterList[base];
        uint256 n = ctrs.length;
        for (uint256 i; i < n; ++i) {
            isCounterKnown[base][ctrs[i]] = false;
        }
        delete baseCounterList[base];
    }

    // [NEW] Helper to get a normalized key for a token pair
    function _getPairKey(
        address tokenA,
        address tokenB
    ) internal pure returns (bytes32) {
        return
            tokenA < tokenB
                ? keccak256(abi.encodePacked(tokenA, tokenB))
                : keccak256(abi.encodePacked(tokenB, tokenA));
    }

    function _removeTokenFromSupported(address token) internal {
        uint256 n = supportedTokens.length;
        for (uint256 i; i < n; ++i) {
            if (supportedTokens[i] == token) {
                supportedTokens[i] = supportedTokens[n - 1];
                supportedTokens.pop();
                break;
            }
        }
        _clearCountersForBase(token); // idempotent
    }

    /* ---------------- add / remove pools ---------------- */
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

        uint256 initialActivityIndicator;
        if (poolType == PoolType.V3) {
            (, , uint16 obsIndex, , , , ) = IUniswapV3Pool(poolAddr).slot0();
            initialActivityIndicator = obsIndex;
        } else if (poolType == PoolType.PANCAKESWAP_V3) {
            // Use the specific IPancakeV3Pool interface to avoid ABI issues
            (, , uint16 obsIndex, , , , ) = IPancakeV3Pool(poolAddr).slot0();
            initialActivityIndicator = obsIndex;
        } else {
            // V2 or PCS V2
            (, , uint32 timestamp) = IUniswapV2Pair(poolAddr).getReserves();
            initialActivityIndicator = timestamp;
        }
        poolActivityCache[poolAddr] = initialActivityIndicator;

        address counter = (t0 == token) ? t1 : t0;
        if (!isCounterKnown[token][counter]) {
            isCounterKnown[token][counter] = true;
            baseCounterList[token].push(counter);
        }
    }

    function _removePool(address token, uint256 poolIndex) internal {
        PoolInfo[] storage pools = tokenPools[token];
        uint256 numPools = pools.length;
        if (numPools == 0) revert ArbErrors.TokenHasNoPools();
        if (poolIndex >= numPools) revert ArbErrors.PoolIndexOutOfBounds();

        address poolAddr = pools[poolIndex].poolAddress;
        (address t0, address t1) = _tokens(IUniswapV3Pool(poolAddr));
        address counter = (t0 == token) ? t1 : t0;

        if (poolIndex != numPools - 1) pools[poolIndex] = pools[numPools - 1];
        pools.pop();

        /* orphan-pruning skipped for brevity; unchanged behaviour */
        if (pools.length == 0) _removeTokenFromSupported(token);
    }

    function _resetTokenPools(address token) internal {
        if (tokenPools[token].length == 0) return;
        _clearCountersForBase(token);
        delete tokenPools[token];
        _removeTokenFromSupported(token);
    }

    function _resetAllPools() internal {
        uint256 s = supportedTokens.length;
        for (uint256 i; i < s; ++i) {
            address token = supportedTokens[i];
            _clearCountersForBase(token);
            delete tokenPools[token];
        }
        delete supportedTokens;
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

    /// @dev Fetch token0 / token1 with uniform custom errors.
    function _tokens(
        IUniswapV3Pool p
    ) internal view returns (address t0, address t1) {
        try p.token0() returns (address _t0) {
            t0 = _t0;
        } catch {
            revert ArbErrors.HelperToken0Failed();
        }
        try p.token1() returns (address _t1) {
            t1 = _t1;
        } catch {
            revert ArbErrors.HelperToken1Failed();
        }
    }

    // -------------------------------------------------------------------
    //  Step 3 – swap helpers
    // -------------------------------------------------------------------

    // mirror of IterativeArbBot's event so the compiler can emit it here too
    event SwapExecuted(
        address indexed pool,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

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
