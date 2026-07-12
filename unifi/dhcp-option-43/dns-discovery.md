# DNS-based controller discovery (`unifi` record)

When you can't (or don't want to) push DHCP Option 43, a factory UniFi device
also probes a well-known hostname on boot:

```
http://unifi:8080/inform
```

So if the device's DNS resolves the bare name `unifi` to the controller, it
self-discovers with zero DHCP changes.

## Add the record

Point `unifi` at the IP the device can actually reach:

- **On the LAN:** the controller's LAN IP.
- **Remote / L3 adoption:** the public IP `69.169.98.98` with the inform port
  (`8080`) reachable.

| Environment | What to add |
|-------------|-------------|
| Windows Server AD DNS | An **A record** `unifi` in the zone the device's DHCP hands out as its DNS suffix (e.g. `unifi.corp.local → 10.x.x.x`). |
| FortiGate internal DNS | `config system dns-database` → add an A entry `unifi` → controller IP for the served domain. |
| Pi-hole / dnsmasq | `address=/unifi/10.x.x.x` (or a host override). |
| Public DNS (Cloudflare) | `unifi.cktechx.com` already resolves to `69.169.98.98`; the bare-name probe needs a **search-domain** match, so LAN DNS is still cleaner for on-site devices. |

> The device probes the **unqualified** name `unifi`. It only resolves if the
> DHCP-provided DNS search/suffix domain makes `unifi` → `unifi.<suffix>`
> resolvable. If your DHCP hands out no suffix, use Option 43 instead.

## `set-inform` fallback

For remote/L3 devices where neither DHCP Option 43 nor DNS can reach the device
subnet, point each device at the controller directly over SSH:

```
mca-cli-op set-inform http://69.169.98.98:8080/inform
```

ghostctl automates the discovery + set-inform loop across a subnet:

```
ghostctl unifi adopt --subnet 192.168.1.0/24
```

(`ghostctl unifi adopt --help` for options; add `--dry-run` to preview the exact
`set-inform` without touching anything.)

## Order of preference

1. **DHCP Option 43** — most robust on a managed LAN (see the sibling docs).
2. **DNS `unifi` record** — clean when you control the resolver and hand out a
   search domain.
3. **`set-inform`** — the fallback for remote/L3 adoption where L2 discovery and
   DHCP/DNS hints can't reach.

## Verify

- After the device gets a lease (or reboot), it should appear as **pending
  adoption** on the controller: `ghostctl unifi devices --pending`.
- If it doesn't, confirm the device's resolver actually answers `unifi` and that
  device→controller `:8080` is open (a FortiGate policy or VLAN boundary is the
  usual culprit).
