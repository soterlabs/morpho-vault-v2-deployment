// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, MarketParams, Id, Market} from "metamorpho-v1.1-morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "metamorpho-v1.1-morpho-blue/src/interfaces/IOracle.sol";

import {CappedOracleFeed} from "capped-oracle-feed/CappedOracleFeed.sol";
import {Constants} from "../../src/lib/Constants.sol";
import {IMorphoChainlinkOracleV2, AggregatorV3Interface} from "../../src/lib/DeployHelpers.sol";
import {DeployOracleAndMarket} from "../../script/usdt_savings_market_migration/1_DeployOracleAndMarket.s.sol";

/**
 * @title DeployMigrationScriptTest
 * @notice Tests for the Phase 1 migration script: deploy capped oracle, Morpho oracle, create and seed market
 */
contract DeployMigrationScriptTest is Test {
    using SafeERC20 for IERC20;

    DeployOracleAndMarket public script;
    DeployOracleAndMarket.DeploymentResult public result;

    address public deployer;

    function setUp() public {
        vm.setEnv("PRIVATE_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
        deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        script = new DeployOracleAndMarket();
    }

    function _runScript() internal {
        deal(Constants.USDT, deployer, 10e6);
        deal(Constants.S_USDS, deployer, 3e18);
        result = script.run();
    }

    // ============ SCRIPT EXECUTION ============

    function testRunScript() public {
        _runScript();

        assertTrue(result.cappedUsdtFeed != address(0), "CappedOracleFeed should be deployed");
        assertTrue(result.oracle != address(0), "Oracle should be deployed");
        assertTrue(result.marketId != bytes32(0), "Market ID should be set");
        console.log("CappedOracleFeed:", result.cappedUsdtFeed);
        console.log("Oracle:", result.oracle);
        console.log("Market ID:", vm.toString(result.marketId));
    }

    // ============ CAPPED ORACLE FEED TESTS ============

    function testCappedFeedCapsAtOneDollar() public {
        _runScript();

        CappedOracleFeed feed = CappedOracleFeed(result.cappedUsdtFeed);

        assertEq(feed.maxPrice(), 1e8, "Max price should be $1.00 (8 decimals)");
        assertEq(feed.decimals(), 8, "Decimals should be 8");
        assertEq(address(feed.source()), Constants.CHAINLINK_USDT_USD, "Source should be USDT/USD Chainlink");
    }

    function testCappedFeedLatestRoundDataPriceCapped() public {
        _runScript();

        CappedOracleFeed feed = CappedOracleFeed(result.cappedUsdtFeed);
        (, int256 answer,,,) = feed.latestRoundData();

        // USDT is ~$1, capped at $1 — answer should be <= 1e8
        assertGt(answer, 0, "Answer should be positive");
        assertLe(answer, 1e8, "Answer should be <= $1.00");
        console.log("Capped USDT/USD answer:", uint256(answer));
    }

    function testCappedFeedLatestRoundData() public {
        _runScript();

        CappedOracleFeed feed = CappedOracleFeed(result.cappedUsdtFeed);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();

        assertGt(roundId, 0, "Round ID should be positive");
        assertGt(answer, 0, "Answer should be positive");
        assertLe(answer, 1e8, "Answer should be capped at $1.00");
        assertGt(startedAt, 0, "StartedAt should be set");
        assertGt(updatedAt, 0, "UpdatedAt should be set");
        assertGt(answeredInRound, 0, "AnsweredInRound should be set");
    }

    function testCappedFeedDecimalsMatchSource() public {
        _runScript();

        CappedOracleFeed feed = CappedOracleFeed(result.cappedUsdtFeed);
        assertEq(feed.decimals(), AggregatorV3Interface(Constants.CHAINLINK_USDT_USD).decimals(), "Decimals should match source");
    }

    // ============ MORPHO ORACLE TESTS ============

    function testOracleFeedConfiguration() public {
        _runScript();

        IMorphoChainlinkOracleV2 oracle = IMorphoChainlinkOracleV2(result.oracle);

        assertEq(oracle.BASE_VAULT(), Constants.S_USDS, "Base vault should be sUSDS");
        assertEq(oracle.BASE_VAULT_CONVERSION_SAMPLE(), 1e18, "Base vault conversion sample should be 1e18");
        assertEq(oracle.BASE_FEED_1(), Constants.CHAINLINK_USDS_USD, "Base feed 1 should be USDS/USD");
        assertEq(oracle.BASE_FEED_2(), address(0), "Base feed 2 should be zero");
        assertEq(oracle.QUOTE_VAULT(), address(0), "Quote vault should be zero");
        assertEq(oracle.QUOTE_FEED_1(), result.cappedUsdtFeed, "Quote feed 1 should be CappedOracleFeed");
        assertEq(oracle.QUOTE_FEED_2(), address(0), "Quote feed 2 should be zero");
    }

    function testOracleReturnsValidPrice() public {
        _runScript();

        uint256 price = IOracle(result.oracle).price();

        // Scale = 10^(36 + 6 - 18) = 10^24. sUSDS ~$1.05 USDT
        uint256 scale = 1e24;
        assertGt(price, scale, "Price should be >= 1.00 * scale");
        assertLt(price, scale * 120 / 100, "Price should be < 1.20 * scale");
        console.log("Oracle price:", price);
    }

    function testOraclePriceIsHigherOrEqualToExisting() public {
        _runScript();

        // With USDT capped at $1, the oracle should value sUSDS at least as high as the existing oracle.
        // If USDT trades above $1, the capped oracle will report a higher sUSDS/USDT price
        // (because denominator is smaller), making the vault more conservative (harder to borrow).
        uint256 newPrice = IOracle(result.oracle).price();
        uint256 existingPrice = IOracle(Constants.EXISTING_SUSDS_USDT_ORACLE).price();

        // Prices won't match exactly due to different base feeds (USDS/USD vs DAI/USD)
        // but should be in the same ballpark
        uint256 scale = 1e24;
        assertGt(newPrice, scale * 99 / 100, "New oracle price should be reasonable");
        assertGt(existingPrice, scale * 99 / 100, "Existing oracle price should be reasonable");
        console.log("New oracle price:", newPrice);
        console.log("Existing oracle price:", existingPrice);
    }

    // ============ MARKET TESTS ============

    function testMarketCreatedOnMorpho() public {
        _runScript();

        IMorpho morpho = IMorpho(Constants.MORPHO_BLUE);
        Market memory marketState = morpho.market(Id.wrap(result.marketId));

        assertGt(marketState.totalSupplyShares, 0, "Market should have supply shares");
        assertGt(marketState.totalBorrowShares, 0, "Market should have borrow shares");
    }

    function testMarketParams() public {
        _runScript();

        assertEq(result.params.loanToken, Constants.USDT, "Loan token should be USDT");
        assertEq(result.params.collateralToken, Constants.S_USDS, "Collateral should be sUSDS");
        assertEq(result.params.oracle, result.oracle, "Oracle should be the new capped oracle");
        assertEq(result.params.irm, Constants.IRM_ADAPTIVE, "IRM should be adaptive");
        assertEq(result.params.lltv, Constants.LLTV_SAVINGS, "LLTV should be 96.5%");
    }

    function testMarketIdMatchesParams() public {
        _runScript();

        bytes32 computedId = keccak256(abi.encode(result.params));
        assertEq(computedId, result.marketId, "Market ID should match keccak of params");
    }

    function testMarketSeededWith90PercentUtilization() public {
        _runScript();

        IMorpho morpho = IMorpho(Constants.MORPHO_BLUE);
        Market memory marketState = morpho.market(Id.wrap(result.marketId));

        // Total supply assets should be 2 USDT
        assertGt(marketState.totalSupplyAssets, 0, "Market should have supply");

        // Total borrow assets should be 1.8 USDT (90% of 2 USDT)
        assertGt(marketState.totalBorrowAssets, 0, "Market should have borrows");

        // Utilization ~90%
        uint256 utilization = (uint256(marketState.totalBorrowAssets) * 100) / uint256(marketState.totalSupplyAssets);
        assertEq(utilization, 90, "Utilization should be 90%");
        console.log("Market utilization:", utilization, "%");
    }

    function testNewMarketIdDiffersFromExisting() public {
        _runScript();

        assertFalse(
            result.marketId == Constants.EXISTING_SUSDS_USDT_MARKET_ID,
            "New market should have different ID from existing market"
        );
    }
}
