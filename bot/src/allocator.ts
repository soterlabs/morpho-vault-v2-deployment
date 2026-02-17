/**
 * Flagship Vault V2 Allocator Bot
 *
 * This bot maintains the 80% idle / 20% allocated strategy for the Flagship USDS Vault.
 * It allocates 5% to each of 4 markets: stUSDS, cbBTC, wstETH, WETH (all with USDS as loan token).
 *
 * Transactions are executed through a Safe 1/3 multisig. The bot is one of the 3 signers
 * and can execute autonomously since the threshold is 1.
 *
 * Run as a cronjob (e.g., every hour):
 *   0 * * * * cd /path/to/bot && npm run allocate >> /var/log/allocator.log 2>&1
 *
 * Environment Variables (see .env.example):
 *   - RPC_URL: Ethereum RPC endpoint
 *   - PRIVATE_KEY: Bot signer's private key (one of the Safe owners)
 *   - SAFE_ADDRESS: Safe 1/3 multisig address (set as allocator on the vault)
 *   - VAULT_ADDRESS: Flagship Vault V2 address
 *   - ADAPTER_ADDRESS: MorphoMarketV1AdapterV2 address
 */

import { createPublicClient, createWalletClient, http, formatEther, parseEther, encodeFunctionData, encodeAbiParameters, keccak256, hexToBytes, bytesToHex, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { mainnet } from 'viem/chains';
import 'dotenv/config';
import { computeAllocationActions, computeCapLimit, bpsToWad, CAP_HEADROOM_BPS } from './allocation-logic.js';

// ============ CONFIGURATION ============

const config = {
  rpcUrl: process.env.RPC_URL || 'https://eth.llamarpc.com',
  privateKey: process.env.PRIVATE_KEY as Hex,
  safeAddress: process.env.SAFE_ADDRESS as Address,
  vaultAddress: process.env.VAULT_ADDRESS as Address,
  adapterAddress: process.env.ADAPTER_ADDRESS as Address,

  // Target allocation percentages (in basis points, 10000 = 100%)
  targetIdlePercent: 8000, // 80%
  targetAllocatedPercent: 2000, // 20%
  targetPerMarketPercent: 500, // 5% each

  // Rebalance threshold - only rebalance if deviation exceeds this (in basis points)
  rebalanceThresholdBps: 100, // 1%

  // Minimum allocation amount (to avoid dust transactions)
  minAllocationAmount: parseEther('100'), // 100 USDS minimum

  // Dry run mode (set to true to simulate without executing)
  dryRun: process.env.DRY_RUN === 'true',
};

// Market configurations - loaded from environment
interface MarketConfig {
  name: string;
  collateral: Address;
  oracle: Address;
  lltv: bigint;
  encodedParams?: Hex;
}

// All markets use 86% LLTV per BA Labs recommendation (02/02/2026)
const LLTV_86_PERCENT = '860000000000000000';

// Existing stUSDS oracle from USDS vault deployment
const EXISTING_STUSDS_ORACLE = '0x0A976226d113B67Bd42D672Ac9f83f92B44b454C';

const markets: MarketConfig[] = [
  {
    name: 'stUSDS/USDS',
    collateral: '0x99CD4Ec3f88A45940936F469E4bB72A2A701EEB9' as Address,
    oracle: (process.env.ORACLE_STUSDS || EXISTING_STUSDS_ORACLE) as Address,
    lltv: BigInt(process.env.LLTV_STUSDS || LLTV_86_PERCENT),
  },
  {
    name: 'cbBTC/USDS',
    collateral: '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf' as Address,
    oracle: (process.env.ORACLE_CBBTC || '0x0') as Address,
    lltv: BigInt(process.env.LLTV_CBBTC || LLTV_86_PERCENT),
  },
  {
    name: 'wstETH/USDS',
    collateral: '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0' as Address,
    oracle: (process.env.ORACLE_WSTETH || '0x0') as Address,
    lltv: BigInt(process.env.LLTV_WSTETH || LLTV_86_PERCENT),
  },
  {
    name: 'WETH/USDS',
    collateral: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2' as Address,
    oracle: (process.env.ORACLE_WETH || '0x0') as Address,
    lltv: BigInt(process.env.LLTV_WETH || LLTV_86_PERCENT),
  },
];

// Constants
const USDS = '0xdC035D45d973E3EC169d2276DDab16f1e407384F' as Address;
const IRM_ADAPTIVE = '0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC' as Address;

// ============ ABIs ============

const vaultAbi = [
  {
    name: 'totalAssets',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'isAllocator',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ type: 'bool' }],
  },
  {
    name: 'allocate',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'adapter', type: 'address' },
      { name: 'data', type: 'bytes' },
      { name: 'assets', type: 'uint256' },
    ],
    outputs: [],
  },
  {
    name: 'deallocate',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'adapter', type: 'address' },
      { name: 'data', type: 'bytes' },
      { name: 'assets', type: 'uint256' },
    ],
    outputs: [],
  },
] as const;

const adapterAbi = [
  {
    name: 'realAssets',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'marketIdsLength',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'marketIds',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'index', type: 'uint256' }],
    outputs: [{ type: 'bytes32' }],
  },
  {
    name: 'expectedSupplyAssets',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'marketId', type: 'bytes32' }],
    outputs: [{ type: 'uint256' }],
  },
] as const;

const erc20Abi = [
  {
    name: 'balanceOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
] as const;

const safeAbi = [
  {
    name: 'nonce',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'getThreshold',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'isOwner',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }],
    outputs: [{ type: 'bool' }],
  },
  {
    name: 'getTransactionHash',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'value', type: 'uint256' },
      { name: 'data', type: 'bytes' },
      { name: 'operation', type: 'uint8' },
      { name: 'safeTxGas', type: 'uint256' },
      { name: 'baseGas', type: 'uint256' },
      { name: 'gasPrice', type: 'uint256' },
      { name: 'gasToken', type: 'address' },
      { name: 'refundReceiver', type: 'address' },
      { name: '_nonce', type: 'uint256' },
    ],
    outputs: [{ type: 'bytes32' }],
  },
  {
    name: 'execTransaction',
    type: 'function',
    stateMutability: 'payable',
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'value', type: 'uint256' },
      { name: 'data', type: 'bytes' },
      { name: 'operation', type: 'uint8' },
      { name: 'safeTxGas', type: 'uint256' },
      { name: 'baseGas', type: 'uint256' },
      { name: 'gasPrice', type: 'uint256' },
      { name: 'gasToken', type: 'address' },
      { name: 'refundReceiver', type: 'address' },
      { name: 'signatures', type: 'bytes' },
    ],
    outputs: [{ type: 'bool' }],
  },
] as const;

// ============ HELPERS ============

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as Address;

function encodeMarketParams(market: MarketConfig): Hex {
  // MarketParams struct: (loanToken, collateralToken, oracle, irm, lltv)
  // This matches the Solidity struct encoding
  const encoded = encodeFunctionData({
    abi: [{
      name: 'encode',
      type: 'function',
      inputs: [{
        name: 'params',
        type: 'tuple',
        components: [
          { name: 'loanToken', type: 'address' },
          { name: 'collateralToken', type: 'address' },
          { name: 'oracle', type: 'address' },
          { name: 'irm', type: 'address' },
          { name: 'lltv', type: 'uint256' },
        ],
      }],
      outputs: [],
    }],
    functionName: 'encode',
    args: [{
      loanToken: USDS,
      collateralToken: market.collateral,
      oracle: market.oracle,
      irm: IRM_ADAPTIVE,
      lltv: market.lltv,
    }],
  });

  // Remove the function selector (first 4 bytes / 10 hex chars including 0x)
  return `0x${encoded.slice(10)}` as Hex;
}

function computeMarketId(market: MarketConfig): Hex {
  const encoded = encodeAbiParameters(
    [
      { name: 'loanToken', type: 'address' },
      { name: 'collateralToken', type: 'address' },
      { name: 'oracle', type: 'address' },
      { name: 'irm', type: 'address' },
      { name: 'lltv', type: 'uint256' },
    ],
    [USDS, market.collateral, market.oracle, IRM_ADAPTIVE, market.lltv],
  );
  return keccak256(encoded);
}

function log(message: string, data?: unknown) {
  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] ${message}`);
  if (data !== undefined) {
    console.log(JSON.stringify(data, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2));
  }
}

/**
 * Execute a transaction through the Safe multisig.
 * Signs the Safe transaction hash using eth_sign and calls execTransaction.
 * Works for threshold=1 Safes where the bot is one of the owners.
 */
async function executeSafeTransaction(
  publicClient: ReturnType<typeof createPublicClient>,
  walletClient: ReturnType<typeof createWalletClient>,
  account: ReturnType<typeof privateKeyToAccount>,
  safeAddress: Address,
  to: Address,
  data: Hex,
): Promise<Hex> {
  // Get current Safe nonce
  const nonce = await publicClient.readContract({
    address: safeAddress,
    abi: safeAbi,
    functionName: 'nonce',
  });

  // Get the Safe transaction hash to sign
  const safeTxHash = await publicClient.readContract({
    address: safeAddress,
    abi: safeAbi,
    functionName: 'getTransactionHash',
    args: [to, 0n, data, 0, 0n, 0n, 0n, ZERO_ADDRESS, ZERO_ADDRESS, nonce],
  });

  // Sign using eth_sign (signMessage adds "\x19Ethereum Signed Message:\n32" prefix)
  const signature = await account.signMessage({ message: { raw: safeTxHash } });

  // Adjust v value: +4 to indicate eth_sign signature type to Safe contract
  // Safe uses v > 30 to identify eth_sign signatures
  const sigBytes = hexToBytes(signature);
  sigBytes[64] += 4;
  const adjustedSig = bytesToHex(sigBytes);

  // Estimate gas with a buffer to account for state changes between estimation and execution.
  // The stUSDS market is highly active (~14M TVL), so adapter.realAssets() gas cost varies
  // depending on market state at execution time vs estimation time.
  const estimatedGas = await publicClient.estimateContractGas({
    account,
    address: safeAddress,
    abi: safeAbi,
    functionName: 'execTransaction',
    args: [to, 0n, data, 0, 0n, 0n, 0n, ZERO_ADDRESS, ZERO_ADDRESS, adjustedSig],
  });
  const gasWithBuffer = estimatedGas * 150n / 100n; // 50% buffer

  // Execute through Safe (bot's EOA pays gas, Safe executes the inner call)
  const hash = await walletClient.writeContract({
    account,
    chain: mainnet,
    address: safeAddress,
    abi: safeAbi,
    functionName: 'execTransaction',
    args: [to, 0n, data, 0, 0n, 0n, 0n, ZERO_ADDRESS, ZERO_ADDRESS, adjustedSig],
    gas: gasWithBuffer,
  });

  return hash;
}

// ============ MAIN ALLOCATOR LOGIC ============

async function main() {
  log('=== Flagship Vault Allocator Bot ===');
  log(`Mode: ${config.dryRun ? 'DRY RUN' : 'LIVE'}`);

  // Validate configuration
  if (!config.privateKey) {
    throw new Error('PRIVATE_KEY environment variable is required');
  }
  if (!config.safeAddress) {
    throw new Error('SAFE_ADDRESS environment variable is required');
  }
  if (!config.vaultAddress) {
    throw new Error('VAULT_ADDRESS environment variable is required');
  }
  if (!config.adapterAddress) {
    throw new Error('ADAPTER_ADDRESS environment variable is required');
  }

  // Create clients
  const account = privateKeyToAccount(config.privateKey);
  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(config.rpcUrl),
  });
  const walletClient = createWalletClient({
    account,
    chain: mainnet,
    transport: http(config.rpcUrl),
  });

  log(`Bot signer address: ${account.address}`);
  log(`Safe multisig address: ${config.safeAddress}`);
  log(`Vault address: ${config.vaultAddress}`);
  log(`Adapter address: ${config.adapterAddress}`);

  // Verify bot is an owner of the Safe
  const isOwner = await publicClient.readContract({
    address: config.safeAddress,
    abi: safeAbi,
    functionName: 'isOwner',
    args: [account.address],
  });
  if (!isOwner) {
    throw new Error(`Bot signer ${account.address} is not an owner of Safe ${config.safeAddress}`);
  }

  // Verify Safe threshold is 1 (so bot can execute autonomously)
  const threshold = await publicClient.readContract({
    address: config.safeAddress,
    abi: safeAbi,
    functionName: 'getThreshold',
  });
  if (threshold !== 1n) {
    throw new Error(`Safe threshold is ${threshold}, expected 1. Bot cannot execute autonomously.`);
  }
  log('Safe ownership and threshold verified (1/3 multisig)');

  // Check if the Safe is an allocator on the vault
  const isAllocator = await publicClient.readContract({
    address: config.vaultAddress,
    abi: vaultAbi,
    functionName: 'isAllocator',
    args: [config.safeAddress],
  });

  if (!isAllocator) {
    throw new Error(`Safe ${config.safeAddress} is not an allocator for this vault`);
  }
  log('Allocator permission verified (Safe is allocator)');

  // Get current state
  const [totalAssets, adapterAssets, vaultIdleBalance] = await Promise.all([
    publicClient.readContract({
      address: config.vaultAddress,
      abi: vaultAbi,
      functionName: 'totalAssets',
    }),
    publicClient.readContract({
      address: config.adapterAddress,
      abi: adapterAbi,
      functionName: 'realAssets',
    }),
    publicClient.readContract({
      address: USDS,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [config.vaultAddress],
    }),
  ]);

  log('Current vault state:', {
    totalAssets: formatEther(totalAssets),
    adapterAssets: formatEther(adapterAssets),
    vaultIdleBalance: formatEther(vaultIdleBalance),
    currentAllocationPercent: totalAssets > 0n
      ? Number((adapterAssets * 10000n) / totalAssets) / 100
      : 0,
  });

  // Calculate target allocations
  const targetTotalAllocated = (totalAssets * BigInt(config.targetAllocatedPercent)) / 10000n;
  const targetPerMarket = (totalAssets * BigInt(config.targetPerMarketPercent)) / 10000n;

  log('Target allocations:', {
    targetTotalAllocated: formatEther(targetTotalAllocated),
    targetPerMarket: formatEther(targetPerMarket),
    targetIdlePercent: config.targetIdlePercent / 100,
  });

  // Check if rebalancing is needed
  const allocationDiff = adapterAssets > targetTotalAllocated
    ? adapterAssets - targetTotalAllocated
    : targetTotalAllocated - adapterAssets;

  const deviationBps = totalAssets > 0n
    ? Number((allocationDiff * 10000n) / totalAssets)
    : 0;

  log(`Current deviation: ${deviationBps / 100}% (threshold: ${config.rebalanceThresholdBps / 100}%)`);

  if (deviationBps < config.rebalanceThresholdBps) {
    log('Allocation within threshold, no rebalancing needed');
    return;
  }

  // Read per-market allocations from the adapter
  const configuredMarkets = markets.filter(m => m.oracle !== '0x0');
  for (const market of configuredMarkets) {
    market.encodedParams = encodeMarketParams(market);
  }

  const marketIds = configuredMarkets.map(m => computeMarketId(m));
  const perMarketAssets = await Promise.all(
    marketIds.map(id =>
      publicClient.readContract({
        address: config.adapterAddress,
        abi: adapterAbi,
        functionName: 'expectedSupplyAssets',
        args: [id],
      }),
    ),
  );

  log('Per-market allocations:');
  for (let i = 0; i < configuredMarkets.length; i++) {
    log(`  ${configuredMarkets[i].name}: ${formatEther(perMarketAssets[i])} USDS`);
  }

  // Compute per-market allocation/deallocation actions
  const result = computeAllocationActions({
    totalAssets,
    adapterAssets,
    perMarketAssets,
    targetAllocatedPercent: config.targetAllocatedPercent,
    targetPerMarketPercent: config.targetPerMarketPercent,
    rebalanceThresholdBps: config.rebalanceThresholdBps,
  });

  if (result.skipped) {
    log(`No actions needed (${result.reason})`);
    return;
  }

  // Map computed actions back to market configs
  const actions = result.actions.map(a => ({
    market: configuredMarkets[a.marketIndex],
    action: a.action,
    amount: a.amount,
  }));

  log(`Executing ${actions.length} allocation actions:`);

  const relativeCapWad = bpsToWad(config.targetPerMarketPercent);

  for (const { market, action, amount } of actions) {
    if (config.dryRun) {
      log(`  ${action} ${formatEther(amount)} USDS to ${market.name} [DRY RUN]`);
      continue;
    }

    try {
      const functionName = action === 'allocate' ? 'allocate' : 'deallocate';
      let execAmount = amount;

      if (action === 'allocate') {
        // Re-read fresh state right before execution to avoid RelativeCapExceeded.
        // The vault checks: caps[id].allocation <= totalAssets * relativeCap / WAD
        // Interest accrues between our initial read and execution, so the pre-computed
        // amount may overshoot the cap. Instead, we replicate the vault's exact math
        // using fresh on-chain values: amount = capLimit - currentExpectedSupplyAssets.
        const marketId = computeMarketId(market);
        const [freshTotalAssets, freshExpectedSupplyAssets] = await Promise.all([
          publicClient.readContract({
            address: config.vaultAddress,
            abi: vaultAbi,
            functionName: 'totalAssets',
          }),
          publicClient.readContract({
            address: config.adapterAddress,
            abi: adapterAbi,
            functionName: 'expectedSupplyAssets',
            args: [marketId],
          }),
        ]);

        const capLimit = computeCapLimit(freshTotalAssets, relativeCapWad);
        const headroom = capLimit * CAP_HEADROOM_BPS / 10000n;
        const effectiveCap = capLimit - headroom;
        execAmount = effectiveCap > freshExpectedSupplyAssets
          ? effectiveCap - freshExpectedSupplyAssets
          : 0n;

        if (execAmount === 0n) {
          log(`  ${market.name}: already at cap (${formatEther(freshExpectedSupplyAssets)} >= ${formatEther(effectiveCap)}), skipping`);
          continue;
        }

        log(`  allocate ${formatEther(execAmount)} USDS to ${market.name} (cap: ${formatEther(capLimit)}, headroom: ${formatEther(headroom)}, current: ${formatEther(freshExpectedSupplyAssets)})`);
      } else {
        log(`  deallocate ${formatEther(execAmount)} USDS from ${market.name}`);
      }

      // Encode the vault call data
      const callData = encodeFunctionData({
        abi: vaultAbi,
        functionName,
        args: [config.adapterAddress, market.encodedParams!, execAmount],
      });

      // Execute through Safe multisig
      const hash = await executeSafeTransaction(
        publicClient,
        walletClient,
        account,
        config.safeAddress,
        config.vaultAddress,
        callData,
      );

      log(`  Transaction submitted via Safe: ${hash}`);

      // Wait for confirmation
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      log(`  Confirmed in block ${receipt.blockNumber}, status: ${receipt.status}`);
    } catch (error) {
      log(`  ERROR: ${error instanceof Error ? error.message : String(error)}`);
      // Continue with other actions even if one fails
    }
  }

  // Log final state
  const [finalAdapterAssets, finalIdleBalance] = await Promise.all([
    publicClient.readContract({
      address: config.adapterAddress,
      abi: adapterAbi,
      functionName: 'realAssets',
    }),
    publicClient.readContract({
      address: USDS,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [config.vaultAddress],
    }),
  ]);

  log('Final vault state:', {
    adapterAssets: formatEther(finalAdapterAssets),
    vaultIdleBalance: formatEther(finalIdleBalance),
    allocationPercent: totalAssets > 0n
      ? Number((finalAdapterAssets * 10000n) / totalAssets) / 100
      : 0,
  });

  log('=== Allocation complete ===');
}

// Run
main().catch((error) => {
  log('FATAL ERROR:', error instanceof Error ? error.message : String(error));
  process.exit(1);
});
