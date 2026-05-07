# Clean Rollout Results (2026-05-07)

Full R1-R5 runbook executed in a single pass on clean state.

```
R1: ✓ bootstrap          — 8 slots, fingerprints on both Macs
R2: ✓ distribution       — 15ms RPC round-trip, 2-node cluster
R3: ✓ single-host        — 42ms converge (dataset + snapshot)
R4: ✓ two-host           — 100ms coordinated converge (248 + 247)
R5: ✓ P0 fix holds       — 100ms chaos test, rollback destroys created datasets
```

## Final ZFS state

mac-248 (`mac_zroot/zed-test`):
- `rollout-app` — R3 single-host converge
- `twohost-248` — R4 coordinated converge
- `zed/secrets` — Bootstrap (encrypted, AES-256-GCM)

mac-247 (`zroot/zed-test`):
- `twohost-247` — R4 coordinated converge (created via RPC)
- `zed/secrets` — Bootstrap (encrypted, AES-256-GCM)

No chaos artifacts — `chaos-good` (mac-248) destroyed by
coordinated rollback when `chaos-bad` (mac-247) failed.

## Protocol verified

TLA+ spec (CoordinatedConverge.tla v2): 172 states, 0 errors.
Three invariants hold: NoPartialState, NoConvergedWithFailure,
RollbackMatchesAction.
