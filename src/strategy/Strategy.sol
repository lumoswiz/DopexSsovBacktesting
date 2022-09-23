// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {Simulate} from "../simulate/Simulate.sol";

// Interfaces
import {ISsovV3} from "../interfaces/ISsovV3.sol";
import {ISim} from "../interfaces/ISim.sol";

import {Strings} from "openzeppelin-contracts/utils/Strings.sol";

struct Details {
    uint256 blockNumber;
    uint256 strikeIndex;
    uint256 amount;
}

struct withdrawDetails {
    uint256 collateralTokenWithdrawAmount;
    uint256[] rewardTokenWithdrawAmounts;
}

contract Strategy is Test {
    // epoch => Details
    mapping(uint256 => Details[]) public purchases;
    mapping(uint256 => Details[]) public deposits;

    // depositId => withdrawDetails
    mapping(uint256 => withdrawDetails) public withdraws;

    address sim;
    address ssov;
    uint256 epoch;

    // constants
    uint256 internal constant OPTIONS_PRECISION = 1e18;
    uint256 internal constant DEFAULT_PRECISION = 1e8;
    uint256 internal constant REWARD_PRECISION = 1e18;

    constructor(
        address _sim,
        address _ssov,
        uint256 _epoch
    ) {
        sim = _sim;
        ssov = _ssov;
        epoch = _epoch;
    }

    function getDepositLength() public view returns (uint256) {
        return deposits[epoch].length;
    }

    function createDeposits(
        uint256[] memory blockNumbers,
        uint256[] memory strikeIndexes,
        uint256[] memory amounts
    ) public {
        assertEq(blockNumbers.length, strikeIndexes.length);
        assertEq(strikeIndexes.length, amounts.length);

        for (uint256 i; i < blockNumbers.length; ++i) {
            deposits[epoch].push(
                Details({
                    blockNumber: blockNumbers[i],
                    strikeIndex: strikeIndexes[i],
                    amount: amounts[i]
                })
            );
        }
    }

    function createPurchases(
        uint256[] memory blockNumbers,
        uint256[] memory strikeIndexes,
        uint256[] memory amounts
    ) public {
        require(
            ((blockNumbers.length == strikeIndexes.length) &&
                (blockNumbers.length == amounts.length)),
            "PurchaseArrayLengthsNotEqual"
        );

        for (uint256 i; i < blockNumbers.length; ++i) {
            purchases[epoch].push(
                Details({
                    blockNumber: blockNumbers[i],
                    strikeIndex: strikeIndexes[i],
                    amount: amounts[i]
                })
            );
        }
    }

    /// @dev queued deposits from this contract -> sim deposit in Simulate.
    function executeDeposits() public returns (uint256[] memory depositIds) {
        depositIds = new uint256[](deposits[epoch].length);

        for (uint256 i; i < deposits[epoch].length; ++i) {
            setupForkBlockSpecified(deposits[epoch][i].blockNumber);

            uint256 id = ISim(sim).deposit(
                ISsovV3(ssov),
                epoch,
                deposits[epoch][i].strikeIndex,
                deposits[epoch][i].amount
            );

            depositIds[i] = id;
        }
    }

    /// @dev queued purchases from this contract -> sim purchase in Simulate.
    function executePurchases()
        public
        returns (
            uint256[] memory purchaseIds,
            uint256[] memory premiums,
            uint256[] memory purchaseFees
        )
    {
        purchaseIds = new uint256[](purchases[epoch].length);
        premiums = new uint256[](purchases[epoch].length);
        purchaseFees = new uint256[](purchases[epoch].length);

        for (uint256 i = 0; i < purchases[epoch].length; ++i) {
            setupForkBlockSpecified(purchases[epoch][i].blockNumber);

            (uint256 id, uint256 prem, uint256 fee) = ISim(sim).purchase(
                ISsovV3(ssov),
                epoch,
                purchases[epoch][i].strikeIndex,
                purchases[epoch][i].amount
            );

            purchaseIds[i] = id;
            premiums[i] = prem;
            purchaseFees[i] = fee;
        }
    }

    function executeSettle(uint256[] memory purchaseIds)
        public
        returns (uint256[] memory netPnls)
    {
        setupFork();
        assertEq(ISsovV3(ssov).getEpochData(epoch).expired, true);

        netPnls = new uint256[](purchaseIds.length);

        for (uint256 i = 0; i < purchaseIds.length; ++i) {
            uint256 netPnl = ISim(sim).settle(
                ISsovV3(ssov),
                epoch,
                purchaseIds[i]
            );

            netPnls[i] = netPnl;
        }
    }

    function executeWithdraw(uint256[] memory depositIds) public {
        setupFork();
        assertEq(ISsovV3(ssov).getEpochData(epoch).expired, true);

        for (uint256 i = 0; i < depositIds.length; ++i) {
            (
                uint256 collateralTokenWithdrawAmount,
                uint256[] memory rewardTokenWithdrawAmounts
            ) = ISim(sim).withdraw(ISsovV3(ssov), epoch, depositIds[i]);

            withdraws[depositIds[i]]
                .collateralTokenWithdrawAmount = collateralTokenWithdrawAmount;
            withdraws[depositIds[i]]
                .rewardTokenWithdrawAmounts = rewardTokenWithdrawAmounts;
        }
    }

    /*=== HELPER FUNCTIONS ===*/
    function setupFork() public returns (uint256 id) {
        id = vm.createSelectFork(vm.rpcUrl("arbitrum"));
        assertEq(vm.activeFork(), id);
    }

    function setupForkBlockSpecified(uint256 blk) public returns (uint256 id) {
        id = vm.createSelectFork(vm.rpcUrl("arbitrum"), blk);
        assertEq(vm.activeFork(), id);
    }

    function returnWithdrawDetails(uint256 depositId)
        public
        view
        returns (
            uint256 collateralTokenWithdrawAmount,
            uint256[] memory rewardTokenWithdrawAmounts
        )
    {
        collateralTokenWithdrawAmount = withdraws[depositId]
            .collateralTokenWithdrawAmount;
        rewardTokenWithdrawAmounts = withdraws[depositId]
            .rewardTokenWithdrawAmounts;
    }

    function logWithdraws(uint256 depositId) public {
        emit log_named_uint(
            "collateralTokenWithdrawAmount",
            withdraws[depositId].collateralTokenWithdrawAmount
        );

        emit log_named_array(
            "rewardTokenWithdrawAmounts",
            withdraws[depositId].rewardTokenWithdrawAmounts
        );
    }

    function concatenate(string memory _a, string memory _b)
        public
        pure
        returns (string memory)
    {
        return string(abi.encodePacked(_a, _b));
    }

    function optionsAvailableForPurchase() public {
        uint256[] memory strikes = ISsovV3(ssov).getEpochData(epoch).strikes;

        for (uint256 i = 0; i < strikes.length; ++i) {
            uint256 availableCollateral = ISsovV3(ssov)
                .getEpochStrikeData(epoch, strikes[i])
                .totalCollateral -
                ISsovV3(ssov)
                    .getEpochStrikeData(epoch, strikes[i])
                    .activeCollateral;

            string memory temp = concatenate(
                "strikeIndex: ",
                Strings.toString(i)
            );
            temp = concatenate(temp, "-strike: ");
            temp = concatenate(temp, Strings.toString(strikes[i]));
            temp = concatenate(temp, "-availableCollateral: ");
            temp = concatenate(temp, Strings.toString(availableCollateral));
            temp = concatenate(temp, " (");
            temp = concatenate(
                temp,
                Strings.toString(availableCollateral / 10**18)
            );
            temp = concatenate(temp, " units)");

            emit log_string(temp);
        }

        emit log_string(
            "*******************************************************************************"
        );
    }
}
