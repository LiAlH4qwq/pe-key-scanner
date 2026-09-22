# pe-key-scanner

PECMD-style provisioning helper: scan **every** block-device partition, mount the
ones that are not mounted yet (read-only), and look for an SSH private key at a
configured path — by default `LIUXUTOOLS/ssh.key`. The first key found is copied
to a configured location with mode `600` and the scan stops.

The behaviour is driven entirely by a JSON file, and the whole thing is packaged
both as a Nix flake and as a NixOS module that runs it as a systemd service.

## How it works

1. Refuses to run unless it is root (mounting needs `CAP_SYS_ADMIN`).
2. Enumerates partitions with `lsblk -J`, keeping `type == "part"` entries whose
   filesystem is in the allow-list. `swap` and encrypted (`crypto_*`) devices are
   always skipped.
3. For each partition:
   - **already mounted** → scanned in place (left untouched), unless
     `scan_mounted = false`;
   - **not mounted** → mounted read-only at one of `temp_mounts`, scanned, then
     unmounted (unless `cleanup = false`).
4. Resolves `search_path` relative to the filesystem root, case-insensitively by
   default (FAT/NTFS are case-insensitive).
5. On the first hit: copies the key to `output`, `chmod 600`, prints the source
   path and stops.

Every run scans **all** partitions again, so when the service is re-triggered by
a newly plugged device, previously unavailable keys are discovered.

## Configuration

Validated against [`pe-key-scanner.schema.json`](./pe-key-scanner.schema.json).

| key | type | default | meaning |
| --- | --- | --- | --- |
| `output` | string | `"/run/pe-key-scanner/ssh.key"` | Where the found private key is stored (mode 600). |
| `temp_mounts` | list of paths | `["/run/pe-key-scanner/mnt"]` | Temporary mount points, reused round-robin. |
| `search_path` | string | `"LIUXUTOOLS/ssh.key"` | Path looked up under each filesystem root. |
| `filesystems` | list of strings | ext*/vfat/exfat/ntfs/btrfs/xfs/f2fs/hfsplus/iso9660 | Allowed `lsblk` filesystem types. |
| `read_only` | bool | `true` | Mount temporary filesystems read-only. |
| `scan_mounted` | bool | `true` | Also scan filesystems that are already mounted. |
| `stop_on_first` | bool | `true` | Stop after the first key. |
| `cleanup` | bool | `true` | Unmount/remove temporary mounts afterwards. |
| `case_insensitive` | bool | `true` | Case-insensitive `search_path` matching. |
| `mount_options` | attrs string→string | `{}` | Extra mount options per fstype, e.g. `{"vfat":"utf8=true"}`. |

Every key has a default, so an empty config `{}` is valid and uses the values
above. Example [`pe-key-scanner.json`](./pe-key-scanner.json):

```json
{
  "temp_mounts": ["/run/pe-key-scanner/mnt"],
  "search_path": "LIUXUTOOLS/ssh.key",
  "output": "/run/pe-key-scanner/ssh.key"
}
```

## Standalone usage

```sh
sudo nu pe-key-scanner.nu                      # all defaults
sudo nu pe-key-scanner.nu --config pe-key-scanner.json
sudo nu pe-key-scanner.nu --dry-run            # list the plan, mount nothing
sudo nu pe-key-scanner.nu -v                   # per-device progress on stderr
```

## Nix flake

```sh
nix build                        # -> result/bin/pe-key-scanner
nix run . -- --dry-run
```

Exports: `packages.default`, `overlays.default`, `nixosModules.default`.

## NixOS module

Everything has a default (applied by the program), so enabling the module is enough:

```nix
{
  imports = [ inputs.pe-key-scanner.nixosModules.default ];

  services.pe-key-scanner.enable = true;
}
```

That renders an empty `/etc/pe-key-scanner.json` (`{}`) — the program fills in
`temp_mounts`, `search_path` and `output` — runs once at boot, and rescans on
device add.

Override only what you need; the rest keep their defaults:

```nix
services.pe-key-scanner = {
  enable = true;
  settings.output = "/persist/ssh.key";      # default: /run/pe-key-scanner/ssh.key
  service.onSuccess = [ "sshd.service" ];    # re-trigger consumers once a key is found
};
```

### Options

- `services.pe-key-scanner.enable` — **the only required option**
- `package` — default `pkgs.pe-key-scanner`
- `settings` — rendered to `/etc/pe-key-scanner.json`, schema-validated at build time;
  empty by default, the program applies the defaults below
  - `settings.temp_mounts` — default `[ "/run/pe-key-scanner/mnt" ]`
  - `settings.search_path` — default `"LIUXUTOOLS/ssh.key"`
  - `settings.output` — default `"/run/pe-key-scanner/ssh.key"`
- `service.enable` — default `true`
- `service.startAtBoot` — default `true`, `WantedBy=multi-user.target`
- `service.restartOnDeviceAdd` — default `true`, udev (`SYSTEMD_WANTS=`) rerun on device add
- `service.deviceAddMatch` — default `"partition"` (`partition` | `disk` | `any`)
- `service.onSuccess` — default `[ ]`, `OnSuccess=` units activated after a successful scan
- `service.after` / `service.wants` — default `[ ]`, extra unit dependencies
- `service.extraConfig` — default `{ }`, extra `serviceConfig` attributes

The unit is a plain `Type=oneshot` with no `RemainAfterExit`, so it returns to
`inactive` after each run. That is what allows udev to re-trigger it and lets
`OnSuccess=` fire. A failed scan (no key) does **not** activate `onSuccess`.
