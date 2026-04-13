# Social Media Posts

## Twitter/X (280 chars)

```
ZFS has been hiding a superpower: user properties.

com.zed:version=1.4.2

It's a replicated KV store. It travels with snapshots. It IS your deployment state.

We just wrote the DSL to use it.

Zed: because your filesystem was a database all along.

github.com/[repo]
```

---

## Bluesky (300 chars)

```
Everyone's building databases on top of filesystems.

ZFS: "I literally AM a database."

- User properties = key-value store
- Snapshots = consistent state
- zfs send/recv = replication
- Rollback = O(1), atomic

Zed is just an Elixir DSL that finally listens to what ZFS has been saying for 20 years.
```

---

## LinkedIn

```
For 20 years, ZFS has been trying to tell us something. We weren't listening.

"I have user properties."
"They replicate with snapshots."
"They travel with zfs send/receive."
"I am literally a transactional, replicated key-value store."

We built etcd instead. And consul. And stored Terraform state in S3. And invented 47 ways to track "what version is deployed where" — all while sitting on a filesystem that already knew.

Zed is an apology to ZFS.

It's an Elixir DSL that treats ZFS as what it actually is: the deployment database.

$ zfs get all tank/apps/trading | grep com.zed

com.zed:version      1.4.2
com.zed:deployed_at  2024-04-12T19:25:00Z
com.zed:managed      true

Snapshot = backup of data AND state
Replicate = data AND state travel together
Rollback = atomic, O(1), no reconciliation

The deployment state IS the filesystem metadata. There is no drift because there is no separate state.

We didn't invent anything. We just stopped ignoring what ZFS has been offering since 2005.

~2,000 lines of Elixir. Apache 2.0. PRs welcome.

(Especially from the illumos/SmartOS crowd — you understood this before anyone.)

#zfs #elixir #freebsd #illumos #opensource #devops
```
