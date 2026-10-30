#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
#
# probes/probe.sh - the networking question, answered with a TCP listener instead of a database.
#
# Before any Valkey logic matters, node A must be able to open a TCP connection to node B on the
# client port and on the cluster-bus port, at the address B tells the world it has. Everything else -
# slots, handshake, failover - is downstream of that. This script measures exactly that: a failure
# here is a platform networking fact, a pass here means a cluster failure is ours.
#
#   sh probe.sh --role listen  [--port N] [--bus-port N]      start listeners, record the node
#   sh probe.sh --role selftest [--port N] [--bus-port N]     prove the listener works on THIS node
#   sh probe.sh --role test --peers "ip ip ip" [--port N]     the connectivity matrix
#
# Why selftest exists: a failed connection means nothing until the test itself is validated. If the
# listeners never came up, every cross-node result would read FAIL and the platform would be blamed
# for a broken probe. selftest answers "is my own listener accepting connections" first, and the
# matrix refuses to run when it did not.
#
# POSIX sh over busybox applets: the valkey/valkey alpine image ships busybox 1.37 and nothing else -
# no bash, no curl, no iptables, no ss. Which busybox options are compiled in varies between builds,
# so nothing here assumes -z, -k or -L: the tool's own usage text is read, the capabilities are
# printed, and the connect test falls back to a form every nc can do.

set -eu

ROLE=listen
PEERS=""
CLIENT_PORT=6379
BUS_PORT=16379
LOG=${PROBE_LOG:-/var/log/jelastic-probe.log}

i=1
while [ $# -gt 0 ]; do
    opt=$1; value=; eq=0
    case $opt in
        *=*) value=${opt#*=}; opt=${opt%%=*}; eq=1 ;;
        *) if [ $# -ge 2 ]; then value=$2; else value=""; fi ;;
    esac
    case $opt in
        --role) ROLE=$value ;;
        --peers) PEERS=$value ;;
        --port) CLIENT_PORT=$value ;;
        --bus-port) BUS_PORT=$value ;;
        --log) LOG=$value ;;
        *) printf 'unknown argument: %s (accepted: --role, --peers, --port, --bus-port, --log)\n' "$1" >&2; exit 3 ;;
    esac
    if [ -z "$value" ]; then
        printf 'FAIL %s needs a value\n' "$opt" >&2
        exit 3
    fi
    if [ "$eq" = 1 ]; then shift 1; else shift 2; fi
    i=$((i + 1))
done

case $ROLE in listen|selftest|test|listen-one|stop) : ;; *)
    printf 'FAIL unknown --role %s (want listen, selftest, test or listen-one)\n' "$ROLE" >&2
    exit 3 ;;
esac

for p in "$CLIENT_PORT" "$BUS_PORT"; do
    case $p in ''|*[!0-9]*) printf 'FAIL a port must be a number, got %s\n' "$p" >&2; exit 3 ;; esac
done

mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG=./probe.log

say()  { printf '%s\n' "$1" | tee -a "$LOG"; }
log()  { printf '%s\n' "$1" >>"$LOG"; }
stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# ---------------------------------------------------------------- interfaces and capabilities

# all local IPv4 addresses, no mask, no loopback. Both the interface name and the address are kept:
# the interface name is evidence in its own right, because the platform's own Redis cluster package
# reads its announce address off venet0 specifically.
my_addrs() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | awk '/inet /{split($2, a, "/"); if (a[1] !~ /^127\./) print a[1]}'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '/inet addr/{split($2, a, ":"); sub("inet addr:", "", a[1]);
            if (a[1] !~ /^127\./) print a[1]}'
    fi
}

my_first_addr() { my_addrs | sed -n 1p; }

is_local() {
    a=$1
    for local_ in $(my_addrs); do
        [ "$a" = "$local_" ] && return 0
    done
    return 1
}

# Does this nc accept -z? Decided behaviourally rather than by reading the usage text, because the
# text differs between builds and a scraped answer is a guess. Port 1 is closed on any sane host: a
# tool that answers "connection refused" understood the flag, a tool that answers "illegal option"
# did not. An unsupported option is reported out loud, never silently worked around.
nc_supports_z() {
    command -v nc >/dev/null 2>&1 || return 1
    err=$(nc -z -w 1 127.0.0.1 1 2>&1 >/dev/null || true)
    case $err in
        *llegal*|*nvalid*|*nrecognized*|*not*found*) return 1 ;;
        *) return 0 ;;
    esac
}

nc_capabilities() {
    command -v nc >/dev/null 2>&1 || { printf 'no nc at all\n'; return 0; }
    # busybox nc has no -h (it answers "unrecognized option"), so the identity line comes from
    # calling it with nothing, which prints usage on every build tried.
    first=$(nc 2>&1 | sed -n 1p)
    if nc_supports_z; then
        printf '%s | -z accepted, quiet scan available\n' "$first"
    else
        printf '%s | -z NOT supported by this build, using a connect-and-close probe\n' "$first"
    fi
    # Keep-listening is reported for information only. Nothing depends on it: the listener here is a
    # re-arming loop, which works whether or not the build has -k or -L.
    # Not grep with --: busybox grep does not accept --, and on the live node this line went looking
    # for a file named "-k". A case statement needs no external tool.
    usage=$(nc 2>&1 || true)
    case $usage in *-lk*) printf '  -lk advertised (not required, the loop re-arms)\n' ;; esac
    case $usage in *"-L "*) printf '  -L advertised (not required, the loop re-arms)\n' ;; esac
}

# tcp_probe <address> <port> -> 0 open, 1 not open, 2 no tool to ask with
tcp_probe() {
    host=$1; port=$2
    command -v nc >/dev/null 2>&1 || return 2
    tries=0
    while [ "$tries" -lt 2 ]; do
        tries=$((tries + 1))
        if nc_supports_z; then
            nc -z -w 3 "$host" "$port" >/dev/null 2>&1 && return 0
        fi
        # the form that needs no optional flags, so a build without -z still gets measured
        nc -w 3 "$host" "$port" </dev/null >/dev/null 2>&1 && return 0
        # one retry: a re-arming listener spends a moment between accepting one connection and
        # binding again, and that window must not read as a blocked port
        [ "$tries" -lt 2 ] && sleep 1
    done
    return 1
}

# What is bound right now, read straight from /proc so it does not depend on netstat or ss being
# in the image (they are not). The state column 0A is LISTEN; the port is hex, and busybox awk has
# no strtonum, so the conversion is done by hand.
tcp_files() {
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] && printf '%s\n' "$f"
    done
}

# Both tables are scanned. busybox nc binds IPv6 by default on some builds, and a probe that read
# only /proc/net/tcp would then report a live listener as missing - which is exactly the false
# "port never reached LISTEN" this script produced on 2026-10-27 before the second table was added.
listeners_dump() {
    files=$(tcp_files)
    if [ -n "$files" ]; then
        # shellcheck disable=SC2086
        awk 'FNR > 1 && $4 == "0A" {
                split($2, a, ":"); hex = toupper(a[2]); n = 0
                for (i = 1; i <= length(hex); i++)
                    n = n * 16 + index("0123456789ABCDEF", substr(hex, i, 1)) - 1
                print "  LISTEN :" n
            }' $files | sort -u -n -k1.9
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | tail -n +3 | sed 's/^/  /'
    else
        printf '  (no /proc/net/tcp and no netstat in this image)\n'
    fi
}

port_listening() {
    files=$(tcp_files)
    [ -n "$files" ] || return 0
    want=$(printf '%04X' "$1" 2>/dev/null) || return 0
    # shellcheck disable=SC2086
    awk -v w="$want" 'FNR > 1 && $4 == "0A" {split($2, a, ":"); if (toupper(a[2]) == w) found = 1} END {exit !found}' $files
}

# ---------------------------------------------------------------- listeners

# The listener has to accept more than one connection, and this busybox may have neither -k nor -L.
# So the listener is a loop that re-arms after every accepted connection - that works on any nc -
# and the command form is discovered once, because busybox has been shipped as `nc -l -p N`,
# `nc -lt N` and `nc -l N` at different times.
listen_cmd_form() {
    # Prints the command that binds this port, or "already-listening" when something - usually this
    # probe's own loop, on a second run of the step - holds it already. Conflating those two is how a
    # re-run of the listen step reports "no nc listen form worked" while the port is in fact up.
    port=$1
    if port_listening "$port"; then
        printf 'already-listening\n'
        return 0
    fi

    err=$(mktemp 2>/dev/null || printf '/tmp/probe-nc-err-%s' "$$")
    # Order matters and is not a guess. The nc shipped in valkey/valkey:9.1.3-alpine3.24 is busybox
    # 1.37.0, whose usage line reads "nc [OPTIONS] -l -p PORT [HOST] [PORT]": -lt PORT is not a
    # listen form at all on that build (it exits 1), and busybox has neither -k nor -L. Measured on
    # 2026-10-27 by running that binary, because every earlier version of this loop was written
    # against a guess.
    for form in "nc -l -p $port" "nc -l 0.0.0.0 $port" "nc -lt $port"; do
        $form </dev/null >/dev/null 2>"$err" &
        pid=$!
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            # still alive after a second, so it bound the port rather than erroring out
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            rm -f "$err"
            printf '%s\n' "$form"
            return 0
        fi
        case $(cat "$err" 2>/dev/null || true) in
            *ddress*in*use*|*EADDRINUSE*)
                wait "$pid" 2>/dev/null || true
                if port_listening "$port"; then
                    rm -f "$err"
                    printf 'already-listening\n'
                    return 0
                fi
                ;;
        esac
        wait "$pid" 2>/dev/null || true
    done
    rm -f "$err"
    return 1
}

# The re-arm loop is a child of a shell step, so its nc survives if the loop shell is killed. The
# stop role clears both, which is what makes the probe re-runnable on the same nodes.
pidfile() { printf '%s/probe-listener-%s.pid' "${PROBE_PID_DIR:-/tmp}" "$1"; }

stop_listeners() {
    # By pidfile, deliberately. The first version used pgrep -f, which also matches the shell that
    # invoked it - and killed it. A pidfile names exactly the process this probe started.
    for p in "$CLIENT_PORT" "$BUS_PORT"; do
        pf=$(pidfile "$p")
        if [ -f "$pf" ]; then
            pid=$(cat "$pf" 2>/dev/null || true)
            case $pid in
                ''|*[!0-9]*) printf 'note  %s holds no pid\n' "$pf" ;;
                *) kill "$pid" 2>/dev/null && printf 'listener %s (pid %s) stopped\n' "$p" "$pid" || printf 'note  pid %s was already gone\n' "$pid" ;;
            esac
            rm -f "$pf"
        else
            printf 'note  no pidfile for port %s; nothing this probe started\n' "$p"
        fi
    done
}

case $ROLE in
    listen)
        {
            printf '=== probe:listen %s host=%s ===\n' "$(stamp)" "$(hostname 2>/dev/null || echo unknown)"
            if command -v ip >/dev/null 2>&1; then
                # No `ip -br addr`: the busybox on valkey/valkey:*-alpine has no -br and answers
                # with its usage text (measured on the live node), which buries the interfaces.
                log '-- ip addr --';     ip -4 addr show 2>&1 | sed 's/^/  /' >>"$LOG" 2>&1 || true
                log '-- ip route --';    ip route 2>&1    | sed 's/^/  /' >>"$LOG" 2>&1 || true
            else
                log '(ip command absent)'; ifconfig -a 2>&1 | sed 's/^/  /' >>"$LOG" 2>&1 || true
            fi
            log '-- addresses this node has --'
            log "  $(my_addrs | tr '\n' ' ')"
            log '-- nc capabilities --'
            log "  $(nc_capabilities)"
            log '-- packet filter --'
            if command -v iptables >/dev/null 2>&1; then
                iptables -S 2>&1 | head -40 >>"$LOG" || log '  (iptables present, unreadable)'
            elif command -v nft >/dev/null 2>&1; then
                nft list ruleset 2>&1 | head -40 >>"$LOG" || log '  (nft present, unreadable)'
            else
                log '  (no iptables and no nft in this image, so nothing filters inside the container.'
                log '   Any filtering that exists sits above it - platform firewall, provider network'
                log '   or host - and only the connection matrix can show it.)'
            fi
            log "-- JELASTIC_PORTS as this node sees it: '${JELASTIC_PORTS:-not set}'"
        } >>"$LOG" 2>&1

        for p in "$CLIENT_PORT" "$BUS_PORT"; do
            form=$(listen_cmd_form "$p") || {
                printf 'FAIL port %s: no nc listen form worked (tried -l -p, -lt, -l). The probe cannot test what it cannot serve.\n' "$p" >&2
                exit 2
            }
            # Detached re-arm loop. nohup so the loop survives this step's shell exiting; the
            # redirect keeps a chatty nc from writing into the install log.
            if [ "$form" = "already-listening" ]; then
                printf 'listener %s is already in LISTEN; no new loop started\n' "$p"
                continue
            fi
            nohup sh "$0" --role listen-one --port "$p" --log "$LOG" >/dev/null 2>&1 &
            # Do not report a listener that is not yet in LISTEN. Running this probe by hand on
            # 2026-10-27 produced a false "no listener" in the self-test for exactly the first two
            # seconds after this step, because the loop had not bound the port yet.
            n=0
            until port_listening "$p"; do
                n=$((n + 1))
                if [ "$n" -ge 10 ]; then
                    printf 'FAIL port %s never reached LISTEN within 10s\n' "$p" >&2
                    printf '     what is bound now: %s\n' "$(listeners_dump | tr -s ' \n' ' ')" >&2
                    exit 2
                fi
                sleep 1
            done
            printf 'listener %s is in LISTEN (%s), re-arming after each connection\n' "$p" "$form"
        done
        printf 'recorded so far: %s\n' "$LOG"
        ;;

    listen-one)
        # The re-arm loop for one port. Only --port is honoured here, so a caller cannot point the
        # loop at an arbitrary command.
        form=$(listen_cmd_form "$CLIENT_PORT") || exit 2
        if [ "$form" = "already-listening" ]; then
            exit 0
        fi
        printf '%s\n' "$$" > "$(pidfile "$CLIENT_PORT")" || true
        # The trap matters: nc is a child of this loop, so killing the loop alone would leave nc
        # holding the port with nothing to re-arm it.
        ncpid=
        trap 'kill $ncpid 2>/dev/null; rm -f "$(pidfile "$CLIENT_PORT")"; exit 0' TERM INT
        while :; do
            $form </dev/null >/dev/null 2>&1 &
            ncpid=$!
            wait "$ncpid" || sleep 1
        done
        ;;

    stop)
        stop_listeners
        ;;

    selftest)
        printf '=== probe:selftest %s ===\n' "$(stamp)"
        printf 'nc capabilities: %s\n' "$(nc_capabilities)"
        addrs=$(my_addrs)
        if [ -z "$addrs" ]; then
            say 'FAIL this node reports no non-loopback address; the probe cannot identify it'
            exit 2
        fi
        printf 'addresses: %s\n' "$addrs"
        fails=0
        for target in 127.0.0.1 $addrs; do
            for port in "$CLIENT_PORT" "$BUS_PORT"; do
                tcp_probe "$target" "$port" && rc=0 || rc=$?
                case $rc in
                    0) say "ok       listener answers on $target:$port" ;;
                    2) say "unknown  cannot test $target:$port, no nc in this image"; fails=$((fails + 1)) ;;
                    *) say "FAIL     no listener on $target:$port"
                       port_listening "$port" || say "         and /proc/net/tcp agrees: nothing is bound to $port"
                       fails=$((fails + 1)) ;;
                esac
            done
        done
        if [ "$fails" -gt 0 ]; then
            say 'SELF-TEST FAILED: this node''s own listener is not accepting connections. Do not'
            say 'attribute any cross-node result below to the platform - the test itself is broken.'
            say 'listeners seen: ('; listeners_dump; say ')'
            exit 1
        fi
        say 'ok    the probe works on this node; cross-node results below mean what they say'
        ;;

    test)
        [ -n "$PEERS" ] || { printf 'FAIL --peers is empty; discovery produced no addresses\n' >&2; exit 1; }
        printf '=== probe:test %s from %s ===\n' "$(stamp)" "$(my_first_addr)"
        printf 'nc capabilities: %s\n' "$(nc_capabilities)"

        # Never test the harness before testing the network: if our own listener is down, every
        # FAIL below would be a false accusation against the platform.
        if ! sh "$0" --role selftest --port "$CLIENT_PORT" --bus-port "$BUS_PORT" --log "$LOG"; then
            printf 'FAIL self-test failed on this node, refusing to report a matrix\n' >&2
            exit 1
        fi

        fails=0; tests=0; skipped=0
        for p in $PEERS; do
            if is_local "$p"; then
                skipped=$((skipped + 1))
                say "SKIP     $p is this node"
                continue
            fi
            for port in "$CLIENT_PORT" "$BUS_PORT"; do
                tests=$((tests + 1))
                tcp_probe "$p" "$port" && rc=0 || rc=$?
                case $rc in
                    0) say "PASS     $(my_first_addr) -> $p:$port" ;;
                    2) say "UNKNOWN  $(my_first_addr) -> $p:$port (no nc in this image)"
                        fails=$((fails + 1)) ;;
                    *) say "FAIL     $(my_first_addr) -> $p:$port"
                        fails=$((fails + 1)) ;;
                esac
            done
        done
        say "matrix: $tests connection test(s), $fails failed, $skipped node(s) skipped as local"
        [ "$fails" -eq 0 ] || {
            say 'The matrix failed. Compare it with the packet-filter dump and the addresses'
            say 'recorded by --role listen on the same nodes, then take it to the provider with'
            say 'the platform version.'
            exit 1
        }
        ;;

    *)
        printf 'FAIL unknown --role %s\n' "$ROLE" >&2
        exit 3
        ;;
esac
