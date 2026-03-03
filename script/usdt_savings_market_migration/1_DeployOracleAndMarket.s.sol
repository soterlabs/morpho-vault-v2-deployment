// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, MarketParams} from "metamorpho-v1.1-morpho-blue/src/interfaces/IMorpho.sol";

import {CappedOracleFeed} from "capped-oracle-feed/CappedOracleFeed.sol";
import {Constants} from "../../src/lib/Constants.sol";
import {IMorphoChainlinkOracleV2Factory} from "../../src/lib/DeployHelpers.sol";

/**
 * @title 1_DeployOracleAndMarket
 * @notice Phase 1: Deploy capped oracle, Morpho oracle, create and seed the new sUSDS/USDT market
 *
 * @dev This script is permissionless (any EOA can execute). It:
 *   1. Deploys CappedOracleFeed wrapping USDT/USD Chainlink feed (capped at $1.00)
 *   2. Deploys MorphoChainlinkOracleV2 using sUSDS redemption + USDS/USD + CappedUSDT/USD
 *   3. Creates sUSDS/USDT market on Morpho Blue (96.5% LLTV)
 *   4. Seeds market with 90% utilization (2 USDT supply, 1.8 USDT borrow)
 *
 * Prerequisites:
 *   - Deployer needs: 2 USDT, 2.1 sUSDS
 *
 * After running, set these env vars for script 2:
 *   CAPPED_USDT_FEED=<deployed capped feed address>
 *   NEW_ORACLE=<deployed oracle address>
 *   NEW_MARKET_ID=<new market ID>
 */
contract DeployOracleAndMarket is Script {
    using SafeERC20 for IERC20;

    // Capped price: $1.00 in Chainlink 8-decimal format
    int256 constant CAPPED_USDT_PRICE = 1e8;

    // Market seeding parameters
    uint256 constant DEAD_SUPPLY_AMOUNT = 2e6; // 2 USDT (6 decimals)
    uint256 constant DEAD_COLLATERAL_SUSDS = 21e17; // 2.1 sUSDS (18 decimals)
    uint256 constant DEAD_BORROW_AMOUNT = 18e5; // 1.8 USDT for 90% utilization (6 decimals)

    struct DeploymentResult {
        address cappedUsdtFeed;
        address oracle;
        bytes32 marketId;
        MarketParams params;
    }

    function run() external returns (DeploymentResult memory result) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Phase 1: Deploy Oracle and Market ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy CappedOracleFeed (USDT/USD capped at $1.00)
        result.cappedUsdtFeed = address(new CappedOracleFeed(Constants.CHAINLINK_USDT_USD, CAPPED_USDT_PRICE));
        console.log("CappedOracleFeed deployed at:", result.cappedUsdtFeed);

        // 2. Deploy MorphoChainlinkOracleV2
        // price = sUSDS_redemption * USDS/USD / CappedUSDT/USD
        // baseVault: sUSDS (ERC4626 redemption rate)
        // baseFeed1: USDS/USD
        // quoteFeed1: CappedUSDT/USD
        result.oracle = _createOracle(result.cappedUsdtFeed);

        // 3. Create Market
        result.params = _createMarket(result.oracle);
        result.marketId = keccak256(abi.encode(result.params));
        console.log("Market ID:", vm.toString(result.marketId));

        // 4. Seed Market
        _seedMarket(result.params, deployer);

        vm.stopBroadcast();

        // Instructions for next steps
        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("Set these environment variables:");
        console.log("");
        console.log("export CAPPED_USDT_FEED=%s", result.cappedUsdtFeed);
        console.log("export NEW_ORACLE=%s", result.oracle);
        console.log("export NEW_MARKET_ID=%s", vm.toString(result.marketId));
        console.log("");
        console.log("Then run: forge script script/usdt_savings_market_migration/2_GenerateSafePayload.s.sol ...");
    }

    function _createOracle(address cappedUsdtFeed) internal returns (address oracle) {
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, "OracleSUsdsUsdtCapped"));

        // Oracle: sUSDS/USDT = sUSDS_redemption * USDS/USD / CappedUSDT/USD
        // Price scale: 10^(36 + loanDecimals - collateralDecimals) = 10^(36 + 6 - 18) = 10^24
        oracle = IMorphoChainlinkOracleV2Factory(Constants.ORACLE_FACTORY).createMorphoChainlinkOracleV2(
            Constants.S_USDS, // baseVault: sUSDS ERC4626 (redemption rate)
            1e18, // baseVaultConversionSample
            Constants.CHAINLINK_USDS_USD, // baseFeed1: USDS/USD
            address(0), // baseFeed2: unused
            Constants.DECIMALS_SUSDS, // baseTokenDecimals: 18
            address(0), // quoteVault: none
            1, // quoteVaultConversionSample
            cappedUsdtFeed, // quoteFeed1: CappedUSDT/USD
            address(0), // quoteFeed2: unused
            Constants.DECIMALS_USDT, // quoteTokenDecimals: 6
            salt
        );
        console.log("Oracle sUSDS/USDT (capped) deployed at:", oracle);
    }

    function _createMarket(address oracle) internal returns (MarketParams memory params) {
        params = MarketParams({
            loanToken: Constants.USDT,
            collateralToken: Constants.S_USDS,
            oracle: oracle,
            irm: Constants.IRM_ADAPTIVE,
            lltv: Constants.LLTV_SAVINGS
        });

        IMorpho morpho = IMorpho(Constants.MORPHO_BLUE);
        try morpho.createMarket(params) {
            console.log("Market created for sUSDS/USDT (capped oracle)");
        } catch {
            console.log("Market already exists for sUSDS/USDT (capped oracle)");
        }
    }

    function _seedMarket(MarketParams memory params, address deployer) internal {
        IMorpho morpho = IMorpho(Constants.MORPHO_BLUE);

        // 1. Supply 2 USDT to market (to dead address)
        IERC20(Constants.USDT).forceApprove(Constants.MORPHO_BLUE, DEAD_SUPPLY_AMOUNT);
        morpho.supply(params, DEAD_SUPPLY_AMOUNT, 0, address(0xdEaD), bytes(""));
        console.log("Dead supply: 2 USDT");

        // 2. Supply 2.1 sUSDS as collateral
        IERC20(Constants.S_USDS).approve(Constants.MORPHO_BLUE, DEAD_COLLATERAL_SUSDS);
        morpho.supplyCollateral(params, DEAD_COLLATERAL_SUSDS, deployer, bytes(""));
        console.log("Dead collateral: 2.1 sUSDS");

        // 3. Borrow 1.8 USDT for 90% utilization (1.8 / 2 = 90%)
        morpho.borrow(params, DEAD_BORROW_AMOUNT, 0, deployer, deployer);
        console.log("Dead borrow: 1.8 USDT (90% utilization)");
    }
}
