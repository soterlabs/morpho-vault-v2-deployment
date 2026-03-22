/**
 * Pure allocation logic for the Flagship Vault Allocator Bot.
 *
 * Extracted from allocator.ts so it can be unit-tested without RPC or Safe dependencies.
 */

const WAD = 1_000_000_000_000_000_000n; // 1e18

/**
 * Headroom subtracted from the cap limit before allocating.
 * Covers interest accrual between the fresh RPC read and tx execution.
 * 1 bps (0.01%) of cap limit — covers ~10 min delay at 200% APR max rate.
 */
export const CAP_HEADROOM_BPS = 1n;

/**
 * Percentage of pool supply reserved as a liquidity cushion when deallocating.
 * Prevents the bot from pushing market utilization too high.
 * 5% means we leave at least 5% of the pool's totalSupply as idle liquidity.
 */
export const LIQUIDITY_RESERVE_PERCENT = 5n;

export interface AllocationAction {
  marketIndex: number;
  action: 'allocate' | 'deallocate';
  amount: bigint;
}

export interface AllocationInput {
  totalAssets: bigint;
  adapterAssets: bigint;
  perMarketAssets: bigint[];
  targetAllocatedPercent: number; // basis points, e.g. 2000 = 20%
  targetPerMarketPercent: number; // basis points, e.g. 500 = 5%
  rebalanceThresholdBps: number; // basis points, e.g. 100 = 1%
}

export interface AllocationResult {
  actions: AllocationAction[];
  skipped: boolean;
  reason?: string;
}

/**
 * Replicate the vault's `mulDivDown(totalAssets, relativeCap, WAD)` exactly.
 * Returns the maximum allocation allowed by a relative cap for a given totalAssets.
 *
 * @param totalAssets - The vault's totalAssets (matches firstTotalAssets in the same block)
 * @param relativeCapWad - The relative cap in WAD (e.g. 5e16 for 5%)
 */
export function computeCapLimit(totalAssets: bigint, relativeCapWad: bigint): bigint {
  return totalAssets * relativeCapWad / WAD;
}

/**
 * Convert a basis-points cap value to WAD for use with computeCapLimit.
 * E.g. 500 bps (5%) → 5e16
 */
export function bpsToWad(bps: number): bigint {
  return BigInt(bps) * WAD / 10000n;
}

/**
 * Compute the allocation/deallocation actions needed to reach target per-market allocations.
 *
 * For allocations, the returned amounts are approximate (based on the initial state read).
 * The caller should re-read fresh state before each allocation and recompute the exact
 * amount using computeCapLimit() to avoid RelativeCapExceeded from interest accrual.
 *
 * Cases handled:
 * 1. Within threshold  — no actions (deviation < rebalanceThresholdBps)
 * 2. Under-allocated   — allocate the deficit per market
 * 3. Over-allocated    — deallocate the excess per market
 * 4. Mixed             — some markets get allocations, others get deallocations
 * 5. Partial (bug fix) — only under-funded markets receive allocations;
 *                         markets already at target are skipped
 */
export function computeAllocationActions(input: AllocationInput): AllocationResult {
  const {
    totalAssets,
    adapterAssets,
    perMarketAssets,
    targetAllocatedPercent,
    targetPerMarketPercent,
    rebalanceThresholdBps,
  } = input;

  if (totalAssets === 0n) {
    return { actions: [], skipped: true, reason: 'totalAssets is zero' };
  }

  const targetTotalAllocated = (totalAssets * BigInt(targetAllocatedPercent)) / 10000n;
  const targetPerMarket = (totalAssets * BigInt(targetPerMarketPercent)) / 10000n;

  // Check if total deviation exceeds threshold
  const allocationDiff = adapterAssets > targetTotalAllocated
    ? adapterAssets - targetTotalAllocated
    : targetTotalAllocated - adapterAssets;

  const deviationBps = Number((allocationDiff * 10000n) / totalAssets);

  if (deviationBps < rebalanceThresholdBps) {
    return { actions: [], skipped: true, reason: 'within threshold' };
  }

  // Compute per-market actions based on actual on-chain balances
  const actions: AllocationAction[] = [];

  for (let i = 0; i < perMarketAssets.length; i++) {
    const current = perMarketAssets[i];

    if (current < targetPerMarket) {
      const diff = targetPerMarket - current;
      if (diff > 0n) {
        actions.push({ marketIndex: i, action: 'allocate', amount: diff });
      }
    } else if (current > targetPerMarket) {
      const excess = current - targetPerMarket;
      if (excess > 0n) {
        actions.push({ marketIndex: i, action: 'deallocate', amount: excess });
      }
    }
  }

  if (actions.length === 0) {
    return { actions: [], skipped: true, reason: 'all markets at target' };
  }

  return { actions, skipped: false };
}

export interface MarketLiquidity {
  marketIndex: number;
  totalSupplyAssets: bigint;
  totalBorrowAssets: bigint;
}

export interface CappedAction {
  marketIndex: number;
  amount: bigint;
  capped: boolean;       // true if amount was reduced due to liquidity
  skipped: boolean;      // true if skipped entirely (no withdrawable liquidity)
  availableLiquidity: bigint;
}

/**
 * Cap deallocate amounts to available market liquidity, reserving a cushion
 * to avoid pushing utilization to 100%.
 *
 * For each market:
 *   reserve = totalSupplyAssets * LIQUIDITY_RESERVE_PERCENT / 100
 *   maxWithdrawable = max(0, liquidity - reserve)
 *   actualAmount = min(desiredAmount, maxWithdrawable)
 */
export function capDeallocationsToLiquidity(
  actions: AllocationAction[],
  marketLiquidity: MarketLiquidity[],
): CappedAction[] {
  // Index liquidity by marketIndex for O(1) lookup
  const liquidityByIndex = new Map<number, MarketLiquidity>();
  for (const ml of marketLiquidity) {
    liquidityByIndex.set(ml.marketIndex, ml);
  }

  return actions.map(a => {
    const ml = liquidityByIndex.get(a.marketIndex);
    if (!ml) {
      // No liquidity data — skip to be safe (shouldn't happen)
      return { marketIndex: a.marketIndex, amount: 0n, capped: false, skipped: true, availableLiquidity: 0n };
    }

    const liquidity = ml.totalSupplyAssets > ml.totalBorrowAssets
      ? ml.totalSupplyAssets - ml.totalBorrowAssets
      : 0n;

    const reserve = ml.totalSupplyAssets * LIQUIDITY_RESERVE_PERCENT / 100n;
    const maxWithdrawable = liquidity > reserve ? liquidity - reserve : 0n;

    if (maxWithdrawable === 0n) {
      return { marketIndex: a.marketIndex, amount: 0n, capped: false, skipped: true, availableLiquidity: liquidity };
    }

    const actualAmount = a.amount < maxWithdrawable ? a.amount : maxWithdrawable;
    return {
      marketIndex: a.marketIndex,
      amount: actualAmount,
      capped: actualAmount < a.amount,
      skipped: false,
      availableLiquidity: liquidity,
    };
  });
}
