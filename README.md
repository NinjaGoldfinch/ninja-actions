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

## License

Licensed under the [MIT License](LICENSE).
