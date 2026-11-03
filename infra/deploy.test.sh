#!/bin/sh
# Exercises infra/deploy.sh against a fake service: a fake `sudo systemctl`
# that "restarts" by publishing the live release's version (or a broken
# answer) on a local HTTP health endpoint. Needs python3 and curl.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
trap 'kill "$server" 2>/dev/null || true; rm -rf "$t"' EXIT

mkdir -p "$t/etc" "$t/srv/svc/releases" "$t/srv/svc/shared" "$t/bin" "$t/www"
echo data > "$t/srv/svc/shared/state.db"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
echo 'ENV=test' > "$t/etc/env"
cat > "$t/etc/svc.conf" <<EOF
UNIT=svc
HEALTH_URL=http://127.0.0.1:$port/healthz
SHARED=state.db
KEEP=2
HEALTH_WAIT=3
EOF

# `sudo -n systemctl restart|status svc`: a release containing `broken`
# answers with the wrong version, as if the new process never came up.
cat > "$t/bin/sudo" <<EOF
#!/bin/sh
[ "\$1" = -n ] && shift
[ "\$1" = systemctl ] || exit 1
case \$2 in
restart)
    cur=\$(readlink "$t/srv/svc/current")
    if [ -e "\$cur/broken" ]; then v=0.0.0; else v=\${cur##*/v}; fi
    printf '{"status":"ok","version":"%s"}' "\$v" > "$t/www/healthz" ;;
status) echo "svc status" ;;
esac
EOF
chmod +x "$t/bin/sudo"
(cd "$t/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
server=$!

export PATH="$t/bin:$PATH" NINJA_DEPLOY_ETC="$t/etc" NINJA_DEPLOY_SRV="$t/srv"
run() { SSH_ORIGINAL_COMMAND="$*" sh "$here/deploy.sh" svc; }
tarball() { # <version> [broken]
    rm -rf "$t/pkg" && mkdir -p "$t/pkg/svc"
    printf '{"version":"%s","commit":"abc%s","built_at":"x"}\n' "$1" "$1" > "$t/pkg/svc/version.json"
    [ $# -gt 1 ] && touch "$t/pkg/svc/broken"
    tar -czf - -C "$t/pkg" svc
}
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
live() { readlink "$t/srv/svc/current" | sed 's|.*/||'; }

for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fs "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.2; done

tarball v1.0.0 | run upload v1.0.0 >/dev/null
run has v1.0.0 || fail "has after upload"
run has v9.9.9 && fail "has for a missing version"
run activate v1.0.0 >/dev/null || fail "first activate"
[ "$(live)" = v1.0.0 ] || fail "live is $(live)"
grep -q '"commit":"abcv1.0.0"' "$t/srv/svc/live.json" || fail "live.json: $(cat "$t/srv/svc/live.json")"
[ "$(cat "$t/srv/svc/releases/v1.0.0/state.db")" = data ] || fail "shared item not linked"
ok "upload, activate, live.json and shared links"

tarball v1.0.0 | run upload v1.0.0 | grep -q 'already on disk' || fail "re-upload not skipped"
ok "re-upload is skipped"

tarball v1.1.0 broken | run upload v1.1.0 >/dev/null
out=$(run activate v1.1.0) && fail "unhealthy activate succeeded"
[ "$(live)" = v1.0.0 ] || fail "not rolled back, live is $(live)"
echo "$out" | grep -q 'rolled back to v1.0.0' || fail "no rollback message: $out"
grep -q '"version":"v1.0.0"' "$t/srv/svc/live.json" || fail "live.json changed by a failed deploy"
ok "unhealthy release rolls back to the previous one"

tarball v1.2.0 | run upload v1.2.0 >/dev/null
run activate v1.2.0 >/dev/null || fail "activate v1.2.0"
run activate v1.0.0 >/dev/null || fail "roll back by activating an older release"
[ "$(live)" = v1.0.0 ] || fail "manual rollback, live is $(live)"
ok "rollback by activating an older release"

sleep 1 # distinct mtimes for pruning
tarball v1.3.0 | run upload v1.3.0 >/dev/null
run activate v1.3.0 >/dev/null || fail "activate v1.3.0"
[ -d "$t/srv/svc/releases/v1.0.0" ] || fail "pruned the previous release"
[ -d "$t/srv/svc/releases/v1.1.0" ] && fail "kept more than KEEP=2 old releases"
run list | grep -qx 'v1.3.0 (live)' || fail "list: $(run list)"
ok "pruning keeps KEEP releases plus the previous one; list marks live"

run activate 'v1.0.0;id' 2>/dev/null && fail "accepted a bad version"
run activate ../x 2>/dev/null && fail "accepted a path"
run rm -rf / 2>/dev/null && fail "accepted an unknown action"
tar -czf - -C "$here" deploy.sh | run upload v2.0.0 2>/dev/null && fail "accepted a release without version.json"
[ -e "$t/srv/svc/releases/v2.0.0" ] && fail "left a bad upload behind"
SSH_ORIGINAL_COMMAND=list sh "$here/deploy.sh" other 2>/dev/null && fail "accepted an unknown service"
ok "rejects bad versions, actions, services and releases"

echo "all deploy.sh tests passed"
