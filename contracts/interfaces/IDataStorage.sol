// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDataStorage {
    struct TradeData {
        address tokenA;
        address tokenB;
        address buyPool;
        address sellPool;
        uint256 buyPoolIndex;
        uint256 sellPoolIndex;
        uint256 totalAmountSwapped;
        uint256 profit;
        uint256 iterations;
        uint256 timestamp;
    }

    function storeTradeData(TradeData calldata data) external;

    function fetchTradeData(
        uint256 index
    ) external view returns (uint256[] memory);

    function getTradeCount() external view returns (uint256);
}
