#!/bin/sh
# Register a GitHub Actions runner for one repository and run it as a
# systemd service. Run as root inside the runner VM, after runner-setup.sh.
#
#   ./runner-add.sh <repo>        e.g. ./runner-add.sh ninja-monitor
#
# It asks for a registration token (hidden input). Get one, valid for an hour,
# from Settings -> Actions -> Runners -> New self-hosted runner, or with:
#   gh api -X POST repos/NinjaGoldfinch/<repo>/actions/runners/registration-token --jq .token
#
# A personal account cannot share one runner across repositories, so each
# repository gets its own runner process in /home/runner/<repo>. Labels:
# self-hosted, linux, x64 (automatic) and proxmox.
set -eu

owner=NinjaGoldfinch
version=2.338.2
sha256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40

repo=${1:?usage: runner-add.sh <repo>}
dir=/home/runner/$repo
tarball=/home/runner/actions-runner-linux-x64-$version.tar.gz

if [ ! -f "$tarball" ]; then
    curl -fsSL -o "$tarball.tmp" \
        "https://github.com/actions/runner/releases/download/v$version/actions-runner-linux-x64-$version.tar.gz"
    echo "$sha256  $tarball.tmp" | sha256sum -c -
    mv "$tarball.tmp" "$tarball"
fi

if [ -f "$dir/.runner" ]; then
    echo "$dir is already registered; remove it first (./svc.sh uninstall; ./config.sh remove)" >&2
    exit 1
fi

install -d -o runner -g runner "$dir"
runuser -u runner -- tar -xzf "$tarball" -C "$dir"
"$dir/bin/installdependencies.sh" >/dev/null

printf 'Registration token for %s/%s: ' "$owner" "$repo"
stty -echo; read -r token; stty echo; echo

# A login shell, so ~/.cargo/bin is on the PATH the service records.
runuser -l runner -c "cd '$dir' && ./config.sh --unattended --replace \
    --url 'https://github.com/$owner/$repo' --token '$token' \
    --name '$(hostname)-$repo' --labels proxmox"

cd "$dir"
./svc.sh install runner
./svc.sh start
echo "ok: $repo runner is running"
