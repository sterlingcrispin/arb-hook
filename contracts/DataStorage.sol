// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IDataStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DataStorage is IDataStorage, Ownable {
    TradeData[] public tradeHistory;
    address public authorizedWriter;

    event TradeStored(uint256 indexed index);
    event WriterUpdated(address indexed newWriter);

    error UnauthorizedWriter(address caller, address writer);

    modifier onlyWriter() {
        if (msg.sender != authorizedWriter) {
            revert UnauthorizedWriter(msg.sender, authorizedWriter);
        }
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setWriter(address newWriter) external onlyOwner {
        authorizedWriter = newWriter;
        emit WriterUpdated(newWriter);
    }

    function storeTradeData(TradeData calldata data) external override onlyWriter {
        tradeHistory.push(data);
        emit TradeStored(tradeHistory.length - 1);
    }

    function fetchTradeData(uint256 index) external view override returns (uint256[] memory) {
        require(index < tradeHistory.length, "Index out of bounds");
        TradeData storage trade = tradeHistory[index];
        uint256[] memory raw = new uint256[](7);
        raw[0] = uint256(uint160(trade.buyPool));
        raw[1] = uint256(uint160(trade.sellPool));
        raw[2] = trade.buyPoolIndex;
        raw[3] = trade.sellPoolIndex;
        raw[4] = trade.totalAmountSwapped;
        raw[5] = trade.profit;
        raw[6] = trade.iterations;
        return raw;
    }

    function getTradeCount() external view override returns (uint256) {
        return tradeHistory.length;
    }
}
