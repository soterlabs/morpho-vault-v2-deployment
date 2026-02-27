// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {IMorpho, MarketParams, Id, Market} from "metamorpho-v1.1-morpho-blue/src/interfaces/IMorpho.sol";
import {IMorphoMarketV1AdapterV2} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";

import {Constants} from "../../src/lib/Constants.sol";
import {CappedChainlinkFeed} from "../../src/CappedChainlinkFeed.sol";
import {IMorphoChainlinkOracleV2} from "../../src/lib/DeployHelpers.sol";
import {BaseDeployedVaultTest} from "../base/BaseDeployedVaultTest.sol";

/**
 * @title DeployedUsdtSavingsVaultTest
 * @notice Tests against already-deployed USDT Savings vault on Tenderly or mainnet fork
 * @dev Set VAULT_ADDRESS env var to test a specific deployed vault
 */
contract DeployedUsdtSavingsVaultTest is BaseDeployedVaultTest {
    function _loanTokenAddress() internal pure override returns (address) {
        return Constants.USDT;
    }

    function _initialDeadDeposit() internal pure override returns (uint256) {
        return Constants.INITIAL_DEAD_DEPOSIT_6DEC;
    }

    function _depositAmount() internal pure override returns (uint256) {
        return 100e6;
    }

    function _expectedVaultName() internal pure override returns (string memory) {
        return "sky.money USDT Savings";
    }

    function _expectedVaultSymbol() internal pure override returns (string memory) {
        return "skyMoneyUsdtSavings";
    }

    // ============ USDT SAVINGS SPECIFIC TESTS ============

    function testLiquidityAdapterSet() public view {
        console.log("=== Liquidity Adapter Check ===");
        address liquidityAdapter = vault.liquidityAdapter();
        console.log("Liquidity Adapter:", liquidityAdapter);

        assertEq(liquidityAdapter, vault.adapters(0), "Liquidity adapter should match first adapter");
    }

    function testMorphoMarketUtilizationIsApprox90Percent() public view {
        console.log("=== Morpho Market Utilization ===");

        bytes memory liquidityData = vault.liquidityData();
        require(liquidityData.length > 0, "Vault has no liquidity data set");

        MarketParams memory params = abi.decode(liquidityData, (MarketParams));
        console.log("Oracle (from vault):", params.oracle);

        Id marketId = Id.wrap(keccak256(abi.encode(params)));
        IMorpho morpho = IMorpho(Constants.MORPHO_BLUE);
        Market memory marketState = morpho.market(marketId);

        console.log("Market totalSupplyAssets:", marketState.totalSupplyAssets);
        console.log("Market totalBorrowAssets:", marketState.totalBorrowAssets);

        uint256 utilizationBps = (uint256(marketState.totalBorrowAssets) * 10000) / uint256(marketState.totalSupplyAssets);
        console.log("Utilization (bps):", utilizationBps);

        assertApproxEqAbs(utilizationBps, 9000, 50, "Market utilization should be ~90% (9000 bps, +/- 50 bps)");
    }

    function testMarketLltvIs96Point5Percent() public view {
        console.log("=== Market LLTV Check ===");

        bytes memory liquidityData = vault.liquidityData();
        require(liquidityData.length > 0, "Vault has no liquidity data set");

        MarketParams memory params = abi.decode(liquidityData, (MarketParams));
        console.log("LLTV:", params.lltv);

        assertEq(params.lltv, Constants.LLTV_SAVINGS, "LLTV should be 96.5%");
    }

    function testOracleReturnsValidPrice() public view {
        console.log("=== Oracle Price Check ===");

        bytes memory liquidityData = vault.liquidityData();
        MarketParams memory params = abi.decode(liquidityData, (MarketParams));

        IMorphoChainlinkOracleV2 oracle = IMorphoChainlinkOracleV2(params.oracle);
        uint256 price = oracle.price();

        // Scale = 10^(36 + 6 - 18) = 10^24. sUSDS ~$1.05 USDT
        uint256 expectedScale = 1e24;
        assertGt(price, expectedScale * 100 / 100, "Price should be >= 1.00 * scale");
        assertLt(price, expectedScale * 120 / 100, "Price should be < 1.20 * scale");
        console.log("Oracle price:", price);
    }

    function testOracleFeedConfiguration() public view {
        console.log("=== Oracle Feed Configuration ===");

        bytes memory liquidityData = vault.liquidityData();
        MarketParams memory params = abi.decode(liquidityData, (MarketParams));

        IMorphoChainlinkOracleV2 oracle = IMorphoChainlinkOracleV2(params.oracle);

        assertEq(oracle.BASE_VAULT(), Constants.S_USDS, "Base vault should be sUSDS");
        assertEq(oracle.BASE_VAULT_CONVERSION_SAMPLE(), 1e18, "Base vault conversion sample should be 1e18");
        assertEq(oracle.BASE_FEED_1(), Constants.CHAINLINK_USDS_USD, "Base feed 1 should be USDS/USD");
        assertEq(oracle.BASE_FEED_2(), address(0), "Base feed 2 should be zero");
        assertEq(oracle.QUOTE_VAULT(), address(0), "Quote vault should be zero");
        // Quote feed 1 is a capped USDT/USD feed (not the raw Chainlink feed)
        address quoteFeed1 = oracle.QUOTE_FEED_1();
        assertTrue(quoteFeed1 != address(0), "Quote feed 1 should not be zero");
        CappedChainlinkFeed cappedFeed = CappedChainlinkFeed(quoteFeed1);
        assertEq(address(cappedFeed.source()), Constants.CHAINLINK_USDT_USD, "Capped feed underlying should be USDT/USD");
        assertEq(cappedFeed.maxPrice(), 1e8, "Capped feed max price should be $1 (1e8)");
        assertEq(oracle.QUOTE_FEED_2(), address(0), "Quote feed 2 should be zero");
    }

    function testMarketParams() public view {
        console.log("=== Market Params Check ===");

        bytes memory liquidityData = vault.liquidityData();
        MarketParams memory params = abi.decode(liquidityData, (MarketParams));

        assertEq(params.loanToken, Constants.USDT, "Loan token should be USDT");
        assertEq(params.collateralToken, Constants.S_USDS, "Collateral should be sUSDS");
        assertEq(params.irm, Constants.IRM_ADAPTIVE, "IRM should be adaptive");
        assertEq(params.lltv, Constants.LLTV_SAVINGS, "LLTV should be 96.5%");
        assertTrue(params.oracle != address(0), "Oracle should not be zero");
    }

    function testAdapterTimelocks() public view {
        console.log("=== Adapter Timelocks Check ===");

        IMorphoMarketV1AdapterV2 adapter = IMorphoMarketV1AdapterV2(vault.adapters(0));

        assertEq(adapter.timelock(IMorphoMarketV1AdapterV2.burnShares.selector), Constants.TIMELOCK_LOW, "burnShares timelock should be 3 days");
        assertEq(adapter.timelock(IMorphoMarketV1AdapterV2.setSkimRecipient.selector), Constants.TIMELOCK_LOW, "setSkimRecipient timelock should be 3 days");
        assertEq(adapter.timelock(IMorphoMarketV1AdapterV2.abdicate.selector), Constants.TIMELOCK_HIGH, "abdicate timelock should be 7 days");
        assertEq(adapter.timelock(IMorphoMarketV1AdapterV2.increaseTimelock.selector), Constants.TIMELOCK_HIGH, "increaseTimelock timelock should be 7 days");
    }
}
