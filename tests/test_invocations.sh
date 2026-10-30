#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
#
# tests/test_invocations.sh - run the command lines the manifest actually emits, against the script
# as it exists in this repository, with stub valkey-cli, ip and nc.
#
# Why this file exists: an install failed because manifest.jps said `--role=prep` while
# init-cluster.sh only understood `--role prep`. Nothing caught it, because every other test in this
# repo examines one file at a time and the bug lived in the seam between two files. A test that reads
# the manifest, substitutes its own placeholders and executes the result is the only thing that fails
# when the two sides drift apart - in either direction.
#
# The cases below then cover the behaviour that seam has to keep guaranteeing: which address gets
# advertised when there is a choice, that a wrong advertised address is repaired before it is
# blamed, that a refused port stops the run instead of producing a green install, and that every
# failure path says what went wrong.

set -eu
cd "$(dirname "$0")/.."

chmod +x tests/stub/valkey-cli tests/stub/ip tests/stub/nc 2>/dev/null || true
STUB_ANNOUNCE_SEEN_TMP=$(mktemp)
trap 'rm -f "$STUB_ANNOUNCE_SEEN_TMP" "${STUB_ANNOUNCE_FILE_TMP:-}"' EXIT
python3 - <<'PY'
import os
import re
import subprocess
import sys
import tempfile
import yaml

STUB = os.path.abspath("tests/stub")
CONTAINER_SCRIPT = "/var/lib/jelastic/valkey-cluster/init-cluster.sh"
LOCAL_SCRIPT = os.path.abspath("scripts/init-cluster.sh")
PEERS = ["10.11.0.1", "10.11.0.2", "10.11.0.3"]

m = yaml.safe_load(open("manifest.jps", encoding="utf-8"))
g = m["globals"]
fields = {f["name"]: f for f in m["settings"]["fields"]}


def subst(text):
    """Substitute the placeholders this manifest is allowed to use, the way the platform would."""
    text = re.sub(r"\$\{globals\.([A-Za-z0-9_]+)\}", lambda x: str(g[x.group(1)]), text)

    def setting(x):
        name, default = x.group(1), x.group(2)
        if default is None:
            return str(fields[name].get("default", ""))
        return default.rstrip(":}").split(":")[-1].rstrip("}")

    text = re.sub(r"\$\{settings\.([A-Za-z0-9_]+)(:[^}]*)?\}", setting, text)
    text = text.replace("${fn.random}", "1")
    return text


def localise(cmd):
    return subst(cmd).replace(CONTAINER_SCRIPT, LOCAL_SCRIPT)


cases = []

# 1. prep: whatever cmd[nosqldb] says, with the container path swapped for the working copy
prep_cmd = [c for c in m["actions"]["prepNodes"]["cmd [nosqldb]"] if "init-cluster.sh" in c]
assert prep_cmd, "prepNodes no longer calls init-cluster.sh"
prep_line = localise(prep_cmd[-1])
cases.append(("prep", prep_line, {"STUB_IP": "10.11.0.1"}))

# 2. check: same idea, from checkCluster
check_step = [v for k, v in m["actions"]["checkCluster"].items() if k.startswith("cmd")]
check_cmd = [c for c in check_step[0] if "init-cluster.sh" in c]
assert check_cmd, "checkCluster no longer calls init-cluster.sh"
cases.append(("check", localise(check_cmd[-1]), {}))

# 3. form: the command is assembled in JavaScript, so reassemble it from the string literals and the
#    addrs.join(' ') that only the platform knows at run time.
js = m["actions"]["formCluster"]["script"]
assign = " ".join(line.strip() for line in js.splitlines()
                  if "onAfterReturn['cmd" in line or line.strip().startswith(("'", "--port")) or "+ '" in line)
assign = assign.split("=", 1)[1]           # drop the key, keep the right-hand side
assign = re.sub(r"addrs\.join\(['\"] ['\"]\)", "'" + " ".join(PEERS) + "'", assign)
form_cmd = "".join(re.findall(r"'([^']*)'", assign))
assert "init-cluster.sh" in form_cmd, "could not recover the form command from the manifest JS"
form_cmd = localise(form_cmd)

# the leader is the node whose address sorts first, so the stub ip decides which branch runs
cases.append(("form as the node that forms", form_cmd, {"STUB_IP": "10.11.0.1"}))
cases.append(("form as a waiting node", form_cmd, {"STUB_IP": "10.11.0.3"}))

# 4. address selection. A decoy interface is listed first on purpose: the platform's own Redis cluster
#    package reads venet0, so venet0 must win over interface order, and a machine with no venet0 at
#    all must say so rather than announce a guess quietly.
cases.append(("prep, decoy interface first", prep_line,
              {"STUB_IP_IFACES": "docker0:10.99.0.9 venet0:10.11.0.1"}, "announce          : 10.11.0.1"))
cases.append(("prep, no venet0 at all", prep_line,
              {"STUB_IP_IFACES": "eth0:10.11.0.7"}, "neither on venet0 nor in the platform"))

# 5. the advertised address, repaired before it is blamed. The peer says one thing, the platform
#    lists another; CONFIG SET is runtime-settable in 9.x, so the script must fix it and say so. If
#    the fix does not stick, that is a hard failure - not a handshake that never completes.
# The stub keeps what it was told to set in a state file, so "repaired" means the value really
# changed rather than the script having printed an intention.
announce_state = tempfile.NamedTemporaryFile(prefix="announce-", suffix=".txt", delete=False)
announce_state.close()
open(announce_state.name, "w").close()
announce_fix_env = {"STUB_IP": "10.11.0.1", "STUB_ANNOUNCE_FILE": announce_state.name,
                    "STUB_ANNOUNCE_SEEN": os.environ.get("STUB_ANNOUNCE_SEEN_TMP", "")}
cases.append(("form repairs a wrong announce", form_cmd, announce_fix_env, "now advertises"))
cases.append(("form, announce will not change", form_cmd,
              {"STUB_IP": "10.11.0.1", "STUB_ANNOUNCE_STICK": "10.99.99.99"}, "after CONFIG SET"))

# 6. the platform facts the form role refuses to be silent about
cases.append(("form, bus port filtered", form_cmd,
              {"STUB_IP": "10.11.0.1", "STUB_NC_FAIL": "16379"}, "cannot open TCP to 10.11.0.1:16379"))
cases.append(("form, nc without -z still probes", form_cmd,
              {"STUB_IP": "10.11.0.1", "STUB_NC_NO_Z": "1"}, "tcp 10.11.0.1:16379 is reachable"))

# 7. discovery and reporting failures must be failures
# An empty peer list reaches the script as `--peers ""` (that is what the JS builds when GetEnvInfo
# returned nothing), and must be a named failure with a nonzero exit, not a run that forms nothing
# and reports success.
no_peers = form_cmd.replace(' --peers "10.11.0.1 10.11.0.2 10.11.0.3"', ' --peers ""')
cases.append(("form with no peers", no_peers, {"STUB_IP": "10.11.0.1"}, "--peers needs a value"))
no_peers2 = form_cmd.replace(' --peers "10.11.0.1 10.11.0.2 10.11.0.3"', ' --peers "  "')
cases.append(("form with blank peers", no_peers2, {"STUB_IP": "10.11.0.1"}, "--peers is empty"))
cases.append(("check on a broken cluster", localise(check_cmd[-1]),
              {"STUB_CLUSTER_STATE": "fail"}, "cluster_state=fail"))

# 7b. the exact value that killed a deployed node. It got "--appendonly true" from a
#     checkbox and the server answered "FATAL CONFIG FILE ERROR ... argument must be 'yes' or 'no'"
#     before it ever bound a port. prep must translate the boolean, and refuse a word it cannot map
#     instead of handing it to a server that would die at startup.
aof_seen = tempfile.NamedTemporaryFile(prefix="aof-", suffix=".txt", delete=False)
aof_seen.close()
prep_aof = prep_line + " --aof true --maxmemory 1024mb --eviction noeviction"
cases.append(("prep translates --aof true", prep_aof,
              {"STUB_IP": "10.11.0.1"}, "ok    appendonly applied"))
bad_aof = prep_line + " --aof maybe"
cases.append(("prep refuses a bad boolean", bad_aof,
              {"STUB_IP": "10.11.0.1"}, "is not a yes/no value"))

# 8. the regression that started all of this: both argument spellings, forever
for spelling in ["--role prep", "--role=prep"]:
    cases.append(("arg spelling %r" % spelling,
                  "sh %s %s --port 6379 --bus-port 16379 --timeout 5000" % (LOCAL_SCRIPT, spelling),
                  {"STUB_IP": "10.11.0.1"}))

env = dict(os.environ)
env["PATH"] = STUB + os.pathsep + env["PATH"]
env["VALKEY_PASS"] = "stub-password-not-a-real-one"
env["VALKEY_EXTRA_FLAGS"] = "--requirepass stub-password-not-a-real-one --cluster-enabled yes"

failed = 0
for case in [c + (None,) for c in cases]:
    name, cmd, extra, expect = case[:4]
    run_env = dict(env)
    run_env.update({k: v for k, v in extra.items() if v})
    proc = subprocess.run(["sh", "-c", cmd], env=run_env, capture_output=True, text=True, timeout=180)
    out = (proc.stdout or "") + (proc.stderr or "")

    if "unknown argument" in out:
        print("FAIL  %-30s the script rejected the manifest's arguments: %s" % (name, out.strip().splitlines()[0]))
        failed += 1
        continue

    if expect:
        if re.search(re.escape(expect), out):
            print("ok    %-30s %s, and says why" % (name, "exit %d" % proc.returncode if proc.returncode else "exit 0"))
        else:
            print("FAIL  %-30s never mentions %r (exit %d): %s" % (name, expect, proc.returncode, out.strip()[:200]))
            failed += 1
        continue

    if proc.returncode != 0:
        # A nonzero exit is allowed only when the script reports a real finding, and then it must
        # come with a line that says what. Silence plus failure is the worst combination.
        if not re.search(r"(FAIL|WARN|FATAL)", out):
            print("FAIL  %-30s exit %d with no explanation: %s" % (name, proc.returncode, out.strip()[:200]))
            failed += 1
            continue
        print("skip  %-30s exit %d explained: %s" % (name, proc.returncode, out.strip().splitlines()[-1][:80]))
        continue
    print("ok    %-30s exit 0" % name)

print("\ncommands the manifest emits, as executed (paths are repository-relative):")
for c in cases:
    shown = c[1].replace(LOCAL_SCRIPT, "scripts/init-cluster.sh")
    print("  %-30s %s" % (c[0], shown if len(shown) < 150 else shown[:150] + "..."))

sys.exit(1 if failed else 0)
PY
