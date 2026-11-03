#!/bin/sh
# Let CI deploy one service to this host. Run as root, after
# deploy-host-setup.sh. Safe to run again: it replaces the service's key,
# settings and sudo rule, and never touches releases already on disk.
#
#   sudo ./infra/deploy-host-add.sh <service> --unit <unit> --health-url <url> \
#       --key '<ssh public key>' [--shared '<items>'] [--keep <n>] \
#       [--adopt <installed binary> <its version> --exec-args '<arguments>']
#
#   --unit        systemd unit to restart, e.g. ninja-monitor.service
#   --health-url  loopback URL answering 2xx, with "version" in its JSON if it can
#   --key         public half of the key whose private half is the repository's
#                 DEPLOY_SSH_KEY secret; it is forced to `ninja-deploy <service>`
#   --shared      names under /srv/<service>/shared/ linked into every release
#   --keep        releases kept on disk (default 5)
#   --adopt       move a service that is already running into /srv: copy the
#                 installed binary in as the first release, point the unit at
#                 /srv/<service>/current/<binary> with a drop-in, restart and
#                 health-check it. If it is not healthy the drop-in is removed
#                 and the old setup restarted. --exec-args gives the arguments
#                 for the new ExecStart (the unit's current ones, usually).
set -eu

user=deploy
etc=/etc/ninja-deploy
deployer=/usr/local/sbin/ninja-deploy

die() { echo "deploy-host-add.sh: $*" >&2; exit 1; }

service=${1:-}
case $service in
    -h | --help) sed -n '2,22s/^# \{0,1\}//p' "$0"; exit 0 ;;
    '' | -* | *[!a-z0-9-]*) die "first argument: a service name (a-z, 0-9, -); try --help" ;;
esac
shift
unit='' health_url='' key='' shared='' keep=5 adopt_bin='' adopt_version='' exec_args='' have_exec_args=no
while [ $# -gt 0 ]; do
    case $1 in
        --unit) shift; unit=${1:-} ;;
        --health-url) shift; health_url=${1:-} ;;
        --key) shift; key=${1:-} ;;
        --shared) shift; shared=${1:-} ;;
        --keep) shift; keep=${1:-} ;;
        --adopt) shift; adopt_bin=${1:-}; shift; adopt_version=${1:-} ;;
        --exec-args) shift; exec_args=${1-}; have_exec_args=yes ;;
        *) die "unknown argument $1 (try --help)" ;;
    esac
    [ $# -gt 0 ] && shift
done

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -x "$deployer" ] && [ -r "$etc/env" ] && id "$user" >/dev/null 2>&1 \
    || die "run deploy-host-setup.sh first"

case $unit in
    '') die "--unit is required" ;;
    *.*) ;;
    *) unit=$unit.service ;;
esac
case $unit in *[!A-Za-z0-9@._-]*) die "bad unit name $unit" ;; esac
systemctl cat "$unit" >/dev/null 2>&1 || die "no systemd unit $unit"

case $health_url in
    http://127.0.0.1:* | http://localhost:* | 'http://[::1]:'*) ;;
    *) die "--health-url must be a loopback http:// URL" ;;
esac
case $health_url in *[!A-Za-z0-9:/._~?=\&%-]*) die "unexpected characters in --health-url" ;; esac
case $keep in '' | *[!0-9]*) die "--keep takes a number" ;; esac
[ "$keep" -ge 2 ] || die "--keep must be at least 2 (the live release and the one before)"
case $shared in *[!A-Za-z0-9._\ -]*) die "--shared takes space-separated file names" ;; esac

# A bare public key: type, base64, optional comment. No options, which this
# script sets itself.
printf '%s' "$key" | grep -Eqx '(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com) [A-Za-z0-9+/]+=* ?[A-Za-z0-9@._+-]*' \
    || die "--key must be one public key line, e.g. 'ssh-ed25519 AAAA... ci-$service'"

if [ -n "$adopt_bin" ] || [ -n "$adopt_version" ]; then
    [ -x "$adopt_bin" ] && [ -f "$adopt_bin" ] || die "--adopt: $adopt_bin is not an executable file"
    printf '%s' "$adopt_version" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' \
        || die "--adopt: version '$adopt_version' should look like v1.2.3"
    [ "$have_exec_args" = yes ] || die "--adopt needs --exec-args (use '' for none)"
    nl='
'
    case $exec_args in *"$nl"*) die "--exec-args must be one line" ;; esac
fi

root=/srv/$service
install -d -m 0755 -o "$user" -g "$user" "$root" "$root/releases"
install -d -m 0755 -o root -g root "$root/shared"

# Settings, sourced by ninja-deploy.
conf=$etc/$service.conf
{
    printf "UNIT='%s'\n" "$unit"
    printf "HEALTH_URL='%s'\n" "$health_url"
    printf "SHARED='%s'\n" "$shared"
    printf "KEEP=%s\n" "$keep"
} > "$conf.new"
chmod 0644 "$conf.new"
mv -f "$conf.new" "$conf"
echo "wrote $conf"

# sudo for exactly the two commands ninja-deploy runs.
systemctl=$(command -v systemctl)
rule=/etc/sudoers.d/ninja-deploy-$service
printf '%s ALL=(root) NOPASSWD: %s restart %s, %s status %s\n' \
    "$user" "$systemctl" "$unit" "$systemctl" "$unit" > "$rule.tmp"
chmod 0440 "$rule.tmp"
if ! visudo -c -f "$rule.tmp" >/dev/null; then
    rm -f "$rule.tmp"
    die "visudo rejected the sudo rule; nothing changed"
fi
mv -f "$rule.tmp" "$rule"
echo "wrote $rule"

# The key, forced to this service. Any earlier key for it is replaced.
home=$(getent passwd "$user" | cut -d: -f6)
keys=$home/.ssh/authorized_keys
line="command=\"$deployer $service\",restrict $key"
{
    grep -vF "command=\"$deployer $service\"," "$keys" 2>/dev/null || true
    printf '%s\n' "$line"
} > "$keys.new"
chown "$user:$user" "$keys.new"
chmod 0600 "$keys.new"
mv -f "$keys.new" "$keys"
echo "authorized the key for $service in $keys"

json_version() { sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p'; }

# Up to 30 s for the health URL to answer with the expected version.
healthy() {
    want=${1#v} i=0 body=
    while [ "$i" -lt 30 ]; do
        if body=$(curl -fsS --max-time 2 "$health_url" 2>/dev/null); then
            got=$(printf '%s' "$body" | json_version)
            if [ -z "$got" ] || [ "${got#v}" = "$want" ]; then
                echo "healthy: $body"
                return 0
            fi
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "not healthy after 30 s; last response: ${body:-none}"
    return 1
}

if [ -n "$adopt_bin" ]; then
    dropin_dir=/etc/systemd/system/$unit.d
    dropin=$dropin_dir/ninja-deploy.conf
    if [ -e "$root/current" ]; then
        echo "$root/current already exists; not adopting again"
    else
        name=$(basename "$adopt_bin")
        release=$root/releases/$adopt_version
        [ -e "$release" ] && die "$release already exists; remove it or adopt under another version"
        tmp=$(mktemp -d "$root/releases/.adopt.XXXXXX")
        cp "$adopt_bin" "$tmp/$name"
        printf '{"version":"%s","commit":"adopted","built_at":"%s"}\n' \
            "$adopt_version" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp/version.json"
        chmod 0755 "$tmp" "$tmp/$name"
        chmod 0644 "$tmp/version.json"
        chown -R "$user:$user" "$tmp"
        mv -T "$tmp" "$release"
        # Absolute, as ninja-deploy writes it.
        ln -sfn "$release" "$root/current"
        chown -h "$user:$user" "$root/current"

        install -d -m 0755 "$dropin_dir"
        {
            echo "# Written by ninja-actions infra/deploy-host-add.sh: run the release"
            echo "# ninja-deploy activated. Delete this file to go back to the unit's own ExecStart."
            echo "[Service]"
            echo "ExecStart="
            echo "ExecStart=$root/current/$name${exec_args:+ $exec_args}"
        } > "$dropin"
        systemctl daemon-reload
        echo "restarting $unit from $root/current/$name"
        systemctl restart "$unit" || true
        if healthy "$adopt_version"; then
            printf '{"service":"%s","env":"%s","version":"%s","commit":"adopted","deployed_at":"%s"}\n' \
                "$service" "$(sed -n 's/^ENV=//p' "$etc/env")" "$adopt_version" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$root/live.json"
            chown "$user:$user" "$root/live.json"
            echo "adopted $service $adopt_version into $root"
        else
            echo "reverting: removing $dropin and restarting the old setup"
            systemctl status "$unit" --no-pager || true
            rm -f "$dropin" "$root/current"
            rm -rf "${release:?}"
            systemctl daemon-reload
            systemctl restart "$unit" || true
            die "adoption failed; $unit is back on its own ExecStart"
        fi
    fi
fi

echo
echo "ok: CI can deploy $service here as $user, restarting $unit."
[ -e "$root/current" ] || echo "Nothing is live yet: the first deploy creates $root/current."
