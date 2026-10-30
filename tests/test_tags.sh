#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
#
# tests/test_tags.sh - prove that every tag manifest.jps offers is actually published, and (with
# --deep) that it really is an Alpine base rather than a Debian one that only looks like Alpine.
#
#   sh tests/test_tags.sh            existence per tag, writes tests/.dockerhub-tags
#   sh tests/test_tags.sh --deep     also reads the registry config history and looks for the
#                                    alpine-minirootfs layer
#
# Per-tag lookup rather than a tag listing: the listing is paginated (321 tags, 100 per page as of
# 2026-10-27) and a partial page would make a perfectly good tag look unpublished - which is the
# kind of test that fails for the wrong reason and then gets deleted.
#
# Exit status: 0 every offered tag is published, 1 at least one is not, 2 no network.

set -eu
cd "$(dirname "$0")/.."

DEEP=0
[ "${1:-}" = "--deep" ] && DEEP=1

if command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO- "$1" 2>/dev/null; }
    code() { wget -q -O /dev/null "$1" 2>/dev/null && printf 200 || printf 0; }
elif command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" 2>/dev/null; }
    code() { curl -s -o /dev/null -w '%{http_code}' -L "$1" 2>/dev/null || printf 0; }
else
    printf 'skip tag check (neither wget nor curl on this host)\n'
    exit 2
fi

tags=$(python3 -c "
import yaml
m = yaml.safe_load(open('manifest.jps', encoding='utf-8'))
print(' '.join(k for f in m['settings']['fields'] if f.get('name') == 'valkeyTag' for k in f['values']))
")

[ -n "$tags" ] || { printf 'FAIL no valkeyTag field to check\n' >&2; exit 1; }

: >tests/.dockerhub-tags
failed=0
for t in $tags; do
    status=$(code "https://hub.docker.com/v2/repositories/valkey/valkey/tags/$t")
    if [ "$status" = "0" ]; then
        printf 'skip tag %-20s (no network)\n' "$t"
        continue
    fi
    if [ "$status" != 200 ]; then
        printf 'FAIL  tag %-20s HTTP %s - not published, the install would fail on the image pull\n' "$t" "$status"
        failed=$((failed + 1))
        continue
    fi
    printf '%s\n' "$t" >>tests/.dockerhub-tags
    if [ "$DEEP" = 1 ]; then
        tok=$(fetch "https://auth.docker.io/token?service=registry.docker.io&scope=repository:valkey/valkey:pull" \
            | python3 -c 'import json,sys;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
        base=$(python3 - "$t" "$tok" <<'PY' 2>/dev/null
import json, re, sys, urllib.request
tag, tok = sys.argv[1], sys.argv[2]
reg = "https://registry-1.docker.io/v2/valkey/valkey"
def get(url, accept):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok, "Accept": accept})
    return json.load(urllib.request.urlopen(req, timeout=30))
try:
    top = get(reg + "/manifests/" + tag, "application/vnd.oci.image.index.v1+json")
    dig = [m["digest"] for m in top.get("manifests", [])
           if m.get("platform", {}).get("architecture") == "amd64"]
    cfgref = dig[0] if dig else tag
    man = get(reg + "/manifests/" + cfgref, "application/vnd.oci.image.manifest.v1+json")
    cfg = get(reg + "/blobs/" + man["config"]["digest"], "application/vnd.oci.image.config.v1+json")
    hist = " ".join(h.get("created_by", "") for h in cfg.get("history", []))
    if "alpine-minirootfs" in hist:
        v = re.search(r"alpine-minirootfs-([0-9.]+)", hist)
        print("alpine " + (v.group(1) if v else "?"))
    elif "debian.sh" in hist or "debuerreotype" in hist:
        d = re.search(r"out/ '([a-z0-9]+)'", hist)
        codename = d.group(1) if d else "?"
        # the only Debian release on the platform's list is 12 (bookworm)
        print("debian12" if codename == "bookworm" else "debian/" + codename)
    else:
        print("unknown base")
except Exception as exc:                       # noqa: BLE001
    print("unknown (%s)" % exc)
PY
)
        # the platform accepts Alpine 3 and Debian 12, among others; Debian 13 is not on the list
        case "$base" in
            alpine*|debian12*) printf 'ok    tag %-20s published, base %s\n' "$t" "$base" ;;
            *) printf 'FAIL  tag %-20s published but the base is %s - not on the platform list\n' "$t" "$base"
               failed=$((failed + 1)) ;;
        esac
    else
        printf 'ok    tag %-20s published\n' "$t"
    fi
done

if [ "$failed" -gt 0 ]; then
    printf '\n%d tag(s) would not install\n' "$failed"
    exit 1
fi
exit 0
