// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from 'forge-std/interfaces/IERC20.sol';
import {AaveV3Polygon, AaveV3PolygonAssets} from 'aave-address-book/AaveV3Polygon.sol';
import {IAaveIncentivesController} from '../src/interfaces/IAaveIncentivesController.sol';

import {IEmissionManager, ITransferStrategyBase, RewardsDataTypes, IEACAggregatorProxy} from '../src/interfaces/IEmissionManager.sol';
import {BaseTest} from './utils/BaseTest.sol';
import {IMockOracle} from './utils/IMockOracle.sol';


contract EmissionTestLDOPolygon is BaseTest {
  /// @dev Used to simplify the definition of a program of emissions
  /// @param asset The asset on which to put reward on, usually Aave aTokens or vTokens (variable debt tokens)
  /// @param emission Total emission of a `reward` token during the whole distribution duration defined
  /// E.g. With an emission of 10_000 LDO tokens during 1 month, an emission of 50% for variableDebtPolstMATIC would be
  /// 10_000 * 1e18 * 50% / 30 days in seconds = 1_000 * 1e18 / 2_592_000 = ~ 0.0003858 * 1e18 LDO per second
  struct EmissionPerAsset {
    address asset;
    uint256 emission;
  }

  address constant EMISSION_ADMIN = 0x87D93d9B2C672bf9c9642d853a8682546a5012B5; // LDO multi-sig
  address constant REWARD_ASSET = 0xC3C7d422809852031b44ab29EEC9F1EfF2A58756;
  IEACAggregatorProxy constant REWARD_ORACLE =
    IEACAggregatorProxy(0xfb7559d168286DdAf38B862Ac0ACF16E01BD7C45);

  /// @dev already deployed and configured for the both the stMATIC asset and the 0x0c54a0BCCF5079478a144dBae1AFcb4FEdf7b263
  /// EMISSION_ADMIN
  ITransferStrategyBase constant TRANSFER_STRATEGY =
    ITransferStrategyBase(0xc62F9c7A785856141FC282C133fF4B4895179c0B);

  uint256 constant TOTAL_DISTRIBUTION = 10_000 ether; // 10'000 stMATIC/month, 6 months
  uint88 constant DURATION_DISTRIBUTION = 60 days;

  address LDO_WHALE = 0xD0c417aAB37c6b3ACf93dA6036bFE29963C5B3D9;
  address vstMATIC_WHALE = 0xC9c6Fc48a6fA8D7F06699B78EB46C908751966Df;

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('polygon'));
  }

  function test_activation() public {
    vm.startPrank(0x2981b6be80a1Efe9869EbFa5bCA895959C8312e1);
    IMockOracle(address(REWARD_ORACLE)).setAnswer(3150000000000000000);
    vm.stopPrank();

    vm.startPrank(EMISSION_ADMIN);
    /// @dev IMPORTANT!!
    /// The emissions admin should have REWARD_ASSET funds, and have approved the TOTAL_DISTRIBUTION
    /// amount to the transfer strategy. If not, REWARDS WILL ACCRUE FINE AFTER `configureAssets()`, BUT THEY
    /// WILL NOT BE CLAIMABLE UNTIL THERE IS FUNDS AND ALLOWANCE.
    /// It is possible to approve less than TOTAL_DISTRIBUTION and doing it progressively over time as users
    /// accrue more, but that is a decision of the emission's admin
    IERC20(REWARD_ASSET).approve(address(TRANSFER_STRATEGY), TOTAL_DISTRIBUTION);



    // REWARD_ORACLE.decimals();
    // require(TRANSFER_STRATEGY.getRewardsAdmin() == REWARD_ASSET, "Errorrrrrrrrrrrrrrrr");
    IEmissionManager(AaveV3Polygon.EMISSION_MANAGER).configureAssets(_getAssetConfigs());

    emit log_named_bytes(
      'calldata to submit from Gnosis Safe',
      abi.encodeWithSelector(
        IEmissionManager(AaveV3Polygon.EMISSION_MANAGER).configureAssets.selector,
        _getAssetConfigs()
      )
    );

    vm.stopPrank();

    vm.startPrank(LDO_WHALE);
    IERC20(REWARD_ASSET).transfer(EMISSION_ADMIN, 15_000 ether);

    vm.stopPrank();

    vm.startPrank(vstMATIC_WHALE);

    vm.warp(block.timestamp + 30 days);

    address[] memory assets = new address[](1);
    assets[0] = AaveV3PolygonAssets.stMATIC_A_TOKEN;

    uint256 balanceBefore = IERC20(REWARD_ASSET).balanceOf(vstMATIC_WHALE);

    IAaveIncentivesController(AaveV3Polygon.DEFAULT_INCENTIVES_CONTROLLER).claimRewards(
      assets,
      type(uint256).max,
      vstMATIC_WHALE,
      REWARD_ASSET
    );

    uint256 balanceAfter = IERC20(REWARD_ASSET).balanceOf(vstMATIC_WHALE);

    uint256 deviationAccepted = 2000 ether; // Approx estimated rewards with current emission in 1 month
    assertApproxEqAbs(
      balanceBefore,
      balanceAfter,
      deviationAccepted,
      'Invalid delta on claimed rewards'
    );

    vm.stopPrank();
  }

  function _getAssetConfigs() internal view returns (RewardsDataTypes.RewardsConfigInput[] memory) {
    uint32 distributionEnd = uint32(block.timestamp + DURATION_DISTRIBUTION);

    EmissionPerAsset[] memory emissionsPerAsset = _getEmissionsPerAsset();

    RewardsDataTypes.RewardsConfigInput[]
      memory configs = new RewardsDataTypes.RewardsConfigInput[](emissionsPerAsset.length);
    for (uint256 i = 0; i < emissionsPerAsset.length; i++) {
      configs[i] = RewardsDataTypes.RewardsConfigInput({
        emissionPerSecond: _toUint88(emissionsPerAsset[i].emission / DURATION_DISTRIBUTION),
        totalSupply: 0, // IMPORTANT this will not be taken into account by the contracts, so 0 is fine
        distributionEnd: distributionEnd,
        asset: emissionsPerAsset[i].asset,
        reward: REWARD_ASSET,
        transferStrategy: TRANSFER_STRATEGY,
        rewardOracle: REWARD_ORACLE
      });
    }

    return configs;
  }

  function _getEmissionsPerAsset() internal pure returns (EmissionPerAsset[] memory) {
    EmissionPerAsset[] memory emissionsPerAsset = new EmissionPerAsset[](1);
    emissionsPerAsset[0] = EmissionPerAsset({
      asset: AaveV3PolygonAssets.stMATIC_A_TOKEN,
      emission: TOTAL_DISTRIBUTION // 100% of the distribution
    });

    uint256 totalDistribution;
    for (uint256 i = 0; i < emissionsPerAsset.length; i++) {
      totalDistribution += emissionsPerAsset[i].emission;
    }
    require(totalDistribution == TOTAL_DISTRIBUTION, 'INVALID_SUM_OF_EMISSIONS');

    return emissionsPerAsset;
  }

  function _toUint88(uint256 value) internal pure returns (uint88) {
    require(value <= type(uint88).max, "SafeCast: value doesn't fit in 88 bits");
    return uint88(value);
  }
}
