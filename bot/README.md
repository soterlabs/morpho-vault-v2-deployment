# Flagship Vault Allocator Bot

A simple allocator bot for the Flagship USDS Vault V2 that maintains the 80% idle / 20% allocated strategy.

Transactions are executed through a **Safe 1/3 multisig**. The bot is one of the 3 signers and can execute autonomously since the threshold is 1.

## Strategy

The bot allocates vault funds according to this strategy:
- **80% idle** - Kept in the vault for immediate withdrawal liquidity
- **20% allocated** - Split equally across 4 Morpho Blue markets:
  - stUSDS/USDS (5%)
  - cbBTC/USDS (5%)
  - wstETH/USDS (5%)
  - WETH/USDS (5%)

## Prerequisites

- Node.js >= 18.0.0
- A Safe multisig (1/3 threshold) where the bot is one of the owners
- The **Safe address** must be set as an **Allocator** on the vault
- Deployed vault and adapter addresses from the deployment script

## Setup

1. Install dependencies:
   ```bash
   cd bot
   npm install
   ```

2. Configure environment:
   ```bash
   cp .env.example .env
   # Edit .env with your values
   ```

3. Required environment variables:

   **From your setup:**
   - `RPC_URL` - Ethereum RPC endpoint
   - `PRIVATE_KEY` - Bot signer's private key (one of the 3 Safe owners)
   - `SAFE_ADDRESS` - Safe 1/3 multisig address (set as allocator on the vault)

   **From DeployFlagshipVaultV2 output:**
   - `VAULT_ADDRESS` - Flagship Vault V2 address
   - `ADAPTER_ADDRESS` - MorphoMarketV1AdapterV2 address
   - `ORACLE_CBBTC` - cbBTC/USDS oracle address
   - `ORACLE_WSTETH` - wstETH/USDS oracle address
   - `ORACLE_WETH` - WETH/USDS oracle address

   **Pre-configured (existing deployment):**
   - `ORACLE_STUSDS` - Already defaults to `0x0A976226d113B67Bd42D672Ac9f83f92B44b454C`

   **Optional (correct defaults provided):**
   - `LLTV_*` - All default to 86% (860000000000000000) per BA Labs recommendation
   - `DRY_RUN` - Set to `true` for simulation mode

## Usage

### Manual Run

```bash
# Development (uses tsx)
npm run dev

# Production (compile first)
npm run build
npm start
```

### Dry Run Mode

Set `DRY_RUN=true` in `.env` to simulate without executing transactions:
```bash
DRY_RUN=true npm run dev
```

### Cronjob Setup

Run every hour to maintain allocation:
```bash
# Edit crontab
crontab -e

# Add this line (adjust paths as needed)
0 * * * * cd /path/to/morpho-vault-v2-deployment/bot && /usr/bin/npm run allocate >> /var/log/vault-allocator.log 2>&1
```

## How It Works

1. **Verify Safe setup** — Confirms bot is a Safe owner and threshold is 1
2. **Check permissions** — Verifies the Safe is an allocator on the vault
3. **Read current state** — Gets total assets, adapter total, idle balance
4. **Early threshold check** — If total deviation < 0.1%, skip (avoids unnecessary RPC calls)
5. **Read per-market balances** — Calls `adapter.expectedSupplyAssets(marketId)` for each market
6. **Compute per-market actions** — Only allocate/deallocate markets that are off-target
7. **Execute via Safe** — Signs and executes through the Safe multisig with a 50% gas buffer
8. **Log results** — Reports final state

## Allocation Logic

The core allocation logic lives in `src/allocation-logic.ts` and is tested independently in `src/allocation-logic.test.ts`. It handles these cases:

### Case 1: Fresh vault (zero allocations)
All markets at 0%. The bot allocates 5% of totalAssets to each market.
```
Before: [0%, 0%, 0%, 0%]  → Actions: allocate 5% to each
After:  [5%, 5%, 5%, 5%]  (20% total)
```

### Case 2: Partial allocation (some markets funded, some not)
Happens when some transactions succeed and others fail (e.g., gas issues). The bot reads actual per-market balances and **only** allocates to under-funded markets — it does NOT blindly divide the total deficit by 4.
```
Before: [5%, 0%, 5%, 0%]  → Actions: allocate 5% to markets 1 and 3 only
After:  [5%, 5%, 5%, 5%]  (20% total)
```

### Case 3: All markets at target
Total deviation is below the 0.1% threshold. No actions taken.
```
Before: [5%, 5%, 5%, 5%]  → No actions
```

### Case 4: Over-allocated
Can happen after large withdrawals shrink totalAssets. The bot deallocates the excess per market.
```
Before: [7.5%, 7.5%, 7.5%, 7.5%]  → Actions: deallocate 2.5% from each
After:  [5%, 5%, 5%, 5%]           (20% total)
```

### Case 5: Mixed (some over, some under)
Some markets are above target, others below. The bot issues both allocate and deallocate actions in a single run.
```
Before: [8%, 1%, 8%, 1%]  → Actions: deallocate 3% from 0,2; allocate 4% to 1,3
After:  [5%, 5%, 5%, 5%]  (20% total)
```

### Case 6: Interest accrual
Markets accrue interest over time, causing small deviations. As long as the total deviation stays below 0.1%, no rebalancing is triggered.

### Fresh state reads + headroom (1 bps)
The vault's relative cap check uses `mulDivDown(totalAssets, relativeCap, WAD)` to compute the maximum allowed allocation. Interest accrues between the bot's RPC read and tx execution, which can cause the adapter's `expectedSupplyAssets` to overshoot the cap.

The 80% idle portion doesn't earn interest, so `totalAssets` grows slower than any individual market's `expectedSupplyAssets`. This means even with fresh reads, interest accrual over a few blocks can cause `RelativeCapExceeded`.

To prevent this, the bot:
1. Re-reads `vault.totalAssets()` and `adapter.expectedSupplyAssets(marketId)` fresh right before each allocation
2. Subtracts a 1 bps (0.01%) headroom from the cap limit

```
capLimit     = totalAssets * relativeCap / WAD   // replicates vault's mulDivDown
headroom     = capLimit * 1 / 10000              // 1 bps of cap limit
effectiveCap = capLimit - headroom
amount       = effectiveCap - expectedSupplyAssets
```

The headroom covers ~10 minutes of delay at 200% APR max rate. On a $20M vault (5% cap = $1M per market), the headroom is $100 per market — negligible for the strategy. Deallocations don't need this treatment since they have no cap check.

## Testing

```bash
npm test
```

Runs unit tests for the allocation logic covering all cases above, including the real-world "1 USDS dead deposit" scenario.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `targetIdlePercent` | 80% | Target idle percentage |
| `targetPerMarketPercent` | 5% | Target per market |
| `rebalanceThresholdBps` | 0.1% | Min deviation to trigger rebalance |
| `minAllocationAmount` | 100 USDS | Min amount to allocate (avoids dust) |

## Security Notes

- **Never commit `.env`** - Contains private key
- **Safe multisig** - Even though the bot can execute with threshold=1, the 1/3 setup allows 2 other signers to intervene or replace the bot signer if compromised
- **Bot's EOA only pays gas** - The bot's EOA doesn't hold any vault permissions directly; only the Safe does
- **Monitor the bot** - Check logs regularly
- **Test with DRY_RUN first** - Verify logic before live execution

## Extending for Dynamic Weights

To implement price-based dynamic allocation:

1. Add Chainlink price feed reads
2. Calculate weights based on price/volatility
3. Adjust `targetPerMarket` per asset
4. Ensure total still respects 20% cap

Example modification point in `allocator.ts`:
```typescript
// Replace fixed weights with dynamic calculation
const weights = await calculateDynamicWeights(publicClient);
const targetPerMarket = (targetTotalAllocated * weights[market.name]) / 10000n;
```

## Troubleshooting

### "Safe is not an allocator"
The Safe multisig address (not the bot's EOA) must be set as allocator by the curator:
```solidity
vault.submit(abi.encodeWithSelector(IVaultV2.setIsAllocator.selector, safeAddress, true));
vault.setIsAllocator(safeAddress, true);
```

### "Bot signer is not an owner of Safe"
The bot's EOA must be one of the 3 owners on the Safe multisig.

### "Safe threshold is N, expected 1"
The Safe must have a threshold of 1 so the bot can execute autonomously.

### GS013 revert (Safe inner call failure)
The Safe reverts with GS013 when the inner call fails. Common causes:
- **Per-market cap exceeded** — The bot tried to allocate beyond 5% to a market that was already at target. Fixed by reading per-market balances instead of assuming equal distribution.
- **Out of gas** — Gas estimation was too tight due to state changes between estimation and execution. Fixed by adding a 50% gas buffer on `estimateContractGas`.
- **Insufficient idle balance** — Not enough USDS in the vault to allocate.

### "Allocation exceeds cap"
The vault has 5% relative cap per market and 20% total. If you're hitting this:
- Check existing per-market allocations (the bot logs these)
- Reduce allocation amount
- Or increase caps via curator (timelocked)

### Transaction reverts
Common causes:
- Oracle address incorrect
- Market doesn't exist (needs to be created first)
