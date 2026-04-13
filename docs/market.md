# Zed Market Analysis

## How Many Companies Fit in ≤50 Nodes?

### Business Size Distribution

| Business Size | % of All Businesses | Typical Server Count |
|---------------|---------------------|----------------------|
| Micro (1-9 employees) | ~70-75% | 0-2 |
| Small (10-49 employees) | ~15-20% | 2-10 |
| Medium (50-249 employees) | ~5-8% | 10-50 |
| Large (250-999 employees) | ~1-2% | 50-200 |
| Enterprise (1000+) | ~0.5% | 200-5,000+ |
| Hyperscale (FAANG) | ~0.001% | 100,000-4,000,000 |

### Companies That Fit ≤50 Nodes

**~95-98% of all businesses worldwide.**

But more usefully, of companies with *meaningful IT infrastructure*:

```
┌────────────────────────────────────────────────────────────────┐
│  Companies with servers/VMs (not just laptops)                 │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  ████████████████████████████████████████░░░░░░░  ~85%  ≤50    │
│  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░██████░  ~12%  50-500 │
│  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░██  ~3%  500+   │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### Real-World Reference Points

| Company Type | Employees | Servers |
|--------------|-----------|---------|
| Local dev shop | 10-20 | 2-5 |
| Trading firm | 50-200 | 10-30 |
| Regional bank | 500-2000 | 100-500 |
| SaaS startup | 50-500 | 5-50 (mostly cloud) |
| Mid-size enterprise | 1000-5000 | 200-1000 |
| Fortune 500 | 10,000+ | 1,000-50,000 |

## Zed's Sweet Spot

**5-50 hosts covers:**
- ~85% of companies with on-prem infrastructure
- Most trading firms, SaaS backends, regional businesses
- Anyone not running hyperscale (which is nearly everyone)

**The 3% who need K8s:**
- Already have dedicated platform teams
- Already invested in the complexity
- Not your market anyway

## Scaling Characteristics

### Where Zed Scales Well

| Dimension | Why |
|-----------|-----|
| **Hosts: 1-50** | Erlang distribution handles this easily. Cookie auth, `:rpc.call` is fast. |
| **Apps per host: 100s** | ZFS properties are O(1) lookup per dataset. No central index to bottleneck. |
| **Rollback speed** | O(1) regardless of data size. 1TB rollback = same as 1MB. |
| **Replication** | `zfs send -i` is incremental. Only changed blocks travel. |
| **State queries** | `zfs get` is local, in-memory after pool import. No network hop. |

### Where Zed Hits Limits

| Dimension | Limit | Why |
|-----------|-------|-----|
| **Hosts: 100+** | Erlang mesh topology = N² connections | Could shard into clusters |
| **Cross-datacenter** | `zfs send` over WAN is slow | Need async replication, not sync |
| **Central inventory** | No "list all apps across all hosts" | Each host knows itself only |
| **Secrets** | Properties are readable by root | Need envelope encryption |

### Compared to etcd/consul at Scale

```
etcd at 1000 nodes:
  - 3-5 node etcd cluster becomes SPOF
  - Every state change = Raft consensus round-trip
  - Watch streams multiply load
  - Separate backup/restore infrastructure

Zed at 1000 nodes:
  - No central cluster to fail
  - State changes are local (no consensus needed)
  - BUT: no global view without querying each host
  - BUT: coordination requires explicit fan-out
```

## Target Markets

### Ideal Fit
- Trading firms (10-20 servers, low latency requirements)
- SaaS backends (handful of beefy machines)
- Edge deployments (many independent nodes)
- FreeBSD/illumos shops (already have ZFS)
- Erlang/Elixir teams (native tooling)

### Not a Fit
- Hyperscalers (use K8s, you have the team)
- Multi-region with strong consistency needs
- Environments without ZFS
- Teams that want GUI dashboards

## Sources

- [Statista - SMEs worldwide](https://www.statista.com/statistics/1261592/global-smes/)
- [OECD - Enterprises by size](https://www.oecd.org/en/data/indicators/enterprises-by-business-size.html)
- [UN - MSMEs represent 90% of businesses](https://www.un.org/en/observances/micro-small-medium-businesses-day)
- [C&C Tech - Data center server counts](https://cc-techgroup.com/how-many-servers-in-a-data-center/)
- [RackSolutions - Server counts](https://www.racksolutions.com/news/blog/how-many-servers-does-a-data-center-have/)
