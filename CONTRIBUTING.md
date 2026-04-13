# Contributing to Zed

PRs are welcome!

## Areas Where Help is Needed

### Phase 5 — Cluster + Polish
- [ ] `cluster` verb for distributed Erlang topology
- [ ] Secret resolution (envelope encryption for ZFS properties)
- [ ] Burrito binary builds (single executable)

### Phase 6 — illumos Parity
- [ ] SMF manifest generation
- [ ] `zone` verb (zonecfg/zoneadm)
- [ ] illumos-specific testing

### Phase 7 — GPU Cluster (Vision)
- [ ] `node` verb for hardware capability declaration
- [ ] GPU detection (nvidia-smi, Metal, ROCm)
- [ ] `model` verb for ML artifact tracking
- [ ] `job` verb for distributed job state
- [ ] Checkpoint as ZFS snapshot
- [ ] Smart routing (match model requirements to node capabilities)
- [ ] Linux + OpenZFS support
- [ ] See [docs/gpu-cluster.md](docs/gpu-cluster.md)

### Improvements
- [ ] mDNS/DNS-SD agent discovery
- [ ] Web dashboard (LiveView?)
- [ ] Metrics export (Prometheus)
- [ ] More health check types (TCP, HTTP endpoints)
- [ ] Release tarball unpacking + symlink (currently stubbed)

### Documentation
- [ ] More examples in `lib/zed/examples/`
- [ ] Video walkthrough
- [ ] Comparison guides (vs Ansible, vs K8s, vs Nomad)

## How to Contribute

1. **Fork & clone**
   ```sh
   git clone https://github.com/YOUR_USERNAME/zed.git
   cd zed
   mix deps.get
   ```

2. **Run tests**
   ```sh
   mix test                      # Unit tests (run anywhere)
   mix test --include zfs_live   # ZFS tests (requires FreeBSD + ZFS)
   ```

3. **Make changes**
   - Follow existing code style (pattern matching, pipes)
   - Add tests for new functionality
   - Update docs if needed

4. **Submit PR**
   - Clear description of what and why
   - Link to relevant issue if exists

## Development Setup

### Minimal (Linux/macOS)
```sh
mix deps.get
mix test  # 37 unit tests pass without ZFS
```

### Full (FreeBSD with ZFS)
```sh
# In a jail with delegated ZFS dataset
zfs create tank/zed-test
zfs allow -ldu $USER create,destroy,mount,snapshot,rollback tank/zed-test

mix test --include zfs_live  # 58 tests total
```

### Multi-host Testing
See [docs/MULTI_HOST_TEST.md](docs/MULTI_HOST_TEST.md) for setting up agent jails.

## Code Style

- Pattern matching over conditionals
- Pipes (`|>`) for data transformation
- `with` for happy-path chains
- No unnecessary abstractions
- Tests for public functions

```elixir
# Good
def process(data) do
  data
  |> validate()
  |> transform()
  |> persist()
end

# Good
with {:ok, validated} <- validate(data),
     {:ok, transformed} <- transform(validated) do
  persist(transformed)
end
```

## Architecture Overview

```
lib/zed/
├── dsl.ex           # Macro DSL (use Zed.DSL)
├── ir.ex            # Intermediate representation
├── ir/validate.ex   # Compile-time validation
├── converge.ex      # Main convergence API
├── converge/
│   ├── diff.ex      # Desired vs actual state
│   ├── plan.ex      # Ordered execution plan
│   └── executor.ex  # Execute steps
├── zfs/
│   ├── dataset.ex   # Dataset operations
│   ├── property.ex  # com.zed:* properties
│   ├── snapshot.ex  # Snapshot operations
│   └── replicate.ex # zfs send/receive
├── platform/
│   ├── freebsd.ex   # rc.d, jails
│   ├── illumos.ex   # SMF, zones (stub)
│   └── linux.ex     # Dev/test only
├── agent.ex         # Per-host GenServer
└── cluster.ex       # Multi-host coordination
```

## Questions?

Open an issue or start a discussion. We're friendly.

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
