// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MarketParams} from "metamorpho-v1.1-morpho-blue/src/interfaces/IMorpho.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {VaultV2} from "vault-v2/VaultV2.sol";
import {IMorphoMarketV1AdapterV2} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";

import {Constants} from "../../src/lib/Constants.sol";
import {DeployHelpers} from "../../src/lib/DeployHelpers.sol";

/**
 * @title 5_ConfigureVault
 * @notice Step 5/5: Configure vault with all markets, caps, timelocks, and transfer ownership
 *
 * @dev This script:
 *   1. Sets up roles (curator, allocator)
 *   2. Abdicates gates and registry
 *   3. Adds adapter and configures caps (20% adapter, 5% per market)
 *   4. Makes dead deposit to vault
 *   5. Configures timelocks (3d low, 7d high)
 *   6. Transfers ownership to final addresses
 *
 * Required environment variables:
 *   VAULT_ADDRESS - From script 1
 *   ADAPTER_ADDRESS - From script 1
 *   ORACLE_CBBTC - From script 2
 *   ORACLE_WSTETH - From script 3
 *   ORACLE_WETH - From script 4
 */
contract ConfigureVault is DeployHelpers {
    // Allocation caps
    uint256 constant ADAPTER_RELATIVE_CAP = 20e16; // 20%
    uint256 constant MARKET_RELATIVE_CAP = 5e16; // 5%

    // Existing stUSDS/USDS market
    address constant EXISTING_STUSDS_ORACLE = 0x0A976226d113B67Bd42D672Ac9f83f92B44b454C;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Required: addresses from previous scripts
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        address adapterAddress = vm.envAddress("ADAPTER_ADDRESS");
        address oracleCbBtc = vm.envAddress("ORACLE_CBBTC");
        address oracleWstEth = vm.envAddress("ORACLE_WSTETH");
        address oracleWeth = vm.envAddress("ORACLE_WETH");

        // Final role addresses
        address finalOwner = Constants.SKY_MONEY_CURATOR;
        address finalCurator = Constants.SKY_MONEY_CURATOR;
        address finalAllocator = Constants.ALLOCATOR_FLAGSHIP;
        address sentinel = Constants.SKY_MONEY_CURATOR;

        console.log("=== Step 5/5: Configure Vault ===");
        console.log("Vault:", vaultAddress);
        console.log("Adapter:", adapterAddress);

        VaultV2 vault = VaultV2(vaultAddress);

        // Build market params
        MarketParams memory paramsStUsds = MarketParams({
            loanToken: Constants.USDS,
            collateralToken: Constants.ST_USDS,
            oracle: EXISTING_STUSDS_ORACLE,
            irm: Constants.IRM_ADAPTIVE,
            lltv: Constants.LLTV_STUSDS
        });

        MarketParams memory paramsCbBtc = MarketParams({
            loanToken: Constants.USDS,
            collateralToken: Constants.CBBTC,
            oracle: oracleCbBtc,
            irm: Constants.IRM_ADAPTIVE,
            lltv: Constants.LLTV_VOLATILE
        });

        MarketParams memory paramsWstEth = MarketParams({
            loanToken: Constants.USDS,
            collateralToken: Constants.WSTETH,
            oracle: oracleWstEth,
            irm: Constants.IRM_ADAPTIVE,
            lltv: Constants.LLTV_VOLATILE
        });

        MarketParams memory paramsWeth = MarketParams({
            loanToken: Constants.USDS,
            collateralToken: Constants.WETH,
            oracle: oracleWeth,
            irm: Constants.IRM_ADAPTIVE,
            lltv: Constants.LLTV_VOLATILE
        });

        vm.startBroadcast(deployerPrivateKey);

        // 1. Setup roles
        vault.setCurator(deployer);
        console.log("Defined Deployer as Curator");

        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.setIsAllocator.selector, deployer, true));

        // 2. Abdicate gates and registry
        _abdicateGatesAndRegistry(vault);

        // 3. Add adapter
        console.log("No liquidity adapter set - deposits stay idle for 80% idle strategy.");
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.addAdapter.selector, adapterAddress));

        // 4. Set adapter caps (20% max total)
        bytes memory adapterIdData = abi.encode("this", adapterAddress);
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, adapterIdData, type(uint128).max));
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, adapterIdData, ADAPTER_RELATIVE_CAP));

        // 5. Set market caps (5% max each)
        _setMarketCaps(vault, adapterAddress, paramsStUsds, Constants.ST_USDS);
        _setMarketCaps(vault, adapterAddress, paramsCbBtc, Constants.CBBTC);
        _setMarketCaps(vault, adapterAddress, paramsWstEth, Constants.WSTETH);
        _setMarketCaps(vault, adapterAddress, paramsWeth, Constants.WETH);
        console.log("Caps configured: 5% max per market, 20% max to adapter.");

        // 6. Set max rate
        vault.setMaxRate(Constants.MAX_RATE);
        console.log("Max Rate set to 200% APR");

        // 7. Dead deposit to vault
        IERC20(Constants.USDS).approve(address(vault), Constants.INITIAL_DEAD_DEPOSIT);
        vault.deposit(Constants.INITIAL_DEAD_DEPOSIT, address(0xdEaD));
        console.log("Dead deposit to vault executed.");

        // 8. Configure timelocks
        _configureTimelocks(vault);
        _configureAdapterTimelocks(IMorphoMarketV1AdapterV2(adapterAddress));

        // 9. Finalize ownership
        _finalizeOwnership(vault, deployer, finalOwner, finalCurator, finalAllocator, sentinel);

        vm.stopBroadcast();

        // Log market IDs for allocator bot
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Market IDs for allocator bot:");
        console.log("  stUSDS/USDS:", vm.toString(keccak256(abi.encode(paramsStUsds))));
        console.log("  cbBTC/USDS:", vm.toString(keccak256(abi.encode(paramsCbBtc))));
        console.log("  wstETH/USDS:", vm.toString(keccak256(abi.encode(paramsWstEth))));
        console.log("  WETH/USDS:", vm.toString(keccak256(abi.encode(paramsWeth))));
        console.log("");
        console.log("Allocator bot env vars:");
        console.log("  VAULT_ADDRESS=%s", vaultAddress);
        console.log("  ADAPTER_ADDRESS=%s", adapterAddress);
        console.log("  ORACLE_STUSDS=%s", EXISTING_STUSDS_ORACLE);
        console.log("  ORACLE_CBBTC=%s", oracleCbBtc);
        console.log("  ORACLE_WSTETH=%s", oracleWstEth);
        console.log("  ORACLE_WETH=%s", oracleWeth);
    }

    function _setMarketCaps(VaultV2 vault, address adapter, MarketParams memory params, address collateral) internal {
        bytes memory marketIdData = abi.encode("this/marketParams", adapter, params);
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, marketIdData, type(uint128).max));
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, marketIdData, MARKET_RELATIVE_CAP));

        bytes memory collateralIdData = abi.encode("collateralToken", collateral);
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, collateralIdData, type(uint128).max));
        _submitAndExecute(address(vault), abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, collateralIdData, MARKET_RELATIVE_CAP));
    }
}
