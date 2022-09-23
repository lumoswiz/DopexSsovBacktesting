// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SimulateState} from "./SimulateState.sol";

// Interfaces
import {ISsovV3} from "../interfaces/ISsovV3.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IFeeStrategy} from "../interfaces/IFeeStrategy.sol";
import {IStakingStrategy} from "../interfaces/IStakingStrategy.sol";
import {IOptionPricing} from "../interfaces/IOptionPricing.sol";

import {Counters} from "openzeppelin-contracts/utils/Counters.sol";

contract Simulate is Test, SimulateState {
    using stdStorage for StdStorage;
    using Counters for Counters.Counter;
    Counters.Counter public _depositIdCounter;
    Counters.Counter public _purchaseIdCounter;

    uint256 internal constant OPTIONS_PRECISION = 1e18;
    uint256 internal constant DEFAULT_PRECISION = 1e8;
    uint256 internal constant REWARD_PRECISION = 1e18;

    /*=== DEPOSIT ===*/

    function deposit(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 strikeIndex,
        uint256 amount
    ) public returns (uint256 depositId) {
        _epochNotExpired(ISsovV3(ssov), epoch);
        _valueNotZero(amount);

        uint256 strike = ssov.getEpochData(epoch).strikes[strikeIndex];
        _valueNotZero(strike);

        uint256[] memory rewardDistributionRatios = _updateRewards(
            ssov,
            epoch,
            _getRewards(ssov, epoch)
        );

        uint256 checkpointIndex = ssov.getEpochStrikeCheckpointsLength(
            epoch,
            strike
        ) - 1;

        depositId = getDepositId();

        writePositions[depositId] = WritePosition({
            epoch: epoch,
            strike: strike,
            collateralAmount: amount,
            checkpointIndex: checkpointIndex,
            rewardDistributionRatios: rewardDistributionRatios
        });
    }

    /*=== PURCHASE ===*/
    function purchase(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 strikeIndex,
        uint256 amount
    )
        public
        returns (
            uint256 purchaseId,
            uint256 premium,
            uint256 purchaseFee
        )
    {
        _valueNotZero(amount);

        (, uint256 epochExpiry) = ssov.getEpochTimes(epoch);
        _validate(block.timestamp < epochExpiry, 5);

        uint256 strike = ssov.getEpochData(epoch).strikes[strikeIndex];
        _valueNotZero(strike);

        // Get total premium for all options being purchased
        premium = _calculatePremium(ssov, epoch, strike, amount);

        // Total fee charged
        purchaseFee = _calculatePurchaseFees(ssov, strike, amount);

        purchaseId = getPurchaseId();

        purchasePositions[purchaseId] = PurchasePosition({
            epoch: epoch,
            strike: strike,
            amount: amount,
            premium: premium,
            purchaseFee: purchaseFee
        });
    }

    /*=== SETTLE ===*/
    function settle(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 purchaseId
    ) public returns (uint256 netPnl) {
        (
            uint256 _epoch,
            uint256 strike,
            uint256 amount,
            ,

        ) = getPurchasePosition(purchaseId);

        purchasePositions[purchaseId].amount = 0;

        _valueNotZero(amount);
        _validate(_epoch == epoch, 11);
        _epochExpired(ssov, epoch);

        // uint256 strike = ssov.getEpochData(epoch).strikes[strikeIndex];
        _valueNotZero(strike);

        // Get settlement price for epoch
        uint256 settlementPrice = ssov.getEpochData(epoch).settlementPrice;

        // Calculate pnl
        uint256 pnl = _calculatePnl(
            ssov,
            settlementPrice,
            strike,
            amount,
            ssov.getEpochData(epoch).settlementCollateralExchangeRate
        );

        // Total fee charged
        uint256 settlementFee = _calculateSettlementFees(ssov, pnl);

        if (pnl == 0) {
            netPnl = 0;
        } else {
            netPnl = pnl - settlementFee;
        }
    }

    /*=== WITHDRAW ===*/
    function calculateAccruedPremiumOnWithdraw(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 depositId
    ) public view returns (uint256 accruedPremium) {
        (
            uint256 _epoch,
            uint256 strike,
            uint256 collateralAmount,
            uint256 checkpointIndex,

        ) = getWritePosition(depositId);

        _valueNotZero(strike);
        _validate(_epoch == epoch, 11);
        _epochExpired(ssov, epoch);

        uint256 extractedAmount;
        uint256 calculatedAccruedPremium;
        uint256 pointer = checkpointIndex;

        while (
            (extractedAmount < collateralAmount) &&
            (pointer < ssov.getEpochStrikeCheckpointsLength(epoch, strike))
        ) {
            uint256 _remainingRequired = collateralAmount - extractedAmount;

            if (
                ssov.checkpoints(epoch, strike, pointer).activeCollateral >=
                _remainingRequired
            ) {
                extractedAmount += _remainingRequired;
                calculatedAccruedPremium +=
                    (((collateralAmount * DEFAULT_PRECISION) /
                        ssov
                            .checkpoints(epoch, strike, pointer)
                            .activeCollateral) *
                        ssov
                            .checkpoints(epoch, strike, pointer)
                            .accruedPremium) /
                    DEFAULT_PRECISION;
            } else {
                extractedAmount += ssov
                    .checkpoints(epoch, strike, pointer)
                    .activeCollateral;
                calculatedAccruedPremium += ssov
                    .checkpoints(epoch, strike, pointer)
                    .accruedPremium;
                pointer += 1;
            }
        }

        accruedPremium =
            ((ssov.checkpoints(epoch, strike, checkpointIndex).accruedPremium +
                calculatedAccruedPremium) * collateralAmount) /
            ssov.checkpoints(epoch, strike, checkpointIndex).totalCollateral;
    }

    function calculateCollateralTokenWithdrawAmount(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 depositId,
        uint256 accruedPremium
    ) public view returns (uint256 collateralTokenWithdrawAmount) {
        (
            ,
            uint256 strike,
            uint256 collateralAmount,
            uint256 checkpointIndex,

        ) = getWritePosition(depositId);

        // Calculate the withdrawable collateral amount
        // Potentially change: `optionsWritten` -> collateralAmount
        collateralTokenWithdrawAmount =
            ((ssov.checkpoints(epoch, strike, checkpointIndex).totalCollateral -
                _calculatePnl(
                    ssov,
                    ssov.getEpochData(epoch).settlementPrice,
                    strike,
                    collateralAmount,
                    ssov.getEpochData(epoch).settlementCollateralExchangeRate
                )) * collateralAmount) /
            ssov.checkpoints(epoch, strike, checkpointIndex).totalCollateral;

        // Add premiums
        collateralTokenWithdrawAmount += accruedPremium;
    }

    function calculateRewardTokenWithdrawAmounts(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 depositId,
        uint256 accruedPremium
    ) public view returns (uint256[] memory rewardTokenWithdrawAmounts) {
        (
            ,
            uint256 strike,
            uint256 collateralAmount,
            ,
            uint256[] memory rewardDistributionRatios
        ) = getWritePosition(depositId);

        rewardTokenWithdrawAmounts = getUintArray(
            ssov.getEpochData(epoch).rewardTokensToDistribute.length
        );

        // Calculate rewards
        for (uint256 i; i < rewardTokenWithdrawAmounts.length; ) {
            rewardTokenWithdrawAmounts[i] +=
                ((ssov.getEpochData(epoch).rewardDistributionRatios[i] -
                    rewardDistributionRatios[i]) * collateralAmount) /
                ssov.collateralPrecision();

            if (ssov.getEpochStrikeData(epoch, strike).totalPremiums > 0)
                rewardTokenWithdrawAmounts[i] +=
                    (accruedPremium *
                        ssov
                            .getEpochStrikeData(epoch, strike)
                            .rewardStoredForPremiums[i]) /
                    ssov.getEpochStrikeData(epoch, strike).totalPremiums;

            unchecked {
                ++i;
            }
        }
    }

    function withdraw(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 depositId
    )
        public
        view
        returns (
            uint256 collateralTokenWithdrawAmount,
            uint256[] memory rewardTokenWithdrawAmounts
        )
    {
        uint256 accruedPremium = calculateAccruedPremiumOnWithdraw(
            ssov,
            epoch,
            depositId
        );
        collateralTokenWithdrawAmount = calculateCollateralTokenWithdrawAmount(
            ssov,
            epoch,
            depositId,
            accruedPremium
        );
        rewardTokenWithdrawAmounts = calculateRewardTokenWithdrawAmounts(
            ssov,
            epoch,
            depositId,
            accruedPremium
        );
    }

    /*=== FUNCTIONS FOR DEPOSIT ===*/

    function _getRewards(ISsovV3 ssov, uint256 epoch)
        public
        returns (uint256[] memory rewardTokenAmounts)
    {
        uint256 startTime = ssov.getEpochData(epoch).startTime;
        uint256 expiry = ssov.getEpochData(epoch).expiry;

        // Slot finder logic
        uint256 mappingSlot = 1;
        uint256 elementSize = 1;
        uint256 mapUint = getMapLocation(mappingSlot, epoch);

        uint256 rewardTokenLengths = IStakingStrategy(
            ssov.addresses().stakingStrategy
        ).getRewardTokens().length;

        rewardTokenAmounts = new uint256[](rewardTokenLengths);

        for (uint256 i = 0; i < rewardTokenLengths; ) {
            uint256 rewardsPerEpoch = uint256(
                vm.load(
                    ssov.addresses().stakingStrategy,
                    bytes32(getArrayLocation(mapUint, i, elementSize))
                )
            );

            rewardTokenAmounts[i] =
                (rewardsPerEpoch / (expiry - startTime)) *
                (block.timestamp - startTime);

            unchecked {
                ++i;
            }
        }
    }

    function _updateRewards(
        ISsovV3 ssov,
        uint256 epoch,
        uint256[] memory totalRewardsArray
    ) public view returns (uint256[] memory rewardsDistributionRatios) {
        rewardsDistributionRatios = getUintArray(totalRewardsArray.length);
        uint256 newRewardsCollected;

        for (uint256 i = 0; i < totalRewardsArray.length; ) {
            // Calculate the new rewards accrued
            newRewardsCollected =
                totalRewardsArray[i] -
                ssov.getEpochData(epoch).totalRewardsCollected[i];

            // Calculate the reward distribution ratios for new rewards accrued
            if (ssov.getEpochData(epoch).totalCollateralBalance == 0) {
                rewardsDistributionRatios[i] = 0;
            } else {
                rewardsDistributionRatios[i] =
                    (newRewardsCollected * ssov.collateralPrecision()) /
                    ssov.getEpochData(epoch).totalCollateralBalance;
            }

            rewardsDistributionRatios[i] += ssov
                .getEpochData(epoch)
                .rewardDistributionRatios[i];

            unchecked {
                ++i;
            }
        }
    }

    /*=== FUNCTIONS FOR PURCHASE ===*/
    function _calculatePremium(
        ISsovV3 ssov,
        uint256 epoch,
        uint256 strike,
        uint256 amount
    ) public view returns (uint256 premium) {
        (, uint256 expiry) = ssov.getEpochTimes(epoch);

        premium =
            IOptionPricing(ssov.addresses().optionPricing).getOptionPrice(
                ssov.isPut(),
                expiry,
                strike,
                ssov.getUnderlyingPrice(),
                ssov.getVolatility(strike)
            ) *
            amount;

        premium =
            (premium * ssov.collateralPrecision()) /
            (ssov.getCollateralPrice() * OPTIONS_PRECISION);
    }

    function _calculatePurchaseFees(
        ISsovV3 ssov,
        uint256 strike,
        uint256 amount
    ) public returns (uint256 fee) {
        uint256 purchaseFeePercentage = stdstore
            .target(ssov.addresses().feeStrategy)
            .sig("ssovFeeStructures(address)")
            .with_key(address(ssov))
            .read_uint();

        fee =
            ((purchaseFeePercentage * amount * ssov.getUnderlyingPrice()) /
                1e10) /
            1e18;

        if (ssov.getUnderlyingPrice() < strike) {
            uint256 feeMultiplier = ((strike * 100) /
                (ssov.getUnderlyingPrice()) -
                100) + 100;
            fee = (feeMultiplier * fee) / 100;
        }

        return ((fee * ssov.collateralPrecision()) / ssov.getCollateralPrice());
    }

    /*=== FUNCTIONS FOR SETTLE ===*/
    function _calculatePnl(
        ISsovV3 ssov,
        uint256 price,
        uint256 strike,
        uint256 amount,
        uint256 collateralExchangeRate
    ) public view returns (uint256) {
        if (ssov.isPut())
            return
                strike > price
                    ? ((strike - price) *
                        amount *
                        ssov.collateralPrecision() *
                        collateralExchangeRate) /
                        (OPTIONS_PRECISION *
                            DEFAULT_PRECISION *
                            DEFAULT_PRECISION)
                    : 0;
        return
            price > strike
                ? (((price - strike) *
                    amount *
                    ssov.collateralPrecision() *
                    collateralExchangeRate) / price) /
                    (OPTIONS_PRECISION * DEFAULT_PRECISION)
                : 0;
    }

    function _calculateSettlementFees(ISsovV3 ssov, uint256 pnl)
        public
        returns (uint256 fee)
    {
        uint256 settlementFeePercentage = stdstore
            .target(ssov.addresses().feeStrategy)
            .sig("ssovFeeStructures(address)")
            .with_key(address(ssov))
            .depth(1)
            .read_uint();

        fee = (settlementFeePercentage * pnl) / 1e10;
    }

    /*=== COUNTER FUNCTIONS ===*/

    function getDepositId() public returns (uint256 depositId) {
        depositId = _depositIdCounter.current();
        _depositIdCounter.increment();
    }

    function getPurchaseId() public returns (uint256 purchaseId) {
        purchaseId = _purchaseIdCounter.current();
        _purchaseIdCounter.increment();
    }

    /*=== PRIVATE FUNCTIONS FOR REVERTS ===*/
    /// @dev Internal function to validate a condition
    /// @param _condition boolean condition
    /// @param _errorCode error code to revert with
    function _validate(bool _condition, uint256 _errorCode) private pure {
        if (!_condition) revert SsovV3Error(_errorCode);
    }

    /// @dev Internal function to check if the epoch passed is not expired. Revert if expired.
    /// @param _epoch the epoch
    function _epochNotExpired(ISsovV3 ssov, uint256 _epoch) private view {
        _validate(!ssov.getEpochData(_epoch).expired, 7);
    }

    /// @dev Internal function to check if the value passed is not zero. Revert if 0.
    /// @param _value the value
    function _valueNotZero(uint256 _value) private pure {
        _validate(!valueGreaterThanZero(_value), 8);
    }

    /// @dev Internal function to check if the epoch passed is expired. Revert if not expired.
    /// @param _epoch the epoch
    function _epochExpired(ISsovV3 ssov, uint256 _epoch) private view {
        _validate(ssov.getEpochData(_epoch).expired, 9);
    }

    /*=== VIEW FUNCTIONS ===*/

    /// @notice View a write position
    /// @param depositId depositId a parameter
    function getWritePosition(uint256 depositId)
        public
        view
        returns (
            uint256 epoch,
            uint256 strike,
            uint256 collateralAmount,
            uint256 checkpointIndex,
            uint256[] memory rewardsDistributionRatios
        )
    {
        WritePosition memory _writePosition = writePositions[depositId];

        return (
            _writePosition.epoch,
            _writePosition.strike,
            _writePosition.collateralAmount,
            _writePosition.checkpointIndex,
            _writePosition.rewardDistributionRatios
        );
    }

    /// @notice View a purchase position
    /// @param purchaseId purchaseId a parameter
    function getPurchasePosition(uint256 purchaseId)
        public
        view
        returns (
            uint256 epoch,
            uint256 strike,
            uint256 amount,
            uint256 premium,
            uint256 purchaseFee
        )
    {
        PurchasePosition memory _purchasePosition = purchasePositions[
            purchaseId
        ];

        return (
            _purchasePosition.epoch,
            _purchasePosition.strike,
            _purchasePosition.amount,
            _purchasePosition.premium,
            _purchasePosition.purchaseFee
        );
    }

    /*=== PURE FUNCTIONS ===*/

    function getUintArray(uint256 _arrayLength)
        public
        pure
        returns (uint256[] memory result)
    {
        result = new uint256[](_arrayLength);
    }

    function valueGreaterThanZero(uint256 _value)
        public
        pure
        returns (bool result)
    {
        assembly {
            result := iszero(_value)
        }
    }

    function getMapLocation(uint256 slot, uint256 key)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(key, slot)));
    }

    function getArrayLocation(
        uint256 slot,
        uint256 index,
        uint256 elementSize
    ) public pure returns (uint256) {
        return
            uint256(keccak256(abi.encodePacked(slot))) + (index * elementSize);
    }

    /*==== ERRORS ====*/
    error SsovV3Error(uint256);
}

/*==== ERROR CODE MAPPING ====*/
// 1 - block.timestamp must be greater than expiry timestamp
// 2 - block.timestamp must be lesser than expiry timestamp + delay tolerance
// 3 - block.timestamp must be lesser than the passed expiry timestamp
// 4 - If current epoch is greater than 0 then the current epoch must be expired to bootstrap
// 5 - block.timestamp must be lesser than the expiry timestamp
// 6 - required collateral must be lesser than the available collateral
// 7 - epoch must not be expired
// 8 - value must not be zero
// 9 - epoch must be expired
// 10 - option token balance of msg.sender should be greater than or equal to amount being settled
// 11 - simulation _epoch different to epoch
