// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {IERC20Detailed} from '../dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {ILendingPoolAddressesProvider} from '../interfaces/ILendingPoolAddressesProvider.sol';
import {IAaveIncentivesController} from '../interfaces/IAaveIncentivesController.sol';
import {IUiPoolDataProvider} from './interfaces/IUiPoolDataProvider.sol';
import {ILendingPool} from '../interfaces/ILendingPool.sol';
import {IPriceOracleGetter} from '../interfaces/IPriceOracleGetter.sol';
import {IAToken} from '../interfaces/IAToken.sol';
import {IVariableDebtToken} from '../interfaces/IVariableDebtToken.sol';
import {IStableDebtToken} from '../interfaces/IStableDebtToken.sol';
import {WadRayMath} from '../protocol/libraries/math/WadRayMath.sol';
import {ReserveConfiguration} from '../protocol/libraries/configuration/ReserveConfiguration.sol';
import {UserConfiguration} from '../protocol/libraries/configuration/UserConfiguration.sol';
import {DataTypes} from '../protocol/libraries/types/DataTypes.sol';
import {
  DefaultReserveInterestRateStrategy
} from '../protocol/lendingpool/DefaultReserveInterestRateStrategy.sol';

contract UiPoolDataProvider is IUiPoolDataProvider {
  using WadRayMath for uint256;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
  using UserConfiguration for DataTypes.UserConfigurationMap;

  address public constant MOCK_USD_ADDRESS = 0x10F7Fc1F91Ba351f9C629c5947AD69bD03C05b96;
  IAaveIncentivesController public immutable incentivesController;
  IPriceOracleGetter public immutable oracle;

  constructor(IAaveIncentivesController _incentivesController, IPriceOracleGetter _oracle) public {
    incentivesController = _incentivesController;
    oracle = _oracle;
  }

  function getInterestRateStrategySlopes(DefaultReserveInterestRateStrategy interestRateStrategy)
    internal
    view
    returns (
      uint256,
      uint256,
      uint256,
      uint256
    )
  {
    return (
      interestRateStrategy.variableRateSlope1(),
      interestRateStrategy.variableRateSlope2(),
      interestRateStrategy.stableRateSlope1(),
      interestRateStrategy.stableRateSlope2()
    );
  }

  function getReservesData(ILendingPoolAddressesProvider provider, address user)
    external
    view
    override
    returns (
      AggregatedReserveData[] memory,
      UserReserveData[] memory,
      uint256,
      uint256
    )
  {
    ILendingPool lendingPool = ILendingPool(provider.getLendingPool());
    address[] memory reserves = lendingPool.getReservesList();
    DataTypes.UserConfigurationMap memory userConfig = lendingPool.getUserConfiguration(user);

    AggregatedReserveData[] memory reservesData = new AggregatedReserveData[](reserves.length);
    UserReserveData[] memory userReservesData =
      new UserReserveData[](user != address(0) ? reserves.length : 0);

    for (uint256 i = 0; i < reserves.length; i++) {
      AggregatedReserveData memory reserveData = reservesData[i];
      reserveData.underlyingAsset = reserves[i];

      // reserve current state
      DataTypes.ReserveData memory baseData =
        lendingPool.getReserveData(reserveData.underlyingAsset);
      reserveData.liquidityIndex = baseData.liquidityIndex;
      reserveData.variableBorrowIndex = baseData.variableBorrowIndex;
      reserveData.liquidityRate = baseData.currentLiquidityRate;
      reserveData.variableBorrowRate = baseData.currentVariableBorrowRate;
      reserveData.stableBorrowRate = baseData.currentStableBorrowRate;
      reserveData.lastUpdateTimestamp = baseData.lastUpdateTimestamp;
      reserveData.aTokenAddress = baseData.aTokenAddress;
      reserveData.stableDebtTokenAddress = baseData.stableDebtTokenAddress;
      reserveData.variableDebtTokenAddress = baseData.variableDebtTokenAddress;
      reserveData.interestRateStrategyAddress = baseData.interestRateStrategyAddress;
      reserveData.priceInEth = oracle.getAssetPrice(reserveData.underlyingAsset);

      reserveData.availableLiquidity = IERC20Detailed(reserveData.underlyingAsset).balanceOf(
        reserveData.aTokenAddress
      );
      (
        reserveData.totalPrincipalStableDebt,
        ,
        reserveData.averageStableRate,
        reserveData.stableDebtLastUpdateTimestamp
      ) = IStableDebtToken(reserveData.stableDebtTokenAddress).getSupplyData();
      reserveData.totalScaledVariableDebt = IVariableDebtToken(reserveData.variableDebtTokenAddress)
        .scaledTotalSupply();

      // reserve configuration

      // we're getting this info from the aToken, because some of assets can be not compliant with ETC20Detailed
      reserveData.symbol = IERC20Detailed(reserveData.aTokenAddress).symbol();
      reserveData.name = '';

      (
        reserveData.baseLTVasCollateral,
        reserveData.reserveLiquidationThreshold,
        reserveData.reserveLiquidationBonus,
        reserveData.decimals,
        reserveData.reserveFactor
      ) = baseData.configuration.getParamsMemory();
      (
        reserveData.isActive,
        reserveData.isFrozen,
        reserveData.borrowingEnabled,
        reserveData.stableBorrowRateEnabled
      ) = baseData.configuration.getFlagsMemory();
      reserveData.usageAsCollateralEnabled = reserveData.baseLTVasCollateral != 0;
      (
        reserveData.variableRateSlope1,
        reserveData.variableRateSlope2,
        reserveData.stableRateSlope1,
        reserveData.stableRateSlope2
      ) = getInterestRateStrategySlopes(
        DefaultReserveInterestRateStrategy(reserveData.interestRateStrategyAddress)
      );

      // incentives
      if (address(0) != address(incentivesController)) {
        try incentivesController.getAssetData(reserveData.aTokenAddress) returns (
          uint256 aEmissionPerSecond, uint256 aIncentivesLastUpdateTimestamp, uint256 aTokenIncentivesIndex) {

          reserveData.aEmissionPerSecond = aEmissionPerSecond;
          reserveData.aIncentivesLastUpdateTimestamp = aIncentivesLastUpdateTimestamp;
          reserveData.aTokenIncentivesIndex = aTokenIncentivesIndex;
        } catch {}

        try incentivesController.getAssetData(reserveData.variableDebtTokenAddress) returns (
          uint256 vEmissionPerSecond, uint256 vIncentivesLastUpdateTimestamp, uint256 vTokenIncentivesIndex) {

          reserveData.vEmissionPerSecond = vEmissionPerSecond;
          reserveData.vIncentivesLastUpdateTimestamp = vIncentivesLastUpdateTimestamp;
          reserveData.vTokenIncentivesIndex = vTokenIncentivesIndex;
        } catch {}

        try incentivesController.getAssetData(reserveData.stableDebtTokenAddress) returns (
          uint256 sEmissionPerSecond, uint256 sIncentivesLastUpdateTimestamp, uint256 sTokenIncentivesIndex) {

          reserveData.sEmissionPerSecond = sEmissionPerSecond;
          reserveData.sIncentivesLastUpdateTimestamp = sIncentivesLastUpdateTimestamp;
          reserveData.sTokenIncentivesIndex = sTokenIncentivesIndex;
        } catch {}
      }

      if (user != address(0)) {
        // incentives
        if (address(0) != address(incentivesController)) {
          try incentivesController.getUserAssetData(
            user,
            reserveData.aTokenAddress
          ) returns (
          uint256 aTokenincentivesUserIndex) {
            userReservesData[i].aTokenincentivesUserIndex = aTokenincentivesUserIndex;
          } catch {}

          try incentivesController.getUserAssetData(
            user,
            reserveData.variableDebtTokenAddress
          ) returns (
          uint256 vTokenincentivesUserIndex) {
            userReservesData[i].vTokenincentivesUserIndex = vTokenincentivesUserIndex;
          } catch {}

          try incentivesController.getUserAssetData(
            user,
            reserveData.stableDebtTokenAddress
          ) returns (
          uint256 sTokenincentivesUserIndex) {
            userReservesData[i].sTokenincentivesUserIndex = sTokenincentivesUserIndex;
          } catch {}
        }
        // user reserve data
        userReservesData[i].underlyingAsset = reserveData.underlyingAsset;
        userReservesData[i].scaledATokenBalance = IAToken(reserveData.aTokenAddress)
          .scaledBalanceOf(user);
        userReservesData[i].usageAsCollateralEnabledOnUser = userConfig.isUsingAsCollateral(i);

        if (userConfig.isBorrowing(i)) {
          userReservesData[i].scaledVariableDebt = IVariableDebtToken(
            reserveData
              .variableDebtTokenAddress
          )
            .scaledBalanceOf(user);
          userReservesData[i].principalStableDebt = IStableDebtToken(
            reserveData
              .stableDebtTokenAddress
          )
            .principalBalanceOf(user);
          if (userReservesData[i].principalStableDebt != 0) {
            userReservesData[i].stableBorrowRate = IStableDebtToken(
              reserveData
                .stableDebtTokenAddress
            )
              .getUserStableRate(user);
            userReservesData[i].stableBorrowLastUpdateTimestamp = IStableDebtToken(
              reserveData
                .stableDebtTokenAddress
            )
              .getUserLastUpdated(user);
          }
        }
      }
    }

    uint256 unclaimedRewards;
    if (address(0) != address(incentivesController)) {
      try incentivesController.getUserUnclaimedRewards(user) returns (uint256 rewards) { 
        unclaimedRewards = rewards; 
      } catch {}
    }

    return (
      reservesData,
      userReservesData,
      oracle.getAssetPrice(MOCK_USD_ADDRESS),
      unclaimedRewards
    );
  }
}
