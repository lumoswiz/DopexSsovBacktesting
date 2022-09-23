// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";

// Interfaces
import {ISsovV3} from "../src/interfaces/ISsovV3.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ISim} from "../src/interfaces/ISim.sol";

// Contracts
import {Simulate} from "../src/simulate/Simulate.sol";
import {Strategy} from "../src/strategy/Strategy.sol";

contract StrategyTest is Test {
    address ssov;
    Simulate sim;
    Strategy strat;

    uint256 epoch;

    // Deposit variables
    uint256[] public depositBlockNumbers;
    uint256[] public depositStrikeIndexes;
    uint256[] public depositAmounts;

    // Purchase variables
    uint256[] public purchaseBlockNumbers;
    uint256[] public purchaseStrikeIndexes;
    uint256[] public purchaseAmounts;

    function setUp() public {
        // Deploying contracts to Arbitrum fork & setting their state as persistent.
        setupFork();
        deploySimulateAndStrategy();

        /*=== USER INPUT REQUIRED ===*/

        // Select the SSOV V3 and epoch to test.
        ssov = 0x10FD85ec522C245a63239b9FC64434F58520bd1f; // WEEKLY DPX CALLS

        // Choose an epoch to test
        epoch = 1;

        // Input deposit parameters: block number, strike index and amount
        depositBlockNumbers = [22947245, 22967245];
        depositStrikeIndexes = [0, 1];
        depositAmounts = [5e18, 5e18];

        // Input purchase parameters: block number, strike index and amount
        purchaseBlockNumbers = [22964131, 23319117];
        purchaseStrikeIndexes = [0, 0];
        purchaseAmounts = [4e18, 20e18];
    }

    /*=== STRATEGY BACKTEST ===*/

    // Description:
    //     User inputs SSOV strategy (desired deposits or purchases during an epoch for given block numbers, strike indexes and amounts).
    //     `testStrategy()` then simulates an approximate performance of this strategy based on past SSOV epochs (forked Arbitrum state).

    //     If the desired purchase amount in `purchaseAmounts` for the given block number & strike index exceeds the available collateral,
    //     the purchase amount will be adjusted to the available amount (emits a log when this occurs).

    // To run in CL:
    //     forge test --match-test testStrategy -vvv

    // Returns:
    //
    function testStrategy() public {
        require(
            ((purchaseBlockNumbers.length == purchaseStrikeIndexes.length) &&
                (purchaseBlockNumbers.length == purchaseAmounts.length)),
            "PurchaseArrayLengthsNotEqual"
        );

        require(
            ((depositBlockNumbers.length == depositStrikeIndexes.length) &&
                (depositBlockNumbers.length == depositAmounts.length)),
            "DepositArrayLengthsNotEqual"
        );

        // PURCHASE -> SETTLE LOGIC

        if (purchaseBlockNumbers.length != 0) {
            purchaseCollateralChecker();

            emit log_string(" ");
            emit log_string(" ");

            strat.createPurchases(
                purchaseBlockNumbers,
                purchaseStrikeIndexes,
                purchaseAmounts
            );

            (
                uint256[] memory purchaseIds,
                uint256[] memory premiums,
                uint256[] memory purchaseFees
            ) = strat.executePurchases();

            uint256[] memory netPnls = strat.executeSettle(purchaseIds);

            purchaseSummary(netPnls, premiums, purchaseFees);
        }

        emit log_string(" ");
        emit log_string(" ");

        // DEPOSIT -> WITHDRAW LOGIC

        if (depositBlockNumbers.length != 0) {
            strat.createDeposits(
                depositBlockNumbers,
                depositStrikeIndexes,
                depositAmounts
            );

            uint256[] memory depositIds = strat.executeDeposits();

            strat.executeWithdraw(depositIds);

            depositSummary(depositIds);
        }
    }

    /*=== SUMARRY FUNCTIONS ===*/
    function purchaseSummary(
        uint256[] memory netPnls,
        uint256[] memory premiums,
        uint256[] memory purchaseFees
    ) public {
        emit log_string(
            "##################### PURCHASES #####################"
        );
        emit log_string(" ");

        for (uint256 i; i < purchaseBlockNumbers.length; ++i) {
            emit log_string(concatenate("INDEX ", Strings.toString(i)));
            emit log_string(
                "===================================================="
            );

            emit log_named_string(
                "block number",
                Strings.toString(purchaseBlockNumbers[i])
            );

            emit log_named_string(
                "strike index",
                Strings.toString(purchaseStrikeIndexes[i])
            );

            emit log_named_string(
                "strike",
                Strings.toString(
                    ISsovV3(ssov).getEpochData(epoch).strikes[
                        purchaseStrikeIndexes[i]
                    ]
                )
            );

            emit log_named_string(
                "amount",
                Strings.toString(purchaseAmounts[i])
            );

            emit log_string(
                "****************************************************"
            );

            emit log_named_int(
                "dpx net pnl (units)",
                int256(netPnls[i]) -
                    int256(premiums[i]) -
                    int256(purchaseFees[i])
            );

            emit log_string(" ");
        }
    }

    function depositSummary(uint256[] memory depositIds) public {
        emit log_string("##################### DEPOSITS #####################");
        emit log_string(" ");

        for (uint256 i; i < depositBlockNumbers.length; ++i) {
            emit log_string(concatenate("INDEX ", Strings.toString(i)));
            emit log_string(
                "===================================================="
            );

            emit log_named_string(
                "block number",
                Strings.toString(depositBlockNumbers[i])
            );

            emit log_named_string(
                "strike index",
                Strings.toString(depositStrikeIndexes[i])
            );

            emit log_named_string(
                "strike",
                Strings.toString(
                    ISsovV3(ssov).getEpochData(epoch).strikes[
                        depositStrikeIndexes[i]
                    ]
                )
            );

            emit log_named_string(
                "amount",
                Strings.toString(depositAmounts[i])
            );

            emit log_string(
                "****************************************************"
            );

            (
                uint256 collateralTokenWithdrawAmount,
                uint256[] memory rewardTokenWithdrawAmounts
            ) = strat.returnWithdrawDetails(depositIds[i]);

            emit log_named_string(
                "collateralTokenWithdrawAmount",
                Strings.toString(collateralTokenWithdrawAmount)
            );

            for (uint256 x; x < rewardTokenWithdrawAmounts.length; ++x) {
                string memory symbol = IERC20(
                    ISsovV3(ssov).getEpochData(epoch).rewardTokensToDistribute[
                        x
                    ]
                ).symbol();
                emit log_named_string(
                    concatenate("reward token ", symbol),
                    Strings.toString(rewardTokenWithdrawAmounts[x])
                );
            }

            emit log_named_int(
                "net dpx return (units)",
                int256(collateralTokenWithdrawAmount) -
                    int256(depositAmounts[i]) +
                    int256(rewardTokenWithdrawAmounts[0])
            );

            emit log_string(" ");
        }
    }

    /*=== CHECK OPTIONS AVAILABLE FOR PURCHASE ===*/

    // To run in CL:
    //     forge test --match-test testOptionsAvailableForPurchase -vvv

    // Returns:
    //     strike indexes available for the epoch (corresponding strike with 1e8 precision)
    //     available collateral for purchase at each strike index for a given epoch and given block (1e18 precision)

    // Run this function whenever you want to verify the number of options available for purchase.
    function testOptionsAvailableForPurchase() public {
        for (uint256 i; i < purchaseBlockNumbers.length; ++i) {
            setupForkBlockSpecified(purchaseBlockNumbers[i]);
            emit log_string(
                "*******************************************************************************"
            );
            emit log_string(
                concatenate(
                    "Block Number: ",
                    Strings.toString(purchaseBlockNumbers[i])
                )
            );
            strat.optionsAvailableForPurchase();
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

    function deploySimulateAndStrategy() public {
        sim = new Simulate();
        strat = new Strategy(address(sim), ssov, epoch);
        vm.makePersistent(address(sim), address(strat));
    }

    function concatenate(string memory _a, string memory _b)
        public
        pure
        returns (string memory)
    {
        return string(abi.encodePacked(_a, _b));
    }

    function purchaseCollateralChecker() public {
        for (uint256 i; i < purchaseBlockNumbers.length; ++i) {
            setupForkBlockSpecified(purchaseBlockNumbers[i]);

            uint256 strike = ISsovV3(ssov).getEpochData(epoch).strikes[
                purchaseStrikeIndexes[i]
            ];

            uint256 availableCollateral = ISsovV3(ssov)
                .getEpochStrikeData(epoch, strike)
                .totalCollateral -
                ISsovV3(ssov)
                    .getEpochStrikeData(epoch, strike)
                    .activeCollateral;

            uint256 requiredCollateral = ISsovV3(ssov).isPut()
                ? (purchaseAmounts[i] *
                    strike *
                    ISsovV3(ssov).collateralPrecision() *
                    ISsovV3(ssov).getEpochData(epoch).collateralExchangeRate) /
                    (1e34)
                : (purchaseAmounts[i] *
                    ISsovV3(ssov).getEpochData(epoch).collateralExchangeRate *
                    ISsovV3(ssov).collateralPrecision()) / (1e26);

            if (requiredCollateral > availableCollateral) {
                string memory temp = concatenate(
                    "Purchase amount at index ",
                    Strings.toString(i)
                );
                temp = concatenate(temp, " changed from ");
                temp = concatenate(temp, Strings.toString(purchaseAmounts[i]));
                temp = concatenate(temp, " to ");

                purchaseAmounts[i] = availableCollateral;

                temp = concatenate(temp, Strings.toString(purchaseAmounts[i]));

                emit log_string(temp);
            }
        }
    }
}
