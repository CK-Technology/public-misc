# Wazuh Agent — Windows via Microsoft Intune

Planning document. **No Windows fleet is Intune-managed today** — every Windows
client is on-premises Active Directory and deploys through
[`../gpo/`](../gpo/README.md). This exists so the path is designed before it is
needed, not built speculatively.

Do not build this out until a real Intune-managed Windows tenant exists. The GPO
path is the supported one.

## Recommended channel: Win32 app

Use **Apps → Windows → Windows app (Win32)**. The Win32 type is the only one
with a full install command line, detection rules, and requirement rules — an
MSI line-of-business app cannot express manager-drift protection or a stopped
service repair.

Wrap [`../gpo/deploy-wazuh.ps1`](../gpo/deploy-wazuh.ps1) rather than shipping a
bare MSI. That script already reconciles state: it installs a missing agent,
upgrades an older one without re-enrolling, starts a stopped current-version
service, repairs a missing service, and refuses to overwrite an agent pointed at
a different manager. Those behaviours are exactly what a Win32 app's repeated
evaluation cycle needs, and none of them survive a plain `msiexec` push.

## Packaging

The Microsoft Win32 Content Prep Tool converts a source folder into a single
`.intunewin`. Stage the reconciler script and, if the environment should not
reach `packages.wazuh.com`, the pinned MSI alongside it.

Intune installs Win32 apps through the Intune Management Extension, which
appears automatically once a PowerShell script or Win32 app is assigned, and
re-evaluates hourly.

| Constraint | Value |
|---|---|
| Enrollment | Entra registered, joined, or hybrid joined |
| App size | 30 GB maximum |
| Install context | System |
| Interaction | None — installs must be fully silent |
| Inline PowerShell installer | 50 KB maximum, if used instead of a command line |

## Sketch

Install command, with the client group edited per tenant at upload time:

```text
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\deploy-wazuh.ps1 -AgentGroup "default,<CLIENT>"
```

Uninstall command:

```text
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\wazuh-uninstaller.ps1
```

Detection rule — prefer file version over a registry key, because it verifies the
installed binary rather than an uninstall entry that survives a broken removal:

```text
Path:    C:\Program Files (x86)\ossec-agent
File:    wazuh-agent.exe
Rule:    Version comparison, greater than or equal to <PINNED_VERSION>
```

A `WazuhSvc`-running check does not belong in detection. Detection answers
"is it installed"; a stopped service is a health problem the reconciler fixes on
its next run, and folding it in makes Intune reinstall on every service hiccup.

## Planned shape

```text
wazuh/windows/intune/
├── README.md
└── package/            # planned - .intunewin source folder
```

## Open questions

- [ ] Confirm a tenant actually needs this before building it.
- [ ] Decide whether to stage the MSI in the package or download at runtime.
      Staging pins the bytes; downloading keeps the package small.
- [ ] Decide the assignment intent. *Required* against a device group is the
      only sensible option for a security agent.
- [ ] Map the reconciler's exit codes onto Intune return codes so a
      reboot-pending result (`3010`) reports as success-with-restart, not failure.
- [ ] Decide whether an enrollment password is in play. It must not be baked
      into the `.intunewin`.

## References

- [Win32 app management in Intune](https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-win32-app-management)
- [Prepare Win32 app content for upload](https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-win32-prepare)
- [`../gpo/README.md`](../gpo/README.md) — the reconciler this would wrap
