// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMorpho, MarketParams} from "metamorpho-v1.1-morpho-blue/src/interfaces/IMorpho.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {VaultV2} from "vault-v2/VaultV2.sol";
import {VaultV2Factory} from "vault-v2/VaultV2Factory.sol";
import {IMorphoMarketV1AdapterV2} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";

import {Constants} from "../../src/lib/Constants.sol";
import {DeployHelpers, IMorphoChainlinkOracleV2Factory, IMorphoMarketV1AdapterV2Factory} from "../../src/lib/DeployHelpers.sol";

/**
 * @title DeployUsdtSavings
 * @notice Deploys USDT Savings Vault V2 and connects it to the stUSDS/USDT Morpho Market (96.5% LLTV)
 * @dev Single-market vault with liquidity adapter. Oracle uses stUSDS ERC4626 + USDS/USD and USDT/USD Chainlink feeds.
 *      Higher LLTV (96.5%) compared to Risk Capital vaults (86%).
 */
contract DeployUsdtSavings is DeployHelpers, StdCheats {
    using SafeERC20 for IERC20;
    uint256 constant INITIAL_DEAD_COLLATERAL = 21e17; // 2.1 stUSDS (18 dec)
    uint256 constant DEAD_BORROW_AMOUNT = 18e5; // 1.8 USDT for 90% utilization (6 dec)

    struct DeploymentResult {
        address oracle;
        address vaultV2;
        address adapter;
        bytes32 marketId;
    }

    function run() external returns (DeploymentResult memory result) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address finalOwner = Constants.SKY_MONEY_CURATOR;
        address finalCurator = Constants.SKY_MONEY_CURATOR;
        address finalAllocator = Constants.SKY_MONEY_CURATOR;
        address sentinel = Constants.SKY_MONEY_CURATOR;

        string memory vaultName = "sky.money USDT Savings";
        string memory vaultSymbol = "skyMoneyUsdtSavings";

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Create Oracle (stUSDS/USDT using ERC4626 + Chainlink feeds)
        bytes32 oracleSalt = keccak256(abi.encodePacked(block.timestamp, "OracleUsdtSavings"));
        result.oracle = IMorphoChainlinkOracleV2Factory(Constants.ORACLE_FACTORY).createMorphoChainlinkOracleV2(
            Constants.ST_USDS, 1e18, Constants.CHAINLINK_USDS_USD, address(0), Constants.DECIMALS_STUSDS,
            address(0), 1, Constants.CHAINLINK_USDT_USD, address(0), Constants.DECIMALS_USDT,
            oracleSalt
        );
        console.log("Oracle deployed at:", result.oracle);

        // Step 2: Create Market (96.5% LLTV for savings)
        IMorpho morpho = IMorpho(Constants.MORPHO_BLUE);
        MarketParams memory params = MarketParams({
            loanToken: Constants.USDT,
            collateralToken: Constants.ST_USDS,
            oracle: result.oracle,
            irm: Constants.IRM_ADAPTIVE,
            lltv: Constants.LLTV_SAVINGS
        });

        result.marketId = keccak256(abi.encode(params));
        try morpho.createMarket(params) {
            console.log("Market created successfully");
        } catch {
            console.log("Market already exists, proceeding...");
        }

        // Step 3: Deploy Vault V2
        bytes32 vaultSalt = keccak256(abi.encodePacked(block.timestamp, "VaultV2UsdtSavings"));
        result.vaultV2 = VaultV2Factory(Constants.VAULT_V2_FACTORY).createVaultV2(deployer, Constants.USDT, vaultSalt);
        console.log("VaultV2 deployed at:", result.vaultV2);
        VaultV2 vault = VaultV2(result.vaultV2);

        vault.setName(vaultName);
        vault.setSymbol(vaultSymbol);
        console.log("Vault Name:", vaultName);
        console.log("Vault Symbol:", vaultSymbol);

        // Step 4: Deploy Market Adapter
        result.adapter = IMorphoMarketV1AdapterV2Factory(Constants.ADAPTER_FACTORY)
            .createMorphoMarketV1AdapterV2(result.vaultV2);
        console.log("Adapter deployed at:", result.adapter);

        // Step 5: Configuration
        _configureVault(vault, result.adapter, params, deployer);

        // Step 6: Dead Deposits
        _setupDeadDeposits(vault, morpho, params, deployer);

        // Step 7: Timelocks
        _configureTimelocks(vault);
        _configureAdapterTimelocks(IMorphoMarketV1AdapterV2(result.adapter));

        // Step 8: Finalize Ownership
        _finalizeOwnership(vault, deployer, finalOwner, finalCurator, finalAllocator, sentinel);

        vm.stopBroadcast();
    }

    function _configureVault(VaultV2 vault, address adapter, MarketParams memory params, address deployer) internal {
        vault.setCurator(deployer);
        console.log("Defined Deployer as Curator");

        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.setIsAllocator.selector, deployer, true));

        _abdicateGatesAndRegistry(vault);

        vault.setLiquidityAdapterAndData(adapter, abi.encode(params));

        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.addAdapter.selector, adapter));

        bytes memory adapterIdData = abi.encode("this", adapter);
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, adapterIdData, type(uint128).max));
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, adapterIdData, 1e18));

        bytes memory marketIdData = abi.encode("this/marketParams", adapter, params);
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, marketIdData, type(uint128).max));
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, marketIdData, 1e18));

        bytes memory collateralIdData = abi.encode("collateralToken", Constants.ST_USDS);
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, collateralIdData, type(uint128).max));
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, collateralIdData, 1e18));

        console.log("Caps and Adapter configured.");

        vault.setMaxRate(Constants.MAX_RATE);
        console.log("Max Rate set to 200% APR");
    }

    function _setupDeadDeposits(VaultV2 vault, IMorpho morpho, MarketParams memory params, address deployer) internal {
        // A. Deposit into Vault
        IERC20(Constants.USDT).forceApprove(address(vault), Constants.INITIAL_DEAD_DEPOSIT_6DEC);
        vault.deposit(Constants.INITIAL_DEAD_DEPOSIT_6DEC, address(0xdEaD));
        console.log("Dead deposit to vault executed.");

        // B. Supply directly to Morpho Market
        IERC20(Constants.USDT).forceApprove(Constants.MORPHO_BLUE, Constants.INITIAL_DEAD_DEPOSIT_6DEC);
        morpho.supply(params, Constants.INITIAL_DEAD_DEPOSIT_6DEC, 0, address(0xdEaD), bytes(""));
        console.log("Dead supply to morpho market executed.");

        // C. Supply stUSDS collateral
        IERC20(Constants.ST_USDS).forceApprove(Constants.MORPHO_BLUE, INITIAL_DEAD_COLLATERAL);
        morpho.supplyCollateral(params, INITIAL_DEAD_COLLATERAL, deployer, bytes(""));
        console.log("Dead collateral supply to morpho market executed.");

        // D. Borrow for 90% utilization
        morpho.borrow(params, DEAD_BORROW_AMOUNT, 0, deployer, deployer);
        console.log("Dead borrow executed for 90% utilization.");
    }
}
