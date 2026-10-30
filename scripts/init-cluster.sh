#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
#
# init-cluster.sh - form and verify a Valkey cluster from inside Jelastic containers.
#
#   sh init-cluster.sh --role=prep  [--port N] [--bus-port N] [--timeout MS]
#   sh init-cluster.sh --role=form  --peers "ip ip ip" [--port N] [--replicas 0|1]
#   sh init-cluster.sh --role=check [--port N]
#
# Every node in the group runs the same commands, which is how Jelastic executes cmd[nosqldb].
# That fact drives the design: there is no orchestrator and no shared filesystem, so "form the
# cluster" must be something 3 identical processes can run at once without corrupting each other.
# The rule used here: the node whose own address sorts first in the peer list forms, the others
# wait for the result and report. Any node would do; a deterministic one survives a rebuild, where
# "the master" is not necessarily the machine you think it is.
#
# Exit status: 0 done/ok, 1 a control failed, 2 cannot reach a Valkey, 3 bad invocation.
#
# POSIX sh only. The image is Alpine: busybox ash, no bash, no curl; valkey-cli and openssl are in
# it.

set -eu

# Jelastic runs this from the platform console, with no terminal attached. Any client we call
# would otherwise consider switching to interactive mode and reading stdin, which in a container
# with no tty is where "not a tty" messages come from. Closing stdin up front means this script can
# only ever run in batch mode, which is the only mode it was written for.
exec </dev/null

ROLE=prep
PEERS=""
PORT=6379
BUS_PORT=16379
TIMEOUT_MS=5000
REPLICAS=0
MAXMEM=""
EVICTION=""
AOF=""

WAIT_SECS=120

# Both spellings are accepted, deliberately. The manifest and the script are edited independently and
# shipped from the same ref, and a cached copy of one side cannot be recalled when the other changes
# - so an argument-parsing disagreement has to be impossible rather than unlikely.
while [ $# -gt 0 ]; do
    opt=$1
    value=
    eq=0
    case $opt in
        *=*) value=${opt#*=}; opt=${opt%%=*}; eq=1 ;;
        *)
            if [ $# -ge 2 ]; then value=$2; else value=""; fi
            ;;
    esac

    case $opt in
        --role) ROLE=$value ;;
        --peers) PEERS=$value ;;
        --port) PORT=$value ;;
        --bus-port) BUS_PORT=$value ;;
        --timeout) TIMEOUT_MS=$value ;;
        --replicas) REPLICAS=$value ;;
        --maxmemory) MAXMEM=$value ;;
        --eviction) EVICTION=$value ;;
        --aof) AOF=$value ;;
        --wait) WAIT_SECS=$value ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            printf '       accepted: --role prep|form|check, --peers "ip ip ip", --port N,\n'
            printf '                 --bus-port N, --timeout MS, --replicas 0|1, --wait SECS\n' >&2
            exit 3
            ;;
    esac

    if [ -z "$value" ]; then
        printf 'FAIL %s needs a value (accepted as "--%s value" or "--%s=value")\n' "$opt" "${opt#--}" "${opt#--}" >&2
        exit 3
    fi

    if [ "$eq" = 1 ]; then shift 1; else shift 2; fi
done

CLI=$(command -v valkey-cli || true)
if [ -z "$CLI" ]; then
    printf 'FATAL no valkey-cli here. This manifest targets the official valkey/valkey image;\n' >&2
    printf '      the CLI in a Redis container is named redis-cli and is not what drives a cluster.\n' >&2
    exit 2
fi

# The password is already in this container's environment, because the node passes it to the
# server in VALKEY_EXTRA_FLAGS. Reading it back beats putting it on a command line in the log.
PASS=${VALKEY_PASS:-}
if [ -z "$PASS" ]; then
    PASS=$(printf '%s' "${VALKEY_EXTRA_FLAGS:-}" | sed -n 's/.*--requirepass \([^ ]*\).*/\1/p')
fi

vcli() {
    if [ -n "$PASS" ]; then
        "$CLI" -h 127.0.0.1 -p "$PORT" --user default --pass "$PASS" --no-auth-warning "$@"
    else
        "$CLI" -h 127.0.0.1 -p "$PORT" "$@"
    fi
}

# vcli_at <address> <args...> - the same, against another node in the cluster.
vcli_at() {
    addr=$1; shift
    if [ -n "$PASS" ]; then
        "$CLI" -h "$addr" -p "$PORT" --user default --pass "$PASS" --no-auth-warning "$@"
    else
        "$CLI" -h "$addr" -p "$PORT" "$@"
    fi
}

cget() { vcli config get "$1" 2>/dev/null | sed -n 2p; }

# Address selection.
#
# "The first non-loopback address" is not a valid answer on this platform. Two facts set the rule:
#   * the official Redis cluster package derives its announce address from **venet0** specifically
#     (jelastic-jps/redis-cluster, addons/auto-clustering/auto-cluster.jps) and re-applies it on every
#     topology event - so venet0 is where the platform puts the routable address;
#   * GetEnvInfo reports one address per node, and that is the address the platform itself considers
#     the node's identity.
# So the ranking is: an address the platform API also reports for this environment, then an address
# on a venet* interface, then anything else - and the last case says so out loud, naming every
# candidate, because a wrong announce address produces a handshake that never completes and nothing
# else.
addr_candidates() {
    # "iface address" per line, IPv4, loopback excluded
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | awk '/inet /{split($2, a, "/"); if (a[1] !~ /^127\./) print $NF" "a[1]}'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '/inet addr/{split($2, a, ":"); sub("inet addr:", "", a[1]);
            if (a[1] !~ /^127\./) {iface=$1; sub(":", "", iface); print iface" "a[1]}}'
    fi
}

own_addr() {
    # own_addr [known-addresses] - "known" is the peer list from the platform API, when it exists
    known=${1:-}
    cands=$(addr_candidates)
    [ -n "$cands" ] || return 0

    for c in $known; do
        if printf '%s\n' "$cands" | awk '{print $2}' | grep -qx "$c"; then
            printf '%s\n' "$c"
            return 0
        fi
    done

    venet=$(printf '%s\n' "$cands" | awk '$1 ~ /^venet/ {print $2; exit}')
    if [ -n "$venet" ]; then
        printf '%s\n' "$venet"
        return 0
    fi

    printf 'WARN announcing an address that is neither on venet0 nor in the platform node list:\n' >&2
    printf '     %s\n' "$(printf '%s\n' "$cands" | tr '\n' ' ')" >&2
    printf '%s\n' "$cands" | awk 'NR == 1 {print $2}'
}

# tcp_probe <address> <port> - can a TCP session be opened?
#
# Portability is deliberate: the image ships busybox nc, and busybox builds differ in which options
# they compile in (-z in particular). So try the quiet scan first and fall back to a connection
# closed immediately, which every nc can do. 0 connected, 1 refused or filtered, 2 no tool available
# (which is reported as unknown, never as a pass or a failure).
tcp_probe() {
    host=$1; port=$2
    if ! command -v nc >/dev/null 2>&1; then
        printf 'WARN nc is not in this image, so TCP reachability cannot be measured here\n' >&2
        return 2
    fi
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1 && return 0
    nc -w 3 "$host" "$port" </dev/null >/dev/null 2>&1 && return 0
    return 1
}

wait_for() {
    need=$1; secs=$2; i=0
    while [ "$i" -lt "$secs" ]; do
        if eval "$need" >/dev/null 2>&1; then return 0; fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

cluster_state() {
    vcli cluster info 2>/dev/null | tr -d '\r' | sed -n 's/^cluster_state:\(.*\)/\1/p'
}

cluster_nodes_known() {
    vcli cluster nodes 2>/dev/null | grep -c . || true
}

case "$ROLE" in
    prep)
        printf '=== prep on %s ===\n' "$(hostname)"
        # Recorded before anything else, because if this line is wrong every later line is wrong:
        # it is the address this node will tell the rest of the cluster to come and find it on.
        if command -v ip >/dev/null 2>&1; then
            printf 'interfaces:\n'
            ip -br addr 2>/dev/null | sed 's/^/  /' || true
        fi
        if ! vcli ping >/dev/null 2>&1; then
            printf 'FATAL valkey is not answering on 127.0.0.1:%s\n' "$PORT" >&2
            exit 2
        fi

        enabled=$(cget cluster-enabled)
        if [ "$enabled" != yes ]; then
            printf 'FAIL cluster-enabled = %s. It is a startup-only directive (IMMUTABLE_CONFIG), so\n' "${enabled:-?}" >&2
            printf '     neither CONFIG SET nor a config file edit can turn it on here: the node must\n' >&2
            printf '     carry --cluster-enabled yes in VALKEY_EXTRA_FLAGS. Check the node env vars.\n' >&2
            exit 1
        fi
        printf 'ok    cluster-enabled yes\n'

        # Runtime-settable, unlike cluster-enabled: verified in the 9.1.3 source.
        if vcli config set cluster-node-timeout "$TIMEOUT_MS" >/dev/null 2>&1; then
            printf 'ok    cluster-node-timeout %s\n' "$TIMEOUT_MS"
        else
            printf 'note  cluster-node-timeout could not be set at runtime; the startup flag carries it\n'
        fi

        # Everything the settings screen offers that is runtime-settable. It is applied here, from a
        # cmd line, rather than baked into VALKEY_EXTRA_FLAGS: the platform does not expand
        # placeholders inside a node env value (measured on a live node, where JELASTIC_PORTS arrived
        # as the literal text of its own placeholders), and an unexpanded
        # --maxmemory ${settings.maxMemory} is an unparseable argument that stops valkey-server from
        # starting at all.
        for pair in "maxmemory|v|$MAXMEM" "maxmemory-policy|v|$EVICTION" "appendonly|b|$AOF"; do
            name=${pair%%|*}; rest=${pair#*|}; kind=${rest%%|*}; value=${rest#*|}
            [ -n "$value" ] || continue
            if [ "$kind" = b ]; then
                # The dashboard can hand us a boolean; the directive cannot take one. A deployed node
                # died of exactly this at startup - "--appendonly true" is a FATAL CONFIG FILE ERROR -
                # so the conversion is not decoration, and an unrecognised word is refused here rather
                # than discovered by a server that never comes up.
                case $value in
                    true|1|True|TRUE) value=yes ;;
                    false|0|False|FALSE) value=no ;;
                    yes|no) : ;;
                    *) printf 'FAIL  %s: %s is not a yes/no value this script understands\n' "$name" "$value" >&2
                       exit 1 ;;
                esac
            fi
            if vcli config set "$name" "$value" >/dev/null 2>&1; then
                printf 'ok    %s applied\n' "$name"
            else
                printf 'FAIL  %s could not be set to %s at runtime\n' "$name" "$value" >&2
                exit 1
            fi
        done

        # requirepass/masterauth last: setting them locks this node's connections, including the one
        # making the call, so anything after them would have to authenticate.
        if [ -n "$PASS" ]; then
            for name in masterauth requirepass; do
                if vcli config set "$name" "$PASS" >/dev/null 2>&1 || [ "$(cget "$name")" = "$PASS" ]; then
                    printf 'ok    %s set, value not printed\n' "$name"
                else
                    printf 'FAIL  %s could not be set at runtime\n' "$name" >&2
                    exit 1
                fi
            done
        else
            printf 'WARN  no password reached this node; it is serving with requirepass unset\n' >&2
        fi

        addr=$(own_addr "$PEERS")
        if [ -z "$addr" ]; then
            printf 'WARN  this container has no non-loopback address to announce; gossip may pick 127.0.0.1\n' >&2
            printf '      candidates seen: %s\n' "$(addr_candidates | tr '\n' ' ')" >&2
        else
            printf 'address candidates: %s\n' "$(addr_candidates | tr '\n' ' ')"
            printf 'announce          : %s\n' "$addr"
            # Announce what a peer can actually reach. Left to itself, a node announces whatever it
            # resolves itself to, and inside a container that is often the wrong answer.
            for pair in "cluster-announce-ip $addr" "cluster-announce-port $PORT" "cluster-announce-bus-port $BUS_PORT"; do
                set -- $pair
                if vcli config set "$1" "$2" >/dev/null 2>&1; then
                    printf 'ok    %s = %s\n' "$1" "$2"
                else
                    printf 'WARN  %s rejected at runtime\n' "$1" >&2
                fi
            done
        fi

        printf 'note  in cluster mode Valkey uses cluster-databases (default 1); the databases\n'
        printf '      directive is ignored, which is why it is not set here\n'
        ;;

    form)
        printf '=== form on %s ===\n' "$(hostname)"
        # "  " is not empty to [ -z ] but it is empty to word splitting, and under set -e a
        # word-splitted grep that matches nothing would end this run with status 1 and no message.
        # That is the worst possible failure shape, so emptiness is tested on the characters.
        if [ -z "$(printf '%s' "$PEERS" | tr -d '[:space:]')" ]; then
            printf 'FAIL --peers is empty; the manifest could not read node addresses from GetEnvInfo\n' >&2
            exit 3
        fi

        peer_count=$(printf '%s\n' $PEERS | grep -c . || true)
        if [ "$peer_count" -lt 3 ]; then
            printf 'FAIL a cluster needs at least 3 nodes, the manifest passed %s\n' "$peer_count" >&2
            exit 3
        fi
        case "$REPLICAS" in
            1)
                need=$((peer_count / 2))
                printf 'note  %s nodes with 1 replica each leaves %s primaries\n' "$peer_count" "$need"
                ;;
            0) : ;;
            *) printf 'FAIL --replicas must be 0 or 1, got %s\n' "$REPLICAS" >&2; exit 3 ;;
        esac

        # Slots argument: --cluster create wants host:port per node.
        targets=""
        for p in $PEERS; do
            targets="$targets $p:$PORT"
        done

        if ! wait_for "vcli ping" 60; then
            printf 'FAIL this node never answered on %s\n' "$PORT" >&2
            exit 2
        fi

        # Everyone waits for everyone, before anybody talks to anybody. A create call that reaches
        # a node still starting is the failure that looks like a flaky cluster.
        for p in $PEERS; do
            if ! wait_for "vcli_at $p ping" 60; then
                printf 'FAIL peer %s is not answering on %s, refusing to form a partial cluster\n' "$p" "$PORT" >&2
                exit 1
            fi
            # "cluster_enabled" is a field of INFO, not of CLUSTER INFO (it is emitted from
            # server.c, not from the cluster reply), so ask for the directive itself.
            if [ "$(vcli_at "$p" config get cluster-enabled 2>/dev/null | sed -n 2p)" != yes ]; then
                printf 'FAIL peer %s is not cluster-enabled; it started without the cluster flags\n' "$p" >&2
                exit 1
            fi
            printf 'ok    peer %s is up and cluster-enabled\n' "$p"

            # 2. The address this peer tells everyone to come and find it on. The platform's own
            #    Redis cluster package writes this value from venet0 and re-applies it after every
            #    topology event; nothing does that for a custom image, so the authoritative value used
            #    here is the address GetEnvInfo reports. A mismatch is repaired before it is reported,
            #    because cluster-announce-ip is runtime-settable in 9.x (verified in the source).
            ann=$(vcli_at "$p" config get cluster-announce-ip 2>/dev/null | sed -n 2p)
            if [ "$ann" != "$p" ]; then
                printf 'note  peer %s advertises %s, the platform lists %s - re-advertising\n' "$p" "${ann:-nothing}" "$p"
                for pair in "cluster-announce-ip $p" "cluster-announce-port $PORT" "cluster-announce-bus-port $BUS_PORT"; do
                    set -- $pair
                    vcli_at "$p" config set "$1" "$2" >/dev/null 2>&1 || true
                done
                ann=$(vcli_at "$p" config get cluster-announce-ip 2>/dev/null | sed -n 2p)
                if [ "$ann" != "$p" ]; then
                    printf 'FAIL peer %s still advertises %s after CONFIG SET\n' "$p" "${ann:-nothing}" >&2
                    printf '     CLUSTER NODES would send every peer to %s, so this cluster cannot\n' "$ann" >&2
                    printf '     converge. Either CONFIG SET is refused on that node (check\n' >&2
                    printf '     enable-protected-configs) or %s is not an address that node has.\n' "$p" >&2
                    exit 1
                fi
                printf 'ok    peer %s now advertises %s\n' "$p" "$p"
            fi

            # 3. Whether inbound TCP is open on a custom image is a provider fact, not a Valkey fact,
            #    so it is measured rather than assumed. tcp_probe reports "not measured" when the
            #    image has no nc, which is stated out loud instead of being counted as a pass.
            for tp in "$PORT" "$BUS_PORT"; do
                tcp_probe "$p" "$tp" && rc=0 || rc=$?
                case $rc in
                    0) printf 'ok    tcp %s:%s is reachable\n' "$p" "$tp" ;;
                    2) printf 'note  tcp %s:%s not measured, this image has no nc\n' "$p" "$tp" ;;
                    *)
                        printf 'FAIL cannot open TCP to %s:%s from this node\n' "$p" "$tp" >&2
                        if [ "$tp" = "$BUS_PORT" ]; then
                            printf '     %s is the cluster-bus port. Every node must reach it; no Valkey\n' "$BUS_PORT" >&2
                            printf '     setting compensates for a filtered port. Run\n' >&2
                            printf '     probes/network-probe.jps and report its log with the platform\n' >&2
                            printf '     version to your provider.\n' >&2
                        fi
                        exit 1
                        ;;
                esac
            done
        done

        mine=$(own_addr "$PEERS")
        first=$(printf '%s\n' $PEERS | sort | sed -n 1p)
        if [ -n "$mine" ] && [ "$mine" != "$first" ]; then
            printf '%s is not the forming node (%s is); waiting for the result\n' "$mine" "$first"
            if wait_for '[ "$(cluster_state)" = ok ]' "$WAIT_SECS"; then
                printf 'ok    cluster is ok, seen from %s\n' "$(hostname)"
            else
                printf 'FAIL no cluster_state:ok within %ss as seen from %s\n' "$WAIT_SECS" "$(hostname)" >&2
                vcli cluster info 2>&1 | sed -n 1,6p >&2 || true
                exit 1
            fi
            exit 0
        fi

        known=$(cluster_nodes_known)
        if [ "$(cluster_state)" = ok ] && [ "$known" -ge "$peer_count" ]; then
            printf 'ok    cluster already formed (%s nodes known), nothing to do\n' "$known"
            exit 0
        fi

        printf 'forming a cluster from:%s (replicas per primary: %s)\n' "$targets" "$REPLICAS"
        # --cluster-yes because there is no operator on this console; --cluster-replicas 0 with 3
        # nodes gives 3 primaries and 16384 slots split three ways.
        if [ -n "$PASS" ]; then
            "$CLI" --cluster create $targets --cluster-replicas "$REPLICAS" --cluster-yes \
                --user default --pass "$PASS" --no-auth-warning 2>&1 | tail -25
        else
            "$CLI" --cluster create $targets --cluster-replicas "$REPLICAS" --cluster-yes 2>&1 | tail -25
        fi

        if ! wait_for '[ "$(cluster_state)" = ok ]' "$WAIT_SECS"; then
            printf 'FAIL --cluster create ran but cluster_state is not ok\n' >&2
            vcli cluster info 2>&1 | sed -n 1,8p >&2 || true
            printf '     usually the bus port (%s) is blocked: JELASTIC_PORTS must list it\n' "$BUS_PORT" >&2
            exit 1
        fi
        ;;

    check)
        printf '=== check on %s ===\n' "$(hostname)"
        vcli cluster info 2>/dev/null | tr -d '\r' | grep -E '^cluster_(state|slots_assigned|slots_ok|slots_fail|known_nodes|size|current_epoch):' || {
            printf 'FAIL CLUSTER INFO did not answer\n' >&2
            exit 1
        }
        printf '\nnodes:\n'
        vcli cluster nodes 2>/dev/null | tr -d '\r' \
            | awk '{printf "  %-8s %-22s %-14s %s\n", $3, $2, $4, $9}'
        state=$(cluster_state)
        fail=$(vcli cluster info 2>/dev/null | tr -d '\r' | sed -n 's/^cluster_slots_fail:\([0-9]*\)/\1/p')
        assigned=$(vcli cluster info 2>/dev/null | tr -d '\r' | sed -n 's/^cluster_slots_assigned:\([0-9]*\)/\1/p')
        size=$(vcli cluster info 2>/dev/null | tr -d '\r' | sed -n 's/^cluster_size:\([0-9]*\)/\1/p')
        if [ "$state" = ok ] && [ "${fail:-1}" = 0 ] && [ "${assigned:-0}" = 16384 ]; then
            printf '\nok    cluster_state=ok, 16384/16384 slots assigned, %s primary node(s)\n' "${size:-?}"
        else
            printf '\nFAIL cluster_state=%s slots_assigned=%s slots_fail=%s\n' "${state:-?}" "${assigned:-?}" "${fail:-?}" >&2
            printf '     a cluster with unassigned slots loses keys silently, so this is not a pass.\n' >&2
            exit 1
        fi
        ;;

    *)
        printf 'FAIL unknown --role %s (want prep, form or check)\n' "$ROLE" >&2
        exit 3
        ;;
esac
