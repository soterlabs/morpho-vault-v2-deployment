// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IMorpho, MarketParams} from "metamorpho-v1.1-morpho-blue/src/interfaces/IMorpho.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {VaultV2} from "vault-v2/VaultV2.sol";
import {VaultV2Factory} from "vault-v2/VaultV2Factory.sol";
import {IMorphoMarketV1AdapterV2} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";

import {Constants} from "../../src/lib/Constants.sol";
import {DeployHelpers, IMorphoChainlinkOracleV2Factory, IMorphoMarketV1AdapterV2Factory} from "../../src/lib/DeployHelpers.sol";

/**
 * @title DeployUsdsRiskCapital
 * @notice Deploys USDS Risk Capital Vault V2 and connects it to the stUSDS/USDS Morpho Market
 * @dev This is a single-market vault with liquidity adapter (deposits auto-allocated)
 */
contract DeployUsdsRiskCapital is DeployHelpers, StdCheats {
    // Params specific to this deployment
    uint256 constant INITIAL_DEAD_COLLATERAL = 21e17; // 2.1 stUSDS
    uint256 constant DEAD_BORROW_AMOUNT = 18e17; // 1.8 USDS for 90% utilization

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

        string memory vaultName = "sky.money USDS Risk Capital";
        string memory vaultSymbol = "skyMoneyUsdsRiskCapital";

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Create Oracle (stUSDS/USDS using ERC4626 redemption rate only)
        bytes32 oracleSalt = keccak256(abi.encodePacked(block.timestamp, "Oracle"));
        result.oracle = IMorphoChainlinkOracleV2Factory(Constants.ORACLE_FACTORY).createMorphoChainlinkOracleV2(
            Constants.ST_USDS, 1e18, address(0), address(0), Constants.DECIMALS_STUSDS,
            address(0), 1, address(0), address(0), Constants.DECIMALS_USDS,
            oracleSalt
        );
        console.log("Oracle deployed at:", result.oracle);

        // Step 2: Create Market
        IMorpho morpho = IMorpho(Constants.MORPHO_BLUE);
        MarketParams memory params = MarketParams({
            loanToken: Constants.USDS,
            collateralToken: Constants.ST_USDS,
            oracle: result.oracle,
            irm: Constants.IRM_ADAPTIVE,
            lltv: Constants.LLTV_STUSDS
        });

        result.marketId = keccak256(abi.encode(params));
        try morpho.createMarket(params) {
            console.log("Market created successfully");
        } catch {
            console.log("Market already exists, proceeding...");
        }

        // Step 3: Deploy Vault V2
        bytes32 vaultSalt = keccak256(abi.encodePacked(block.timestamp, "VaultV2"));
        result.vaultV2 = VaultV2Factory(Constants.VAULT_V2_FACTORY).createVaultV2(deployer, Constants.USDS, vaultSalt);
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
        // Setup roles
        vault.setCurator(deployer);
        console.log("Defined Deployer as Curator");

        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.setIsAllocator.selector, deployer, true));

        // Abdicate gates and registry
        _abdicateGatesAndRegistry(vault);

        // Set liquidity adapter (deposits auto-allocated)
        vault.setLiquidityAdapterAndData(adapter, abi.encode(params));

        // Add adapter and caps
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

    /// @dev Dead deposits bootstrap the market to prevent share manipulation attacks and seed initial utilization.
    ///      1. Deposit 1 USDS via the vault (auto-allocated to market via liquidity adapter) → market supply = 1 USDS
    ///      2. Supply 1 USDS directly to the Morpho market → market supply = 2 USDS
    ///      3. Supply 2.1 stUSDS as collateral to the market
    ///      4. Borrow 1.8 USDS from the market → utilization = 1.8 / 2 = 90%
    function _setupDeadDeposits(VaultV2 vault, IMorpho morpho, MarketParams memory params, address deployer) internal {
        // A. Deposit 1 USDS into the vault (sent to 0xdEaD to make shares unrecoverable).
        //    Since the liquidity adapter is set, this deposit is auto-allocated to the Morpho market.
        IERC20(Constants.USDS).approve(address(vault), Constants.INITIAL_DEAD_DEPOSIT);
        vault.deposit(Constants.INITIAL_DEAD_DEPOSIT, address(0xdEaD));
        console.log("Dead deposit to vault executed.");

        // B. Supply 1 USDS directly to the Morpho market (also to 0xdEaD).
        //    Combined with step A, total market supply = 2 USDS.
        IERC20(Constants.USDS).approve(Constants.MORPHO_BLUE, Constants.INITIAL_DEAD_DEPOSIT);
        morpho.supply(params, Constants.INITIAL_DEAD_DEPOSIT, 0, address(0xdEaD), bytes(""));
        console.log("Dead supply to morpho market executed.");

        // C. Supply 2.1 stUSDS as collateral to enable borrowing.
        IERC20(Constants.ST_USDS).approve(Constants.MORPHO_BLUE, INITIAL_DEAD_COLLATERAL);
        morpho.supplyCollateral(params, INITIAL_DEAD_COLLATERAL, deployer, bytes(""));
        console.log("Dead collateral supply to morpho market executed.");

        // D. Borrow 1.8 USDS to reach 90% utilization (1.8 / 2 = 90%).
        morpho.borrow(params, DEAD_BORROW_AMOUNT, 0, deployer, deployer);
        console.log("Dead borrow executed for 90% utilization.");
    }
}
