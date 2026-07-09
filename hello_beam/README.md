# hello_beam

Path C3's smoke-fixture BEAM release. Purpose-built tiny app to prove
Zed's jail-contained-app deployment pipeline with a real mix release
(not the shell stub of Path C1/C2). Not intended to run anything
useful — it boots a distributed BEAM node and stays up.

## Build

```sh
cd hello_beam
MIX_ENV=prod mix release
# → _build/prod/rel/hello_beam/
```

Or use `scripts/build-real-release.sh` from the zed root to tar it
into `/var/tmp/zed-smoke/hello_beam-0.1.0.tar.gz`.

## Boot requirements

`config/runtime.exs` calls `System.fetch_env!/1` on `RELEASE_NODE`
and `RELEASE_COOKIE`. Zed writes those into `/var/db/zed/hello_beam.env`
inside the jail at deploy time; the rc.d script sources it.
