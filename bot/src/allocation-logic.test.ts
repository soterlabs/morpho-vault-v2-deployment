import { describe, it, expect } from 'vitest';
import { computeAllocationActions, computeCapLimit, bpsToWad, CAP_HEADROOM_BPS, capDeallocationsToLiquidity, LIQUIDITY_RESERVE_PERCENT, type AllocationInput, type AllocationAction, type MarketLiquidity } from './allocation-logic.js';
import { parseEther } from 'viem';

// Helper: build an AllocationInput with sensible defaults (4 markets, 80/20 split, 5% each)
function input(overrides: Partial<AllocationInput> & Pick<AllocationInput, 'totalAssets' | 'adapterAssets' | 'perMarketAssets'>): AllocationInput {
  return {
    targetAllocatedPercent: 2000,  // 20%
    targetPerMarketPercent: 500,   // 5%
    rebalanceThresholdBps: 100,    // 1%
    ...overrides,
  };
}

const eth = parseEther;

describe('computeCapLimit', () => {
  it('replicates vault mulDivDown(totalAssets, relativeCap, WAD)', () => {
    // 5% of 1000 USDS = 50 USDS
    expect(computeCapLimit(eth('1000'), bpsToWad(500))).toBe(eth('50'));
  });

  it('handles 100% cap', () => {
    expect(computeCapLimit(eth('1000'), bpsToWad(10000))).toBe(eth('1000'));
  });

  it('truncates fractional wei (integer division)', () => {
    // 5% of 1 wei = 0.05 wei → truncates to 0
    expect(computeCapLimit(1n, bpsToWad(500))).toBe(0n);
  });

  it('handles large totalAssets without overflow', () => {
    // 5% of 100M USDS
    expect(computeCapLimit(eth('100000000'), bpsToWad(500))).toBe(eth('5000000'));
  });

  it('handles zero totalAssets', () => {
    expect(computeCapLimit(0n, bpsToWad(500))).toBe(0n);
  });
});

describe('bpsToWad', () => {
  it('converts 500 bps (5%) to 5e16', () => {
    expect(bpsToWad(500)).toBe(50000000000000000n);
  });

  it('converts 10000 bps (100%) to 1e18', () => {
    expect(bpsToWad(10000)).toBe(1000000000000000000n);
  });

  it('converts 1 bps (0.01%) to 1e14', () => {
    expect(bpsToWad(1)).toBe(100000000000000n);
  });

  it('converts 0 bps to 0', () => {
    expect(bpsToWad(0)).toBe(0n);
  });
});

describe('CAP_HEADROOM_BPS', () => {
  it('is 1 bps', () => {
    expect(CAP_HEADROOM_BPS).toBe(1n);
  });

  it('applied to cap limit gives correct effective cap', () => {
    // Simulates what allocator.ts does:
    // effectiveCap = capLimit - capLimit * CAP_HEADROOM_BPS / 10000
    const capLimit = computeCapLimit(eth('20000000'), bpsToWad(500)); // 5% of $20M = $1M
    const headroom = capLimit * CAP_HEADROOM_BPS / 10000n;
    const effectiveCap = capLimit - headroom;

    expect(capLimit).toBe(eth('1000000'));
    expect(headroom).toBe(eth('100')); // $100 headroom on $1M cap
    expect(effectiveCap).toBe(eth('999900'));
  });

  it('headroom covers interest accrual at max rate over 10 minutes', () => {
    // Max rate = 200% APR, 10 min delay, $1M position
    // interest = $1M * 2.0 * 600 / 31_557_600 ≈ $38
    // gap = 0.8 * $38 ≈ $30 (80% because totalAssets grows slower than per-market interest)
    // headroom = $100 >> $30
    const capLimit = computeCapLimit(eth('20000000'), bpsToWad(500));
    const headroom = capLimit * CAP_HEADROOM_BPS / 10000n;
    const interestGap = eth('1000000') * 2n * 600n * 8n / (31_557_600n * 10n);

    expect(headroom).toBeGreaterThan(interestGap);
  });
});

describe('computeAllocationActions', () => {
  // ============================================================
  // Case 1: Fresh vault — no allocations yet
  // All 4 markets at 0, need to go from 0% → 5% each
  // ============================================================
  describe('fresh vault (zero allocations)', () => {
    it('allocates equally to all 4 markets', () => {
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: 0n,
        perMarketAssets: [0n, 0n, 0n, 0n],
      }));

      expect(result.skipped).toBe(false);
      expect(result.actions).toHaveLength(4);

      for (const action of result.actions) {
        expect(action.action).toBe('allocate');
        expect(action.amount).toBe(eth('50')); // 5% of 1000
      }
    });

    it('produces correct market indices', () => {
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: 0n,
        perMarketAssets: [0n, 0n, 0n, 0n],
      }));

      expect(result.actions.map(a => a.marketIndex)).toEqual([0, 1, 2, 3]);
    });
  });

  // ============================================================
  // Case 2: Partial allocation — some markets funded, some not
  // This was the actual bug: first run succeeded for 2 markets,
  // second run tried to add more to already-full markets
  // ============================================================
  describe('partial allocation (some markets at target, some at zero)', () => {
    it('only allocates to under-funded markets', () => {
      // stUSDS and wstETH at 5% already, cbBTC and WETH at 0%
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: eth('100'),  // 10% total
        perMarketAssets: [eth('50'), 0n, eth('50'), 0n],
      }));

      expect(result.skipped).toBe(false);
      expect(result.actions).toHaveLength(2);

      // Only markets 1 (cbBTC) and 3 (WETH) should get allocations
      expect(result.actions[0]).toEqual({ marketIndex: 1, action: 'allocate', amount: eth('50') });
      expect(result.actions[1]).toEqual({ marketIndex: 3, action: 'allocate', amount: eth('50') });
    });

    it('allocates correct deficit when markets are partially funded', () => {
      // cbBTC and WETH at 2.5% (half target), rest at target
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: eth('150'),  // 15%
        perMarketAssets: [eth('50'), eth('25'), eth('50'), eth('25')],
      }));

      expect(result.skipped).toBe(false);
      expect(result.actions).toHaveLength(2);
      expect(result.actions[0]).toEqual({ marketIndex: 1, action: 'allocate', amount: eth('25') });
      expect(result.actions[1]).toEqual({ marketIndex: 3, action: 'allocate', amount: eth('25') });
    });
  });

  // ============================================================
  // Case 3: All markets at target — no rebalancing needed
  // ============================================================
  describe('all markets at target', () => {
    it('skips when perfectly balanced', () => {
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: eth('200'),  // 20%
        perMarketAssets: [eth('50'), eth('50'), eth('50'), eth('50')],
      }));

      expect(result.skipped).toBe(true);
      expect(result.reason).toBe('within threshold');
      expect(result.actions).toHaveLength(0);
    });
  });

  // ============================================================
  // Case 4: Within threshold — small deviation, no action
  // ============================================================
  describe('within threshold', () => {
    it('skips when deviation is below 1%', () => {
      // 19.5% allocated (0.5% deviation < 1% threshold)
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: eth('195'),
        perMarketAssets: [eth('50'), eth('50'), eth('50'), eth('45')],
      }));

      expect(result.skipped).toBe(true);
      expect(result.reason).toBe('within threshold');
    });

    it('acts when deviation equals threshold', () => {
      // 19% allocated (1% deviation = threshold, triggers rebalance)
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: eth('190'),
        perMarketAssets: [eth('50'), eth('50'), eth('50'), eth('40')],
      }));

      // Deviation is exactly at threshold (not strictly less), so rebalance triggers
      expect(result.skipped).toBe(false);
      expect(result.actions).toHaveLength(1);
      expect(result.actions[0]).toEqual({ marketIndex: 3, action: 'allocate', amount: eth('10') });
    });

    it('acts when deviation exceeds threshold', () => {
      // 18% allocated (2% deviation > 1% threshold)
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: eth('180'),
        perMarketAssets: [eth('50'), eth('50'), eth('50'), eth('30')],
      }));

      expect(result.skipped).toBe(false);
      expect(result.actions).toHaveLength(1);
      expect(result.actions[0]).toEqual({ marketIndex: 3, action: 'allocate', amount: eth('20') });
    });
  });

  // ============================================================
  // Case 5: Over-allocated — needs deallocation
  // ============================================================
  describe('over-allocated', () => {
    it('deallocates from over-funded markets', () => {
      // 30% total allocated, target 20%
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: eth('300'),
        perMarketAssets: [eth('75'), eth('75'), eth('75'), eth('75')],
      }));

      expect(result.skipped).toBe(false);
      for (const action of result.actions) {
        expect(action.action).toBe('deallocate');
        expect(action.amount).toBe(eth('25')); // 75 - 50 = 25 excess
      }
    });
  });

  // ============================================================
  // Case 6: Mixed — some markets over, some under
  // ============================================================
  describe('mixed over/under allocation', () => {
    it('allocates and deallocates per market', () => {
      // Total 18% (2% under), but distribution is uneven
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: eth('180'),
        perMarketAssets: [eth('80'), eth('10'), eth('80'), eth('10')],
      }));

      expect(result.skipped).toBe(false);
      expect(result.actions).toHaveLength(4);

      // Markets 0 and 2 over-allocated (80 > 50)
      expect(result.actions[0]).toEqual({ marketIndex: 0, action: 'deallocate', amount: eth('30') });
      expect(result.actions[2]).toEqual({ marketIndex: 2, action: 'deallocate', amount: eth('30') });

      // Markets 1 and 3 under-allocated (10 < 50)
      expect(result.actions[1]).toEqual({ marketIndex: 1, action: 'allocate', amount: eth('40') });
      expect(result.actions[3]).toEqual({ marketIndex: 3, action: 'allocate', amount: eth('40') });
    });
  });

  // ============================================================
  // Case 7: Tiny vault (dead deposit only, ~1 USDS)
  // The real-world scenario from our deployment
  // ============================================================
  describe('tiny vault (1 USDS dead deposit)', () => {
    it('allocates 5% per market', () => {
      const result = computeAllocationActions(input({
        totalAssets: eth('1'),
        adapterAssets: 0n,
        perMarketAssets: [0n, 0n, 0n, 0n],
      }));

      expect(result.skipped).toBe(false);
      expect(result.actions).toHaveLength(4);
      for (const action of result.actions) {
        expect(action.action).toBe('allocate');
        expect(action.amount).toBe(eth('0.05')); // 5% of 1
      }
    });

    it('reproduces the partial failure scenario', () => {
      // After first run: stUSDS and wstETH at 5%, cbBTC and WETH at 0%
      const result = computeAllocationActions(input({
        totalAssets: eth('1'),
        adapterAssets: eth('0.1'),  // 10%
        perMarketAssets: [eth('0.05'), 0n, eth('0.05'), 0n],
      }));

      expect(result.skipped).toBe(false);
      expect(result.actions).toHaveLength(2);

      // Only cbBTC (index 1) and WETH (index 3) need allocation
      expect(result.actions[0].marketIndex).toBe(1);
      expect(result.actions[0].action).toBe('allocate');
      expect(result.actions[0].amount).toBe(eth('0.05'));

      expect(result.actions[1].marketIndex).toBe(3);
      expect(result.actions[1].action).toBe('allocate');
      expect(result.actions[1].amount).toBe(eth('0.05'));
    });

    it('skips when all 4 markets are at 5%', () => {
      const result = computeAllocationActions(input({
        totalAssets: eth('1'),
        adapterAssets: eth('0.2'),  // 20%
        perMarketAssets: [eth('0.05'), eth('0.05'), eth('0.05'), eth('0.05')],
      }));

      expect(result.skipped).toBe(true);
    });
  });

  // ============================================================
  // Case 8: Approximate amounts — caller re-reads fresh state
  // The allocation amounts from computeAllocationActions are approximate.
  // The caller (allocator.ts) re-reads fresh totalAssets and
  // expectedSupplyAssets before each allocation and uses
  // computeCapLimit() for the exact on-chain amount.
  // ============================================================
  describe('approximate allocations (exact amounts computed by caller)', () => {
    it('returns the raw deficit as allocation amount', () => {
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: 0n,
        perMarketAssets: [0n],
        targetAllocatedPercent: 500,
        targetPerMarketPercent: 500,
      }));

      // Raw deficit — the caller will compute exact amount via computeCapLimit()
      expect(result.actions[0].amount).toBe(eth('50'));
    });

    it('deallocate amounts are exact (no cap check needed)', () => {
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: eth('300'),
        perMarketAssets: [eth('75')],
        targetAllocatedPercent: 500,
        targetPerMarketPercent: 500,
      }));

      expect(result.actions[0].amount).toBe(eth('25'));
    });
  });

  // ============================================================
  // Edge cases
  // ============================================================
  describe('edge cases', () => {
    it('handles zero totalAssets', () => {
      const result = computeAllocationActions(input({
        totalAssets: 0n,
        adapterAssets: 0n,
        perMarketAssets: [0n, 0n, 0n, 0n],
      }));

      expect(result.skipped).toBe(true);
      expect(result.reason).toBe('totalAssets is zero');
    });

    it('handles single market', () => {
      const result = computeAllocationActions(input({
        totalAssets: eth('1000'),
        adapterAssets: 0n,
        perMarketAssets: [0n],
        targetAllocatedPercent: 500,
        targetPerMarketPercent: 500,
      }));

      expect(result.skipped).toBe(false);
      expect(result.actions).toHaveLength(1);
      expect(result.actions[0]).toEqual({ marketIndex: 0, action: 'allocate', amount: eth('50') });
    });

    it('handles interest accrual (market slightly above target)', () => {
      // After interest accrual, markets may be slightly above 5%
      const result = computeAllocationActions(input({
        totalAssets: eth('1000.5'),
        adapterAssets: eth('200.5'),  // ~20.04%
        perMarketAssets: [
          eth('50.2'),  // slightly above due to interest
          eth('50.1'),
          eth('50.1'),
          eth('50.1'),
        ],
      }));

      expect(result.skipped).toBe(true);
      expect(result.reason).toBe('within threshold');
    });
  });
});

// ============================================================
// capDeallocationsToLiquidity
// ============================================================

describe('capDeallocationsToLiquidity', () => {
  // Helper: build a deallocate action
  function dealloc(marketIndex: number, amount: bigint): AllocationAction {
    return { marketIndex, action: 'deallocate', amount };
  }

  // Helper: build market liquidity data
  function liq(marketIndex: number, totalSupply: bigint, totalBorrow: bigint): MarketLiquidity {
    return { marketIndex, totalSupplyAssets: totalSupply, totalBorrowAssets: totalBorrow };
  }

  describe('happy path — plenty of liquidity', () => {
    it('passes through full amount when liquidity is abundant', () => {
      // Market has 10M supply, 5M borrow → 5M liquidity, reserve = 500K
      // Want to deallocate 1M → plenty of room
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('1000000'))],
        [liq(0, eth('10000000'), eth('5000000'))],
      );

      expect(result).toHaveLength(1);
      expect(result[0].amount).toBe(eth('1000000'));
      expect(result[0].capped).toBe(false);
      expect(result[0].skipped).toBe(false);
    });

    it('handles multiple markets with sufficient liquidity', () => {
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('100')), dealloc(1, eth('200')), dealloc(2, eth('300')), dealloc(3, eth('400'))],
        [
          liq(0, eth('10000'), eth('5000')),
          liq(1, eth('10000'), eth('5000')),
          liq(2, eth('10000'), eth('5000')),
          liq(3, eth('10000'), eth('5000')),
        ],
      );

      expect(result).toHaveLength(4);
      for (const r of result) {
        expect(r.capped).toBe(false);
        expect(r.skipped).toBe(false);
      }
      expect(result[0].amount).toBe(eth('100'));
      expect(result[1].amount).toBe(eth('200'));
      expect(result[2].amount).toBe(eth('300'));
      expect(result[3].amount).toBe(eth('400'));
    });
  });

  describe('capping — liquidity insufficient for full amount', () => {
    it('caps to maxWithdrawable when desired exceeds available after reserve', () => {
      // 2.6M supply, 2.47M borrow → 130K liquidity, reserve = 130K
      // maxWithdrawable = 130K - 130K = 0  ← this is the edge case from review!
      // Actually with 2.6M supply: reserve = 2.6M * 5% = 130K
      // liquidity = 130K, reserve = 130K → maxWithdrawable = 0 → skipped
      //
      // Let's use a case where capping actually applies:
      // 2M supply, 1.5M borrow → 500K liquidity, reserve = 100K
      // maxWithdrawable = 400K, want 1M → capped to 400K
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('1000000'))],
        [liq(0, eth('2000000'), eth('1500000'))],
      );

      expect(result).toHaveLength(1);
      expect(result[0].amount).toBe(eth('400000'));
      expect(result[0].capped).toBe(true);
      expect(result[0].skipped).toBe(false);
    });

    it('caps each market independently', () => {
      // Market 0: plenty of liquidity → not capped
      // Market 1: tight liquidity → capped
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('100')), dealloc(1, eth('100'))],
        [
          liq(0, eth('10000'), eth('5000')),     // 5000 liquidity, 500 reserve → 4500 available
          liq(1, eth('1000'), eth('900')),        // 100 liquidity, 50 reserve → 50 available
        ],
      );

      expect(result[0].amount).toBe(eth('100'));
      expect(result[0].capped).toBe(false);
      expect(result[1].amount).toBe(eth('50'));
      expect(result[1].capped).toBe(true);
    });
  });

  describe('skipping — no withdrawable liquidity', () => {
    it('skips when market is at 100% utilization', () => {
      // 2M supply, 2M borrow → 0 liquidity
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('1000000'))],
        [liq(0, eth('2000000'), eth('2000000'))],
      );

      expect(result).toHaveLength(1);
      expect(result[0].amount).toBe(0n);
      expect(result[0].skipped).toBe(true);
      expect(result[0].availableLiquidity).toBe(0n);
    });

    it('skips when liquidity equals the reserve (edge case)', () => {
      // 2M supply, 1.9M borrow → 100K liquidity, reserve = 100K
      // maxWithdrawable = 100K - 100K = 0 → skipped
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('500000'))],
        [liq(0, eth('2000000'), eth('1900000'))],
      );

      expect(result).toHaveLength(1);
      expect(result[0].amount).toBe(0n);
      expect(result[0].skipped).toBe(true);
      expect(result[0].availableLiquidity).toBe(eth('100000'));
    });

    it('skips when liquidity is below the reserve', () => {
      // 2M supply, 1.95M borrow → 50K liquidity, reserve = 100K
      // maxWithdrawable = 0 (liquidity < reserve)
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('500000'))],
        [liq(0, eth('2000000'), eth('1950000'))],
      );

      expect(result).toHaveLength(1);
      expect(result[0].skipped).toBe(true);
    });

    it('skips when no liquidity data is provided for a market', () => {
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('100'))],
        [], // no liquidity data
      );

      expect(result).toHaveLength(1);
      expect(result[0].skipped).toBe(true);
      expect(result[0].amount).toBe(0n);
    });

    it('handles all markets skipped', () => {
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('100')), dealloc(1, eth('200'))],
        [
          liq(0, eth('1000'), eth('1000')),  // 100% utilization
          liq(1, eth('1000'), eth('1000')),  // 100% utilization
        ],
      );

      expect(result).toHaveLength(2);
      expect(result.every(r => r.skipped)).toBe(true);
    });
  });

  describe('mixed — some markets capped, some not, some skipped', () => {
    it('handles realistic 4-market scenario', () => {
      // Market 0: plenty of liquidity
      // Market 1: needs capping
      // Market 2: fully utilized (skip)
      // Market 3: liquidity exactly at reserve (skip)
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('1000')), dealloc(1, eth('1000')), dealloc(2, eth('1000')), dealloc(3, eth('1000'))],
        [
          liq(0, eth('100000'), eth('50000')),   // 50K liquidity, 5K reserve → 45K avail
          liq(1, eth('10000'), eth('9000')),      // 1K liquidity, 500 reserve → 500 avail
          liq(2, eth('10000'), eth('10000')),     // 0 liquidity
          liq(3, eth('10000'), eth('9500')),      // 500 liquidity, 500 reserve → 0 avail
        ],
      );

      expect(result).toHaveLength(4);

      // Market 0: full amount, not capped
      expect(result[0].amount).toBe(eth('1000'));
      expect(result[0].capped).toBe(false);
      expect(result[0].skipped).toBe(false);

      // Market 1: capped to 500
      expect(result[1].amount).toBe(eth('500'));
      expect(result[1].capped).toBe(true);
      expect(result[1].skipped).toBe(false);

      // Market 2: skipped (no liquidity)
      expect(result[2].skipped).toBe(true);

      // Market 3: skipped (liquidity equals reserve)
      expect(result[3].skipped).toBe(true);
    });
  });

  describe('edge cases', () => {
    it('handles empty actions list', () => {
      const result = capDeallocationsToLiquidity([], []);
      expect(result).toHaveLength(0);
    });

    it('handles zero supply market (should not happen but be safe)', () => {
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('100'))],
        [liq(0, 0n, 0n)],
      );

      expect(result).toHaveLength(1);
      expect(result[0].skipped).toBe(true);
      expect(result[0].availableLiquidity).toBe(0n);
    });

    it('handles borrow exceeding supply (should not happen on-chain)', () => {
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('100'))],
        [liq(0, eth('1000'), eth('1500'))],
      );

      expect(result).toHaveLength(1);
      expect(result[0].skipped).toBe(true);
      expect(result[0].availableLiquidity).toBe(0n);
    });

    it('returns exact amount when desired equals maxWithdrawable', () => {
      // 10M supply, 5M borrow → 5M liquidity, reserve = 500K
      // maxWithdrawable = 4.5M, want exactly 4.5M
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('4500000'))],
        [liq(0, eth('10000000'), eth('5000000'))],
      );

      expect(result[0].amount).toBe(eth('4500000'));
      expect(result[0].capped).toBe(false);
      expect(result[0].skipped).toBe(false);
    });

    it('caps when desired is 1 wei above maxWithdrawable', () => {
      // maxWithdrawable = 4.5M, want 4.5M + 1 wei
      const result = capDeallocationsToLiquidity(
        [dealloc(0, eth('4500000') + 1n)],
        [liq(0, eth('10000000'), eth('5000000'))],
      );

      expect(result[0].amount).toBe(eth('4500000'));
      expect(result[0].capped).toBe(true);
    });

    it('preserves market indices in output', () => {
      // Non-contiguous indices (markets 1 and 3 only)
      const result = capDeallocationsToLiquidity(
        [dealloc(1, eth('100')), dealloc(3, eth('200'))],
        [liq(1, eth('10000'), eth('5000')), liq(3, eth('10000'), eth('5000'))],
      );

      expect(result[0].marketIndex).toBe(1);
      expect(result[1].marketIndex).toBe(3);
    });
  });

  describe('reserve constant', () => {
    it('LIQUIDITY_RESERVE_PERCENT is 5', () => {
      expect(LIQUIDITY_RESERVE_PERCENT).toBe(5n);
    });

    it('reserve math: 5% of 2.6M = 130K', () => {
      const totalSupply = eth('2600000');
      const reserve = totalSupply * LIQUIDITY_RESERVE_PERCENT / 100n;
      expect(reserve).toBe(eth('130000'));
    });
  });
});
