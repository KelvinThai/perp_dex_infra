# Custom Perp DEX — Operations Guide

## Table of Contents

1. [Technical Operations](#1-technical-operations)
2. [Market Parameters & Tuning](#2-market-parameters--tuning)
3. [Risk Management](#3-risk-management)
4. [Business Operations](#4-business-operations)
5. [Regulatory & Legal](#5-regulatory--legal)
6. [Growth & Go-to-Market](#6-growth--go-to-market)
7. [Team & Organizational Structure](#7-team--organizational-structure)
8. [Financial Model](#8-financial-model)
9. [Appendix: Runbooks](#9-appendix-runbooks)

---

## 1. Technical Operations

### 1.1 System Architecture

The exchange runs as 8 containerized services on Kubernetes, backed by a Solana program on-chain.

**On-chain (Solana devnet)**:
- Program: `6prdU12bH7QLTHoNPhA3RF1yzSjrduLQg45JQgCMJ1ko`
- Admin: `7XAMFnYGKtJDqATNycQ6JQ7CwvFazrrtmmwn1UHSLQGr`
- All trade execution, margin accounting, liquidation logic lives on-chain
- State is trustless and verifiable by anyone

**Off-chain (Kubernetes)**:
- DLOB server (3 processes) — orderbook aggregation and distribution
- Keeper bots (5 bots) — transaction submission for fills, liquidations, funding, settlements
- Oracle updater — TEAM-PERP price feed
- Market maker — baseline liquidity provision
- Frontend — user-facing trading interface
- Redis — inter-process orderbook cache

### 1.2 Component Dependencies

```
Solana RPC (external)
  └── DLOB Publisher → Redis → DLOB API → Frontend (user-facing)
                             → DLOB WS  → Frontend (real-time)
  └── Keeper Bots (filler, liquidator, trigger, funding, settler)
  └── Oracle Updater (TEAM-PERP price feed)
  └── Market Maker (TEAM-PERP liquidity)
```

**Failure impact matrix**:

| Component down | User impact | Revenue impact | Risk impact |
|----------------|-------------|----------------|-------------|
| DLOB Publisher | Stale orderbook on frontend | Indirect — users stop trading | Low |
| DLOB API | Frontend can't load orderbook | High — no trading UI | Low |
| DLOB WS | No real-time price updates | Medium — delayed UX | Low |
| Redis | All DLOB components fail | High | Low |
| Keeper: Filler | Orders placed but never matched | Critical — no trading | Low |
| Keeper: Liquidator | Underwater positions not closed | Low (short term) | Critical — bad debt |
| Keeper: Trigger | Stop-loss/take-profit orders don't fire | Medium | Medium |
| Keeper: Funding updater | Funding rates don't update | Medium — OI imbalance grows | Medium |
| Keeper: PnL settler | Users can't realize PnL | Medium | Low |
| Oracle Updater | TEAM-PERP price stale | Critical for TEAM market | High — stale liquidations |
| Market Maker | No liquidity on TEAM-PERP | High for TEAM market | Low |
| Frontend | Users can't access UI | Critical | None (on-chain unaffected) |
| Solana RPC | Everything stops | Critical | High |

### 1.3 Monitoring & Alerting

#### What to monitor

**Infrastructure metrics (Prometheus/Grafana)**:
- Pod status: running, restarts, CrashLoopBackOff
- CPU/memory usage per pod (limits defined in K8s manifests)
- Redis memory usage and connection count
- Network latency between pods

**Application health endpoints**:
- `dlob-api:6969/health` — DLOB HTTP API
- `dlob-publisher:8080/health` — DLOB Publisher
- `keeper-bots:8888/health` — Keeper bots aggregate health

**Metrics ports (Prometheus scrape targets)**:
- DLOB API: 9464
- DLOB Publisher: 9465
- DLOB WS: 9467
- Keeper Filler: 9474
- Keeper Liquidator: 9471
- Keeper Trigger: 9472
- Keeper Funding: 9473
- Keeper Settler: 9475

**Business metrics to track**:
- Daily trading volume (by market)
- Number of active traders (daily/weekly/monthly)
- Open interest per market (long vs short)
- Funding rate history
- Liquidation count and volume
- Insurance fund balance
- Orderbook depth at various levels (1%, 2%, 5% from mid)
- Fill rate (% of orders that get matched)
- Time to fill (latency from order placement to execution)

#### Alert thresholds

| Alert | Condition | Severity | Action |
|-------|-----------|----------|--------|
| Pod restart | Any pod restarts > 2 in 5 min | Critical | Check logs, restart if needed |
| Health check fail | /health returns non-200 for > 30s | Critical | Investigate immediately |
| Oracle stale | TEAM-PERP oracle age > 60s | High | Check oracle updater pod |
| Pyth oracle stale | SOL/BTC/ETH oracle age > 120s | Medium | Expected on devnet, critical on mainnet |
| Liquidation failure | Liquidator tx fails > 3 consecutive | Critical | Check RPC, keeper wallet balance |
| Keeper wallet low | SOL balance < 1 SOL | High | Top up keeper wallet |
| Admin wallet low | SOL balance < 2 SOL | High | Top up admin wallet |
| Redis memory > 80% | Memory usage > 80% of limit | Medium | Check for memory leak, increase limit |
| RPC rate limited | 429 responses > 10/min | High | Reduce polling intervals, upgrade RPC plan |
| High funding rate | |Funding rate| > 0.1% per hour | Medium | Check OI imbalance, may need parameter adjustment |
| Insurance fund low | Balance < 10% of total OI | Critical | Pause new position opening, add funds |
| Empty orderbook | L2 depth = 0 for any active market | High | Check market maker, DLOB publisher |

#### Monitoring stack recommendation

```
Prometheus (metrics collection)
  → scrape all :94xx and :9471-9475 metrics ports
  → scrape Kubernetes node/pod metrics

Grafana (dashboards)
  → Infrastructure dashboard: pod health, resource usage
  → Trading dashboard: volume, OI, funding rates
  → Risk dashboard: insurance fund, liquidations, oracle health

Alertmanager (notifications)
  → Slack/Discord/Telegram/PagerDuty integration
  → Route critical alerts to phone, medium to Slack
```

### 1.4 RPC Management

Your RPC endpoint is the single external dependency. Everything breaks if it goes down.

**Current**: QuikNode devnet
```
https://green-little-replica.solana-devnet.quiknode.pro/a4254b67640b9dcb3b0da6f2921e6b7ae00e71f6/
```

**Best practices**:
- Have a fallback RPC (e.g., Helius, Triton, or public devnet endpoint)
- Monitor RPC latency and error rates
- Set `BULK_ACCOUNT_LOADER_POLLING_INTERVAL` appropriately (currently 10000ms for devnet, can reduce for mainnet with better RPC)
- For mainnet: run your own RPC node for critical paths (keeper bots, oracle updater), use third-party for read-heavy paths (DLOB, frontend)

**RPC cost planning (mainnet)**:

| Provider | Tier | Cost/month | Requests/sec | Notes |
|----------|------|-----------|--------------|-------|
| QuikNode | Growth | $49-299 | 25-100 | Good for dev, limited for production |
| Helius | Business | $499+ | 200+ | Solana-native, good DAS support |
| Triton | Dedicated | $1000+ | Unlimited | Run your own, most reliable |
| Self-hosted | — | $500-2000 (hardware) | Unlimited | Full control, highest reliability |

### 1.5 Key Management

**Admin keypair** (`7XAMFn...`):
- Controls: oracle updates, market parameter changes, admin functions
- Location: `~/protocol-v2/keys/admin-keypair.json`
- K8s: mounted as secret `admin-keypair` in oracle-updater + market-maker pods
- Risk: if compromised, attacker can manipulate oracle prices and drain the protocol
- Recommendation: move to multi-sig (e.g., Squads) before mainnet launch

**Keeper keypair** (from `KEEPER_PRIVATE_KEY`):
- Controls: submits fill, liquidation, trigger, funding, settlement transactions
- K8s: stored as secret `keeper-keys`
- Risk: if compromised, attacker can submit malicious transactions (limited by on-chain validation)
- Needs SOL balance for transaction fees (~0.01-0.1 SOL per tx)

**Program keypair** (`6prdU1...`):
- Controls: program upgrade authority
- Location: `~/protocol-v2/keys/program-keypair.json`
- Should NOT be on any server. Store offline.
- Risk: if compromised, attacker can deploy malicious program code

**Key security checklist**:
- [ ] Admin keypair stored in hardware wallet or multi-sig for mainnet
- [ ] Program upgrade authority transferred to multi-sig or revoked
- [ ] Keeper keypair is a separate wallet with minimal SOL balance
- [ ] No keypairs committed to git repositories
- [ ] K8s secrets encrypted at rest (enable etcd encryption)
- [ ] Rotate keeper keypair periodically
- [ ] Backup all keypairs in secure offline storage (safety deposit box, etc.)

### 1.6 Infrastructure Scaling Path

**Phase 1: Devnet / Early testing (current)**
- Single-node K8s (4 CPU / 16 GB)
- 1 replica of everything
- Shared RPC endpoint
- No redundancy

**Phase 2: Private mainnet (<100 users)**
- Single-node K8s (8 CPU / 32 GB)
- Redis persistence enabled (appendonly yes)
- Dedicated RPC for keepers, shared RPC for reads
- Daily database/state backups
- Basic Prometheus + Grafana monitoring

**Phase 3: Public launch (100-1000 users)**
- Multi-node K8s (3 nodes, 8 CPU / 32 GB each)
- DLOB API: 2-3 replicas behind load balancer
- Frontend: 2 replicas
- Dedicated RPC node for keepers
- Geographic CDN for frontend static assets
- Full monitoring + alerting stack

**Phase 4: Scale (1000+ users)**
- Dedicated keeper per bot type (separate pods, separate wallets)
- Redis cluster or Redis Sentinel for HA
- Multiple RPC providers with failover
- Horizontal pod autoscaling for DLOB API and frontend
- Consider gRPC subscription (Yellowstone) instead of polling
- Geographic distribution (multiple regions)

---

## 2. Market Parameters & Tuning

### 2.1 Perpetual Futures Mechanics

A perpetual future tracks an underlying asset price without expiry. Key mechanics:

- **Mark price**: the price used for margin calculations, derived from oracle + AMM
- **Index price**: the oracle price (Pyth for SOL/BTC/ETH, PrelaunchOracle for TEAM)
- **Funding rate**: periodic payment between longs and shorts to keep mark ≈ index
- **Margin**: collateral required to open/maintain a position
- **Liquidation**: forced closure when margin ratio falls below maintenance level

### 2.2 Parameter Reference

These parameters are set on-chain per market via admin transactions:

#### Margin Parameters

| Parameter | Description | SOL-PERP typical | TEAM-PERP typical |
|-----------|-------------|-------------------|-------------------|
| Initial margin ratio | Collateral needed to open (1/leverage) | 5% (20x) | 10-20% (5-10x) |
| Maintenance margin ratio | Minimum before liquidation | 3.125% | 5-10% |
| IMF factor | Scales margin with position size | 0.001 | 0.01-0.05 |
| Max leverage | 1 / initial margin ratio | 20x | 5-10x |

**Guidance for TEAM-PERP**: Since it's a custom market with admin-controlled oracle and likely low liquidity, use conservative parameters:
- Lower max leverage (5-10x, not 20x)
- Higher maintenance margin (5-10%)
- Higher IMF factor (large positions need more margin)
- Lower max OI caps

#### Fee Parameters

| Parameter | Description | Recommended start |
|-----------|-------------|-------------------|
| Taker fee | Fee on market orders | 5 bps (0.05%) |
| Maker fee | Fee on limit orders | 0 bps (free) or -1 bps (rebate) |
| Liquidation fee | Fee taken from liquidated position | 2.5-5% |
| Insurance fund fee | % of fees directed to insurance fund | 20-50% |

#### AMM Parameters

| Parameter | Description | Notes |
|-----------|-------------|-------|
| Base spread | Minimum spread around oracle | Higher = more revenue, worse execution |
| Max spread | Maximum spread during imbalance | Widens during volatile periods |
| Peg multiplier | AMM peg to oracle price | Should track oracle closely |
| Sqrt K | AMM depth (liquidity constant) | Higher = deeper AMM liquidity |
| Concentration coefficient | How concentrated liquidity is around mid | Higher = tighter quotes near mid |

### 2.3 Tuning Process

1. **Start conservative**: high margins, wide spreads, low max OI
2. **Monitor**: watch funding rates, liquidation frequency, orderbook depth
3. **Adjust gradually**: change one parameter at a time, wait 24-48 hours to observe impact
4. **Compare to CEX**: for SOL/BTC/ETH, your funding rates and spreads should be in the same ballpark as Binance/Bybit. If not, something is misconfigured.

**Red flags that need parameter adjustment**:
- Funding rate persistently > 0.05%/hr → OI is very imbalanced, consider widening spread or lowering max OI
- Too many liquidations → maintenance margin may be too tight
- No liquidations ever → maintenance margin may be too loose (dangerous)
- Empty orderbook → base spread too wide, or market maker not running
- AMM taking large directional position → oracle spread or peg needs adjustment

---

## 3. Risk Management

### 3.1 Types of Risk

#### Market Risk (protocol takes directional exposure)
- The AMM acts as counterparty to traders. If all traders are long and price goes up, the AMM (and protocol) loses money.
- Mitigation: funding rates incentivize the minority side, AMM adjusts spreads based on inventory

#### Oracle Risk
- If the oracle reports a wrong price, liquidations and settlements happen at incorrect prices
- For Pyth (SOL/BTC/ETH): Pyth has its own security model with multiple data publishers
- For TEAM-PERP: **you are the oracle**. A bug in your oracle updater or an incorrect price update can cause immediate and severe losses

#### Liquidity Risk
- Insufficient liquidity to fill orders or execute liquidations
- Results in slippage, failed liquidations, and bad user experience
- Mitigation: market maker bots, AMM depth parameters, liquidation incentives

#### Smart Contract Risk
- Bugs in the Drift program that could be exploited
- Mitigation: audits, formal verification, bug bounty programs, gradual rollout

#### Operational Risk
- Infrastructure failures, key compromise, human error
- Mitigation: monitoring, alerting, key management, runbooks

### 3.2 Insurance Fund

The insurance fund is the backstop against socialized losses.

**How it works**:
1. A percentage of trading fees is directed to the insurance fund
2. When a liquidation results in negative equity (bad debt), the insurance fund covers the difference
3. If the insurance fund is depleted, socialized losses kick in — profitable traders' unrealized gains are reduced pro-rata

**Sizing the insurance fund**:

Rule of thumb: insurance fund should be >= 5-10% of total open interest.

```
Example:
  Total OI = $1,000,000
  Insurance fund target = $50,000 - $100,000

  At 5 bps taker fee and 30% insurance fund allocation:
    $1M daily volume × 5 bps × 30% = $150/day to insurance fund
    Time to reach $50K: ~333 days
```

For early launch, you'll likely need to **seed the insurance fund** from your own capital.

**When to halt trading**:
- Insurance fund < 1% of total OI → pause new position opening
- Insurance fund = 0 → consider pausing all trading, assess damage
- Multiple cascading liquidations in short period → potential oracle manipulation or flash crash

### 3.3 Liquidation Engine

The liquidator keeper bot monitors all positions and liquidates those below maintenance margin.

**Liquidation process**:
1. Position's margin ratio falls below maintenance threshold
2. Liquidator bot detects the position
3. Bot submits liquidation transaction on-chain
4. On-chain program validates the position is indeed liquidatable
5. Position is partially or fully closed
6. Liquidation fee is split between liquidator (incentive) and insurance fund

**What can go wrong**:
- **Liquidator bot is down**: positions go unliquidated, losses accumulate, bad debt
- **Price moves too fast**: position goes from above maintenance to negative equity in one block (gap risk)
- **Network congestion**: liquidation tx can't land in time
- **Insufficient liquidity**: liquidation order can't be filled without extreme slippage

**Mitigations**:
- Run redundant liquidator bots (separate wallets, separate pods)
- Set generous `initialDelaySeconds` and `periodSeconds` for health checks
- Monitor liquidator success rate
- Set conservative margin parameters for volatile/illiquid markets (TEAM-PERP)

### 3.4 TEAM-PERP Oracle Risk (Special Section)

TEAM-PERP uses a PrelaunchOracle controlled by your admin keypair. This creates unique risks:

**Risk 1: Oracle manipulation accusation**
- You control the price. Users may suspect manipulation during adverse moves.
- Mitigation: publish oracle methodology, make price feed verifiable, consider using a committee or multi-sig for oracle updates.

**Risk 2: Oracle updater failure**
- If the oracle-updater pod crashes, TEAM-PERP's price freezes.
- Stale price → liquidations happen at wrong price, or don't happen at all.
- Mitigation: monitor oracle staleness, auto-pause market if oracle is stale > 60s.

**Risk 3: Binary events**
- Sports outcomes can cause instant large price moves.
- If your oracle updates after users already know the outcome, they can frontrun the oracle.
- Mitigation: pause trading before known events (game starts/ends), update oracle before unpausing.

**Production oracle strategy for TEAM-PERP**:
1. Replace random walk with real data source (sports API, committee of reporters)
2. Implement circuit breakers (max price change per update)
3. Add multi-sig requirement for oracle updates (e.g., 2-of-3 signers)
4. Publish oracle update history on-chain (already inherent since updates are transactions)
5. Consider time-weighted average price (TWAP) to smooth updates

---

## 4. Business Operations

### 4.1 Revenue Streams

| Revenue source | Description | Typical range |
|----------------|-------------|---------------|
| Trading fees (taker) | Fee on market orders | 2-10 bps of notional |
| Trading fees (maker) | Fee on limit orders (can be negative/rebate) | 0-5 bps |
| Liquidation fees | Spread between liquidation price and bankruptcy price | 2.5-5% of position |
| AMM spread | Implicit fee from AMM bid-ask spread | 1-5 bps |
| Funding rate (protocol share) | Small cut of funding payments | 0-10% of funding |

**Revenue projection model**:

```
Monthly Revenue = (Daily Volume × Net Fee Rate × 30) + Liquidation Revenue

Conservative (early):
  Volume: $100K/day, Fee: 5 bps, Liquidation: negligible
  Revenue: $100K × 0.0005 × 30 = $1,500/month

Moderate (established):
  Volume: $5M/day, Fee: 4 bps, Liquidation: $500/day
  Revenue: ($5M × 0.0004 × 30) + ($500 × 30) = $60K + $15K = $75K/month

Growth:
  Volume: $50M/day, Fee: 3 bps, Liquidation: $5K/day
  Revenue: ($50M × 0.0003 × 30) + ($5K × 30) = $450K + $150K = $600K/month
```

### 4.2 Cost Structure

#### Fixed costs

| Cost | Monthly estimate | Notes |
|------|-----------------|-------|
| Infrastructure (K8s, servers) | $200-2,000 | Scales with user count |
| RPC provider | $200-2,000 | Critical dependency, don't cheap out |
| Domain, DNS, CDN | $50-200 | Cloudflare free tier works early |
| Monitoring (Grafana Cloud, etc.) | $0-500 | Self-host initially |
| **Total fixed** | **$450-4,700** | |

#### Variable costs

| Cost | Estimate | Notes |
|------|----------|-------|
| Solana transaction fees | $0.001-0.01 per tx | Keeper bots pay these |
| Priority fees | $0.001-0.10 per tx | Higher during congestion |
| Market making losses | Highly variable | Can be net positive or negative |
| Insurance fund seeding | One-time + ongoing | Budget $10K-100K initial |
| **Total variable** | **Depends on volume** | |

#### People costs

| Role | Annual cost (USD) | Notes |
|------|-------------------|-------|
| Protocol engineer | $150K-300K | Solana/Rust expertise premium |
| Backend/infra engineer | $120K-200K | K8s, monitoring, bots |
| Frontend engineer | $100K-180K | React/Next.js, trading UI |
| Quant/risk analyst | $150K-250K | Market microstructure, risk modeling |
| BD/Marketing | $80K-150K | Community, partnerships |
| Legal counsel | $60K-240K | Retainer or in-house |
| **Total team (6)** | **$660K-1.32M** | Can start with 2-3 people |

### 4.3 Competitive Landscape

**Direct competitors (Solana perp DEXs)**:
- **Drift Protocol**: the upstream of your fork. Established, audited, high TVL.
- **Jupiter Perps**: leverages Jupiter's massive user base, simple UX.
- **Zeta Markets**: options + perps, institutional focus.
- **Flash Trade**: newer entrant, aggressive incentives.

**Your differentiation**:
- TEAM-PERP (sports index) — unique market nobody else offers
- Custom program — can add features without governance overhead
- Can target niche community (sports bettors who want leveraged exposure)

**Competitive risks**:
- Drift adds a similar sports market (they have the brand and liquidity)
- Jupiter adds custom markets (they have the user base)
- A sports betting platform adds perp-style contracts (they have the audience)

### 4.4 Fee Strategy

**Phase 1: Bootstrapping (0-6 months)**
- Taker: 3 bps
- Maker: 0 bps (free)
- Goal: attract any volume, prove the platform works
- Accept negative unit economics

**Phase 2: Growth (6-18 months)**
- Taker: 5 bps
- Maker: -1 bps (rebate)
- Goal: attract market makers, deepen liquidity
- Volume-based fee tiers to reward high-volume traders

**Phase 3: Mature (18+ months)**
- Taker: 3-7 bps (tiered by volume)
- Maker: -0.5 to 1 bps (tiered)
- Referral program: share 10-20% of referee fees
- VIP tiers for large traders

**Fee tier example**:

| 30-day Volume | Taker Fee | Maker Fee |
|---------------|-----------|-----------|
| < $100K | 7 bps | 2 bps |
| $100K - $1M | 5 bps | 0 bps |
| $1M - $10M | 4 bps | -0.5 bps |
| > $10M | 3 bps | -1 bps |

### 4.5 Liquidity Bootstrapping

The cold start problem: no liquidity → no traders → no liquidity.

**Strategy 1: Self-market-making (current)**
- Your market maker bot places orders around oracle price
- You take directional risk (if all users trade one way, you're on the other side)
- Budget: expect to lose 1-5% of market making capital during bootstrapping
- Scale down as organic market makers arrive

**Strategy 2: Incentive programs**
- Points/rewards for providing liquidity (limit orders that rest on the book)
- Trading competitions with prize pools
- Airdrop allocation based on early trading activity
- Referral bonuses

**Strategy 3: Market maker partnerships**
- Approach professional market makers (Wintermute, GSR, Amber, Jump Crypto)
- Offer: reduced fees, co-marketing, early token allocation
- They provide: deep liquidity, tight spreads, credibility
- Barrier: most won't engage until mainnet with meaningful volume

**Strategy 4: Integration**
- Aggregate with Jupiter (get your markets listed in their routing)
- Wallet integrations (Phantom, Solflare)
- Portfolio tracker integrations (Zapper, DeBank)

### 4.6 User Acquisition

**Target audiences**:

| Segment | Channel | Message |
|---------|---------|---------|
| Crypto traders | Twitter/X, Discord, trading communities | "Trade SOL/BTC/ETH perps with low fees" |
| Sports enthusiasts | Sports forums, Reddit, Telegram groups | "Trade sports indexes with leverage" |
| DeFi users | DeFi Twitter, yield aggregator communities | "Earn fees by providing liquidity" |
| Drift users | Drift Discord, governance forums | "Same protocol, unique markets" |

**Marketing tactics**:
1. Content marketing: trading guides, market analysis, protocol explainers
2. Community: Discord server with trading chat, announcements, support
3. Influencer partnerships: crypto trading influencers (paid or token-incentivized)
4. Trading competitions: weekly/monthly with prize pools
5. Bug bounty: security researchers help audit, builds trust
6. Transparency reports: monthly reports on volume, fees, insurance fund, protocol health

---

## 5. Regulatory & Legal

### 5.1 Classification Risk

Your platform could be classified as:

| Classification | Trigger | Regulation | Jurisdictions |
|----------------|---------|------------|---------------|
| **Futures exchange** | Offers perpetual futures contracts | Commodities/derivatives regulation | US (CFTC), EU (MiFID II), UK (FCA), Singapore (MAS) |
| **Gambling platform** | TEAM-PERP tied to sports outcomes | Gambling licenses required | Most countries |
| **Money transmitter** | Users deposit/withdraw value | Money transmission laws | US (FinCEN), EU (PSD2) |
| **Securities exchange** | Token represents investment contract | Securities regulation | US (SEC), most countries |

**The admin key problem**: Because you hold the admin keypair, control the oracle, and run the infrastructure, regulators in most jurisdictions will consider you the **operator** of the exchange, regardless of the code being on Solana.

### 5.2 Jurisdiction Analysis

| Jurisdiction | Feasibility | Requirements | Notes |
|--------------|-------------|--------------|-------|
| **United States** | Very difficult | CFTC registration, state MTLs, potential SEC issues | Avoid US users initially |
| **European Union** | Difficult | MiCA compliance (2024+), MiFID II for derivatives | Possible but expensive |
| **United Kingdom** | Difficult | FCA registration | Crypto derivatives banned for retail |
| **Singapore** | Moderate | MAS license | Expensive but achievable |
| **Dubai/UAE** | Moderate | VARA license | Crypto-friendly, growing ecosystem |
| **British Virgin Islands** | Easy | SIBA license | Common for crypto entities |
| **Cayman Islands** | Easy | CIMA registration | Very common for DeFi protocols |
| **Panama** | Easy | Minimal regulation | Low barrier, less credibility |
| **El Salvador** | Easy | Minimal regulation | Bitcoin-friendly |

### 5.3 Recommended Legal Structure

**Minimum viable legal setup**:

1. **Operating entity**: BVI or Cayman company
   - Cost: $5K-15K setup, $2K-5K annual maintenance
   - Purpose: holds IP, contracts with service providers, employs team

2. **Terms of Service**: must include
   - Prohibited jurisdictions (US, UK, etc.)
   - Risk disclosures (leverage, liquidation, oracle risk)
   - Dispute resolution (arbitration)
   - Limitation of liability

3. **Geo-fencing**: block restricted jurisdictions
   - IP-based blocking (imperfect but shows good faith)
   - Wallet screening via Chainalysis/TRM Labs
   - VPN detection

4. **KYC/AML** (optional for decentralized, recommended for credibility):
   - Tier 1: email verification (low friction)
   - Tier 2: ID verification for higher limits
   - Provider: Jumio, Onfido, or Synaps

### 5.4 TEAM-PERP Specific Legal Risk

A sports-linked perpetual future is a novel product that sits in a gray area:

- **If it's a derivative**: regulated by financial authorities
- **If it's a bet**: regulated by gambling authorities
- **If it's both**: regulated by both (worst case)

**Risk mitigations**:
- Frame it as a "sports index" not a "sports bet" — the settlement is continuous (mark-to-market), not binary (win/lose)
- The oracle price should be based on a basket/index methodology, not a single game outcome
- Document the methodology publicly
- Get a legal opinion letter from a qualified attorney

### 5.5 Legal Action Items (Priority Order)

1. **Engage crypto-specialized law firm** (cost: $10K-30K initial)
   - Recommended: Anderson Kill, Debevoise, Fenwick & West, Latham & Watkins (US); Walkers (offshore)
2. **Establish operating entity** in favorable jurisdiction
3. **Draft Terms of Service** with proper disclaimers
4. **Implement geo-fencing** before any public launch
5. **Get legal opinion** on TEAM-PERP classification
6. **KYC/AML assessment** — determine if/when required
7. **Insurance** — directors & officers (D&O) liability insurance

---

## 6. Growth & Go-to-Market

### 6.1 Launch Phases

#### Phase 0: Internal Testing (current)
- Duration: 2-4 weeks
- Users: team only
- Goals: stability, bug fixing, parameter tuning
- Checklist:
  - [ ] All services run stable for 72+ hours
  - [ ] Liquidation engine tested under stress
  - [ ] Oracle failover tested
  - [ ] All monitoring alerts configured and tested
  - [ ] Frontend UX review complete

#### Phase 1: Private Alpha
- Duration: 4-8 weeks
- Users: 20-50 invited testers
- Goals: real-user feedback, edge case discovery
- Actions:
  - [ ] Seed insurance fund ($10K-50K)
  - [ ] Set conservative position limits ($10K max per user)
  - [ ] Daily monitoring and manual intervention readiness
  - [ ] Collect detailed feedback via Discord/Telegram
  - [ ] Fix bugs and adjust parameters based on usage

#### Phase 2: Public Beta
- Duration: 3-6 months
- Users: open access (with geo-fencing)
- Goals: volume growth, market maker onboarding, brand building
- Actions:
  - [ ] Launch marketing campaign
  - [ ] Trading competition (week-long, prize pool)
  - [ ] Increase position limits gradually
  - [ ] Publish monthly transparency reports
  - [ ] Approach 2-3 professional market makers
  - [ ] Integration with Phantom wallet
  - [ ] Integration with portfolio trackers

#### Phase 3: Growth
- Duration: 6-18 months
- Goals: $5M+ daily volume, sustainable unit economics
- Actions:
  - [ ] Add new perp markets (based on demand)
  - [ ] Launch fee tiers and referral program
  - [ ] Consider governance token
  - [ ] Smart contract audit (if not done earlier)
  - [ ] Geographic expansion (new regions, languages)
  - [ ] Mobile app or responsive web

#### Phase 4: Maturity
- Duration: 18+ months
- Goals: $50M+ daily volume, profitability
- Actions:
  - [ ] Decentralize governance (DAO)
  - [ ] Multi-chain expansion
  - [ ] Institutional features (sub-accounts, API access, FIX protocol)
  - [ ] Advanced order types (TWAP, iceberg, bracket)

### 6.2 Key Metrics by Phase

| Metric | Alpha | Beta | Growth | Mature |
|--------|-------|------|--------|--------|
| Daily volume | $10K | $100K-1M | $5M-50M | $50M+ |
| Daily active traders | 5-10 | 50-200 | 500-2000 | 5000+ |
| Markets | 4 | 4-6 | 6-10 | 10-20+ |
| L2 depth (1% from mid) | $5K | $50K | $500K | $5M+ |
| Avg fill time | <5s | <3s | <1s | <500ms |
| Insurance fund | $10-50K | $50-200K | $200K-1M | $1M+ |
| Monthly revenue | Negative | $0-5K | $5K-75K | $75K+ |

---

## 7. Team & Organizational Structure

### 7.1 Minimum Viable Team (Phase 1-2)

| Role | Responsibilities | Skills needed |
|------|-----------------|---------------|
| **Founder/CEO** | Strategy, fundraising, legal, partnerships | Business acumen, crypto knowledge |
| **Protocol Engineer** | Solana program, SDK, on-chain parameters | Rust, Anchor, Solana runtime |
| **Full-stack Engineer** | Frontend, backend, infra, bots | TypeScript, React, K8s, DevOps |

Total: 2-3 people. One person can wear multiple hats early on.

### 7.2 Growth Team (Phase 3)

| Role | Responsibilities |
|------|-----------------|
| **Founder/CEO** | Strategy, fundraising, hiring, legal |
| **CTO / Lead Engineer** | Architecture, protocol changes, code review |
| **Backend Engineer** | Keeper bots, DLOB, infra, monitoring |
| **Frontend Engineer** | Trading UI, mobile, user experience |
| **Quant / Risk** | Market parameters, insurance fund, risk monitoring |
| **Community / Marketing** | Discord, Twitter, content, partnerships |
| **Legal (external)** | Regulatory compliance, entity management |

Total: 5-6 people + legal retainer.

### 7.3 Key Hiring Priorities

In order of impact:

1. **Quant/Risk person**: Most technical founders underinvest in risk management. One bad liquidation cascade can wipe out the insurance fund and kill user trust.
2. **DevOps/SRE**: Keeping 8 services running reliably is a full-time job on mainnet.
3. **Community manager**: Users need support 24/7. Trading doesn't stop.

---

## 8. Financial Model

### 8.1 Funding Requirements

| Phase | Duration | Funding needed | Primary costs |
|-------|----------|---------------|---------------|
| Alpha | 2 months | $20K-50K | Insurance fund seed, infra, legal setup |
| Beta | 6 months | $100K-300K | Team (2-3), infra, marketing, legal |
| Growth | 12 months | $500K-2M | Team (5-6), market making capital, marketing |

**Funding sources**:
- Self-funded (bootstrap)
- Angel investors (crypto-native angels)
- Grants (Solana Foundation, ecosystem grants)
- Venture capital (after proving PMF with volume metrics)
- Token sale (after legal framework established)

### 8.2 Break-even Analysis

```
Monthly fixed costs (team of 3 + infra): ~$30,000

Break-even volume at 5 bps net fee:
  $30,000 / 0.0005 / 30 = $2,000,000 daily volume

Break-even volume at 3 bps net fee:
  $30,000 / 0.0003 / 30 = $3,333,333 daily volume
```

For context, mid-tier Solana perp DEXs do $5-50M daily volume. Top tier (Jupiter Perps) does $100M+.

### 8.3 Token Economics (if applicable)

If you decide to launch a governance/utility token:

| Allocation | % | Vesting | Purpose |
|------------|---|---------|---------|
| Team | 20% | 4-year vest, 1-year cliff | Retention, alignment |
| Investors | 15-20% | 2-year vest, 6-month cliff | Fundraising |
| Community/Airdrop | 25-30% | Mix of immediate + vesting | User acquisition, decentralization |
| Treasury/Ecosystem | 20-25% | DAO-controlled | Grants, partnerships, liquidity mining |
| Insurance fund | 5-10% | As needed | Protocol safety |

**Token utility options**:
- Governance (vote on parameters, new markets, fee changes)
- Fee sharing (stake token to earn % of protocol fees)
- Fee discounts (hold token for reduced trading fees)
- Insurance fund staking (stake token to backstop insurance, earn yield)

---

## 9. Appendix: Runbooks

### 9.1 Runbook: Service Recovery

**Pod in CrashLoopBackOff**:
```bash
# 1. Check what's wrong
kubectl -n perp-dex describe pod <pod-name>
kubectl -n perp-dex logs <pod-name> --previous

# 2. Common causes:
#    - OOM (Out of Memory): increase memory limits in YAML
#    - Config error: check env vars, mounted secrets/configmaps
#    - RPC connection failure: check RPC endpoint accessibility

# 3. Quick restart
kubectl -n perp-dex rollout restart deployment/<deployment-name>

# 4. If config change needed
kubectl -n perp-dex edit deployment/<deployment-name>
# or edit YAML and re-apply
kubectl apply -f <manifest>.yaml
```

### 9.2 Runbook: Keeper Wallet Top-up

```bash
# Check keeper wallet balance
solana balance <keeper-pubkey> --url $RPC_ENDPOINT

# Transfer SOL from admin wallet
solana transfer <keeper-pubkey> 5 \
  --keypair ~/protocol-v2/keys/admin-keypair.json \
  --url $RPC_ENDPOINT \
  --allow-unfunded-recipient
```

### 9.3 Runbook: Emergency Market Pause

If you need to halt trading on a market (oracle failure, exploit detected):

```bash
# Use drift admin CLI or custom script
# This requires the admin keypair
cd ~/protocol-v2
npx ts-node --transpile-only scripts/pauseMarket.ts --market-index 3
```

Note: implement this script before mainnet launch. It should call `updatePerpMarketStatus` to set the market to `Paused`.

### 9.4 Runbook: Oracle Updater Recovery (TEAM-PERP)

```bash
# 1. Check oracle updater logs
kubectl -n perp-dex logs deploy/oracle-updater --tail=50

# 2. Check current oracle price on-chain
# (use custom script or solana account command)

# 3. If pod is healthy but oracle is stale, restart
kubectl -n perp-dex rollout restart deployment/oracle-updater

# 4. If oracle is significantly wrong, manually update
cd ~/Perp_bots
npx ts-node --transpile-only scripts/manualOracleUpdate.ts --price <correct-price>
```

### 9.5 Runbook: Insurance Fund Check

```bash
# Check insurance fund balance on-chain
cd ~/protocol-v2
npx ts-node --transpile-only scripts/checkInsuranceFund.ts

# If balance is critically low:
# 1. Consider pausing new position opening
# 2. Add funds from treasury
# 3. Investigate cause (was there a large liquidation? oracle error?)
```

### 9.6 Runbook: Full Redeployment

```bash
cd ~/k8s/perp-dex

# Tear down (preserves secrets and configmaps)
kubectl delete -f 10-ingress.yaml
kubectl delete -f 09-frontend.yaml
kubectl delete -f 08-market-maker.yaml
kubectl delete -f 07-oracle-updater.yaml
kubectl delete -f 06-keeper-bots.yaml
kubectl delete -f 05-dlob-ws.yaml
kubectl delete -f 04-dlob-api.yaml
kubectl delete -f 03-dlob-publisher.yaml
kubectl delete -f 02-redis.yaml

# Rebuild images if code changed
./deploy.sh build

# Redeploy in order
./deploy.sh deploy
```

---

## Revision History

| Date | Change |
|------|--------|
| 2026-02-27 | Initial version |
