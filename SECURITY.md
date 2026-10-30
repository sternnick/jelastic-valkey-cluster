# Security Policy

## Reporting a vulnerability

Please report security issues **privately**, through this repository's Security tab: **Report a
vulnerability**. Do not open a public issue for anything that is exploitable.

You should get a first response within a few working days. If the report is confirmed, a fix is
released as a new tag, and the release notes say so.

## What this project is, and what that implies

This is a deployment manifest plus the script it runs. Installed, it starts a multi-node Valkey
cluster on a hosting platform. Treat it as infrastructure code, not a library:

- **It must not be installed in an environment you intend to keep.** A failed install leaves nodes
  and volumes; clean up from the dashboard.
- **The generated password appears once, in the install result text.** The dashboard logs that text.
  Rotate it after the install if the install log is retained anywhere you do not control.
- **The nodes listen on the environment's private network.** No public port is opened by this
  manifest. Verify that claim from the dashboard's network view before you rely on it.
- **The cluster bus (command port + 10000) must be reachable between nodes.** Nothing here can
  attest for the platform above the container. `probes/network-probe.jps` measures it.
- **TLS between nodes is not configured by this manifest**, and Valkey's default cluster bus is
  unencrypted. Read [Known limitations](README.md#known-limitations) before putting anything
  sensitive in it.

## How this repository keeps itself clean

The history of this project includes real deployments, and real deployments produce real
identifiers: account paths, node ids, environment ids, the name of a hosting provider, absolute
paths from somebody's laptop. Those are not documentation, they are exposure.

Three rules, enforced rather than requested:

1. `sh tests/validate.sh` scans every tracked file, and the document `sbom.py` would generate, using
   one shared rule set (`IDENTIFIERS` in `sbom.py`): no email address, no platform node or
   environment id, no home path, no ssh remote, no GitHub Pages or codespace URL (both encode a
   login), no noreply domain. On top of that, any github URL naming *this* repository must use the
   `<owner>` placeholder, and any other github owner must be in a declared `UPSTREAM_OK` list - so
   naming `valkey-io` or `jelastic-jps` as a dependency is normal, and naming an account is not.
   Proved by mutation: a concrete account URL, a Pages URL, a node id and a stale logo each fail the
   run; an upstream reference passes. The boundary that is *not* covered is a bare path in prose with
   no host in front of it - say "this repository", not "/someone/somewhere".
2. Narrated evidence names the *mechanism* and the *date*, never the account. "A probe node reported
   `JELASTIC_PORTS=,${globals.clusterBusPort}` on 2026-10-27" is a fact anyone can check. A node id
   is a pointer into somebody's infrastructure.
3. `baseUrl` is a `<owner>/<repo>` placeholder, deliberately. It is the one line every installer must
   edit anyway, and it is the reason no upstream account path ever needed to be committed here. The
   `logo:` line follows the platform's own convention and is repository-relative
   (`/images/valkey-cluster.png?raw=true`), so it cannot reintroduce an account either - and the
   check resolves it, which is the guard for the bug this repository actually shipped once: a logo
   pointing at a file that was never committed.

`validate.sh` also checks the things that cost an install to discover: that the two manifests pin the
same ref, that no settings default contains a placeholder, that no value reaching a server directive
can arrive as a YAML boolean, and that every command line the manifest emits is one the script
actually parses.

The project's origin is recorded once, without naming anyone:
[Where the evidence came from](README.md#where-the-evidence-came-from).
