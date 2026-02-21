// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VaultV2} from "vault-v2/VaultV2.sol";
import {VaultV2Factory} from "vault-v2/VaultV2Factory.sol";

import {Constants} from "../../src/lib/Constants.sol";
import {IMorphoMarketV1AdapterV2Factory} from "../../src/lib/DeployHelpers.sol";

/**
 * @title 1_CreateVault
 * @notice Step 1/5: Deploy Flagship Vault V2 and its adapter
 *
 * @dev This script creates:
 *   - VaultV2 for USDS
 *   - MorphoMarketV1AdapterV2 connected to the vault
 *
 * After running, set these env vars for subsequent scripts:
 *   VAULT_ADDRESS=<deployed vault address>
 *   ADAPTER_ADDRESS=<deployed adapter address>
 */
contract CreateVault is Script {
    struct DeploymentResult {
        address vaultV2;
        address adapter;
    }

    function run() external returns (DeploymentResult memory result) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        string memory vaultName = "sky.money USDS Flagship";
        string memory vaultSymbol = "skyMoneyUsdsFlagship";

        console.log("=== Step 1/5: Create Vault ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Vault V2
        bytes32 vaultSalt = keccak256(abi.encodePacked(block.timestamp, "FlagshipVaultV2"));
        result.vaultV2 = VaultV2Factory(Constants.VAULT_V2_FACTORY).createVaultV2(deployer, Constants.USDS, vaultSalt);
        console.log("Flagship VaultV2 deployed at:", result.vaultV2);

        VaultV2 vault = VaultV2(result.vaultV2);
        vault.setName(vaultName);
        vault.setSymbol(vaultSymbol);
        console.log("Vault Name:", vaultName);
        console.log("Vault Symbol:", vaultSymbol);

        // Deploy Market Adapter
        result.adapter = IMorphoMarketV1AdapterV2Factory(Constants.ADAPTER_FACTORY)
            .createMorphoMarketV1AdapterV2(result.vaultV2);
        console.log("Adapter deployed at:", result.adapter);

        vm.stopBroadcast();

        // Instructions for next steps
        console.log("");
        console.log("=== NEXT STEPS ===");
        console.log("Set these environment variables before running the next scripts:");
        console.log("");
        console.log("export VAULT_ADDRESS=%s", result.vaultV2);
        console.log("export ADAPTER_ADDRESS=%s", result.adapter);
        console.log("");
        console.log("Then run: forge script script/flagship/2_CreateCbBtcMarket.s.sol ...");
    }
}
