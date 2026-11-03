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
| `infra/runner-setup.sh` | One-off setup of the self-hosted runner VM on Proxmox (run as root inside it). |
| `infra/runner-add.sh` | Registers one repository's runner on that VM as a systemd service. |

## Report contract

Every test job, whatever the language, writes:

- `reports/junit.xml`: JUnit XML, one `<testcase>` per test.
- `reports/coverage.xml`: Cobertura XML; the root's `line-rate` is the headline figure.

The CI dashboard ingests exactly these two files.
