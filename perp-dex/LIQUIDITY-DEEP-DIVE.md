# Custom Perp DEX — Perpetual Market Liquidity Deep Dive

How the 4-layer liquidity waterfall works for perpetual markets, explained through the full lifecycle of a trade.

---

## The Big Picture

This exchange doesn't work like Binance. On Binance, a market order hits a centralized orderbook and fills instantly against resting limit orders. This exchange has **4 layers of liquidity that an order falls through like a waterfall**. Each layer exists because the previous one might not have enough depth.

The reason Drift built it this way: a pure orderbook on Solana doesn't work well (too slow, too expensive per match), and a pure AMM has terrible pricing. The 4-layer hybrid solves both problems.

```
Taker Order
    │
    ▼
┌──────────────────────────────────────────────────────────┐
│  LAYER 1: JIT AUCTION  (0–10 slots, ~4 seconds)         │
│  Market makers + AMM compete to fill at improving price  │
│  Best price for taker, best margin for fast makers       │
└──────────────────────┬───────────────────────────────────┘
                       │ unfilled remainder
                       ▼
┌──────────────────────────────────────────────────────────┐
│  LAYER 2: DLOB  (after auction ends)                     │
│  Resting limit orders matched by filler keeper bot       │
│  Up to 6 makers per fill transaction                     │
└──────────────────────┬───────────────────────────────────┘
                       │ unfilled remainder
                       ▼
┌──────────────────────────────────────────────────────────┐
│  LAYER 3: AMM BACKSTOP  (always available)               │
│  Virtual constant-product AMM fills any remaining size   │
│  Guarantees every order fills — no "insufficient liq"    │
└──────────────────────┬───────────────────────────────────┘
                       │ position created
                       ▼
┌──────────────────────────────────────────────────────────┐
│  LAYER 4: LP POOL  (background, continuous)              │
│  LPs share AMM position pro-rata via LP shares           │
│  Earns slippage + spread + funding, takes directional    │
│  risk alongside the AMM                                  │
└──────────────────────────────────────────────────────────┘
```

---

## Full Trade Lifecycle: "Long 1 SOL-PERP at Market"

A trader wants to go long 1 SOL-PERP at market price. Oracle says SOL = $150.

### Step 0: Order Creation (on-chain)

The frontend submits a `place_perp_order` transaction. The on-chain program creates an order with:

```
direction:           Long
base_asset_amount:   1 SOL (1e9 in BASE_PRECISION)
order_type:          Market
auction_start_price: $149.25  (oracle - 0.5%)
auction_end_price:   $150.75  (oracle + 0.5%)
auction_duration:    10 slots (~4 seconds)
```

The 0.5% comes from `AUCTION_DERIVE_PRICE_FRACTION = 200` (1/200 = 0.5%). For a long market order, the auction starts **below** oracle (favorable to makers) and ends **above** oracle (the taker's worst acceptable price).

The order is now on-chain and visible to everyone. The auction clock starts.

---

### Layer 1: JIT Auction (slots 0–10, ~0–4 seconds)

This is the first and most price-efficient layer. The order is in "auction mode" — it can't match against the regular orderbook yet. Instead, it's an open invitation for market makers to compete.

#### Auction Price Over Time

```
Slot 0:  $149.25  ←── great price for makers (they sell cheap, oracle is $150)
Slot 3:  $149.70
Slot 5:  $150.00  ←── oracle price (fair for both sides)
Slot 7:  $150.30
Slot 10: $150.75  ←── worst price for taker (auction ends)
```

The price moves linearly: `price = start + (end - start) × slots_elapsed / duration`

Early fillers get better deals. This creates a **speed competition** among market makers — whoever lands a transaction earliest gets the best fill price.

#### Who Participates in JIT

**1. JIT Maker bots (external market makers)**

They watch the chain for new orders, calculate if filling at the current auction price is profitable, and submit a counter-order. The `keeper-bots-v2` repo has a `jitMaker` bot (`src/bots/jitMaker.ts`) with two strategies:

- **JitterSniper**: waits for optimal slot, submits one precise transaction
- **JitterShotgun**: submits multiple transactions across slots, hopes one lands at a good price

Config (`jit-maker-config.yaml`):
```yaml
marketType: "perp"
marketIndexes: [0, 1, 2, 3]     # SOL, BTC, ETH, TEAM
subaccounts: [1]
targetLeverage: 1.0
aggressivenessBps: 10            # How tight to quote vs oracle
```

**2. The AMM itself**

If `amm_jit_intensity > 0` (set per market on-chain), the AMM competes in the auction. But it only does this when it wants to **reduce its inventory**:

```
AMM participates in JIT when:
  - amm_jit_intensity > 0  (range 0-200, per market)
  - AMM has inventory it wants to unwind

  Example:
    AMM is currently short 5 SOL → taker is buying (long)
    → AMM sells into the auction to reduce its short position
    → AMM goes from -5 to -4.5 SOL

  But if:
    AMM is currently long 5 SOL → taker is buying (long)
    → AMM does NOT participate (would increase inventory)
    → Waits for Layer 3 instead
```

#### How Much the AMM Fills in JIT

Calculated in `programs/drift/src/math/amm_jit.rs`:

```
Step 1: Start with 50% of the order size
        → 0.5 SOL

Step 2: Wash trade protection
        If auction price is >5 bps from oracle → reduce fill size
        Prevents someone from placing+filling their own order at manipulated price

Step 3: Market imbalance check
        If max_bids/min_asks ≥ 1.5 (market is lopsided):
          → aggressive: fill up to 100% of order
        If balanced:
          → conservative: fill only 25%

Step 4: Scale by amm_jit_intensity / 100
        If intensity = 100: multiply by 1.0 (full)
        If intensity = 50:  multiply by 0.5 (half)

Step 5: Cap to AMM's current position size
        Can't fill more than its inventory allows

Step 6: Round to order_step_size
```

#### JIT Outcome

In our example: AMM is currently short 5 SOL. Taker wants to buy 1 SOL. Market is balanced.

```
Step 1: 0.5 SOL (50% of 1 SOL)
Step 2: auction price is near oracle → no reduction
Step 3: balanced market → 0.25 SOL (25%)
Step 4: amm_jit_intensity = 100 → 0.25 × 1.0 = 0.25 SOL
Step 5: AMM position is 5 SOL → 0.25 < 5 → no cap
Step 6: round to step size → 0.25 SOL
```

AMM fills 0.25 SOL at ~$149.80 (early auction price). Remaining: 0.75 SOL.

If the JIT auction fills the entire order → done. No further layers needed.
If partially filled or unfilled → remaining continues to Layer 2 after slot 10.

---

### Layer 2: DLOB Matching (after auction ends)

Once the auction is over (current_slot > order_slot + 10), the order becomes eligible to match against **resting limit orders** on the DLOB (Decentralized Limit Order Book).

#### What's a Resting Limit Order?

An order sitting on the book waiting to be filled. An order becomes "resting" when:

```
is_resting = post_only == true
          OR current_slot > order_slot + auction_duration
```

So there are two ways to be a maker:
1. Place a `post_only` order — it's immediately resting (never crosses the book)
2. Place a regular limit order — it rests **after** its own auction period completes

This design prevents front-running: you can't see an incoming order and instantly place a limit order to capture it, because your limit order has its own auction period first.

#### Order Types on the DLOB

| Type | Description | Sorting |
|------|-------------|---------|
| **RestingLimitOrderNode** | Post-only or auction-complete limits | Best price first |
| **TakingLimitOrderNode** | Limits still in their own auction | Oldest first |
| **FloatingLimitOrderNode** | Oracle-offset orders (price = oracle ± offset) | By offset |
| **MarketOrderNode** | Market orders during auction | Oldest first |
| **TriggerOrderNode** | Stop-loss, take-profit (conditional) | By trigger price |

Only **RestingLimitOrderNode** can be matched against incoming takers.

#### The Filler Bot Does the Matching

Your filler keeper bot (running in `keeper-bots` pod, polling every ~6 seconds):

```
1. Read all resting asks (sell orders) from DLOB via Redis
2. Read all open taker buys (our long order)
3. Check if they cross: taker_limit_price ≥ maker_ask_price
4. If yes → submit fill_perp_order transaction with up to 6 makers
```

**Fill price** = the maker's limit price (not the taker's). If a maker is selling at $150.20 and our taker's limit is $150.75 (from auction end price), the fill happens at $150.20. The taker gets price improvement.

#### On-Chain Matching Rules

Enforced in `programs/drift/src/controller/orders.rs`:

| Rule | Purpose |
|------|---------|
| Maker ≠ taker | No self-matching |
| Maker order is older than taker order (or post_only) | Prevents front-running |
| Orders must cross | Long taker price ≥ short maker price |
| Max 6 unique makers per fill tx | Solana compute limit |
| Post-only orders can't take liquidity | Maker protection |

#### DLOB Infrastructure

```
On-chain accounts ──poll──→ DLOB Publisher ──write──→ Redis
                                                        │
                                                        ├──→ DLOB API (HTTP :6969) → Frontend
                                                        ├──→ DLOB WS  (WS :6970)  → Frontend
                                                        └──→ Filler Bot (reads for matching)
```

The Publisher polls on-chain every `ORDERBOOK_UPDATE_INTERVAL` (1000ms) and writes the aggregated L2/L3 orderbook to Redis. The filler bot reads from the same Redis to find matchable orders.

#### DLOB Outcome

In our example: your market maker bot has a resting ask at $150.20 for 0.5 SOL.

```
Filler bot finds the cross:
  Taker wants to buy 0.75 SOL at up to $150.75
  Maker is selling 0.5 SOL at $150.20
  → Match 0.5 SOL at $150.20

Remaining: 0.25 SOL unfilled → falls to Layer 3
```

---

### Layer 3: AMM Backstop (always available)

This is where the exchange guarantees that **every order fills**. Even if there are zero market makers and zero limit orders on the book, the AMM takes the other side. No trader ever sees "insufficient liquidity."

#### How the AMM Prices

The AMM uses a virtual constant-product curve (like Uniswap, but with no real token pools — all virtual):

```
quote_asset_reserve × base_asset_reserve = k

reserve_price = (quote_asset_reserve / base_asset_reserve) × peg_multiplier
```

- `base_asset_reserve` / `quote_asset_reserve`: virtual reserves (not real tokens deposited anywhere)
- `peg_multiplier`: anchors the AMM mid-price to the oracle. Drift auto-adjusts this.
- `sqrt_k`: the **single most important parameter**. Controls liquidity depth. Higher = less slippage.
- `concentration_coef`: concentrates liquidity around mid-price (like Uniswap v3 ranges)

#### Slippage Math

When our taker buys 1 SOL from the AMM (simplified):

```
Before trade:
  base_reserve  = 1,000 SOL
  quote_reserve = 150,000 USDC
  k = 1,000 × 150,000 = 150,000,000
  reserve_price = 150,000 / 1,000 = $150.00

After buying 1 SOL:
  new_base_reserve  = 999
  new_quote_reserve = 150,000,000 / 999 = 150,150.15
  cost = 150,150.15 - 150,000 = $150.15

Slippage = $150.15 - $150.00 = $0.15 (10 bps)
```

**Slippage scales with `sqrt_k`:**

| sqrt_k | Slippage per 1 SOL | Slippage per 10 SOL |
|--------|-------------------|---------------------|
| 100 | 100 bps (1%) | 1000 bps (10%) |
| 1,000 | 10 bps (0.1%) | 100 bps (1%) |
| 10,000 | 1 bps (0.01%) | 10 bps (0.1%) |
| 100,000 | 0.1 bps | 1 bps |

This is why `sqrt_k` is critical. If it's too low, trading is unusably expensive. If it's too high, the AMM takes enormous risk per trade.

#### Dynamic Spreads

The AMM doesn't just use the raw reserve price. It applies spreads:

```
bid = reserve_price × (1 - long_spread)
ask = reserve_price × (1 + short_spread)
```

These spreads **widen and narrow dynamically** based on:

| Condition | Spread behavior | Purpose |
|-----------|----------------|---------|
| AMM inventory is long-heavy | Bid widens, ask tightens | Discourage more longs, attract shorts to rebalance |
| AMM inventory is short-heavy | Ask widens, bid tightens | Discourage more shorts, attract longs |
| Oracle divergence from mark | Spreads adjust toward oracle | Pull AMM price back to oracle |
| High recent volatility | Both spreads widen | Protect AMM during choppy markets |
| Low inventory, calm market | Both spreads narrow | Competitive pricing, attract volume |

This self-correcting mechanism is why the AMM doesn't just bleed money — it adjusts its pricing to incentivize traders to rebalance it.

#### AMM State After Fill

After our taker buys the remaining 0.25 SOL from the AMM at ~$150.25:

```
Before: base_asset_amount_with_amm = -5.0 SOL (AMM is short)
After:  base_asset_amount_with_amm = -5.25 SOL (AMM is more short)

Reserves shift:
  base_reserve decreases (AMM sold base)
  quote_reserve increases (AMM received quote)

Spreads may widen:
  AMM is now more short → ask spread increases slightly
  Next seller gets a slightly better price (incentive to rebalance)
```

#### What the AMM Earns

| Source | Description |
|--------|-------------|
| Bid-ask spread | Every taker crosses the spread → AMM captures it |
| Slippage | Larger orders pay more slippage → AMM profits |
| Funding rate | When the majority side pays funding, AMM collects as counterparty |

#### What the AMM Loses

| Source | Description |
|--------|-------------|
| Adverse inventory | AMM is short and price drops → unrealized loss on short |
| Oracle divergence | Mark price diverges from oracle → arbitrageurs extract value |
| Large directional flow | Everyone trades one way → AMM takes huge directional position |

---

### Layer 4: LP Pool (background, continuous)

LPs don't directly fill orders. They **share the AMM's position and PnL proportionally** via LP shares. Think of it as "fractional ownership of the AMM's trading book."

#### How LP Works Step by Step

**1. Alice provides LP to SOL-PERP**

She calls `add_perp_lp_shares` with some collateral. She receives LP shares proportional to her contribution vs total LP pool. Say she gets 10% of total shares.

```
Alice's PerpPosition:
  lp_shares: 1000  (10% of 10,000 total)
  last_base_asset_amount_per_lp: 0
  last_quote_asset_amount_per_lp: 0
```

**2. Trades happen against the AMM**

Our taker buys 1 SOL from the AMM. The AMM's position changes. This is tracked in accumulator variables:

```
AMM state:
  base_asset_amount_per_lp: -0.0001  (cumulative base per LP share)
  quote_asset_amount_per_lp: 0.015   (cumulative quote per LP share)
```

Alice doesn't see anything change yet — her position isn't updated on every trade (too expensive on-chain).

**3. Settlement (PnL settler bot or manual)**

When the `userPnlSettler` keeper bot runs, or when Alice interacts with her position:

```
delta_base  = (current_base_per_lp - last_base_per_lp) × lp_shares
            = (-0.0001 - 0) × 1000
            = -0.1 SOL

delta_quote = (current_quote_per_lp - last_quote_per_lp) × lp_shares
            = (0.015 - 0) × 1000
            = 15 USDC
```

Alice now has a real perp position: **short 0.1 SOL** with **15 USDC in quote** (her share of the slippage collected by the AMM).

**4. Alice manages her position like any other trader**

She can:
- Hold it and collect ongoing LP revenue
- Close the perp position to realize PnL
- Remove LP shares to stop future accumulation
- Get liquidated if her margin drops too low

#### What LPs Earn

| Revenue source | How it works |
|----------------|-------------|
| **Slippage** | Taker pays $150.25 for $150 asset → $0.25 × Alice's share → revenue |
| **Bid-ask spread** | Every trade crosses the spread → captured in quote accumulator |
| **Funding rates** | If longs pay 0.01%/hr and AMM is short → LPs collect funding |
| **Peg rebalancing** | When peg_multiplier adjusts to match oracle, LPs benefit from the correction |

#### What LPs Risk

| Risk | Description | Severity |
|------|-------------|----------|
| **Directional / inventory risk** | LPs take opposite side of all trades. If everyone goes long, LPs go short. If price pumps, LPs lose. | High |
| **Impermanent loss** | Similar to Uniswap — if price moves far from entry, LPs lose vs simply holding the asset | Medium |
| **Funding rate risk** | If LPs end up on the paying side of funding, it erodes returns | Medium |
| **Liquidation risk** | The LP's accumulated perp position can be liquidated if margin drops | High |
| **Oracle divergence** | Arbitrageurs extract value from AMM when mark ≠ oracle → LPs bear this cost | Medium |
| **No position control** | LPs can't choose what trades they take — it's automatic based on flow | Structural |

#### LP Pool (Multi-Market Diversification)

The protocol also supports a diversified **LPPool** (`state/lp_pool.rs`) that spans multiple markets:

- Users mint/redeem pool-level LP tokens
- Pool allocates capital across SOL, BTC, ETH, TEAM perp markets
- Revenue is distributed across constituents
- **Better risk profile** than single-market LP because directional flows in one market may offset another
- More suitable for passive LPs who don't want to pick individual markets

---

## Complete Example: Realistic Fill on This Exchange

```
═══════════════════════════════════════════════════════════
  Taker places: Long 1 SOL-PERP at market
  Oracle: $150.00
  Auction: $149.25 → $150.75 over 10 slots
═══════════════════════════════════════════════════════════

Layer 1 — JIT Auction (slot 3):
  AMM is short 5 SOL, wants to reduce
  AMM fills 0.25 SOL at $149.70 (auction price at slot 3)
  Cost: $37.43
  Remaining: 0.75 SOL

Layer 2 — DLOB (slot 12, auction over):
  Market maker bot has resting ask: 0.5 SOL at $150.20
  Filler bot matches → fills 0.5 SOL at $150.20
  Cost: $75.10
  Remaining: 0.25 SOL

Layer 3 — AMM Backstop:
  AMM ask (after spread): $150.30
  Slippage on 0.25 SOL: $0.04
  Fills 0.25 SOL at $150.34
  Cost: $37.59
  Remaining: 0 SOL ✓

Layer 4 — LP Settlement (background):
  No LPs on exchange yet → AMM absorbs 100% of position
  AMM goes from -5.0 to -5.25 SOL net short
  If LPs existed with 10% shares, they'd absorb -0.025 SOL

═══════════════════════════════════════════════════════════
  TOTAL FILL SUMMARY
═══════════════════════════════════════════════════════════

  Layer 1 (JIT):   0.25 SOL @ $149.70  =  $37.43
  Layer 2 (DLOB):  0.50 SOL @ $150.20  =  $75.10
  Layer 3 (AMM):   0.25 SOL @ $150.34  =  $37.59
  ─────────────────────────────────────────────────
  Total:           1.00 SOL              = $150.12

  Effective price: $150.12
  vs Oracle:       $150.00
  Total cost:      8 bps  (competitive with centralized exchanges)
```

---

## Current State & Gaps

| Layer | Status on this exchange | What's working | What's missing |
|-------|----------------------|----------------|----------------|
| **Layer 1: JIT** | AMM participates if `amm_jit_intensity > 0` | AMM JIT reduces inventory | No external JIT maker bot enabled |
| **Layer 2: DLOB** | Market maker bot on TEAM-PERP; filler bot on all markets | Orders get matched | MM bot only covers TEAM-PERP; SOL/BTC/ETH have no bot-placed orders |
| **Layer 3: AMM** | Active on all 4 markets | Every order fills | `sqrt_k` values need verification — may be too low for good UX |
| **Layer 4: LP** | Not active | — | No LP providers; AMM absorbs 100% of risk alone |

### What to Enable (Priority Order)

**1. Enable JIT Maker bot** — biggest UX improvement for minimal effort

Add to `~/keeper-bots-v2/custom-dex.config.yaml`:
```yaml
enabledBots:
  - filler
  - liquidator
  - trigger
  - fundingRateUpdater
  - userPnlSettler
  - jitMaker              # ← ADD THIS

botConfigs:
  jitMaker:
    botId: "custom-dex-jit-maker"
    dryRun: false
    metricsPort: 9476
    marketType: "perp"
    marketIndexes: [0, 1, 2, 3]
    subaccounts: [1]
    targetLeverage: 1.0
    spreadBps: 10
```

Impact: takers get better fill prices during the auction window.

**2. Check and tune `sqrt_k` per market**

```bash
# Check current AMM parameters on-chain
cd ~/protocol-v2
npx ts-node --transpile-only scripts/inspectMarket.ts --market-index 0
```

If `sqrt_k` is too low, increase it via admin transaction. Target: slippage < 20 bps for a reasonable trade size ($1000 notional).

**3. Seed LP on each market**

Use the admin account to provide LP shares on each market. This deepens the AMM without changing `sqrt_k`:
```bash
cd ~/protocol-v2
npx ts-node --transpile-only scripts/addLpShares.ts --market-index 0 --amount 1000
```

**4. Expand market maker bot to all markets**

Currently `~/Perp_bots/src/bots/market-maker.ts` only runs on TEAM-PERP (market 3). Run additional instances for SOL/BTC/ETH to populate the DLOB with resting orders.

---

## Key Parameters Reference

### Per-Market On-Chain Parameters

| Parameter | Controls | Layer affected |
|-----------|---------|----------------|
| `amm_jit_intensity` (0-200) | AMM participation in JIT auctions | Layer 1 |
| `min_perp_auction_duration` (slots) | How long the JIT window lasts | Layer 1 |
| `order_step_size` | Minimum order size increment | Layer 1, 2 |
| `order_tick_size` | Minimum price increment | Layer 2 |
| `sqrt_k` | AMM liquidity depth | Layer 3 |
| `peg_multiplier` | AMM price anchor to oracle | Layer 3 |
| `base_spread` | Minimum AMM spread | Layer 3 |
| `max_spread` | Maximum AMM spread | Layer 3 |
| `concentration_coef` | Liquidity concentration around mid | Layer 3 |
| `max_base_asset_reserve` | Max OI cap via reserve limits | Layer 3 |

### Off-Chain Bot Parameters

| Parameter | Where | Controls |
|-----------|-------|---------|
| `fillerPollingInterval` (6000ms) | `custom-dex.config.yaml` | How often filler scans DLOB (Layer 2 responsiveness) |
| `ORDERBOOK_UPDATE_INTERVAL` (1000ms) | DLOB `.env` | How often orderbook refreshes in Redis |
| `aggressivenessBps` | JIT maker config | How tight JIT maker quotes vs oracle (Layer 1) |
| `targetLeverage` | JIT maker config | Max leverage JIT maker takes |
| Market maker spread/depth | `Perp_bots` bot config | Width and depth of resting orders (Layer 2) |

### Timing

| Event | Duration | Notes |
|-------|----------|-------|
| Solana slot | ~400ms | Block production time |
| JIT auction | 10 slots (~4s) | `min_perp_auction_duration` |
| Filler scan | 6000ms | `fillerPollingInterval` |
| DLOB refresh | 1000ms | `ORDERBOOK_UPDATE_INTERVAL` |
| Funding rate update | 1 hour | On-chain, updated by `fundingRateUpdater` bot |
| LP settlement | Periodic | Triggered by `userPnlSettler` bot |
| Total time from order → fill | ~4-10 seconds | Auction (4s) + filler scan (0-6s) |

---

## Source Code Reference

| Component | File |
|-----------|------|
| Auction price math | `protocol-v2/programs/drift/src/math/auction.rs` |
| AMM JIT fill calculation | `protocol-v2/programs/drift/src/math/amm_jit.rs` |
| Order matching logic | `protocol-v2/programs/drift/src/math/matching.rs` |
| Order fill controller | `protocol-v2/programs/drift/src/controller/orders.rs` |
| AMM state & pricing | `protocol-v2/programs/drift/src/state/perp_market.rs` |
| LP controller (settle/add/remove) | `protocol-v2/programs/drift/src/controller/lp.rs` |
| LP pool state | `protocol-v2/programs/drift/src/state/lp_pool.rs` |
| DLOB node types | `protocol-v2/sdk/src/dlob/DLOBNode.ts` |
| Filler keeper bot | `keeper-bots-v2/src/bots/filler.ts` |
| JIT maker bot | `keeper-bots-v2/src/bots/jitMaker.ts` |
| Market maker bot | `Perp_bots/src/bots/market-maker.ts` |
| Oracle updater bot | `Perp_bots/src/bots/oracle-updater.ts` |
