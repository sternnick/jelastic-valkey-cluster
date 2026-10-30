# Valkey Cluster for Jelastic

A complete application JPS manifest for [Jelastic Cloud](https://jelastic.com/) (Virtuozzo
Application Platform). Installing it creates an environment whose `nosqldb` node group runs a real
Valkey cluster - 16384 hash slots sharded across the nodes, formed during the install.

It is not an add-on. It does not attach to something that already exists; it is the thing itself.

There is no Jelastic-certified Valkey stack, so the nodes come from the official `valkey/valkey`
Docker image and everything Valkey-specific lives in the startup flags and in one script.

Security reports and this project's exposure rules: [SECURITY.md](SECURITY.md).

## Contents

```
manifest.jps                  the application: topology, startup flags, cluster bootstrap
scripts/init-cluster.sh       prep / form / check, run inside the containers
probes/network-probe.jps      a separate one-click install: 3 throwaway nodes and a TCP matrix
probes/probe.sh               the listener and the connector the probe runs
tests/validate.sh             offline syntax and invariant checks (no Jelastic needed)
tests/test_invocations.sh     runs the manifest's own command lines against the script
tests/test_tags.sh            asks the registry whether the offered tags exist and are Alpine
tests/stub/                   valkey-cli and ip fixtures, so the above needs no cluster
sbom.py                       writes sbom.json (CycloneDX 1.5): the image tags and refs this
                              repository actually pins - generated, never committed
```

## Requirements

| | |
|---|---|
| Platform | Jelastic Cloud 8.x (Virtuozzo Application Platform) able to pull a custom Docker image |
| Architecture | amd64 only |
| Container base | must be on the platform's [supported OS list](https://www.virtuozzo.com/application-management-docs/container-image-requirements/); see [Base image](#which-base-image-is-allowed) |
| Nodes | 3 minimum - below that it is not a cluster |
| Clients | cluster-aware (`valkey-cli -c`, or `Cluster` mode in a client library) |
| Network | TCP between nodes on 6379 and 16379; `probes/` measures it before you have to guess |

## Install

1. **Host these files somewhere the nodes can fetch them.** Fork or mirror this repository to your
   own account. The nodes download their scripts over HTTP, so the repository URL is part of the
   installation, not decoration.
2. **Set `baseUrl` in both manifests** - one line each in `manifest.jps` and
   `probes/network-probe.jps`. Replace the `<owner>/<repo>` placeholder with your account and
   repository, and keep the ref pinned to a tag or commit:

   ```
   baseUrl: https://raw.githubusercontent.com/<your-account>/<your-repo>/v1.0.4
   ```

   Skipping this fails the install at the `wget` step, which is the clearest possible error; the
   subtler version of the same mistake is pointing it at a branch, described in
   [Absolute `baseUrl`](#absolute-baseurl-and-why-the-ref-is-pinned).
3. **Import the manifest URL** from your dashboard's add-on / custom-install flow. The menu naming
   differs by hosting provider; the thing it wants is the raw URL of `manifest.jps`.
4. **Choose topology and settings**, then install. Three steps run: prep on every node, form once,
   check on the master.

Access from inside the environment:

```sh
valkey-cli -c -h <node-address> -p 6379 -a '<password>' cluster info
valkey-cli -c -h <node-address> -p 6379 -a '<password>' cluster nodes
```

The generated password is reported once, in the install result text. It reaches the server through
the node environment (`--requirepass`), never through a command line in the install log.

## What it creates

```
nosqldb (count: 3)   valkey/valkey:<tag>, one container per node
  node A  6379 clients   16379 cluster bus   slots 0-5460
  node B  6379            16379              slots 5461-10923
  node C  6379            16379              slots 10924-16383
```

Install runs three steps:

1. `prepNodes` - `cmd [nosqldb]` on every node: confirm `cluster-enabled` really took effect, set
   `cluster-node-timeout` and the tunables the settings screen offers, and announce the address a
   peer can reach (`cluster-announce-ip/port/bus-port`).
2. `formCluster` - a `script:` step reads the node addresses from
   `jelastic.env.control.GetEnvInfo('${env.envName}', session)` and emits one `cmd[nosqldb]`
   carrying the peer list. Every node runs the same command; the node whose address sorts first
   performs `valkey-cli --cluster create`, the others wait for `cluster_state:ok` and report.
3. `checkCluster` - `CLUSTER INFO` and `CLUSTER NODES` on the master, with a nonzero exit if any
   slot is unserved.

Three nodes means **3 primaries and no replicas**. Lose one node and the slots it owned are
unavailable until it comes back - a different failure shape from a replicated setup, and the reason
6 nodes is offered.

### Settings

| Field | Default | Notes |
|---|---|---|
| `valkeyTag` | `9.1.3-alpine3.24` | every option is an Alpine-based tag; see [base image](#which-base-image-is-allowed) |
| `nodeCount` | 3 | 3, 4, 5 primaries; or 6 for 3 primaries + 3 replicas |
| `replicasPerPrimary` | 0 | `1` needs 6 nodes - the pair is validated in the script, not discovered at install time |
| `cloudlets` | 16 | per node |
| `maxMemory` | `1024mb` | keep it comfortably under the node's memory |
| `evictionPolicy` | `noeviction` | writes error when full |
| `persistent` | `yes` | AOF; a `yes`/`no` list and deliberately not a checkbox |

## Design decisions

### Absolute `baseUrl`, and why the ref is pinned

`${baseUrl}` defaults to a URL relative to wherever the manifest was imported from. Left implicit,
importing from a CDN means the nodes fetch their scripts from the CDN too, and that copy can lag the
repository. Measured on 2026-10-27: a commit was live on `raw.githubusercontent.com` while
`cdn.jsdelivr.net/...@main` still served the previous version of the same file, and a random query
string (`?_r=99`, `?cb=...`) did not bust it - only a commit or tag reference (`@3ff2234`) returned
the new bytes.

So the manifest declares an absolute `baseUrl` pointing at raw, and the `wget` keeps a `?_r=` buster
for the raw path's own caching. `tests/validate.sh` refuses a branch ref and refuses a cache-buster
inside a pinned URL, because the two claims contradict each other. For a production install, pin the
ref to a tag: an immutable reference is the only version of this that cannot serve two generations
at once.

### Which base image is allowed

The platform unpacks a custom Docker image's filesystem into a Virtuozzo system container, so the
image's base OS has to be one the platform ships a template for. The published list:

| Distribution | Version accepted | VZ template | Since platform |
|---|---|---|---|
| AlmaLinux | 9 | `almalinux-9-x86_64` | 8.3.1 |
| Alpine | 3 | `alpine-3.x-x86_64` | - |
| CentOS | 7 / 8 | `centos-7-x86_64` / `almalinux-8-x86_64` | 8.2.4 (8) |
| **Debian** | **12** | `debian-12.0-x86_64` | **8.4.1** |
| RHEL | 7 | `centos-7-x86_64` | - |
| Ubuntu | 18.04 / 20.04 / 22.04 / 24.04 | `ubuntu-<ver>-x86_64` | 8.11.2 (24.04) |

Architecture is amd64 only, the list is "subject to change", and anything off it needs the vendor:
*"In order to run containers of another type, please, contact us to negotiate the appropriate OS
support."*

Debian is therefore **not** excluded - Debian 12 is on the list, Debian 13 is not, and that is the
whole reason `valkey/valkey:latest` failed on the first attempt:

```
OS debian:13 ... is not supported
```

Upstream publishes 321 tags in three families: 176 Alpine, 49 `-trixie` (Debian 13) and 27
`-bookworm` (Debian 12, newest `8.1.3`), with `latest` and the bare version tags pointing at
Debian 13. Read out of the registry, the amd64 config history of the tags offered here:

| Tag | Base layer in the image history | Base |
|---|---|---|
| `latest` | `# debian.sh --arch 'amd64' out/ 'trixie' '@1792531975'` | Debian 13 |
| `9.2-alpine3.24` | `ADD alpine-minirootfs-3.24.2-x86_64.tar.gz` | Alpine 3.24.2 |
| `9.1.3-alpine3.24` | `ADD alpine-minirootfs-3.24.3-x86_64.tar.gz` | Alpine 3.24.3 |
| `9.1.2-alpine3.24` | `ADD alpine-minirootfs-3.24.2-x86_64.tar.gz` | Alpine 3.24.2 |
| `9.0.7-alpine3.24` | `ADD alpine-minirootfs-3.24.3-x86_64.tar.gz` | Alpine 3.24.3 |
| `8.1.11-alpine3.24` | `ADD alpine-minirootfs-3.24.3-x86_64.tar.gz` | Alpine 3.24.3 |

Alpine is what this manifest ships for a mundane reason: the Debian 12 (`-bookworm`) line stops at
Valkey 8.1.3, so any current release on a Debian base is Debian 13, which is off the list. The tags
pin the Alpine release too (`-alpine3.24`, not `-alpine`) so the base OS cannot move underneath a
running deployment. `tests/validate.sh` refuses an offered tag that is not on a supported base, and
`tests/test_tags.sh --deep` re-reads the base of each tag from the registry.

If a Debian or AlmaLinux base is ever required, the supported route is to build it: the vendor's own
recipe starts `FROM jelasticdocker/almalinuxbase` (their AlmaLinux 9 base, on Docker Hub) or
`FROM debian:12` with the platform on 8.4.1+, pushed to a registry the platform can read
([building a custom container](https://www.virtuozzo.com/application-management-docs/building-custom-container/)).
Two other documented ways to run software the allowlist does not cover are different products: a
Docker Engine CE / Swarm node (`jelastic-jps/docker-native`, `image: jelastic/docker-ce`), where
ordinary `docker run` takes over and the allowlist stops applying, or an Elastic VPS with Valkey
installed by hand.

### About `9.2-alpine3.24`, the testing option

It is a pre-release. Its config reads `ENV VALKEY_VERSION=9.2.0-rc1`, the image was created
2026-09-21 - five weeks before the patch set that came out on 2026-10-26 (`9.1.3`, `9.0.7`,
`8.1.11`, `8.0.12`, `7.2.15`) - and it carries Alpine 3.24.2 rather than 3.24.3. `9.2-alpine3.24`
and `9.2.0-rc1-alpine3.24` are the same image (identical creation timestamp), and there is no
`9.2.0-alpine3.24` tag: the registry's 404 is the confirmation that 9.2.0 has not been released.
Use it to try the 9.2 line; for anything that has to stay up, pick `9.1.3-alpine3.24`.

The 9.2.0-rc1 source still declares `cluster-enabled`, `cluster-config-file`, `cluster-port` and the
`enable-*` options as `IMMUTABLE_CONFIG`, and `cluster-node-timeout`,
`cluster-announce-ip/-bus-port`, `requirepass` and `masterauth` as runtime-settable, which is
everything this manifest and script depend on - so the flags below are valid on both.
`9.1.2-alpine3.24` stays listed because it is a tag a live install has actually used.

### Custom Docker image, because there is no certified Valkey stack

Jelastic ships a Redis engine (`nodeType: redis`, 7.2.x, BSD-era) and nothing for Valkey. A
`nodeType` cannot be invented from a manifest, so the node is declared with
`image: valkey/valkey:<tag>` and everything Valkey-specific moves into the startup flags and the
script. That is also what makes this portable: the same manifest works on any Jelastic 8.x that can
pull an image.

### Startup flags, not `valkey.conf`

`cluster-enabled` and `cluster-config-file` are `IMMUTABLE_CONFIG` in the Valkey source, so
`CONFIG SET` cannot touch them; they have to be on the command line. A Docker node on Jelastic is
`image + node env`, and the official image's entrypoint ends with `exec "$@" $VALKEY_EXTRA_FLAGS`,
which makes the node's environment the durable place for a startup value.

Editing a config file and restarting - the trick the official Redis add-ons use - has nothing to
edit here, and a restart is the wrong tool anyway: restarting a node that is already in a formed
cluster starts a failover clock.

### Both ports open

The bus port is command port + 10000 (`cluster-port` defaults to 0, documented as that offset), so
`JELASTIC_PORTS: '6379,16379'`. With only 6379 open the nodes start happily, gossip never finishes,
and `CLUSTER INFO` says `cluster_state:fail` with slots in `fail` state - a cause that is invisible
from the outside.

### One node forms the cluster

`cmd[nosqldb]` runs in parallel on every node, and three simultaneous `--cluster create` calls
against the same three nodes produce three partially configured clusters and a `CLUSTER DOWN` that
looks like a Valkey bug. So the script elects: the lowest address forms, everyone else waits for
`cluster_state:ok`. Deterministic by address rather than "the master", because after a rebuild the
node you thought was master may not be.

## Failure modes observed in deployment

Each of these cost an install. They are recorded with the evidence that identified them, because
the shape of the failure is the part that is hard to find again.

### The first deployed node never started a server, and the log said why

`/var/log/run.log` on the first deployment:

```
*** FATAL CONFIG FILE ERROR (Version 9.1.3) ***
Reading the configuration file, at line 12
>>> 'appendonly "true"'
argument must be 'yes' or 'no'
```

The `persistent` setting was a checkbox, a checkbox arrives as `true`/`false`, and Valkey's
`appendonly` takes only `yes`/`no`. One unparseable argument is not a warning to this server: it
exits before binding a port. `netstat` on that node showed nothing on 6379, no process, no crash
loop - so there was no cluster to form, and nothing on the platform side was wrong.
`JELASTIC_PORTS` had expanded correctly to `6379,16379`, `iptables` was `-P INPUT ACCEPT`, and the
probe environment in the same account had already proved node-to-node TCP on 6379 **and** 16379
between all three nodes.

The setting is a `yes`/`no` list now, and `prep` translates a boolean and refuses a word it cannot
map, so the same mistake fails a test instead of a deployment.

The fix for that failure then failed the same way once, for a reason worth writing down. v1.0.2
replaced the checkbox with a list whose default was written `default: yes` - and in YAML 1.1 that is
not the word yes, it is the boolean `True`. The install API reported `"persistent": true`, the flag
reached the server as `--appendonly true`, and the redeployed node wrote the same
`argument must be 'yes' or 'no'` into `/var/log/run.log`. v1.0.3 quotes the value, and
`tests/validate.sh` checks the **parsed** type of every field default and list key, so a word YAML
silently turns into a boolean fails the commit. Verified by mutation: un-quoting it again produces
two FAILs.

### Placeholders expand in some places and not in others

An earlier revision of this README blamed the failure above on placeholders not expanding inside
`env:`. That was wrong, and the node disproved it: the container received a fully expanded
`VALKEY_EXTRA_FLAGS` and `JELASTIC_PORTS=6379,16379`.

What is true - and what a probe node's `JELASTIC_PORTS=,${globals.clusterBusPort}` showed directly -
is that **placeholders are not expanded inside a settings default**. They do expand in `cmd` and
`script` steps and in node env values. Both facts are enforced by `tests/validate.sh`: no field
default may contain one, and `env:` keeps literal ports for the same reason.

### Node discovery, three attempts

- A node placeholder for the group's addresses produced an install that ran against a peer list
  containing the literal text `${nodes.nosqldb.address}`. The selector form was wrong, not the idea:
  the working form is `${nodes.nosqldb.join(address,)}`, which the official
  [`jelastic-jps/redis-cluster`](https://github.com/jelastic-jps/redis-cluster) uses to build its
  `--cluster create` argument, and `${*.join()}` is documented in the placeholders reference. (An
  earlier revision of this README claimed no "all addresses of a group" form existed. That was
  wrong, and it is corrected here.) This manifest uses a `script:` step instead of the placeholder,
  because the same step also needs each node's `id` to address its container, and one API call
  returns both.
- Letting each container discover its peers with DNS does not work. Jelastic names a node
  `node<id>-<env domain>`, which is perfect for one node and useless for enumeration: nothing in the
  container lists its siblings, and there is no SRV record to ask.
- What works is what the official cluster manifests already do for Galera seeds
  ([`jelastic-jps/mysql-cluster`](https://github.com/jelastic-jps/mysql-cluster)): a `script:` step
  calling `jelastic.env.control.GetEnvInfo(envName, session)`, filtering `resp.nodes` by `nodeGroup`,
  reading `address`, and returning the assembled list inside `onAfterReturn`. Platform metadata
  knows the topology; the container does not.

### `--role=prep` versus `--role prep`

The first live install died on `unknown argument: --role=prep`. The manifest passed the role with
`=` while the argument parser matched the bare `--role` and read the value from `$2`. The parser now
accepts both spellings for every option, and the manifest uses the two-word form anyway, because a
CDN-cached copy of one side cannot be recalled when the other changes.

`tests/test_invocations.sh` reads the commands out of `manifest.jps`, substitutes the placeholders,
and executes them against the script in the working tree, so the seam is covered in both directions.

The `not a tty` line that came with that report is not from this script: nothing in it runs a CLI
without a subcommand, and `valkey-cli` documents tty behaviour for output formatting only. Stdin is
redirected from `/dev/null` at the top of the script anyway, so no client can decide to become
interactive when the platform runs the command without a terminal.

### A second bug, found by that same test rather than by a cluster

The form step asked each peer for `cluster_enabled` inside `CLUSTER INFO`. That field is not in
`CLUSTER INFO` - it is emitted by `INFO` (the format string lives in `server.c`, not in the cluster
reply in `cluster_legacy.c`), so every peer would have been declared "started without the cluster
flags". The check now reads the directive itself, `CONFIG GET cluster-enabled`.

### `cluster-enabled` is not runtime-settable

A first version of the script did `CONFIG SET cluster-enabled yes`, got `ERR CONFIG SET failed`, and
then `--cluster create` failed with a message about cluster support being disabled. Reading
`IMMUTABLE_CONFIG` in the source before writing the script would have saved the attempt, which is
the argument for checking the source rather than a blog post.

## How this compares to the official Redis cluster

`jelastic-jps/redis-cluster` is the closest official thing to this project - a Redis cluster, on the
same platform, formed the same way (`redis-cli --cluster create` from one node). Reading it line by
line is worth doing before blaming either Valkey or the platform, because it shows which capabilities
the official package gets from the platform and which this project has to provide itself.

| | official `redis-cluster` | this repository |
|---|---|---|
| node | `nodeType: redis` (certified container) | `image: valkey/valkey:<tag>` (custom container) |
| clustering feature | `cluster: true` - the platform's own auto-clustering hook | none exists for custom images; the script does it |
| node addresses | `${nodes.nosqldb.join(address,)}` / `.join(id,)` in the manifest | the same data, read in a `script:` step |
| `redis-cli --cluster create` | yes, in `addons/auto-clustering/auto-cluster.jps` | yes, in `form` |
| `cluster-announce-ip` | set from **`venet0`** (`ip a \| grep -A1 venet0 ...`) and **re-set on every topology event** - scale out, scale in, restart | set once, at container startup, from `ip addr` |
| `JELASTIC_PORTS` | **not set anywhere** in the official manifests | set explicitly (`6379,16379`) |
| cluster bus reachability | never configured: the certified stack's ports are the platform's business | assumed, and now measured before forming |

Two things follow. The first is that `venet0` is where the platform expects a container's routable
address to be - the official package reads that interface explicitly, which is why the announce line
in `form` compares what the node advertises against what the platform API reports, and refuses to
continue when the two disagree. The second is that the official package **re-applies** the announce
address after every topology change, because a redeployed or migrated container can come back with a
different address. This repository does not do that yet, so a scale-out or a migration will need
`prep` to be run again - listed under [limitations](#known-limitations), not hidden.

On the firewall: the platform's own answer, on a 2022 question about exactly this (MinIO cluster,
accepted answer), is that *"Firewall is only supported on official images from Jelastic. When you use
a custom docker image for your node, you won't be able to use the Jelastic Firewall on it. You have
to manually configure the iptables."* If that still holds on a given provider and platform version,
then `JELASTIC_PORTS` installs nothing here - which means it is not what is blocking 16379, and the
question becomes whether anything filters inbound traffic at all. That is a fact about a provider and
a platform version, not about Valkey, and it is measurable: run the probe.

## Measuring the network before blaming the cluster

`probes/network-probe.jps` is a separate one-click install. Import
`https://raw.githubusercontent.com/<owner>/<repo>/<ref>/probes/network-probe.jps`.

It installs three containers from the same image, puts a TCP listener on 6379 and 16379 in each,
proves each node's own listener answers, and then connects every node to every other node on both
ports. No Valkey runs, nothing is exposed publicly. Each node also records `ip addr`, `ip route`,
the addresses it holds, how `JELASTIC_PORTS` reached it and the packet filter, all in
`/var/log/jelastic-probe.log`.

The order is the point. **The self-test runs before the matrix**, because a listener that never
started looks exactly like a blocked port: every cross-node row would read FAIL and the platform
would be accused of its own probe's failure. If the self-test fails, the probe refuses to print a
matrix.

Run the A/B comparison of `JELASTIC_PORTS` by installing the probe twice, as two environments - once
with the `JELASTIC_PORTS` field at its default (`6379,16379`) and once with the field cleared - then
diff the two matrices. A single successful run proves nothing about the firewall: it cannot
distinguish "the variable opened the port" from "nothing filters these nodes at all".

Probe roles, if you are already logged into a node:

```sh
sh probe.sh --role listen    --port 6379 --bus-port 16379   # record + start re-arming listeners
sh probe.sh --role selftest  --port 6379 --bus-port 16379   # prove this node's listener answers
sh probe.sh --role test --peers "ip ip ip" --port 6379 --bus-port 16379
sh probe.sh --role stop      --port 6379 --bus-port 16379   # stop them, by pidfile
```

The probe was run against the real `nc` and `ip` from `valkey/valkey:9.1.3-alpine3.24` (busybox
1.37.0, extracted from the image) on 2026-10-27, and that is what fixed three things in it: that
build listens with `nc -l -p PORT` and rejects `-lt PORT`; it has no `-k`/`-L`, so the listener has
to be a re-arming loop; and a busybox listener can bind IPv6, so `/proc/net/tcp6` has to be read as
well as `/proc/net/tcp` or a live listener is reported as missing.

## Releasing a version

`baseUrl` is pinned to a tag, and both manifests must carry the same one, because the nodes fetch
their scripts over HTTP and a mutable ref means an old script can meet a new manifest.

```sh
# 1. land the change on main
# 2. set version: and the ref in baseUrl in BOTH manifests to the next tag
git commit -a -m 'release <next-tag>'
# 3. tag that commit, then push both
git tag -a <next-tag> -m 'release <next-tag>'
git push <remote> main <next-tag>
```

The tagged manifest's `baseUrl` refers to its own tag, so the manifest and the scripts it fetches can
never come from different generations. Never republish a changed manifest under a tag that already
meant something else: once `v1.0.4` exists, the ref before it has to keep serving exactly the files
it served, or an existing install's next script fetch meets a different generation.
`tests/validate.sh` refuses a branch ref, refuses the two manifests disagreeing, and refuses a result
code that no `responses:` entry explains.

This repository's first published tag is `v1.0.4`. The versions named in the failure notes above
(1.0.1 to 1.0.3) are revisions that were never published as refs here: they are described for what
they taught, and no tag claims to point at them.

## Testing

```sh
sh tests/validate.sh           # offline: syntax, manifest invariants, manifest-vs-script commands
sh tests/test_invocations.sh   # the manifest's own command lines, executed against the script
sh tests/test_tags.sh          # each offered tag is published (network)
sh tests/test_tags.sh --deep   # ...and is really on a supported base, read from the registry
```

`validate.sh` parses `manifest.jps` as YAML, checks the flag/port/count invariants this README
claims, runs `sh -n` over every script, and scans the tracked files so that no account path,
deployment identifier, or local filesystem path can reappear in them. It cannot prove a cluster
forms; it proves the manifest does not contain a typo that would cost an install to discover.

## Verified against

- Valkey 9.1.3 (`valkey/valkey:9.1.3-alpine3.24`), the 9.1.3 source tree, and the same directives
  re-read in the `9.2.0-rc1` source: `cluster-enabled`, `cluster-config-file`, `cluster-port` =
  `IMMUTABLE_CONFIG`; `cluster-node-timeout`, `cluster-announce-ip/port/bus-port`,
  `cluster-preferred-endpoint-type` = `MODIFIABLE_CONFIG`; `valkey-cli --cluster
  create|check|reshard|add-node` and `--cluster-yes/-replicas/-timeout` present in the shipped
  binary.
- Valkey image bases, read from the Docker Hub / registry config history on 2026-10-27: `latest` and
  `-trixie` are Debian 13, the `-alpine`/`-alpine3.24` tags are Alpine 3.24.x. That the platform has
  not certified Debian 13 for custom containers is the platform team's report; the image bases above
  are what was verified here, and `tests/test_tags.sh --deep` re-checks them.
- Cloud Scripting v8.15.1 documentation for `JELASTIC_PORTS`, `nodes` placeholders (`${*.join()}`),
  `cmd[nodeGroup]`, events, and the `script:` / `onAfterReturn` shape of
  `jelastic.env.control.GetEnvInfo`, which returns `node.address`.
- `jelastic-jps/redis-cluster` and `jelastic-jps/mysql-cluster` for the topology-reading idiom.
- Live installs on the platform, from which the failure evidence above is taken. The offline suite
  proves syntax and invariants only, so a fresh install's `checkCluster` log -
  `cluster_state=ok, 16384/16384 slots assigned` - is the acceptance test.

## Known limitations

- **The container base has to be on the platform's supported-OS list.** Alpine 3 is the only base a
  current Valkey release ships that is on it (Debian 12 is listed but Valkey's `-bookworm` line stops
  at 8.1.3; `latest` is Debian 13, which is not listed and fails the install). The tag picker and the
  test suite enforce this rather than relying on memory.
- **The advertised address is applied once.** `prep` writes `cluster-announce-ip` at container
  startup. The official Redis cluster re-applies it after every topology event, because a redeployed
  or migrated container can come back with a different address. Until this repository does the same,
  re-run `scripts/init-cluster.sh --role prep` on the nodes after a scale-out, a migration, or a
  restart that changed addresses; `CLUSTER NODES` shows whether you needed to.
- **Nothing filters traffic inside the container, and the platform firewall probably does not apply
  to custom images at all.** The image ships busybox and no `iptables`/`nft`, and the vendor's own
  answer about custom Docker images is that the platform firewall is unavailable on them. So
  `JELASTIC_PORTS` may be inert here - it is neither the thing blocking 16379 nor the thing that
  would open it. If the bus is unreachable, the filter is above the container and only the provider
  can show it; `probes/network-probe.jps` is what proves whether it is unreachable at all.
- **No Jelastic-certified Valkey stack**, so no platform-managed clustering, no automatic failover
  UI, no `adminUrl` panel: everything cluster-shaped is this manifest's job.
- **Scaling out does not reshard.** `onAfterAddNode` re-runs the check and tells you the slots are
  still uneven; `valkey-cli --cluster reshard` moves them, deliberately by hand.
- **No TLS in this manifest.** Clients and the cluster bus are inside the environment's private
  network; encrypted client connections are separate work.
- **No external CA certificates**, only what the platform and the image provide.
- **3 primaries with no replicas by default.** Read [what it creates](#what-it-creates) before using
  it for anything you cannot rebuild.
- Clients must be cluster-aware. `-c` in the CLI, `Cluster` mode in a client library; a plain
  connection will see `MOVED`.

## Where the evidence came from

This project was written against live installations on a commercial Jelastic hosting account, during
the work that also produced that platform's account inventory and infrastructure-as-code. The
clusters described throughout this README existed and are described exactly as they behaved.

The identifiers that came with that work - the hosting provider, the account, the node and
environment numbers, and one contributor's machine - were removed before this repository was
published, and `tests/validate.sh` refuses them. The findings were kept as they were measured; the
pointers were replaced by descriptions, because a description can be re-verified by anyone and a node
id can be used against somebody.

Two consequences worth knowing. Dates are real: every measurement is dated, and the ones from
2026-10-26 and 2026-10-27 are what a single working session produced. Node ids are not: where an
older revision named one, this revision says "a deployed node" and means it. A public reader loses
nothing by that - a node id is only useful to someone who already owns the account.

## License

BSD-3-Clause. See [LICENSE](LICENSE).

### The parts this repository does not own

| Component | Upstream | License |
|---|---|---|
| Valkey server and CLI | [valkey-io/valkey](https://github.com/valkey-io/valkey) | BSD-3-Clause in two parts - Valkey contributors (2024 to present) and the Redis Ltd code it was forked from (2006 to 2020); see `COPYING` in that tree |
| The container base | Alpine Linux 3.24 (`alpine-minirootfs`) | a mix; the package set is the image's, not ours |
| JPS syntax and the platform API | [Virtuozzo Application Platform](https://jelastic.com/) | proprietary to the platform |
| `jelastic-jps/redis-cluster`, `jelastic-jps/mysql-cluster` | [jelastic-jps](https://github.com/jelastic-jps) | read for their idioms, not vendored |

An install pulls `valkey/valkey:<tag>` from Docker Hub at the tag this manifest offers, which means
it also pulls whatever the current Alpine 3.24 root filesystem is behind that tag. `sbom.py` records
exactly which pins a given version named - `python3 sbom.py` writes `sbom.json`, `python3 sbom.py
--check` generates it, scans it with the same rules `tests/validate.sh` applies to files, and writes
nothing. It is deliberately not a container package inventory: for that, scan the image you deployed
(`trivy image valkey/valkey:9.1.3-alpine3.24`). And a tag is a mutable name, so the SBOM says so in a
`supply-chain:immutability` field rather than pretending to be a digest: what you deploy is pinned by
`docker image inspect --format '{{index .RepoDigests 0}}'`, which is a per-installation act, not a
fact about this repository.
