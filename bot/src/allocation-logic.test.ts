import { describe, it, expect } from 'vitest';
import { computeAllocationActions, computeCapLimit, bpsToWad, CAP_HEADROOM_BPS, type AllocationInput } from './allocation-logic.js';
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
