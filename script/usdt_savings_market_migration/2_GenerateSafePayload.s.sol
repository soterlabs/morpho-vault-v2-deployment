// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MarketParams} from "metamorpho-v1.1-morpho-blue/src/interfaces/IMorpho.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";

import {Constants} from "../../src/lib/Constants.sol";

/**
 * @title 2_GenerateSafePayload
 * @notice Phase 2: Generate Safe Transaction Builder JSON payloads for vault migration
 *
 * @dev Generates 4 JSON files for the Safe{Wallet} Transaction Builder:
 *   - round1_submit.json: Submit timelocked cap increases (Day 0)
 *   - round2_execute_caps.json: Execute caps + change liquidity adapter (Day 3+)
 *   - round2_reallocate.json: Deallocate old + allocate new (Day 3+, amounts TBD at execution)
 *   - round3_cleanup.json: Zero out old market caps (anytime after migration)
 *
 * Prerequisites:
 *   - VAULT_ADDRESS: The deployed USDT Savings vault
 *   - ADAPTER_ADDRESS: The vault's adapter
 *   - NEW_ORACLE: The new Morpho oracle (from script 1)
 */
contract GenerateSafePayload is Script {
    function run() external {
        address vault = vm.envAddress("VAULT_ADDRESS");
        address adapter = vm.envAddress("ADAPTER_ADDRESS");
        address newOracle = vm.envAddress("NEW_ORACLE");

        console.log("=== Phase 2: Generate Safe TX Builder Payloads ===");
        console.log("Vault:", vault);
        console.log("Adapter:", adapter);
        console.log("New Oracle:", newOracle);

        // Old market params (existing sUSDS/USDT market with uncapped oracle)
        MarketParams memory oldParams = MarketParams({
            loanToken: Constants.USDT,
            collateralToken: Constants.S_USDS,
            oracle: Constants.EXISTING_SUSDS_USDT_ORACLE,
            irm: Constants.IRM_ADAPTIVE,
            lltv: Constants.LLTV_SAVINGS
        });

        // New market params (sUSDS/USDT market with capped oracle)
        MarketParams memory newParams = MarketParams({
            loanToken: Constants.USDT,
            collateralToken: Constants.S_USDS,
            oracle: newOracle,
            irm: Constants.IRM_ADAPTIVE,
            lltv: Constants.LLTV_SAVINGS
        });

        // Cap IDs
        bytes memory newMarketIdData = abi.encode("this/marketParams", adapter, newParams);
        bytes memory oldMarketIdData = abi.encode("this/marketParams", adapter, oldParams);

        _generateRound1(vault, newMarketIdData);
        _generateRound2ExecuteCaps(vault, adapter, newParams, newMarketIdData);
        _generateRound2Reallocate(vault, adapter, oldParams, newParams);
        _generateRound3(vault, oldMarketIdData);
    }

    // ============ ROUND 1: Submit timelocked cap increases ============

    function _generateRound1(address vault, bytes memory newMarketIdData) internal {
        bytes memory submitAbsCap = abi.encodeWithSignature(
            "submit(bytes)",
            abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, newMarketIdData, type(uint128).max)
        );

        bytes memory submitRelCap = abi.encodeWithSignature(
            "submit(bytes)",
            abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, newMarketIdData, uint256(1e18))
        );

        string memory json = _buildSafeBatch(
            "USDT Savings Migration - Round 1: Submit Cap Increases",
            vault,
            _buildTxArrayN(vault, submitAbsCap, submitRelCap)
        );

        vm.writeFile("out/migration/round1_submit.json", json);
        console.log("Generated: out/migration/round1_submit.json");
    }

    // ============ ROUND 2a: Execute caps + change liquidity adapter ============

    function _generateRound2ExecuteCaps(
        address vault,
        address adapter,
        MarketParams memory newParams,
        bytes memory newMarketIdData
    ) internal {
        bytes memory execAbsCap =
            abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, newMarketIdData, type(uint128).max);

        bytes memory execRelCap =
            abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, newMarketIdData, uint256(1e18));

        bytes memory changeLiqAdapter =
            abi.encodeWithSelector(IVaultV2.setLiquidityAdapterAndData.selector, adapter, abi.encode(newParams));

        string memory json = _buildSafeBatch(
            "USDT Savings Migration - Round 2a: Execute Caps and Switch Liquidity Adapter",
            vault,
            _buildTxArrayN(vault, execAbsCap, execRelCap, changeLiqAdapter)
        );

        vm.writeFile("out/migration/round2_execute_caps.json", json);
        console.log("Generated: out/migration/round2_execute_caps.json");
    }

    // ============ ROUND 2b: Reallocate (amounts determined at execution time) ============

    function _generateRound2Reallocate(
        address vault,
        address adapter,
        MarketParams memory oldParams,
        MarketParams memory newParams
    ) internal {
        // NOTE: Amount is set to 0 as a placeholder. The Safe operators must query the vault's
        // current allocation and replace 0 with the actual withdrawable amount before executing.
        // Use: vault.allocation(keccak256(abi.encode("this/marketParams", adapter, oldParams)))
        uint256 placeholderAmount = 0;

        bytes memory deallocateOld =
            abi.encodeWithSelector(IVaultV2.deallocate.selector, adapter, abi.encode(oldParams), placeholderAmount);

        bytes memory allocateNew =
            abi.encodeWithSelector(IVaultV2.allocate.selector, adapter, abi.encode(newParams), placeholderAmount);

        string memory json = _buildSafeBatch(
            "USDT Savings Migration - Round 2b: Reallocate (SET AMOUNTS BEFORE EXECUTING)",
            vault,
            _buildTxArrayN(vault, deallocateOld, allocateNew)
        );

        vm.writeFile("out/migration/round2_reallocate.json", json);
        console.log("Generated: out/migration/round2_reallocate.json");
    }

    // ============ ROUND 3: Cleanup old market caps ============

    function _generateRound3(address vault, bytes memory oldMarketIdData) internal {
        bytes memory decAbsCap =
            abi.encodeWithSelector(IVaultV2.decreaseAbsoluteCap.selector, oldMarketIdData, uint256(0));

        bytes memory decRelCap =
            abi.encodeWithSelector(IVaultV2.decreaseRelativeCap.selector, oldMarketIdData, uint256(0));

        string memory json = _buildSafeBatch(
            "USDT Savings Migration - Round 3: Cleanup Old Market Caps", vault, _buildTxArrayN(vault, decAbsCap, decRelCap)
        );

        vm.writeFile("out/migration/round3_cleanup.json", json);
        console.log("Generated: out/migration/round3_cleanup.json");
    }

    // ============ JSON Helpers ============

    function _buildSafeBatch(string memory name, address, /* to */ string memory txArrayJson)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "{\n",
            '  "version": "1.0",\n',
            '  "chainId": "1",\n',
            '  "meta": {\n',
            '    "name": "',
            name,
            '"\n',
            "  },\n",
            '  "transactions": ',
            txArrayJson,
            "\n}\n"
        );
    }

    function _buildTx(address to, bytes memory data) internal pure returns (string memory) {
        return string.concat(
            '    { "to": "', _toHex(to), '", "value": "0", "data": "', _toHex(data), '" }'
        );
    }

    function _buildTxArrayN(address to, bytes memory d1, bytes memory d2)
        internal
        pure
        returns (string memory)
    {
        return string.concat("[\n", _buildTx(to, d1), ",\n", _buildTx(to, d2), "\n  ]");
    }

    function _buildTxArrayN(address to, bytes memory d1, bytes memory d2, bytes memory d3)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "[\n", _buildTx(to, d1), ",\n", _buildTx(to, d2), ",\n", _buildTx(to, d3), "\n  ]"
        );
    }

    function _toHex(address a) internal pure returns (string memory) {
        return _toHex(abi.encodePacked(a));
    }

    function _toHex(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
