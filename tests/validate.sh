#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
#
# tests/validate.sh - offline checks. No Jelastic, no Docker, no network.
#
# This cannot prove a cluster forms. It proves the manifest does not contain the kind of mistake
# that costs an install to discover: invalid YAML, a startup flag that dropped out of the env
# string, the cluster bus port missing from the firewall, a count/replica pair that --cluster
# create cannot satisfy, a script the manifest points at that does not exist.

set -eu
cd "$(dirname "$0")/.."

FAILED=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; FAILED=$((FAILED + 1)); }

# 1. shell syntax
for f in scripts/*.sh probes/*.sh tests/*.sh tests/stub/*; do
    if sh -n "$f" 2>/dev/null; then ok "sh -n $f"; else bad "sh -n $f"; sh -n "$f" || true; fi
done

# 1b. python syntax, for the tooling that is not shell
for f in $(ls *.py scripts/*.py 2>/dev/null); do
    if python3 -m py_compile "$f" >/dev/null 2>&1; then ok "py_compile $f"; else bad "py_compile $f"; python3 -m py_compile "$f" || true; fi
done
rm -rf __pycache__ ./*.pyc 2>/dev/null || true

# the invocation contract: run the manifest's own command lines against this script
if sh tests/test_invocations.sh >tests/.invocations 2>&1; then
    ok "manifest commands execute against init-cluster.sh"
else
    bad "the manifest and init-cluster.sh disagree, see tests/.invocations"
    cat tests/.invocations
fi

# 2. no bash-only constructs, and no curl (the image is Alpine: busybox ash, wget, no curl)
b=tests/.bashisms; : >"$b"
for f in scripts/*.sh; do
    grep -nv '^[[:space:]]*#' "$f" \
        | grep -E '<<<|\[\[ |\bmapfile\b|\bdeclare \b|\$\{[0-9@]+:[0-9]|\bcurl\b' \
        | sed "s|^|$f:|" >>"$b" || true
done
if [ -s "$b" ]; then bad "bash-only syntax or curl (see tests/.bashisms)"; cat "$b"; else ok "POSIX sh, wget not curl"; fi
rm -f "$b"

# 3. manifest is valid YAML and keeps the invariants the README claims
python3 - <<'PY'
import sys
import yaml
import re
import os

# the committed mark's identity, so a silent swap of the logo is a deliberate edit rather than an
# accident in a rebase. Regenerate with: sha256sum images/valkey-cluster.png
LOGO_SHA = "677d1fa304d5"

try:
    m = yaml.safe_load(open("manifest.jps", encoding="utf-8"))
except Exception as exc:                      # noqa: BLE001
    print("FAIL  manifest.jps is not parseable YAML: %s" % exc)
    sys.exit(1)

fail = []
def need(cond, msg):
    if not cond:
        fail.append(msg)

need(m["type"] == "install", "type must be install: this is an application, not an add-on")
need(m["id"] == "valkey-cluster", "id should be valkey-cluster")
need(isinstance(m.get("baseUrl"), str) and str(m["baseUrl"]).startswith("https://"),
     "baseUrl must be an absolute https URL: otherwise ${baseUrl} resolves relative to wherever the"
     " manifest was imported from, and a CDN copy of it can be stale")

node = m["nodes"][0]
need(node["nodeGroup"] == "nosqldb", "database work belongs in the nosqldb layer")
need("${globals.imageRepo}" in node["image"], "image must come from globals.imageRepo")
need("valkey/valkey" in str(m["globals"]["imageRepo"]), "use the official valkey/valkey image")
need("latest" not in node["image"], "never :latest - an application that moves under a running cluster is a slot outage")

env = node["env"]
g = m["globals"]
flags = env["VALKEY_EXTRA_FLAGS"]
for flag in ["--cluster-enabled yes", "--cluster-config-file nodes.conf", "--protected-mode yes",
             "--enable-debug-command no", "--enable-module-command no", "--enable-protected-configs no"]:
    need(flag in flags, "VALKEY_EXTRA_FLAGS must carry %s (cluster-enabled and cluster-config-file are startup-only)" % flag)

# Two mechanisms, both measured on live nodes of this deployment on 2026-10-27, both able to hand
# the server an argument it cannot parse:
#   * a placeholder inside a SETTINGS DEFAULT is never expanded (a probe node received the literal
#     ",${globals.clusterBusPort}" as JELASTIC_PORTS from exactly this),
#   * a value the dashboard renders in a form the directive rejects is fatal at startup: a deployed
#     node got "--appendonly true" from a checkbox and valkey-server exited with
#     "FATAL CONFIG FILE ERROR ... argument must be 'yes' or 'no'".
# So the manifest keeps env literal, and no field that reaches a server directive may be a checkbox.
for name, field in [(f.get("name"), f) for f in m["settings"]["fields"]]:
    need("${" not in str(field.get("default", "")),
         "settings field %s has a placeholder in its default (%s); defaults are not expanded"
         % (name, field.get("default")))
    if name in ("persistent", "evictionPolicy", "maxMemory"):
        need(field.get("type") != "checkbox",
             "settings field %s must not be a checkbox: it renders true/false, which the server"
             " directive rejects at startup" % name)

# env values DO expand (measured: a cluster node received JELASTIC_PORTS=6379,16379 and a fully
# expanded VALKEY_EXTRA_FLAGS), so placeholders there are allowed - but only ever to a value the
# server can parse. Anything derived from a settings field must therefore offer literal words.
for name, field in [(f.get("name"), f) for f in m["settings"]["fields"]]:
    if any(name in str(v) for v in (env or {}).values()):
        if field.get("type") == "list":
            for v in field["values"]:
                need(not re.fullmatch(r"true|false", str(v)),
                     "settings field %s offers %r; a boolean word can be fatal in a server directive" % (name, v))

need("${globals.valkeyPswd}" in str(env["VALKEY_EXTRA_FLAGS"]),
     "requirepass must be a startup flag - CONFIG SET requirepass does not survive a restart")
need("${globals.valkeyPswd}" in str(env.get("VALKEY_PASS", "")),
     "the script must get the password from the node env, not from a command line in the install log")
need("VALKEY_PASS=" not in " ".join(m["actions"]["prepNodes"]["cmd [nosqldb]"]),
     "do not put the password on a cmd line: cmd lines are logged")

ports = str(env["JELASTIC_PORTS"])
need(str(g["clientPort"]) == "6379", "clients connect on 6379, the port Valkey kept from Redis")
need(str(g["clusterBusPort"]) == "16379", "the bus port must be 16379: cluster-port defaults to 0 = command port + 10000")
need(ports.replace(" ", "") == "%s,%s" % (g["clientPort"], g["clusterBusPort"]),
     "JELASTIC_PORTS must be the two literal ports and agree with globals: %s vs %s,%s"
     % (ports, g["clientPort"], g["clusterBusPort"]))

# the settings that left VALKEY_EXTRA_FLAGS must be applied by prep instead, from a cmd line where
# placeholders do expand - otherwise the settings screen silently stops meaning anything
prep_cmd = " ".join(c for c in m["actions"]["prepNodes"]["cmd [nosqldb]"] if isinstance(c, str))
script = open("scripts/init-cluster.sh", encoding="utf-8").read()
for flag in ["--maxmemory", "--eviction", "--aof", "--timeout"]:
    need(flag in prep_cmd, "%s must reach prep on the cmd line, where placeholders expand" % flag)
for directive, needle in [("maxmemory", '"maxmemory|v|$MAXMEM"'),
                          ("maxmemory-policy", '"maxmemory-policy|v|$EVICTION"'),
                          ("appendonly", '"appendonly|b|$AOF"'),
                          ("requirepass", "masterauth requirepass"),
                          ("masterauth", "for name in masterauth requirepass"),
                          ("cluster-node-timeout", 'config set cluster-node-timeout')]:
    need(needle in script, "prep must apply %s at runtime; it is no longer a startup flag" % directive)

counts = {}
replicas = {}
tag_values = []
for f in m["settings"]["fields"]:
    if f.get("name") == "nodeCount":
        counts = {int(k) for k in f["values"]}
    if f.get("name") == "replicasPerPrimary":
        replicas = {int(k) for k in f["values"]}
    if f.get("name") == "valkeyTag":
        tag_values = list(f["values"])

# OS compatibility is a hard platform constraint, not a preference: a Debian-based tag fails the
# install with "OS debian:13 ... is not supported". Anything that is not an Alpine tag is refused
# here, before somebody discovers it in the dashboard.
# The platform unpacks a custom image into a system container built from an OS template, so the
# base has to be on its list. Not "Alpine only": AlmaLinux 9, Alpine 3, CentOS 7/8, Debian 12,
# RHEL 7, Ubuntu 18.04-24.04, amd64 only, per
# www.virtuozzo.com/application-management-docs/container-image-requirements/. What is NOT on the
# list is what must never be offered: Debian 13 (-trixie), older Debian, and :latest, which today
# points at Debian 13.
import re
BASE_SUFFIX = re.compile(r"-alpine([0-9.]+)?$|-bookworm$|-ubuntu(18|20|22|24)[.-]?[0-9.]*$|-almalinux([0-9]+)?$")
for t in tag_values:
    need(BASE_SUFFIX.search(t) is not None,
         "tag %s is not on a base the platform supports (Alpine 3, Debian 12, Ubuntu 18.04-24.04, "
         "AlmaLinux 8/9, CentOS 7/8); Debian 13 and :latest are not" % t)
    need("trixie" not in t, "tag %s is Debian 13, which is not on the platform list yet" % t)
    need(t != "latest", "never offer :latest")
need(len(tag_values) >= 1, "valkeyTag must offer at least one tag")

# when tests/test_tags.sh has fetched the registry's own tag list, the offered tags must be in it
try:
    available = set(open("tests/.dockerhub-tags", encoding="utf-8").read().split())
except OSError:
    available = None
if available:
    for t in tag_values:
        need(t in available, "tag %s is not published on valkey/valkey" % t)

need(3 in counts, "3 must be selectable: it is the minimum cluster")
need(min(counts) >= 3, "a cluster below 3 nodes is not a cluster")
need(replicas <= {0, 1}, "only 0 or 1 replica per primary is offered, and init-cluster.sh enforces the same")
need(1 not in replicas or 6 in counts, "offering 1 replica requires 6 nodes in the count list")

# every referenced script must exist
import re
text = open("manifest.jps", encoding="utf-8").read()
for path in sorted(set(re.findall(r"scripts/([A-Za-z0-9._-]+)", text))):
    import os
    need(os.path.exists("scripts/" + path), "manifest points at scripts/%s which does not exist" % path)

for ref in sorted(set(re.findall(r"\$\{globals\.([A-Za-z0-9_]+)", text))):
    need(ref in (m.get("globals") or {}), "globals.%s is referenced but not defined" % ref)

# YAML 1.1 turns a bare yes/no/on/off into a boolean, and this manifest's values end up inside a
# server directive. An unquoted `default: yes` in v1.0.2 arrived as True, the flag reached the server
# as --appendonly true, and the redeployed node wrote "argument must be 'yes' or 'no'" into run.log -
# so the
# parsed type is checked, not the source text. A number (nodeCount, cloudlets) is fine; a boolean
# standing in for a word is not.
for field in m["settings"]["fields"]:
    name = field.get("name")
    dflt = field.get("default")
    if field.get("type") != "checkbox":
        need(not isinstance(dflt, bool),
             "field %s default is %r: YAML ate the word. Quote it." % (name, dflt))
    for k in (field.get("values") or {}):
        need(not isinstance(k, bool),
             "field %s has the key %r: YAML ate the word. Quote it." % (name, k))

pf = {f["name"]: f for f in m["settings"]["fields"]}["persistent"]
need(all(isinstance(k, str) and k in ("yes", "no") for k in pf["values"])
     and pf.get("default") in ("yes", "no"),
     "persistent must carry the literal words yes/no, got values=%r default=%r" % (list(pf["values"]), pf.get("default")))

# the flags, with the defaults substituted the way the platform would, must never hand a boolean
# word to a yes/no directive
flags_now = str(env["VALKEY_EXTRA_FLAGS"])
for field in m["settings"]["fields"]:
    flags_now = flags_now.replace("${settings.%s}" % field["name"], str(field.get("default", "")))
for key, value in (m.get("globals") or {}).items():
    flags_now = flags_now.replace("${globals.%s}" % key, str(value))
m_append = re.search(r"--appendonly (\S+)", flags_now)
need(m_append is not None and m_append.group(1) in ("yes", "no"),
     "as installed with the defaults, appendonly would get %r; the server accepts only yes/no"
     % (m_append.group(1) if m_append else None))

# the events used must be real ones
hooks = set(re.findall(r"^(on[A-Z][A-Za-z]+)", text, re.M))
for hook in hooks:
    need(hook in {"onInstall", "onAfterAddNode", "onAfterScaleOut", "onUninstall"},
         "unknown event %s in the manifest" % hook)

# Version pinning. The manifest fetches its script over HTTP, so the ref it fetches from has to be
# immutable, and it has to be the same ref the probe fetches from: a versioned manifest pulling
# scripts from a moving branch is the exact mismatch that produced the original "unknown argument"
# install failure, and a tag is what makes that state unrepresentable.
need(re.search(r"/v?\d+\.\d+\.\d+$", str(m["baseUrl"])) is not None
     or re.search(r"@[0-9a-f]{7,40}$", str(m["baseUrl"])) is not None,
     "baseUrl must end in a tag or a commit sha, not a branch: %s" % m["baseUrl"])

# A logo that points at a file nobody committed is a 404 in a marketplace listing, and it is the
# mistake this repository actually shipped once. So the reference is resolved, not trusted: the path
# has to exist here, and it has to be a PNG by magic bytes rather than by extension.
import hashlib
lg = str(m.get("logo") or "")
if lg:
    rel = re.sub(r"^https?://[^/]+", "", lg).split("?")[0]
    rel = rel[rel.index("images/"):] if "images/" in rel else rel.lstrip("/")
    need(os.path.exists(rel), "logo references %s, which is not in this repository" % rel)
    if os.path.exists(rel):
        with open(rel, "rb") as fh:
            need(fh.read(8) == b"\x89PNG\r\n\x1a\n", "logo %s is not a PNG" % rel)
        need(hashlib.sha256(open(rel, "rb").read()).hexdigest()[:12] == LOGO_SHA,
             "logo %s changed identity (now %s); if that is intended, update LOGO_SHA in this check"
             % (rel, hashlib.sha256(open(rel, "rb").read()).hexdigest()[:12]))
    need("raw.githubusercontent" not in lg and "github.com" not in lg,
         "logo should be the repository-relative /images/... form the platform resolves against "
         "baseUrl; an absolute URL re-introduces an account name")
need(not re.search(r"/(main|master|develop)$", str(m["baseUrl"])),
     "baseUrl points at a branch; the scripts it serves can change after this manifest is installed")
# comments are about the pinning, commands are the pinning - only the commands are checked
code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
need("?_r=" not in code,
     "a cache-buster on a pinned URL is a mistake in disguise: it implies the ref is mutable")

# The failure-return antipattern, caught structurally: result 0 tells the engine the step
# succeeded, so an errorMessage carried alongside it is a failure the install never sees. The
# original version of this manifest did exactly that on discovery failure and installed green with
# no cluster formed.
for stmt in re.findall(r"return\s*\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}", code):
    need(not (re.search(r"result:\s*0\b", stmt) and "errorMessage" in stmt),
         "a script step returns result 0 with an errorMessage - the engine reads that as success: %s" % stmt[:70])

# a nonzero result code is only readable by the dashboard if responses: says what it means
codes = set(int(c) for c in re.findall(r"result:\s*(\d{3,})", text))
declared = set(int(c) for c in (m.get("responses") or {}))
for c in sorted(codes):
    need(c in declared, "a script step returns %d but responses: does not declare it, so the operator sees an anonymous error" % c)

# the form command must carry both ports: init-cluster.sh announces cluster-announce-bus-port and
# probes the bus, and a silently-defaulted 16379 would disagree with globals.clusterBusPort
js = m["actions"]["formCluster"]["script"]
need("--bus-port" in js, "the form command must pass --bus-port, or globals.clusterBusPort is a decoration")
need("--port" in js, "the form command must pass --port")

# the default must be the stable release, not a pre-release
field = {f["name"]: f for f in m["settings"]["fields"]}["valkeyTag"]
need(field.get("default") == "9.1.3-alpine3.24",
     "the default tag must be the verified stable release, not %s" % field.get("default"))
need("rc" not in str(field.get("default")).lower(), "never default to a release candidate")
need(field["default"] in field["values"], "the default tag must be one of the offered values")

for f in fail:
    print("FAIL  %s" % f)
if not fail:
    print("ok    manifest.jps parses and keeps its invariants")
sys.exit(1 if fail else 0)
PY

# 4. the script's own argument contract must stay in step with the manifest
if grep -q -- '--role=form\|--role form' scripts/init-cluster.sh && grep -q -- '--peers' scripts/init-cluster.sh; then
    ok "init-cluster.sh still implements the form role the manifest calls"
else
    bad "init-cluster.sh no longer implements --role form --peers, but the manifest calls it"
fi

# Busybox builds differ in which nc options are compiled in, and assuming -z is how a portability
# bug becomes a false "the platform blocked the bus" report. The fallback has to stay in place.
if grep -qE 'timeout [0-9]+ nc -vz' scripts/init-cluster.sh probes/probe.sh; then
    bad "a hardcoded 'timeout N nc -vz' is back; use tcp_probe, which falls back when -z is absent"
else
    ok "TCP probing goes through the portable helper, not an assumed nc option set"
fi

# 5. the network probe must stay a valid manifest and must probe both required ports
python3 - <<'PY2'
import os
import re
import sys
import yaml
try:
    p = yaml.safe_load(open("probes/network-probe.jps", encoding="utf-8"))
    m = yaml.safe_load(open("manifest.jps", encoding="utf-8"))
except Exception as exc:                       # noqa: BLE001
    print("FAIL  a manifest is not parseable YAML: %s" % exc)
    sys.exit(1)

fail = []


def need(cond, why):
    if not cond:
        fail.append(why)


if p.get("type") != "install":
    fail.append("the probe has to be a standalone install, not an add-on")
node = p["nodes"][0]
if int(node["count"]) != 3:
    fail.append("the probe is specified as 3 nodes")
if str(p["globals"]["imageTag"]) != str({f["name"]: f for f in m["settings"]["fields"]}["valkeyTag"]["default"]):
    fail.append("the probe must run on the same image the product defaults to, got %s" % p["globals"]["imageTag"])
if p["globals"]["clusterBusPort"] != int(p["globals"]["clientPort"]) + 10000:
    fail.append("bus port must be client port + 10000, the Valkey default")

# The A/B comparison of JELASTIC_PORTS is a run option, not a code fork: one field carries it, and
# it must contain both ports in the default (run A) so run B differs by exactly that variable.
field = {f["name"]: f for f in p["settings"]["fields"]}
need("firewallPorts" in field, "the probe must expose JELASTIC_PORTS as a field so the A/B run is one click, not an edit")
need(str(field.get("firewallPorts", {}).get("default")).replace(" ", "")
     == "%s,%s" % (m["globals"]["clientPort"], m["globals"]["clusterBusPort"]),
     "the default JELASTIC_PORTS must equal the product's ports, or the A run is not the product's configuration")
need("${" not in str(field.get("firewallPorts", {}).get("default")),
     "a placeholder in a settings default arrives as text - measured on the live node")
need("${settings.firewallPorts}" in str(node["env"]["JELASTIC_PORTS"]),
     "JELASTIC_PORTS must come from the field, not be hardcoded, or B cannot be run")

# selftest has to run before the matrix: without it, a listener that never started looks exactly
# like a blocked port, and the platform gets blamed for the probe
order = p["onInstall"]
need(order.index("selftest") < order.index("mesh"),
     "the probe must self-test its listeners before it tests anybody else's")
need("selftest" in order and "listen" in order, "the probe needs both a listen step and a self-test step")

codes = set(int(c) for c in re.findall(r"result:\s*(\d{3,})", open("probes/network-probe.jps", encoding="utf-8").read()))
for c in sorted(codes):
    need(c in {int(k) for k in (p.get("responses") or {})}, "the probe returns %d but responses: does not declare it" % c)

need(str(p["baseUrl"]) == str(m["baseUrl"]),
     "the probe and the product must be fetched from the same ref: %s vs %s" % (p["baseUrl"], m["baseUrl"]))

script = open("probes/probe.sh", encoding="utf-8").read()
for piece in ("selftest", "listen-one", "tcp_probe", "listeners_dump", "is_local"):
    need(piece in script, "probe.sh lost %s" % piece)
need("refusing to report a matrix" in script,
     "probe.sh must refuse to report a matrix when its own self-test failed")
for path in ("probes/probe.sh",):
    need(os.path.exists(path), "%s is referenced but missing" % path)

for f in fail:
    print("FAIL  %s" % f)
if not fail:
    print("ok    probes/network-probe.jps parses and matches the product's ports and ref")
sys.exit(1 if fail else 0)
PY2

# 6. the repository stays general: no account coordinates, deployment identifiers, personal
#    identifiers, or local filesystem paths in anything tracked - and the same scan applied to what
#    sbom.py generates. SECURITY.md is the policy; this is its enforcement.
#
#    The rules are imported from sbom.py rather than repeated here, on purpose: a generated file is
#    scanned by the same code that scans a committed one, so the two cannot disagree about what an
#    identifier is. If you are reading this in a fork and want your own coordinates in baseUrl, that
#    is a legitimate choice - change sbom.py's OWN_URL handling and the scan follows it.
python3 - <<'PY3'
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath("..")))
sys.path.insert(0, ".")
import sbom                                       # noqa: E402  the one source of the rules


def tracked():
    try:
        out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True)
        names = out.stdout.split()
    except Exception:                            # noqa: BLE001 - no git, no problem
        names = [f for f in os.listdir(".") if os.path.isfile(f)]
        names += ["probes/" + f for f in os.listdir("probes")]
        names += ["scripts/" + f for f in os.listdir("scripts")]
        names += ["tests/" + f for f in os.listdir("tests") if not f.startswith(".")]
    return [n for n in names if os.path.isfile(n)]


fail = []
files = 0
for name in tracked():
    try:
        text = open(name, encoding="utf-8").read()
    except (UnicodeDecodeError, OSError):
        continue
    files += 1
    for line_no, line in enumerate(text.splitlines(), 1):
        for why in sbom.find_identifiers(line):
            fail.append("%s:%d %s" % (name, line_no, why))

for f in fail:
    print("FAIL  %s" % f)
if not fail:
    print("ok    %d tracked files carry no account coordinates, deployment ids, or personal "
          "identifiers" % files)

# and the document sbom.py would generate, from the same files
try:
    generated = sbom.scan(sbom.build())
except SystemExit as exc:                        # sbom.py refuses to guess about an unknown tag
    print("FAIL  sbom.py: %s" % exc)
    generated = []
    fail.append("sbom.py cannot describe the offered tags")
for g in generated:
    print("FAIL  what sbom.py generates carries %s" % g)
if not generated:
    print("ok    the generated SBOM carries none of them either")

sys.exit(1 if fail else 0)
PY3

# 6b. the SBOM generator's own output contract: it produces a document that parses, it names every
#     image the manifest offers, and its two self-check paths are genuinely different - a tool that
#     prints CLEAN on a broken input is worse than no tool.
if python3 sbom.py --check >tests/.sbom 2>&1; then
    ok "sbom.py --check"
else
    bad "sbom.py --check failed"; cat tests/.sbom
fi
rm -f tests/.sbom

printf '\n'
if [ "$FAILED" -gt 0 ]; then
    printf '%d check(s) failed\n' "$FAILED"
    exit 1
fi
printf 'all checks passed\n'
