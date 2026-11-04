#!/bin/sh
# One-off setup of a deploy host (the production or staging host). Run as root
# from a checkout of this repository. Safe to run again.
#
#   sudo ./infra/deploy-host-setup.sh --env prod      (or --env staging)
#
# Installs infra/deploy.sh as /usr/local/sbin/ninja-deploy, creates the
# `deploy` user that CI logs in as, and writes /etc/ninja-deploy/env. It adds
# no keys and grants no sudo: deploy-host-add.sh does that per service.
#
# It reads sshd's effective settings and says if the deploy user would be
# refused, but never edits the sshd configuration itself.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
user=deploy
etc=/etc/ninja-deploy

env=
while [ $# -gt 0 ]; do
    case $1 in
        --env) shift; env=${1:-} ;;
        -h | --help) sed -n '2,12s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "deploy-host-setup.sh: unknown argument $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done
case $env in
    prod | staging) ;;
    *) echo "deploy-host-setup.sh: --env prod or --env staging is required" >&2; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "deploy-host-setup.sh: run as root" >&2; exit 1; }

# ninja-deploy needs these at run time.
missing=
for cmd in curl flock tar sudo visudo systemctl sshd; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
[ -z "$missing" ] || { echo "deploy-host-setup.sh: missing:$missing" >&2; exit 1; }

install -m 0755 -o root -g root "$here/deploy.sh" /usr/local/sbin/ninja-deploy
echo "installed /usr/local/sbin/ninja-deploy"

# A real shell, because sshd runs the forced command through it. The password
# is "*" (no password can match) rather than useradd's "!" (locked), which
# some sshd and PAM setups treat as "refuse every login".
if ! id "$user" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/sh --user-group "$user"
    echo "created user $user"
fi
usermod -p '*' "$user"
home=$(getent passwd "$user" | cut -d: -f6)
install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"
if [ ! -e "$home/.ssh/authorized_keys" ]; then
    install -m 0600 -o "$user" -g "$user" /dev/null "$home/.ssh/authorized_keys"
fi

install -d -m 0755 -o root -g root "$etc"
printf 'ENV=%s\n' "$env" > "$etc/env.new"
chmod 0644 "$etc/env.new"
mv -f "$etc/env.new" "$etc/env"
echo "wrote $etc/env (ENV=$env)"

install -d -m 0755 -o root -g root /srv

# Would sshd let the deploy user in? -C fills in Match blocks for this user.
settings=$(sshd -T -C "user=$user,host=localhost,addr=127.0.0.1" 2>/dev/null || sshd -T)
allowed=yes
users=$(printf '%s\n' "$settings" | awk '$1 == "allowusers" { $1 = ""; print }')
groups=$(printf '%s\n' "$settings" | awk '$1 == "allowgroups" { $1 = ""; print }')
if [ -n "$users" ] || [ -n "$groups" ]; then
    allowed=no
    for u in $users; do [ "${u%%@*}" = "$user" ] && allowed=yes; done
    for g in $groups; do id -nG "$user" | tr ' ' '\n' | grep -qx "$g" && allowed=yes; done
fi
for u in $(printf '%s\n' "$settings" | awk '$1 == "denyusers" { $1 = ""; print }'); do
    [ "${u%%@*}" = "$user" ] && allowed=no
done
if printf '%s\n' "$settings" | grep -qx 'pubkeyauthentication no'; then
    allowed=no
fi
if [ "$allowed" = no ]; then
    echo
    echo "WARNING: sshd would refuse the $user user (AllowUsers, AllowGroups, DenyUsers or"
    echo "PubkeyAuthentication). Add $user to AllowUsers (or its group to AllowGroups) in"
    echo "/etc/ssh/sshd_config.d/, check with 'sshd -t', then 'systemctl reload ssh'."
    echo "Keep your current SSH session open until a new login works."
else
    echo "sshd allows the $user user"
fi

echo
echo "ok: deploy host ready ($env); add each service with deploy-host-add.sh"
