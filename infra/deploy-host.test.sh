#!/bin/sh
# End-to-end test of deploy-host-setup.sh, deploy-host-add.sh and ninja-deploy
# over real SSH, sudo and systemd. It creates users, units, sudo rules and
# /srv directories, so it runs only as root on a throwaway machine (CI=true),
# with sshd running. Needs python3, curl and ssh-keygen.
#
# A fake service stands in for a real one: a shell script serving
# {"version": ...} from the version.json next to it (0.0.1 when there is none,
# 0.0.0 when the release holds a file named `broken`). Started with the
# argument `broken`, it exits at once.
set -eu

if [ "$(id -u)" -ne 0 ] || [ "${CI:-}" != true ]; then
    echo "deploy-host.test.sh: only as root on a throwaway CI machine (CI=true)" >&2
    exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

cat > /usr/local/bin/fakesvc <<'EOF'
#!/bin/sh
[ "${1:-}" = broken ] && exit 1
d=$(dirname "$(readlink -f "$0")")
v=$(sed -n 's/.*"version" *: *"v\{0,1\}\([^"]*\)".*/\1/p' "$d/version.json" 2>/dev/null || true)
[ -n "$v" ] || v=0.0.1
[ -e "$d/broken" ] && v=0.0.0
printf '{"status":"ok","version":"%s"}' "$v" > "$RUNTIME_DIRECTORY/healthz"
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$RUNTIME_DIRECTORY"
EOF
chmod 0755 /usr/local/bin/fakesvc
for svc in fakesvc:18080 badsvc:18081; do
    cat > "/etc/systemd/system/${svc%%:*}.service" <<EOF
[Service]
DynamicUser=yes
RuntimeDirectory=${svc%%:*}
Environment=PORT=${svc##*:}
ExecStart=/usr/local/bin/fakesvc
EOF
done
systemctl daemon-reload
systemctl start fakesvc badsvc

version_on() { # <port>: the version the service reports, after up to 10 s
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        v=$(curl -fsS "http://127.0.0.1:$1/healthz" 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p') && [ -n "$v" ] && break
        sleep 1
    done
    echo "${v:-none}"
}
[ "$(version_on 18080)" = 0.0.1 ] || fail "fake service did not start"

# Host setup, twice: it must be safe to run again.
sh "$here/deploy-host-setup.sh" --env staging >/dev/null
sh "$here/deploy-host-setup.sh" --env staging >/dev/null
[ -x /usr/local/sbin/ninja-deploy ] || fail "ninja-deploy not installed"
grep -qx 'ENV=staging' /etc/ninja-deploy/env || fail "env file"
[ "$(getent shadow deploy | cut -d: -f2)" = '*' ] || fail "deploy user password is not *"
ok "host setup, run twice"

ssh-keygen -q -t ed25519 -N '' -C ci-fakesvc -f "$t/key"
ssh-keygen -q -t ed25519 -N '' -C ci-fakesvc-new -f "$t/key2"
ssh-keygen -q -t ed25519 -N '' -C ci-badsvc -f "$t/key3"
ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null > "$t/known_hosts"
remote() { # <key> <command...>
    k=$1; shift
    ssh -i "$k" -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR \
        -o UserKnownHostsFile="$t/known_hosts" -o StrictHostKeyChecking=yes deploy@127.0.0.1 "$@"
}
add() { sh "$here/deploy-host-add.sh" "$@"; }

# Adopt the running service into /srv.
cp /usr/local/bin/fakesvc /usr/local/bin/fakesvc-orig
add fakesvc --unit fakesvc --health-url http://127.0.0.1:18080/healthz \
    --key "$(cat "$t/key.pub")" --keep 2 \
    --adopt /usr/local/bin/fakesvc v0.0.1 --exec-args '' --link >/dev/null
[ "$(readlink /srv/fakesvc/current)" = /srv/fakesvc/releases/v0.0.1 ] || fail "current after adopt"
systemctl show -p ExecStart --value fakesvc | grep -q 'path=/srv/fakesvc/current/fakesvc' \
    || fail "unit not pointed at current: $(systemctl show -p ExecStart --value fakesvc)"
[ "$(version_on 18080)" = 0.0.1 ] || fail "service unhealthy after adopt"
grep -q '"version":"v0.0.1"' /srv/fakesvc/live.json || fail "live.json after adopt"
[ "$(readlink /usr/local/bin/fakesvc)" = /srv/fakesvc/current/fakesvc ] || fail "--link: no symlink to current"
cmp -s /usr/local/bin/fakesvc.pre-deploy /usr/local/bin/fakesvc-orig || fail "--link: original not kept"
ok "adopt moves a running service into /srv; --link points the old path at current"

# A failed adoption (here, new ExecStart arguments that make it exit) puts the
# old setup back.
if add badsvc --unit badsvc --health-url http://127.0.0.1:18081/healthz \
    --key "$(cat "$t/key3.pub")" --adopt /usr/local/bin/fakesvc v0.0.1 --exec-args broken >/dev/null 2>&1; then
    fail "an adoption whose service does not start succeeded"
fi
[ ! -e /etc/systemd/system/badsvc.service.d/ninja-deploy.conf ] || fail "drop-in left behind"
if [ -e /srv/badsvc/current ] || [ -e /srv/badsvc/releases/v0.0.1 ]; then fail "adoption leftovers"; fi
[ "$(version_on 18081)" = 0.0.1 ] || fail "service not restored after a failed adopt"
ok "failed adoption restores the old setup"

package() { # <version> [broken]
    rm -rf "$t/pkg" && mkdir -p "$t/pkg/fakesvc"
    cp /usr/local/bin/fakesvc "$t/pkg/fakesvc/"
    printf '{"version":"%s","commit":"c%s","built_at":"x"}\n' "$1" "$1" > "$t/pkg/fakesvc/version.json"
    [ $# -gt 1 ] && touch "$t/pkg/fakesvc/broken"
    tar -czf "$t/release.tgz" -C "$t/pkg" fakesvc
}

# Deploy over SSH, exactly as the deploy action does.
remote "$t/key" has v0.0.2 && fail "has for a version not on disk"
package v0.0.2
remote "$t/key" upload v0.0.2 < "$t/release.tgz" >/dev/null || fail "upload"
remote "$t/key" activate v0.0.2 >/dev/null || fail "activate"
[ "$(version_on 18080)" = 0.0.2 ] || fail "not serving v0.0.2"
grep -q '"version":"v0.0.2"' /srv/fakesvc/live.json || fail "live.json after deploy"
ok "deploy over SSH: upload, activate, restart through sudo"

package v0.0.3 broken
remote "$t/key" upload v0.0.3 < "$t/release.tgz" >/dev/null
remote "$t/key" activate v0.0.3 >/dev/null 2>&1 && fail "unhealthy release activated"
[ "$(readlink /srv/fakesvc/current)" = /srv/fakesvc/releases/v0.0.2 ] || fail "not rolled back"
[ "$(version_on 18080)" = 0.0.2 ] || fail "not serving v0.0.2 after rollback"
ok "unhealthy release rolls back"

# The key runs ninja-deploy and nothing else; the user may restart its unit only.
out=$(remote "$t/key" id 2>&1) && fail "a shell command ran: $out"
echo "$out" | grep -q 'usage' || fail "unexpected answer to a shell command: $out"
remote "$t/key" list | grep -qx 'v0.0.2 (live)' || fail "list"
runuser -u deploy -- sudo -n systemctl restart ssh 2>/dev/null && fail "deploy may restart another unit"
runuser -u deploy -- sudo -n systemctl status fakesvc.service >/dev/null || fail "deploy may not check its unit"
ok "forced command and sudo rule hold"

# A key already used for one service is refused for another.
if add other --unit fakesvc --health-url http://127.0.0.1:18080/healthz \
    --key "$(cat "$t/key.pub")" >/dev/null 2>&1; then
    fail "one key accepted for two services"
fi
[ ! -e /etc/ninja-deploy/other.conf ] || fail "a refused key still left settings behind"
ok "a key cannot serve two services"

# Running add again rotates the key and keeps what is deployed.
add fakesvc --unit fakesvc --health-url http://127.0.0.1:18080/healthz \
    --key "$(cat "$t/key2.pub")" --keep 2 >/dev/null
[ "$(grep -c 'ninja-deploy fakesvc"' ~deploy/.ssh/authorized_keys)" = 1 ] || fail "duplicate keys"
remote "$t/key" list >/dev/null 2>&1 && fail "the old key still works"
remote "$t/key2" list | grep -qx 'v0.0.2 (live)' || fail "new key, or the live release changed"
ok "re-running add rotates the key and keeps the live release"
[ "$(readlink /usr/local/bin/fakesvc)" = /srv/fakesvc/current/fakesvc ] || fail "--link changed by a later run"

# --health-wait reaches ninja-deploy's settings; nonsense is refused before anything changes.
add fakesvc --unit fakesvc --health-url http://127.0.0.1:18080/healthz \
    --key "$(cat "$t/key2.pub")" --keep 2 --health-wait 120 >/dev/null
grep -qx 'HEALTH_WAIT=120' /etc/ninja-deploy/fakesvc.conf || fail "HEALTH_WAIT not written"
if add fakesvc --unit fakesvc --health-url http://127.0.0.1:18080/healthz \
    --key "$(cat "$t/key2.pub")" --health-wait soon >/dev/null 2>&1; then
    fail "--health-wait soon accepted"
fi
grep -qx 'HEALTH_WAIT=120' /etc/ninja-deploy/fakesvc.conf || fail "a refused run changed the settings"
ok "--health-wait is written for ninja-deploy, and checked"

echo "all deploy-host tests passed"
