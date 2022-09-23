// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ISsovV3} from "../interfaces/ISsovV3.sol";

interface ISim {
    function deposit(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 strikeIndex,
        uint256 amount
    ) external returns (uint256 depositId);

    function purchase(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 strikeIndex,
        uint256 amount
    )
        external
        returns (
            uint256 purchaseId,
            uint256 premium,
            uint256 purchaseFee
        );

    function settle(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 purchaseId
    ) external returns (uint256 netPnl);

    function withdraw(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 depositId
    )
        external
        view
        returns (
            uint256 collateralTokenWithdrawAmount,
            uint256[] memory rewardTokenWithdrawAmounts
        );
}
