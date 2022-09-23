// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract SimulateState {
    /// @dev depositId => WritePosition
    mapping(uint256 => WritePosition) public writePositions;

    struct WritePosition {
        uint256 epoch;
        uint256 strike;
        uint256 collateralAmount;
        uint256 checkpointIndex;
        uint256[] rewardDistributionRatios;
    }

    /// @dev purchaseId => PurchasePosition
    mapping(uint256 => PurchasePosition) public purchasePositions;

    struct PurchasePosition {
        uint256 epoch;
        uint256 strike;
        uint256 amount;
        uint256 premium;
        uint256 purchaseFee;
    }
}
