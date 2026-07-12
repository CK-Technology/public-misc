# DHCP Option 43 on FortiGate

When the FortiGate is the DHCP server for a UniFi VLAN, hand out Option 43 so
devices discover the controller.

## Value

FortiGate takes Option 43 as a **hex string** = sub-option + length + IP:

```
0104 <controller-IP hex>
```

For `unifi.cktechx.com` = `69.169.98.98` → `45a96262`:

**Option 43 value:** `010445a96262`

> Any IP: `0104` + each octet as 2 hex digits (e.g. `10.0.0.5` → `01040a000005`).

## CLI

```
config system dhcp server
    edit <server-id>            # the DHCP server for the UniFi VLAN/interface
        config options
            edit 1
                set code 43
                set type hex
                set value 010445a96262
            next
        end
    next
end
```

Find `<server-id>` with `show system dhcp server` (match the interface/subnet).

## GUI

`Network → Interfaces → <UniFi VLAN> → DHCP Server → Advanced → Additional DHCP
Options`:

- **Option:** `43`
- **Type:** `Hex`
- **Value:** `010445a96262`

## Verify / gotchas

- After committing, renew the AP/switch lease (or reboot it); it should appear
  as pending adoption on the controller.
- Confirm the device VLAN is the one served by this DHCP server.
- If a FortiSwitch sits between the device and controller, check that
  loop-guard / storm-control isn't dropping UniFi discovery/inform traffic, and
  that STP edge/BPDU settings aren't blocking the UniFi uplink (see the doctor
  checklist: `ghostctl unifi doctor`).
