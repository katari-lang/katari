# Security Policy

## Reporting a vulnerability

Please report security issues **privately** rather than opening a public issue.

- Use GitHub's [private vulnerability reporting](https://github.com/katari-lang/katari/security/advisories/new) for this repository, or
- email **yamanasy.kap@gmail.com** with `katari security` in the subject.

Include what you need to make the problem reproducible: the version (`katari --version`, or the runtime's
`/api/v1/health`), the component (compiler, CLI, runtime), and the smallest input or configuration that shows
it. A proof of concept helps but is not required — a clear description of the mechanism is enough.

You should get an acknowledgement within a few days. Katari is maintained by one person, so please treat any
timeline as best-effort rather than a guarantee. If you plan to publish, tell us when, and we will try to
have a fix out first.

## Supported versions

Katari is pre-1.0. Only the latest released version receives fixes; there are no maintenance branches.

## What is in scope

The compiler, the CLI, the runtime server, the admin console, and the published packages under
`@katari-lang/*`.

Two things are **by design** rather than vulnerabilities, and are worth stating plainly because they look
alarming otherwise:

- **Deploying a snapshot is arbitrary code execution on the runtime host.** A snapshot carries an FFI sidecar
  bundle — opaque JavaScript the runtime writes to disk and runs. Anyone holding `KATARI_API_KEY` can
  therefore run code on the runtime. That is what a language runtime is; treat the API key as equivalent to
  shell access.
- **A program can make outbound HTTP requests.** That is `http.fetch`'s purpose. What is *not* by design is
  reaching the deployment's internal network or the cloud metadata service, and the runtime blocks those by
  default — see the egress guard in [`docs/deploying.md`](docs/deploying.md).

## Known limitations

These are understood gaps rather than undiscovered ones. Reports that restate them are still welcome, but
they will not be a surprise.

- **An FFI sidecar runs as the same OS user as the runtime.** Its environment is restricted to a scoped,
  short-lived capability token, but on Linux a process can read `/proc/<parent pid>/environ`, so a determined
  FFI handler can still recover whatever the runtime process itself was *started* with. Supplying secrets via
  the `*_FILE` variables (see `docs/deploying.md`) keeps them out of that environment entirely; running the
  sidecar under its own user or in its own container is the real fix and is not implemented yet.
- **One runtime process per database.** The engine has no cross-process coordination, so the runtime takes a
  Postgres advisory lock at boot and refuses to start if another holds it. Horizontal scaling is not
  supported.
- **Capability URLs put their token in the path.** `/inbound/<token>` and `/mcp/<token>` are unguessable, and
  the runtime redacts them from its own logs — but a load balancer's access logs record full paths. Treat
  such a log bucket as secret-bearing.
- **Capability tokens have no expiry and no revocation of their own.** An `/inbound` or `/mcp` URL stays valid
  for as long as the `webhook.inbound` or `mcp.serve` call that minted it is running; ending that call, or
  cancelling its run, is the only way to revoke it. Tokens are stored in the database as-is, so a database
  backup holds every live URL. There is no per-token quota and no replay protection beyond the runtime-wide
  rate limit.
- **A program's work is not bounded.** A loop whose iterations never suspend keeps its own project busy
  indefinitely. The engine yields to the event loop every 1,000 steps, so the API, timers, and other projects
  keep running, but nothing stops the loop itself short of cancelling the run. Fan-out (fibers, delegation
  depth) has no cap either.
