# DHCP Option 43 on Windows Server (AD environments)

Point UniFi devices (incl. Flex Mini and remote/L3 devices) at the controller
via DHCP, so they self-adopt without manual `set-inform`.

## The value

UniFi encodes the controller IP in Option 43 **sub-option 1**:

```
01 04 <controller-IP as 4 hex bytes>
```

- `01` = sub-option (controller IP)
- `04` = length (4 bytes)
- next 4 bytes = the controller IPv4 the device must reach

For `unifi.cktechx.com` = `69.169.98.98`:

| Octet | 69 | 169 | 98 | 98 |
|-------|----|-----|----|----|
| Hex   | 45 | a9  | 62 | 62 |

**Option 43 value:** `01 04 45 a9 62 62`

> Convert any IP: each octet → 2 hex digits. e.g. `10.0.0.5` → `0a000005`,
> so the value is `0104 0a000005`.
>
> Use the IP the device can actually reach. On the LAN that's the controller's
> LAN IP; for remote/L3 adoption over the internet it's the public IP
> (`69.169.98.98`) with the inform port forwarded.

## Configure (DHCP console / GUI)

1. Open **DHCP** (`dhcpmgmt.msc`).
2. Decide scope: right-click the specific **Scope → Scope Options** (per-VLAN,
   preferred) or **Server Options** (all scopes).
3. **Configure Options… → Advanced** is not needed for a raw option; on the
   **General** tab scroll to **043 Vendor Specific Information** and tick it.
4. Click into the **Data entry → Binary** field and type the hex bytes:
   `01 04 45 a9 62 62` (type them in the binary/hex column; Windows shows the
   ASCII column beside it — ignore that).
5. **OK**. Renew a device's lease (or reboot the AP/switch); it will inform to
   the controller and appear as **pending adoption**.

## Configure (PowerShell)

```powershell
# Per-scope (replace the ScopeId). Value is the raw bytes 01 04 45 a9 62 62.
Set-DhcpServerv4OptionValue -ScopeId 10.20.30.0 -OptionId 43 `
  -Value 0x01,0x04,0x45,0xa9,0x62,0x62
```

## Notes for Flex Mini / small devices

- Flex Mini (USW-Flex-Mini) has no console port and is powered/adopted purely
  over the network — Option 43 (or the `unifi` DNS record) is the clean way to
  get it discovered on a remote/AD-managed LAN.
- If the device already tried (and failed) to adopt elsewhere, factory-reset it
  so it re-reads DHCP.
- Verify the device is on the expected VLAN/untagged network; Option 43 only
  helps if the device's DHCP lease comes from this scope.
