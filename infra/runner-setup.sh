#!/bin/sh
# One-off setup of the CI runner VM (Debian 13 cloud image). Run as root
# inside the VM. Safe to run again.
#
# Installs the build tools the jobs need, a `runner` user with no sudo, and
# Rust (rustup) for that user. Node and pnpm are not installed here: the
# workflows fetch them with actions/setup-node. Register runners afterwards
# with runner-add.sh, one per repository.
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential pkg-config musl-tools git rsync jq curl ca-certificates \
    file unzip xz-utils python3 shellcheck gh \
    qemu-guest-agent unattended-upgrades
systemctl enable --now qemu-guest-agent

# Security updates daily; the runner updates itself.
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
    > /etc/apt/apt.conf.d/20auto-upgrades

id runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash runner

# rustup for the runner user, from the official binary checked against its
# published sha256. It adds ~/.cargo/bin to the user's ~/.profile.
if [ ! -x /home/runner/.cargo/bin/rustup ]; then
    url=https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/rustup-init" "$url"
    want=$(curl -fsSL "$url.sha256" | cut -d' ' -f1)
    echo "$want  $tmp/rustup-init" | sha256sum -c -
    install -m 0755 -o runner -g runner "$tmp/rustup-init" /home/runner/rustup-init
    rm -rf "$tmp"
    runuser -l runner -c './rustup-init -y --profile minimal --default-toolchain stable && rm rustup-init'
fi
runuser -l runner -c 'rustup --version && cargo --version'

echo "ok: runner VM ready; now run runner-add.sh <repo> for each repository"
