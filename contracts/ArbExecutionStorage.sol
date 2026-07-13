// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ArbUtils.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title ArbExecutionStorage
/// @notice Storage shared by the hook shell and its delegatecalled execution engine.
/// @dev Both contracts deliberately inherit this contract as their first stateful
///      base. The executor is never called directly: when delegatecalled, every
///      field below resolves against the hook's storage.
abstract contract ArbExecutionStorage is ArbUtils {
    struct PoolMeta {
        address token0;
        address token1;
        uint24 fee;
        PoolType poolType;
        bool exists;
    }

    // Callback validation and execution both require the same pool metadata.
    mapping(address => PoolMeta) internal poolMetaByAddr;

    // One-shot V2 flash-swap callback capability. V2 pairs invoke the `to`
    // address, unlike V3 pools, so factory validation alone is insufficient.
    bytes32 internal activeV2SwapContext;

    // A physical pool can be registered under multiple base tokens. Keep its
    // callback metadata alive until its final registration is removed.
    mapping(address => uint256) internal poolRegistrationCount;

    // Avoid repeated metadata calls while sizing and discovering routes.
    mapping(address => uint8) internal cachedTokenDecimals;

    // A positive execution below this threshold remains economically valid but
    // is intentionally not persisted/emitted.
    uint256 public minProfitToEmit;

    event ArbitrageAttempted(
        address indexed tokenA,
        address indexed tokenB,
        address indexed buyPool,
        address sellPool,
        uint256 totalAmountSwapped,
        int256 cumulativeProfit,
        uint256 iterations
    );

    event PairExecutionFailed(address tokenA, address tokenB, address buyPool, address sellPool, bytes revertData);

    /// @dev Registered tokens are warmed during `addPools`; retain a defensive
    ///      fallback for a direct/external test setup.
    function _minChunk(address token) internal view virtual override returns (uint256) {
        uint8 decimals_ = cachedTokenDecimals[token];
        if (decimals_ == 0) {
            try IERC20Metadata(token).decimals() returns (uint8 fetched) {
                decimals_ = fetched;
            } catch {
                decimals_ = 18;
            }
        }
        if (decimals_ > MAX_SAFE_TOKEN_DECIMALS) return type(uint256).max;
        return decimals_ > 4 ? 10 ** (decimals_ - 4) : 1;
    }

    function _v2SwapContextHash(
        address pool,
        PoolType poolType,
        address tokenToPay,
        uint256 amountToPay,
        uint256 amount0Out,
        uint256 amount1Out
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(pool, poolType, tokenToPay, amountToPay, amount0Out, amount1Out));
    }
}
