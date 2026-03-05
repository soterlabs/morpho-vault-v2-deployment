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
 * @dev Generates 5 JSON files for the Safe{Wallet} Transaction Builder:
 *   - round1_submit_caps.json: Submit timelocked cap increases (Day 0, run once)
 *   - round2_execute_caps.json: Execute cap increases (Day 3+, run once)
 *   - round3_switch_adapter.json: Switch liquidity adapter to new market (run once)
 *   - round4_reallocate.json: Deallocate old + allocate new (run MULTIPLE TIMES as liquidity frees up)
 *   - round5_cleanup.json: Zero out old market caps (run once, after full migration)
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

        _generateRound1SubmitCaps(vault, newMarketIdData);
        _generateRound2ExecuteCaps(vault, newMarketIdData);
        _generateRound3SwitchAdapter(vault, adapter, newParams);
        _generateRound4Reallocate(vault, adapter, oldParams, newParams);
        _generateRound5Cleanup(vault, oldMarketIdData);
    }

    // ============ ROUND 1: Submit timelocked cap increases (run once, Day 0) ============

    function _generateRound1SubmitCaps(address vault, bytes memory newMarketIdData) internal {
        bytes memory submitAbsCap = abi.encodeWithSignature(
            "submit(bytes)",
            abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, newMarketIdData, type(uint128).max)
        );

        bytes memory submitRelCap = abi.encodeWithSignature(
            "submit(bytes)",
            abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, newMarketIdData, uint256(1e18))
        );

        string memory json = _buildSafeBatch(
            "USDT Savings Migration - Round 1: Submit Cap Increases (3-day timelock)",
            vault,
            _buildTxArrayN(vault, submitAbsCap, submitRelCap)
        );

        vm.writeFile("out/migration/round1_submit_caps.json", json);
        console.log("Generated: out/migration/round1_submit_caps.json");
    }

    // ============ ROUND 2: Execute cap increases (run once, Day 3+) ============

    function _generateRound2ExecuteCaps(address vault, bytes memory newMarketIdData) internal {
        bytes memory execAbsCap =
            abi.encodeWithSelector(IVaultV2.increaseAbsoluteCap.selector, newMarketIdData, type(uint128).max);

        bytes memory execRelCap =
            abi.encodeWithSelector(IVaultV2.increaseRelativeCap.selector, newMarketIdData, uint256(1e18));

        string memory json = _buildSafeBatch(
            "USDT Savings Migration - Round 2: Execute Cap Increases",
            vault,
            _buildTxArrayN(vault, execAbsCap, execRelCap)
        );

        vm.writeFile("out/migration/round2_execute_caps.json", json);
        console.log("Generated: out/migration/round2_execute_caps.json");
    }

    // ============ ROUND 3: Switch liquidity adapter to new market (run once) ============

    function _generateRound3SwitchAdapter(address vault, address adapter, MarketParams memory newParams) internal {
        bytes memory changeLiqAdapter =
            abi.encodeWithSelector(IVaultV2.setLiquidityAdapterAndData.selector, adapter, abi.encode(newParams));

        string memory json = _buildSafeBatch(
            "USDT Savings Migration - Round 3: Switch Liquidity Adapter to New Market",
            vault,
            _buildTxArray1(vault, changeLiqAdapter)
        );

        vm.writeFile("out/migration/round3_switch_adapter.json", json);
        console.log("Generated: out/migration/round3_switch_adapter.json");
    }

    // ============ ROUND 4: Reallocate (run MULTIPLE TIMES as liquidity frees up) ============

    function _generateRound4Reallocate(
        address vault,
        address adapter,
        MarketParams memory oldParams,
        MarketParams memory newParams
    ) internal {
        // NOTE: Amounts are set to 0 as placeholders. Before EACH execution, the Safe operators must:
        //   1. Query available liquidity in old market: min(vault.allocation(oldCapId), morpho.idle(marketId))
        //   2. Patch the deallocate amount with the withdrawable amount
        //   3. Execute deallocate, then query vault.idleAsset() for the allocate amount
        //
        // This file may need to be executed MULTIPLE TIMES if the old market doesn't have enough
        // idle liquidity to withdraw everything at once. As borrowers repay (driven by rising rates
        // from reduced supply), more liquidity frees up for subsequent rounds.
        uint256 placeholderAmount = 0;

        bytes memory deallocateOld =
            abi.encodeWithSelector(IVaultV2.deallocate.selector, adapter, abi.encode(oldParams), placeholderAmount);

        bytes memory allocateNew =
            abi.encodeWithSelector(IVaultV2.allocate.selector, adapter, abi.encode(newParams), placeholderAmount);

        string memory json = _buildSafeBatch(
            "USDT Savings Migration - Round 4: Reallocate (PATCH AMOUNTS - MAY RUN MULTIPLE TIMES)",
            vault,
            _buildTxArrayN(vault, deallocateOld, allocateNew)
        );

        vm.writeFile("out/migration/round4_reallocate.json", json);
        console.log("Generated: out/migration/round4_reallocate.json");
    }

    // ============ ROUND 5: Cleanup old market caps (run once, after full migration) ============

    function _generateRound5Cleanup(address vault, bytes memory oldMarketIdData) internal {
        bytes memory decAbsCap =
            abi.encodeWithSelector(IVaultV2.decreaseAbsoluteCap.selector, oldMarketIdData, uint256(0));

        bytes memory decRelCap =
            abi.encodeWithSelector(IVaultV2.decreaseRelativeCap.selector, oldMarketIdData, uint256(0));

        string memory json = _buildSafeBatch(
            "USDT Savings Migration - Round 5: Cleanup Old Market Caps",
            vault,
            _buildTxArrayN(vault, decAbsCap, decRelCap)
        );

        vm.writeFile("out/migration/round5_cleanup.json", json);
        console.log("Generated: out/migration/round5_cleanup.json");
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

    function _buildTxArray1(address to, bytes memory d1) internal pure returns (string memory) {
        return string.concat("[\n", _buildTx(to, d1), "\n  ]");
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
