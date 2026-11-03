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
| `infra/deploy.sh` | `ninja-deploy`, the forced command of each deploy key on the VPS and staging VM: `has`, `upload`, `activate` (restart, health check, automatic rollback), `list`. |
| `infra/deploy.test.sh` | Tests `deploy.sh` against a fake service. |
| `infra/deploy-host-setup.sh` | One-off setup of a deploy host: installs `ninja-deploy`, creates the `deploy` user, writes `/etc/ninja-deploy/env`. |
| `infra/deploy-host-add.sh` | Lets one repository deploy one service to that host: `/srv` layout, settings, a sudo rule for its unit only, the forced-command key. Can move a running service into `/srv`. |
| `infra/deploy-host.test.sh` | End-to-end test of the three over real SSH, sudo and systemd; CI runs it on a throwaway hosted runner. |
| `infra/runner-setup.sh` | One-off setup of the self-hosted runner VM on Proxmox (run as root inside it). |
| `infra/runner-add.sh` | Registers one repository's runner on that VM as a systemd service. |

## Report contract

Every test job, whatever the language, writes:

- `reports/junit.xml`: JUnit XML, one `<testcase>` per test.
- `reports/coverage.xml`: Cobertura XML; the root's `line-rate` is the headline figure.

The CI dashboard ingests exactly these two files.

## Deploys

A host (the VPS, later the staging VM) has a `deploy` user whose
`authorized_keys` holds one key per service, each forced to
`ninja-deploy <service>`, so a repository's key can only deploy that
repository's service, and only through the commands above. Releases live in
`/srv/<service>/releases/<version>/`, `current` points at the live one, and
`/srv/<service>/shared/` holds what outlives a release. Rollback is deploying
an older version that is still on disk; the last five are kept.

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

ninja-monitor on the VPS, for example:

```sh
sudo ./infra/deploy-host-add.sh ninja-monitor --unit ninja-monitor.service \
    --health-url http://127.0.0.1:9090/healthz --key 'ssh-ed25519 AAAA... ci-ninja-monitor-prod' \
    --adopt /usr/local/bin/ninja-monitor v0.2.1 \
    --exec-args '--config /etc/ninja-monitor/config.toml'
```

After that, releases reach the host only through `deploy.yml`. The service's
own installer still edits its configuration, but the binary it installs is no
longer the one that runs.

A deploy key lets its repository run any release of that service with the
service's own permissions and secrets, which is why the `prod` environment
needs an approval.

## License

Licensed under the [MIT License](LICENSE).
