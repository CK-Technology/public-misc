# Wazuh Agent — macOS via Microsoft Intune

Planning document for deploying the Wazuh agent to Intune-managed Macs. Nothing
here is deployed yet. The findings below come from unpacking the official
`wazuh-agent-4.14.7-1.arm64.pkg` and they drive the choice of Intune channel.

## Recommended channel: shell script, not an app

Use **Devices → macOS → Scripts**, not Apps. Three properties of the vendor pkg
make the app types a poor fit.

**The pkg ships no application bundle.** Its `PackageInfo` declares an empty
`<bundle-version/>`; the payload is `/Library/Ossec` plus
`/Library/LaunchDaemons/com.wazuh.agent.plist`. Intune's macOS app types key
detection and install reporting off `CFBundleIdentifier` values from included
`.app` bundles. There are none, so app-type reporting has nothing truthful to
report. Confirm the behaviour in-tenant before committing to an app type.

**Architecture is baked into the package.** The `preinstall` script hardcodes
`ARCH` and aborts on a mismatched CPU — the arm64 pkg refuses to run on Intel,
and the Intel pkg demands Rosetta on Apple silicon. One uploaded app object
therefore cannot serve a mixed fleet. A script detects `uname -m` at runtime and
fetches the right package, which is what
[`../install-wazuh-agent.sh`](../install-wazuh-agent.sh) already does.

**Enrollment settings arrive out-of-band.** The manager, group, and agent name
are passed by writing `/tmp/wazuh_envs` *before* `installer` runs. The pkg
**sources** that file (`. ${WAZUH_MACOS_AGENT_DEPLOYMENT_VARS}` in
`register_configure_agent.sh`) and then deletes it. A plain app push has no
natural place to stage it. The PKG app type does support a preinstall script,
but that only solves this problem, not the two above.

## Fresh installs need an explicit start

The pkg's `postinstall` runs `launchctl bootstrap system` **only** on the
upgrade path, guarded by `if [ -n "${upgrade}" ] && [ -n "${restart}" ]`. On a
first install nothing loads the daemon. Any deployment method must start it:

```bash
launchctl bootstrap system /Library/LaunchDaemons/com.wazuh.agent.plist
```

`launchctl load` is the legacy spelling of the same operation and also works;
`bootstrap` is what the vendor's own script uses.

## Intune shell script constraints

| Constraint | Value |
|---|---|
| Minimum OS | macOS 12.0 |
| Network | Direct internet — proxies are not supported |
| Script file | Must begin with `#!`, under 1 MB |
| Run as signed-in user | **No** — the agent install needs root |
| Script frequency | *Not configured* runs it once; a frequency also re-runs after restart |
| Retries | *Max number of times to retry if script fails* — set it, or a transient failure is terminal |
| Timeout | Scripts running over 60 minutes are killed and reported failed |
| Success signal | Exit code `0`. Any non-zero is **Failed** |
| Agent requirement | Intune management agent at `/Library/Intune/Microsoft Intune Agent.app`, installed automatically on first script assignment; checks in every 8 hours |

Status reporting is thinner than it looks: a script with a set frequency reports
status only on its first run, and thereafter only when the status *changes*.
Do not treat the Intune blade as agent inventory — the Wazuh manager is the
source of truth for whether an agent is active and correctly grouped.

## Planned shape

A thin Intune wrapper that reuses the existing installer rather than a second
implementation:

```text
wazuh/macos/intune/
├── README.md
└── intune-install-wazuh-agent.sh   # planned
```

The wrapper should: set `WAZUH_MANAGER` / `WAZUH_AGENT_GROUP` / `WAZUH_VERSION`
as variables at the top of the file for the admin to edit before upload, fetch
[`../install-wazuh-agent.sh`](../install-wazuh-agent.sh) pinned to a reviewed
commit, execute it, verify with `wazuh-control status`, and exit non-zero on any
failure so Intune reports it honestly.

Group is edited per client at upload time. Client codes do not belong in this
repository — see the runbooks under the gitignored `wazuh/tasks/`.

## Open questions

- [ ] Confirm in-tenant what the PKG app type does for detection with a pkg that
      has no app bundle. If it reports usefully, the app type becomes viable and
      simpler than a script.
- [ ] Decide whether the agent needs Full Disk Access via a PPPC profile. An MDM
      run and a local `sudo` run do not have identical permissions.
- [ ] Decide the script frequency. Run-once leaves no drift correction; a
      recurring run needs the script to be a safe no-op on an enrolled agent.
- [ ] Confirm the Macs can reach `packages.wazuh.com` over HTTPS and the manager
      on `1514`/`1515`.

## References

- [Use shell scripts on macOS devices in Intune](https://learn.microsoft.com/en-us/intune/intune-service/apps/macos-shell-scripts)
- [Wazuh macOS agent deployment variables](https://documentation.wazuh.com/current/user-manual/agent/agent-enrollment/index.html)
- [`../README.md`](../README.md) — the underlying macOS scripts
