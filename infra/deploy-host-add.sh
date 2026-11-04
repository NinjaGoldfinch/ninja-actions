#!/bin/sh
# Let CI deploy one service to this host. Run as root, after
# deploy-host-setup.sh. Safe to run again: it replaces the service's key,
# settings and sudo rule, and never touches releases already on disk.
#
#   sudo ./infra/deploy-host-add.sh <service> --unit <unit> --health-url <url> \
#       --key '<ssh public key>' [--shared '<items>'] [--keep <n>] [--health-wait <s>] \
#       [--smoke-urls '<loopback urls>'] \
#       [--adopt <installed binary> <its version> --exec-args '<arguments>' [--link]]
#       [--adopt-release <release .tar.gz> <its version> --exec-start '<command>']
#
#   --unit        systemd unit to restart, e.g. ninja-monitor.service
#   --health-url  loopback URL answering 2xx, with "version" in its JSON if it can
#   --key         public half of the key whose private half is the repository's
#                 DEPLOY_SSH_KEY secret; it is forced to `ninja-deploy <service>`
#   --shared      names under /srv/<service>/shared/ linked into every release
#   --keep        releases kept on disk (default 5)
#   --health-wait seconds a restarted release has to pass the health check (default 30);
#                 make it cover the slowest boot, migrations included
#   --smoke-urls  space-separated loopback http:// URLs that must answer 2xx once
#                 the health check passes, or the deploy rolls back; list only
#                 pages that depend on nothing else (a re-run without it clears it)
#   --adopt       move a service that is already running into /srv: copy the
#                 installed binary in as the first release, point the unit at
#                 /srv/<service>/current/<binary> with a drop-in, restart and
#                 health-check it. If it is not healthy the drop-in is removed
#                 and the old setup restarted. --exec-args gives the arguments
#                 for the new ExecStart (the unit's current ones, usually).
#   --link        with --adopt: replace the installed binary by a symlink to
#                 /srv/<service>/current/<binary> (the original is kept as
#                 <path>.pre-deploy), so helpers and runbooks that call the old
#                 path run the live release. Safe to add on a later run.
#   --adopt-release  the same move for a service that runs from a directory
#                 (e.g. `node build` in a checkout): unpack a release tarball,
#                 as CI uploads it, as the first release, and point the unit's
#                 WorkingDirectory at /srv/<service>/current and its ExecStart
#                 at --exec-start, a full command line (absolute program,
#                 arguments relative to the release). The tarball's
#                 version.json must name the version given.
set -eu

user=deploy
etc=/etc/ninja-deploy
deployer=/usr/local/sbin/ninja-deploy

die() { echo "deploy-host-add.sh: $*" >&2; exit 1; }

service=${1:-}
case $service in
    -h | --help) sed -n '2,39s/^# \{0,1\}//p' "$0"; exit 0 ;;
    '' | -* | *[!a-z0-9-]*) die "first argument: a service name (a-z, 0-9, -); try --help" ;;
esac
shift
unit='' health_url='' key='' shared='' smoke_urls='' keep=5 health_wait=30 adopt_bin='' adopt_tar='' adopt_version='' exec_args='' have_exec_args=no exec_start='' link=no
while [ $# -gt 0 ]; do
    case $1 in
        --unit) shift; unit=${1:-} ;;
        --health-url) shift; health_url=${1:-} ;;
        --key) shift; key=${1:-} ;;
        --shared) shift; shared=${1:-} ;;
        --keep) shift; keep=${1:-} ;;
        --health-wait) shift; health_wait=${1:-} ;;
        --smoke-urls) shift; smoke_urls=${1:-} ;;
        --adopt) shift; adopt_bin=${1:-}; shift; adopt_version=${1:-} ;;
        --adopt-release) shift; adopt_tar=${1:-}; shift; adopt_version=${1:-} ;;
        --exec-args) shift; exec_args=${1-}; have_exec_args=yes ;;
        --exec-start) shift; exec_start=${1:-} ;;
        --link) link=yes ;;
        *) die "unknown argument $1 (try --help)" ;;
    esac
    [ $# -gt 0 ] && shift
done

[ "$(id -u)" -eq 0 ] || die "run as root"
if [ ! -x "$deployer" ] || [ ! -r "$etc/env" ] || ! id "$user" >/dev/null 2>&1; then
    die "run deploy-host-setup.sh first"
fi

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
# Split on whitespace only (a URL's ? must not glob), and store one space apart.
set -f
# shellcheck disable=SC2086 # splitting is the point; globbing is off
set -- $smoke_urls
smoke_urls=$*
for url in "$@"; do
    case $url in
        http://127.0.0.1:* | http://localhost:* | 'http://[::1]:'*) ;;
        *) die "--smoke-urls: $url is not a loopback http:// URL" ;;
    esac
    case $url in *[!A-Za-z0-9:/._~?=\&%-]*) die "--smoke-urls: unexpected characters in $url" ;; esac
done
set +f
case $keep in '' | *[!0-9]*) die "--keep takes a number" ;; esac
[ "$keep" -ge 2 ] || die "--keep must be at least 2 (the live release and the one before)"
case $health_wait in '' | *[!0-9]*) die "--health-wait takes a number of seconds" ;; esac
[ "$health_wait" -ge 5 ] || die "--health-wait must be at least 5 seconds"
case $shared in *[!A-Za-z0-9._\ -]*) die "--shared takes space-separated file names" ;; esac

# A bare public key: type, base64, optional comment. No options, which this
# script sets itself.
printf '%s' "$key" | grep -Eqx '(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com) [A-Za-z0-9+/]+=* ?[A-Za-z0-9@._+-]*' \
    || die "--key must be one public key line, e.g. 'ssh-ed25519 AAAA... ci-$service'"

json_version() { sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p'; }
nl='
'

if [ "$link" = yes ] && [ -z "$adopt_bin" ]; then
    die "--link goes with --adopt (it replaces the adopted binary)"
fi
[ -n "$adopt_bin" ] && [ -n "$adopt_tar" ] && die "use --adopt or --adopt-release, not both"
if [ -n "$adopt_bin" ] || [ -n "$adopt_tar" ] || [ -n "$adopt_version" ]; then
    printf '%s' "$adopt_version" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' \
        || die "adopting: version '$adopt_version' should look like v1.2.3"
fi
if [ -n "$adopt_tar" ]; then
    [ -f "$adopt_tar" ] || die "--adopt-release: $adopt_tar is not a file"
    [ "$have_exec_args" = no ] || die "--adopt-release takes --exec-start (the whole command), not --exec-args"
    case $exec_start in
        '') die "--adopt-release needs --exec-start, e.g. '/usr/bin/node build'" ;;
        /*) ;;
        *) die "--exec-start must start with an absolute program path" ;;
    esac
    case $exec_start in *"$nl"*) die "--exec-start must be one line" ;; esac
    # As ninja-deploy unpacks it: one top-level directory, version.json in it.
    # An unreadable file lists nothing, and one without version.json has no version.
    tops=$(tar -tzf "$adopt_tar" 2>/dev/null | cut -d/ -f1 | sort -u)
    case $tops in '' | *"$nl"* | .) die "--adopt-release: $adopt_tar must be a .tar.gz holding one top-level directory" ;; esac
    tar_version=$(tar -xzOf "$adopt_tar" "$tops/version.json" 2>/dev/null | json_version)
    [ -n "$tar_version" ] || die "--adopt-release: $adopt_tar has no version in $tops/version.json"
    [ "${tar_version#v}" = "${adopt_version#v}" ] \
        || die "--adopt-release: $adopt_tar is $tar_version, not $adopt_version"
elif [ -n "$exec_start" ]; then
    die "--exec-start goes with --adopt-release"
fi
if [ -n "$adopt_bin" ] || { [ -z "$adopt_tar" ] && [ -n "$adopt_version" ]; }; then
    if [ ! -f "$adopt_bin" ] || [ ! -x "$adopt_bin" ]; then
        die "--adopt: $adopt_bin is not an executable file"
    fi
    [ "$have_exec_args" = yes ] || die "--adopt needs --exec-args (use '' for none)"
    case $exec_args in *"$nl"*) die "--exec-args must be one line" ;; esac
fi

# One key per service: sshd uses the first line that matches a key, so a key
# listed for two services would only ever reach one of them.
home=$(getent passwd "$user" | cut -d: -f6)
keys=$home/.ssh/authorized_keys
blob=$(printf '%s' "$key" | cut -d' ' -f2)
other=$(grep -F " $blob" "$keys" 2>/dev/null | grep -vF "command=\"$deployer $service\"," \
    | sed -n 's/^command="[^ ]* \([a-z0-9-]*\)".*/\1/p' | head -n 1)
[ -z "$other" ] || die "that key is already used for $other; make a separate key for $service"

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
    printf "HEALTH_WAIT=%s\n" "$health_wait"
    printf "SMOKE_URLS='%s'\n" "$smoke_urls"
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
line="command=\"$deployer $service\",restrict $key"
{
    grep -vF "command=\"$deployer $service\"," "$keys" 2>/dev/null || true
    printf '%s\n' "$line"
} > "$keys.new"
chown "$user:$user" "$keys.new"
chmod 0600 "$keys.new"
mv -f "$keys.new" "$keys"
echo "authorized the key for $service in $keys"

# Up to --health-wait seconds for the health URL to answer with the expected version.
healthy() {
    want=${1#v} i=0 body=
    while [ "$i" -lt "$health_wait" ]; do
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
    echo "not healthy after $health_wait s; last response: ${body:-none}"
    return 1
}

if [ -n "$adopt_bin" ] || [ -n "$adopt_tar" ]; then
    dropin_dir=/etc/systemd/system/$unit.d
    dropin=$dropin_dir/ninja-deploy.conf
    if [ -e "$root/current" ]; then
        echo "$root/current already exists; not adopting again"
    else
        release=$root/releases/$adopt_version
        [ -e "$release" ] && die "$release already exists; remove it or adopt under another version"
        tmp=$(mktemp -d "$root/releases/.adopt.XXXXXX")
        if [ -n "$adopt_tar" ]; then
            # Exactly as ninja-deploy's upload unpacks it.
            tar -xzf "$adopt_tar" -C "$tmp" --strip-components=1 --no-same-owner
            chmod 0755 "$tmp"
            command=$exec_start
            workdir=$root/current
        else
            name=$(basename "$adopt_bin")
            cp "$adopt_bin" "$tmp/$name"
            printf '{"version":"%s","commit":"adopted","built_at":"%s"}\n' \
                "$adopt_version" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp/version.json"
            chmod 0755 "$tmp" "$tmp/$name"
            chmod 0644 "$tmp/version.json"
            command="$root/current/$name${exec_args:+ $exec_args}"
            workdir=''
        fi
        chown -R "$user:$user" "$tmp"
        mv -T "$tmp" "$release"
        # Absolute, as ninja-deploy writes it.
        ln -sfn "$release" "$root/current"
        chown -h "$user:$user" "$root/current"

        install -d -m 0755 "$dropin_dir"
        {
            echo "# Written by ninja-actions infra/deploy-host-add.sh: run the release"
            echo "# ninja-deploy activated. Delete this file to go back to the unit's own settings."
            echo "[Service]"
            [ -z "$workdir" ] || echo "WorkingDirectory=$workdir"
            echo "ExecStart="
            echo "ExecStart=$command"
        } > "$dropin"
        systemctl daemon-reload
        echo "restarting $unit: $command${workdir:+ (in $workdir)}"
        systemctl restart "$unit" || true
        if healthy "$adopt_version"; then
            commit=adopted
            if [ -n "$adopt_tar" ]; then
                commit=$(sed -n 's/.*"commit" *: *"\([^"]*\)".*/\1/p' "$release/version.json")
            fi
            printf '{"service":"%s","env":"%s","version":"%s","commit":"%s","deployed_at":"%s"}\n' \
                "$service" "$(sed -n 's/^ENV=//p' "$etc/env")" "$adopt_version" "$commit" \
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
            die "adoption failed; $unit is back on its own settings"
        fi
    fi
fi

if [ "$link" = yes ] && [ -e "$root/current" ]; then
    target=$root/current/$(basename "$adopt_bin")
    if [ "$(readlink "$adopt_bin" 2>/dev/null)" = "$target" ]; then
        echo "$adopt_bin already points at $target"
    else
        [ -e "$adopt_bin.pre-deploy" ] && die "$adopt_bin.pre-deploy exists; move it away first"
        mv "$adopt_bin" "$adopt_bin.pre-deploy"
        ln -s "$target" "$adopt_bin"
        echo "$adopt_bin -> $target (the original is $adopt_bin.pre-deploy)"
    fi
fi

echo
echo "ok: CI can deploy $service here as $user, restarting $unit."
[ -e "$root/current" ] || echo "Nothing is live yet: the first deploy creates $root/current."
