# ninja-actions

Shared pieces of the CI/CD pipeline for riot-proxy, ninja-monitor and
ninjagoldfinch-lol. Every repository's `ci.yml`, `release.yml` and
`deploy.yml` have the same shape and call what lives here, so a fix here
reaches all three.

Workflows reference `NinjaGoldfinch/ninja-actions/<action>@v1`. `v1` is a
moving tag: after a change, move it (`git tag -f v1 && git push -f origin v1`).

| Path | What |
|---|---|
| `test-report/` | Composite action. Checks a test run left `reports/junit.xml` and `reports/coverage.xml` (Cobertura), writes a summary to the job page, uploads both as the `test-reports` artifact. |
| `deploy/` | Composite action. Downloads a release asset, checks its sha256, uploads it to a deploy host unless already there, and activates it through `ninja-deploy`. Writes the deploy log to the job summary. |
| `infra/deploy.sh` | `ninja-deploy`, the forced command of each deploy key on the production and staging hosts: `has`, `upload`, `activate` (restart, health check, automatic rollback), `list`. |
| `infra/deploy.test.sh` | Tests `deploy.sh` against a fake service. |
| `infra/deploy-host-setup.sh` | One-off setup of a deploy host: installs `ninja-deploy`, creates the `deploy` user, writes `/etc/ninja-deploy/env`. |
| `infra/deploy-host-add.sh` | Lets one repository deploy one service to that host: `/srv` layout, settings, a sudo rule for its unit only, the forced-command key. Can move a running service (one binary, or a directory from a release tarball) into `/srv`. |
| `infra/deploy-host.test.sh` | End-to-end test of the three over real SSH, sudo and systemd; CI runs it on a throwaway hosted runner. |
| `tools/ngf-deploy` | Starts `deploy.yml` from your own machine with `gh`: the latest release (or `-v`) of one service or `all`, to `prod` (or `-e staging`). `-l` lists the latest releases. |
| `tools/ngf-host` | On a host: `ngf-host status` compares what runs with the latest release or commit; `ngf-host update` deploys `deploy:` services through `ninja-deploy` on the box (latest release, or `--version` to roll back; no GitHub approval, but on a prod host only a version with `staging/smoke` or `prod/deployed`, unless `--unverified '<reason>'`) and updates git checkouts and `gh:` release binaries. `ngf-host self-update` replaces it with the `v1` version (or a ref you name), checked against git's hash. Config in `~/.config/ngf-host/projects.conf`. |
| `tools/ngf-tunnel` | On your own machine: runs the `*-tunnels` entries of `~/.ssh/config` in the background (`ngf-tunnel up`, `status`, `down`). |
| `infra/runner-setup.sh` | One-off setup of the self-hosted runner VM on Proxmox (run as root inside it). |
| `infra/runner-add.sh` | Registers one repository's runner on that VM as a systemd service. |

## Report contract

Every test job, whatever the language, writes:

- `reports/junit.xml`: JUnit XML, one `<testcase>` per test.
- `reports/coverage.xml`: Cobertura XML; the root's `line-rate` is the headline figure.

The CI dashboard ingests exactly these two files.

## Deploys

A host (production `ngf-prod-syd1`, staging `ngf-mon-syd1`) has a `deploy` user whose
`authorized_keys` holds one key per service, each forced to
`ninja-deploy <service>`, so a repository's key can only deploy that
repository's service, and only through the commands above. Releases live in
`/srv/<service>/releases/<version>/`, `current` points at the live one, and
`/srv/<service>/shared/` holds what outlives a release. Rollback is deploying
an older version that is still on disk; the last five are kept.

### Deploying

From your own machine (needs `gh`, logged in):

```sh
curl -fsSL -o ~/bin/ngf-deploy https://raw.githubusercontent.com/NinjaGoldfinch/ninja-actions/main/tools/ngf-deploy
chmod +x ~/bin/ngf-deploy
ngf-deploy ninja-monitor            # latest release to prod; approve it in the run
ngf-deploy ninja-monitor -v v0.2.1  # a specific version, e.g. to roll back
ngf-deploy -l                       # latest release of each repository
```

### Staging

Staging is the OVH VPS `ngf-mon-syd1` (Sydney, Ubuntu, `ENV=staging` in
`/etc/ninja-deploy/env`). It is set up like production: the same
`ninja-deploy`, `deploy` user and `/srv` layout, one key per service. Its
public hostnames are served by its own Cloudflare tunnel, `ngf-staging`
(never a connector of the production or home tunnels), and both hostnames
are behind one Access application (`staging`) that only the owner can log in
to. Deploys still come in over SSH, not through the tunnel:

| Hostname | On the host |
|---|---|
| `staging.ninjagoldfinch.lol` | the site, `127.0.0.1:3000` |
| `riot-proxy-staging.ninjagoldfinch.com` | riot-proxy, `127.0.0.1:8080` |

Each repository has a `staging` environment next to `prod`: no required
reviewer, deployment branches `main` plus the tag pattern `v*` (a deploy
started by a release runs on its tag), and its own `DEPLOY_SSH_KEY`,
`DEPLOY_HOST` and `DEPLOY_KNOWN_HOSTS`.

Every release goes to staging by itself; production still waits for an
approval. A release created by a workflow's `GITHUB_TOKEN` starts no other
workflow, so `on: release` in `deploy.yml` would never fire. Instead
`deploy.yml` can also be called, and `release.yml` calls it once the release
is published:

```yaml
# deploy.yml
on:
  workflow_dispatch:
    inputs:
      env: { type: choice, options: [staging, prod], default: staging }
      version: { required: true }
  workflow_call:
    inputs:
      env: { type: string, required: true }
      version: { type: string, required: true }

jobs:
  deploy:
    runs-on: [self-hosted, linux, proxmox]
    environment: ${{ inputs.env }}
    # On the job, not the workflow, so it also holds when called.
    concurrency: { group: deploy-${{ inputs.env }}, cancel-in-progress: false }
    steps:
      - uses: NinjaGoldfinch/ninja-actions/deploy@v1
        with: { ... as for prod ... }
```

```yaml
# release.yml, after the job that publishes the release
  staging:
    needs: publish
    uses: ./.github/workflows/deploy.yml
    with:
      env: staging
      version: ${{ github.ref_name }}
    permissions:
      contents: read
```

The called job reads the `staging` environment's own secrets and variables,
so nothing is passed down. A failed staging deploy rolls back on the host and
fails the release run, which is the signal not to deploy that version to
production.

### Setting up a host

On your own machine, make a key pair for the repository and store the private
half in its environment, then delete the local copies:

```sh
ssh-keygen -t ed25519 -N '' -C ci-<service>-prod -f /tmp/deploy-key
gh secret set DEPLOY_SSH_KEY -R NinjaGoldfinch/<repo> --env prod < /tmp/deploy-key
cat /tmp/deploy-key.pub      # needed on the host
rm /tmp/deploy-key /tmp/deploy-key.pub
```

The environment also needs the variables `DEPLOY_HOST` and
`DEPLOY_KNOWN_HOSTS` (the host's `ssh-keyscan -t ed25519 <host>` line).

On the host, from a copy of this repository:

```sh
curl -fsSL https://github.com/NinjaGoldfinch/ninja-actions/archive/refs/heads/main.tar.gz | tar -xz
cd ninja-actions-main
sudo ./infra/deploy-host-setup.sh --env prod          # once per host
sudo ./infra/deploy-host-add.sh <service> --unit <unit> \
    --health-url http://127.0.0.1:<port>/healthz --key '<the .pub line>'
```

`deploy-host-setup.sh` warns if sshd's `AllowUsers` or `AllowGroups` would
refuse the `deploy` user; it does not change sshd's configuration.

A service that already runs from somewhere else (for example
`/usr/local/bin`, put there by its own installer) is moved over with
`--adopt <installed binary> <its version> --exec-args '<its arguments>'`. The
installed binary becomes the first release, a drop-in
(`/etc/systemd/system/<unit>.d/ninja-deploy.conf`) points the unit at
`/srv/<service>/current/`, and the unit is restarted and health-checked. If
that fails, the drop-in is removed and the old setup restarted, so nothing is
left half moved. Deleting the drop-in later (then `systemctl daemon-reload`
and a restart) goes back to the unit's own `ExecStart` just as well.

Add `--link` when other tools call the installed path (an admin helper, a
runbook): the installed binary is moved to `<path>.pre-deploy` and replaced
by a symlink to `/srv/<service>/current/<binary>`, so they run whatever
release is live instead of the one installed before adoption.

ninja-monitor on the VPS, for example:

```sh
sudo ./infra/deploy-host-add.sh ninja-monitor --unit ninja-monitor.service \
    --health-url http://127.0.0.1:9090/healthz --key 'ssh-ed25519 AAAA... ci-ninja-monitor-prod' \
    --adopt /usr/local/bin/ninja-monitor v0.2.1 \
    --exec-args '--config /etc/ninja-monitor/config.toml'
```

A service that runs from a directory rather than one binary (a Node server
started as `node build` in a checkout, say) is moved over with
`--adopt-release <release .tar.gz> <its version> --exec-start '<command>'`.
The tarball is the release asset CI would upload, unpacked the same way as the
first release; its `version.json` must name the version given. The drop-in
sets `WorkingDirectory=/srv/<service>/current` and `ExecStart=<command>`, so
the command's arguments are relative to whichever release is live, and the
unit's other settings (user, environment file, sandboxing) stay as they are.
A failed health check removes the drop-in, which puts back the old directory
and command. Download the release and check it first:

```sh
gh release download v1.0.0 -R NinjaGoldfinch/ninjagoldfinch-lol -D /tmp/site-v1.0.0
(cd /tmp/site-v1.0.0 && sha256sum -c SHA256SUMS)
sudo ./infra/deploy-host-add.sh ninjagoldfinch-lol --unit ninjagoldfinch-lol.service \
    --health-url http://127.0.0.1:3000/healthz --key 'ssh-ed25519 AAAA... ci-ninjagoldfinch-lol-prod' \
    --adopt-release /tmp/site-v1.0.0/ninjagoldfinch-lol.tar.gz v1.0.0 \
    --exec-start '/usr/bin/node build'
```

A service whose boot can take long (a database migration, a large cache to
load) needs `--health-wait <seconds>` covering its slowest boot (default 30).
If the wait runs out after a forward-only migration has already applied,
the automatic rollback starts the previous release on a database it may
refuse, so err on the long side.

After that, releases reach the host only through `deploy.yml`. The service's
own installer still edits its configuration, but the binary it installs is no
longer the one that runs.

A deploy key lets its repository run any release of that service with the
service's own permissions and secrets, which is why the `prod` environment
needs an approval.

## License

Licensed under the [MIT License](LICENSE).
