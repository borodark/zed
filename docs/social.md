# Social Media Posts

## Twitter/X (140 chars)

```
ZFS properties = deployment state that travels with snapshots. No external DB needed.

https://github.com/borodark/zed
```

---

## Bluesky (300 chars)

```
What if your filesystem already knew what was deployed?

ZFS user properties:
- Key-value store in metadata
- Replicate with snapshots
- Travel with zfs send/receive

Zed: an Elixir DSL that finally uses them.

https://github.com/borodark/zed
```

---

## LinkedIn

```
What if your filesystem already knew what was deployed to it?

ZFS has had user properties since 2005. They're a key-value store that:
- Lives in filesystem metadata
- Replicates with snapshots
- Travels with zfs send/receive

We just... weren't using them.

$ zfs get all tank/apps/trading | grep com.zed

com.zed:version      1.4.2
com.zed:deployed_at  2024-04-12T19:25:00Z
com.zed:managed      true

That's your deployment state. No external database. No state file in S3. No cluster to maintain.

Snapshot your app? State comes with it.
Replicate to another host? State arrives intact.
Rollback? Atomic, O(1). Data and state together.

We built Zed — an Elixir DSL that treats ZFS as what it quietly always was: a transactional, replicated state store.

~2,000 lines of code. Apache 2.0. Works today on FreeBSD.

Next up: GPU cluster support. Imagine ML checkpoints as ZFS snapshots. Model distribution via zfs send. Training state in filesystem properties. No MLflow, no DVC — just the filesystem you already have.

If you're running BEAM apps on FreeBSD or illumos, or you're curious about ZFS beyond "nice checksums," take a look.

PRs welcome. Especially from the illumos/SmartOS folks who understood this before anyone.

#zfs #elixir #freebsd #opensource #devops #mlops
```
