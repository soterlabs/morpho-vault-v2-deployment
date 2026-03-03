// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, MarketParams, Id, Market} from "metamorpho-v1.1-morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "metamorpho-v1.1-morpho-blue/src/interfaces/IOracle.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {VaultV2} from "vault-v2/VaultV2.sol";
import {VaultV2Factory} from "vault-v2/VaultV2Factory.sol";
import {IMorphoMarketV1AdapterV2} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";

import {Constants} from "../../src/lib/Constants.sol";
import {DeployHelpers, IMorphoMarketV1AdapterV2Factory} from "../../src/lib/DeployHelpers.sol";
import {DeployOracleAndMarket} from "../../script/usdt_savings_market_migration/1_DeployOracleAndMarket.s.sol";
import {GenerateSafePayload} from "../../script/usdt_savings_market_migration/2_GenerateSafePayload.s.sol";
import {DeployUsdtSavings} from "../../script/usdt_savings/DeployUsdtSavings.s.sol";

/**
 * @title MigrationIntegrationTest
 * @notice Full end-to-end migration simulation driven by Safe TX Builder JSON payloads.
 *
 * @dev The test:
 *   1. Deploys the USDT Savings vault (initial state)
 *   2. Runs Phase 1 script (deploy capped oracle + market)
 *   3. Runs Phase 2 script to generate Safe TX Builder JSON files
 *   4. Reads each JSON file, parses transactions, and executes them as raw calls
 *      impersonating the curator/allocator Safe wallet
 *   5. Verifies vault state after each round
 *
 * This proves the generated JSON payloads contain correct calldata that the Safe
 * wallet can execute to perform the migration.
 */
contract MigrationIntegrationTest is Test {
    using SafeERC20 for IERC20;

    IVaultV2 public vault;
    address public adapter;
    address public curator;

    // Phase 1 results
    DeployOracleAndMarket.DeploymentResult public migrationResult;

    // Market params
    MarketParams public oldParams;
    MarketParams public newParams;

    address public deployer;

    function setUp() public {
        vm.setEnv("PRIVATE_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
        deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        // Step 1: Deploy the initial USDT Savings vault
        deal(Constants.USDT, deployer, 100e6);
        deal(Constants.S_USDS, deployer, 10e18);

        DeployUsdtSavings deployScript = new DeployUsdtSavings();
        DeployUsdtSavings.DeploymentResult memory vaultResult = deployScript.run();
        vault = IVaultV2(vaultResult.vaultV2);
        adapter = vaultResult.adapter;
        curator = vault.curator();

        oldParams = MarketParams({
            loanToken: Constants.USDT,
            collateralToken: Constants.S_USDS,
            oracle: Constants.EXISTING_SUSDS_USDT_ORACLE,
            irm: Constants.IRM_ADAPTIVE,
            lltv: Constants.LLTV_SAVINGS
        });

        // Step 2: Run Phase 1 (permissionless: deploy oracle + market)
        deal(Constants.USDT, deployer, 10e6);
        deal(Constants.S_USDS, deployer, 3e18);

        DeployOracleAndMarket phase1Script = new DeployOracleAndMarket();
        migrationResult = phase1Script.run();
        newParams = migrationResult.params;

        // Step 3: Generate Safe TX Builder JSON files
        vm.setEnv("VAULT_ADDRESS", vm.toString(address(vault)));
        vm.setEnv("ADAPTER_ADDRESS", vm.toString(adapter));
        vm.setEnv("NEW_ORACLE", vm.toString(migrationResult.oracle));

        vm.createDir("out/migration", true);
        GenerateSafePayload phase2Script = new GenerateSafePayload();
        phase2Script.run();

        // Warp to old market's lastUpdate + 1 to avoid stale fork IRM overflow.
        // Without this, the adaptive IRM overflows computing exp(speed * elapsed) for large elapsed.
        Id oldMarketId = Id.wrap(Constants.EXISTING_SUSDS_USDT_MARKET_ID);
        Market memory marketState = IMorpho(Constants.MORPHO_BLUE).market(oldMarketId);
        vm.warp(marketState.lastUpdate + 1);
    }

    // ============ FULL MIGRATION FLOW ============

    function testFullMigrationFlow() public {
        // User deposits into the vault (goes to old market via liquidity adapter)
        address user = makeAddr("user");
        uint256 depositAmount = 100e6; // 100 USDT
        deal(Constants.USDT, user, depositAmount);

        vm.startPrank(user);
        IERC20(Constants.USDT).forceApprove(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertGt(shares, 0, "User should receive shares");
        console.log("User deposited 100 USDT, received shares:", shares);

        // === ROUND 1: Execute round1_submit.json ===
        _executeJsonAsRole("out/migration/round1_submit.json", 2, curator);
        console.log("Round 1: Executed submit txs from JSON");

        // === TIMELOCK: Wait 3 days ===
        vm.warp(block.timestamp + Constants.TIMELOCK_LOW + 1);
        console.log("Warped 3 days for timelock");

        // === ROUND 2a: Execute round2_execute_caps.json ===
        _executeJsonAsRole("out/migration/round2_execute_caps.json", 3, curator);
        console.log("Round 2a: Executed caps + liquidity adapter change from JSON");

        // Verify liquidity adapter now points to new market
        MarketParams memory currentParams = abi.decode(vault.liquidityData(), (MarketParams));
        assertEq(currentParams.oracle, migrationResult.oracle, "Liquidity adapter should use new oracle");

        // Verify new market caps are set
        bytes memory newMarketIdData = abi.encode("this/marketParams", adapter, newParams);
        bytes32 newMarketCapId = keccak256(newMarketIdData);
        assertEq(vault.absoluteCap(newMarketCapId), type(uint128).max, "New market absolute cap should be max");
        assertEq(vault.relativeCap(newMarketCapId), 1e18, "New market relative cap should be 100%");

        // === ROUND 2b: Execute round2_reallocate.json (with patched amounts) ===
        // The JSON has placeholder amount=0. We patch with actual amounts before executing.
        _executeReallocateJsonWithPatchedAmounts("out/migration/round2_reallocate.json");
        console.log("Round 2b: Executed reallocation from JSON (amounts patched)");

        // Verify old market is near-empty
        bytes32 oldMarketCapId = keccak256(abi.encode("this/marketParams", adapter, oldParams));
        uint256 oldAllocation = vault.allocation(oldMarketCapId);
        assertLt(oldAllocation, 1e5, "Old market should have near-zero allocation (dust only)");

        // Verify user can still withdraw
        uint256 userSharesBefore = vault.balanceOf(user);
        vm.startPrank(user);
        uint256 assetsReceived = vault.redeem(userSharesBefore, user, user);
        vm.stopPrank();

        assertGt(assetsReceived, 0, "User should receive assets on withdraw");
        assertEq(vault.balanceOf(user), 0, "User should have no shares left");
        console.log("User withdrew:", assetsReceived, "USDT");

        // Verify new deposits go to new market
        deal(Constants.USDT, user, depositAmount);
        vm.startPrank(user);
        IERC20(Constants.USDT).forceApprove(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertGt(vault.balanceOf(user), 0, "New deposit should work after migration");
        console.log("New deposit successful after migration");
    }

    // ============ ROUND 3: CLEANUP ============

    function testCleanupOldMarketCaps() public {
        // Run full migration first
        testFullMigrationFlow();

        // Execute round3_cleanup.json
        _executeJsonAsRole("out/migration/round3_cleanup.json", 2, curator);
        console.log("Round 3: Executed cleanup from JSON");

        bytes32 oldCapId = keccak256(abi.encode("this/marketParams", adapter, oldParams));
        assertEq(vault.absoluteCap(oldCapId), 0, "Old market absolute cap should be zero");
        assertEq(vault.relativeCap(oldCapId), 0, "Old market relative cap should be zero");
        console.log("Old market caps cleaned up");
    }

    // ============ EDGE CASES ============

    function testMigrationWithNoUserDeposits() public {
        // Execute JSON rounds without user deposits (vault has only dead deposit as idle USDT).
        // The dead deposit is made before the liquidity adapter is set, so the old market has
        // zero allocation. Reallocation is skipped — only caps + liquidity adapter change needed.
        _executeJsonAsRole("out/migration/round1_submit.json", 2, curator);
        vm.warp(block.timestamp + Constants.TIMELOCK_LOW + 1);
        _executeJsonAsRole("out/migration/round2_execute_caps.json", 3, curator);

        // Verify old market has zero allocation (nothing to reallocate)
        bytes32 oldMarketCapId = keccak256(abi.encode("this/marketParams", adapter, oldParams));
        assertEq(vault.allocation(oldMarketCapId), 0, "Old market should have zero allocation");

        // Verify vault still works — new deposits go to new market via liquidity adapter
        address user = makeAddr("user");
        deal(Constants.USDT, user, 100e6);
        vm.startPrank(user);
        IERC20(Constants.USDT).forceApprove(address(vault), 100e6);
        uint256 shares = vault.deposit(100e6, user);
        vm.stopPrank();

        assertGt(shares, 0, "Deposit should work after migration");
    }

    // ============ JSON EXECUTION HELPERS ============

    /**
     * @notice Read a Safe TX Builder JSON file and execute all transactions as `role`
     * @dev Parses each transaction by index, extracting `to` (address) and `data` (bytes),
     *      then executes via vm.prank. This proves the JSON calldata is correct end-to-end.
     * @param path Path to the JSON file
     * @param txCount Known number of transactions in the file
     * @param role Address to impersonate when executing
     */
    function _executeJsonAsRole(string memory path, uint256 txCount, address role) internal {
        string memory json = vm.readFile(path);

        for (uint256 i = 0; i < txCount; i++) {
            string memory prefix = string.concat("$.transactions[", vm.toString(i), "]");
            address to = vm.parseJsonAddress(json, string.concat(prefix, ".to"));
            bytes memory data = vm.parseJsonBytes(json, string.concat(prefix, ".data"));

            vm.prank(role);
            (bool success, bytes memory returnData) = to.call(data);
            require(success, string.concat("JSON tx ", vm.toString(i), " failed: ", _getRevertMsg(returnData)));
        }
    }

    /**
     * @notice Execute round2_reallocate.json but patch the placeholder amounts (0) with actual values
     * @dev The JSON contains the correct selectors, adapter address, and market params encoding.
     *      Only the uint256 amount at the end of each call needs patching.
     *      - tx[0]: deallocate — amount = vault's current allocation in old market
     *      - tx[1]: allocate — amount = vault's idle USDT balance after deallocate
     */
    function _executeReallocateJsonWithPatchedAmounts(string memory path) internal {
        string memory json = vm.readFile(path);

        // Parse both transactions by index
        address deallocateTo = vm.parseJsonAddress(json, "$.transactions[0].to");
        bytes memory deallocateData = vm.parseJsonBytes(json, "$.transactions[0].data");
        address allocateTo = vm.parseJsonAddress(json, "$.transactions[1].to");
        bytes memory allocateData = vm.parseJsonBytes(json, "$.transactions[1].data");

        // Verify targets match vault
        assertEq(deallocateTo, address(vault), "Deallocate target should be vault");
        assertEq(allocateTo, address(vault), "Allocate target should be vault");

        // Verify selectors match
        assertEq(bytes4(deallocateData), IVaultV2.deallocate.selector, "Deallocate selector mismatch");
        assertEq(bytes4(allocateData), IVaultV2.allocate.selector, "Allocate selector mismatch");

        // Determine actual amounts
        bytes32 oldMarketCapId = keccak256(abi.encode("this/marketParams", adapter, oldParams));
        uint256 deallocateAmount = vault.allocation(oldMarketCapId);

        // Patch deallocate: replace the uint256 amount parameter (3rd word after selector)
        // ABI layout for deallocate(address, bytes, uint256): [4:36] adapter, [36:68] offset, [68:100] amount
        _patchWordAt(deallocateData, 68, deallocateAmount);

        vm.prank(curator);
        (bool ok1,) = address(vault).call(deallocateData);
        require(ok1, "Patched deallocate failed");
        console.log("Deallocated from old market:", deallocateAmount);

        // Determine allocate amount (idle balance after deallocate)
        uint256 allocateAmount = IERC20(Constants.USDT).balanceOf(address(vault));

        // Patch allocate: same layout as deallocate
        _patchWordAt(allocateData, 68, allocateAmount);

        vm.prank(curator);
        (bool ok2,) = address(vault).call(allocateData);
        require(ok2, "Patched allocate failed");
        console.log("Allocated to new market:", allocateAmount);
    }

    /**
     * @notice Replace a 32-byte word at a specific byte offset in calldata
     * @param data The calldata bytes to patch
     * @param byteOffset Byte offset from start of data (e.g., 68 for 3rd word after 4-byte selector)
     * @param newValue The uint256 value to write
     */
    function _patchWordAt(bytes memory data, uint256 byteOffset, uint256 newValue) internal pure {
        require(data.length >= byteOffset + 32, "Data too short to patch at offset");
        assembly {
            mstore(add(add(data, 0x20), byteOffset), newValue)
        }
    }

    function _getRevertMsg(bytes memory returnData) internal pure returns (string memory) {
        if (returnData.length < 4) return "no revert data";
        // Try to decode Error(string)
        if (bytes4(returnData) == bytes4(keccak256("Error(string)"))) {
            (, string memory reason) = abi.decode(returnData, (bytes4, string));
            return reason;
        }
        return "unknown revert";
    }
}
