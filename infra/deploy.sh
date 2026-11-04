#!/bin/sh
# ninja-deploy: the only command a CI deploy key can run on a deploy host
# (the production or staging host). Install as /usr/local/sbin/ninja-deploy and
# force it from the deploy user's authorized_keys, one key per service:
#
#   command="/usr/local/sbin/ninja-deploy ninja-monitor",restrict ssh-ed25519 AAAA... ci-ninja-monitor
#
# The client's command arrives in SSH_ORIGINAL_COMMAND:
#
#   has <version>       exit 0 if releases/<version> is already on disk
#   upload <version>    a .tar.gz on stdin (one top-level directory) -> releases/<version>
#   activate <version>  point current at it, restart, health-check; on failure
#                       point current back, restart, and exit 1
#   list                releases on disk, newest first, the live one marked
#
# Layout, per service:
#   /srv/<service>/releases/<version>/   unpacked release, with version.json
#   /srv/<service>/current -> releases/<version>
#   /srv/<service>/shared/               config and data that outlive a release
#   /srv/<service>/live.json             what is live, written after a healthy deploy
#
# Settings, all root-owned:
#   /etc/ninja-deploy/env              ENV=prod (or staging)
#   /etc/ninja-deploy/<service>.conf   UNIT=, HEALTH_URL=, optional SHARED=, KEEP=5, HEALTH_WAIT=30
#
# The deploy user needs sudo for exactly `systemctl restart <unit>` and
# `systemctl status <unit>`, nothing else.
set -eu
set -f
umask 022

die() { echo "ninja-deploy: $*" >&2; exit 1; }

service=${1:-}
case $service in '' | *[!a-z0-9-]*) die "bad service name" ;; esac

# Overridable for infra/deploy.test.sh only; sshd passes no client environment
# through a `restrict`ed forced command.
etc=${NINJA_DEPLOY_ETC:-/etc/ninja-deploy}
srv=${NINJA_DEPLOY_SRV:-/srv}

[ -r "$etc/env" ] || die "no $etc/env"
[ -r "$etc/$service.conf" ] || die "unknown service $service"
ENV='' UNIT='' HEALTH_URL='' SHARED='' KEEP=5 HEALTH_WAIT=30
# shellcheck disable=SC1090,SC1091 # root-owned settings files
. "$etc/env"
# shellcheck disable=SC1090
. "$etc/$service.conf"
if [ -z "$ENV" ] || [ -z "$UNIT" ] || [ -z "$HEALTH_URL" ]; then
    die "incomplete settings for $service"
fi

root=$srv/$service
releases=$root/releases
[ -d "$releases" ] || die "$releases does not exist"

# shellcheck disable=SC2086 # split the client's command into words; globbing is off
set -- ${SSH_ORIGINAL_COMMAND:-}
action=${1:-}
version=${2:-}

need_version() {
    printf '%s' "$version" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' \
        || die "bad version '$version' (want a tag such as v1.2.3)"
}

# Value of a top-level "key": "string" in a one-line JSON document.
json_field() { printf '%s' "$2" | sed -n "s/.*\"$1\" *: *\"\\([^\"]*\\)\".*/\\1/p"; }

# Poll the health endpoint for up to HEALTH_WAIT seconds. If it reports a version, it must
# be the one we expect, so the old process still answering does not count.
healthy() {
    want=${1#v}
    i=0
    while [ "$i" -lt "$HEALTH_WAIT" ]; do
        if body=$(curl -fsS --max-time 2 "$HEALTH_URL" 2>/dev/null); then
            got=$(json_field version "$body")
            if [ -z "$got" ] || [ "${got#v}" = "$want" ]; then
                echo "healthy: $body"
                return 0
            fi
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "not healthy after $HEALTH_WAIT s; last response: ${body:-none}"
    return 1
}

point_current_at() {
    ln -sfn "$1" "$root/current.new"
    mv -T "$root/current.new" "$root/current"
}

restart() { sudo -n systemctl restart "$UNIT"; }

case $action in
has)
    need_version
    [ -d "$releases/$version" ]
    ;;

upload)
    need_version
    if [ -e "$releases/$version" ]; then
        cat >/dev/null
        echo "$version is already on disk"
        exit 0
    fi
    tmp=$(mktemp -d "$releases/.upload.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    tar -xzf - -C "$tmp" --strip-components=1 --no-same-owner
    [ -f "$tmp/version.json" ] || die "the release has no version.json"
    chmod 0755 "$tmp"
    mv -T "$tmp" "$releases/$version"
    trap - EXIT
    echo "uploaded $version"
    ;;

activate)
    need_version
    exec 9>"$root/.deploy.lock"
    flock -n 9 || die "another deploy of $service is running"
    target=$releases/$version
    [ -d "$target" ] || die "$version is not on disk; upload it first"
    previous=$(readlink "$root/current" 2>/dev/null || true)

    for item in $SHARED; do
        ln -sfn "$root/shared/$item" "$target/$item"
    done

    echo "activating $service $version on $ENV (was ${previous##*/})"
    point_current_at "$target"
    restart
    if healthy "$version"; then
        commit=$(json_field commit "$(cat "$target/version.json")")
        now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '{"service":"%s","env":"%s","version":"%s","commit":"%s","deployed_at":"%s"}\n' \
            "$service" "$ENV" "$version" "$commit" "$now" > "$root/live.json"
        echo "live: $(cat "$root/live.json")"

        # Keep the newest $KEEP releases, never the live one or the one before it.
        # shellcheck disable=SC2012 # release names are validated tags
        ls -1t "$releases" | tail -n +"$((KEEP + 1))" | while read -r old; do
            [ "$releases/$old" = "$target" ] || [ "$releases/$old" = "$previous" ] && continue
            rm -rf "${releases:?}/$old"
            echo "removed old release $old"
        done
        exit 0
    fi

    sudo -n systemctl status "$UNIT" || true
    if [ -n "$previous" ] && [ "$previous" != "$target" ] && [ -d "$previous" ]; then
        echo "rolling back: $version -> ${previous##*/}"
        point_current_at "$previous"
        restart
        if healthy "${previous##*/}"; then
            echo "rolled back to ${previous##*/}"
        else
            echo "ROLLBACK UNHEALTHY: ${previous##*/} did not come back either"
        fi
    else
        echo "no previous release to roll back to"
    fi
    exit 1
    ;;

list)
    live=$(readlink "$root/current" 2>/dev/null || true)
    # shellcheck disable=SC2012 # release names are validated tags
    ls -1t "$releases" | while read -r r; do
        if [ "$releases/$r" = "$live" ]; then echo "$r (live)"; else echo "$r"; fi
    done
    ;;

*)
    die "usage: has|upload|activate <version>, or list"
    ;;
esac
