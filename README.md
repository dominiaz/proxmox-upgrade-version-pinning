# proxmox-upgrade-version-pinning

Pin all Proxmox VE packages to the exact versions shipped in the official ISO, then automatically clean up once the system matches.

## Problem

Proxmox VE repositories continuously ship new package versions. If your node has drifted (e.g. some packages were already upgraded, or you need to match a freshly-installed ISO baseline), `apt full-upgrade` will pull the latest available versions rather than ISO-matched ones. This script solves that by creating strict apt pinning derived directly from the ISO's own `Packages` manifest.

## How It Works

1. **Download the ISO** — fetches `proxmox-ve_9.2-1.iso` from the official Proxmox enterprise mirror.
2. **Mount and parse** — mounts the ISO as a loopback device and extracts the `Packages` index from the embedded repository.
3. **Generate apt pinning** — writes `/etc/apt/preferences.d/pve-iso-all-versions.pref` with `Pin-Priority: 1001` for every package found in the ISO, locking each one to its exact ISO version.
4. **Record the baseline version** — saves the ISO's `pve-manager` version to `/root/pve-iso-pve-manager.version` as an upgrade-completion marker.
5. **Install a boot-time checker** — writes `/root/check-pve-iso-version-onboot.sh` and registers it as a `@reboot` cron job. On every subsequent boot it compares the installed `pve-manager` version against the recorded ISO version:
   - **Match** → pinning is no longer needed; the script removes the `.pref` file, the cron entry, the version file, and both helper scripts (self-cleaning).
   - **No match** → pinning stays active, upgrade on the next maintenance window.
6. **Dry run** — runs `apt update` and `apt full-upgrade -s` (simulation) so you can review what would change **before** committing.

The actual upgrade is **never run automatically**. You must run `apt full-upgrade` yourself after reviewing the dry-run output.

## Files Created

| Path | Purpose |
|------|---------|
| `/etc/apt/preferences.d/pve-iso-all-versions.pref` | apt pin file (Priority 1001) |
| `/root/pve-iso-pve-manager.version` | ISO baseline version marker |
| `/root/check-pve-iso-version-onboot.sh` | Boot-time checker / self-cleaner |
| `/root/proxmox-upgrade-version-pinning.sh` | This setup script (removed on cleanup) |

## Usage

```bash
# Download and run in one step
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/proxmox-upgrade-version-pinning/main/proxmox-upgrade-version-pinning.sh | bash

# Or run locally
chmod +x proxmox-upgrade-version-pinning.sh
./proxmox-upgrade-version-pinning.sh

# After reviewing the dry-run output, perform the upgrade
apt full-upgrade
```

> **Note:** must be run as `root` on a Proxmox VE node.

## Workflow

```
Run script
    │
    ├─ Download ISO
    ├─ Parse Packages manifest
    ├─ Write apt pinning (.pref)
    ├─ Install @reboot checker
    ├─ apt update + dry-run
    └─ Manual: apt full-upgrade + reboot
                    │
                    └─ On each boot: checker compares versions
                            │
                            ├─ Version matches ISO → self-clean everything
                            └─ Version differs   → keep pinning, retry later
```

## Requirements

- Proxmox VE 9.x (tested on 9.2)
- `curl`, `mount`, `awk`, `cron` (all present in a default PVE install)
- Proxmox no-subscription repository enabled
- Root access

## Changing the ISO Version

Edit the `ISO_URL` variable at the top of `proxmox-upgrade-version-pinning.sh` to point to a different ISO before running:

```bash
ISO_URL="https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso"
```

## Safety

- The upgrade is never triggered automatically — the script only runs a simulation (`-s` flag).
- Pinning uses Priority 1001 which overrides repository defaults but does not prevent manual overrides.
- All helper files are removed automatically once the system reaches the target version, leaving no persistent side-effects.
