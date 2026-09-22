# pe-key-scanner

PECMD-style provisioning helper: scan **every** block device (partitions and bare
disks), mount the ones that are not mounted yet (always read-only), and look for
an SSH private key at a configured path — by default `LIUXUTOOLS/ssh.key`. The
first key found is copied to a configured location with mode `600` and the scan
stops.

The behaviour is driven entirely by a JSON file, and the whole thing is packaged
both as a Nix flake and as a NixOS module that runs it as a systemd service.

## How it works

1. Refuses to run unless it is root (mounting needs `CAP_SYS_ADMIN`).
2. Enumerates block devices with `lsblk -J`, keeping both partitions and bare
   disks. `swap` and encrypted (`crypto_*`) devices are skipped, since they
   cannot be mounted without first being activated.
3. For each device:
   - **already mounted** → scanned in place (left untouched);
   - **not mounted** → mounted read-only in a per-device subdirectory of the
     `temp_mount_dir` pool, scanned, then unmounted and `rmdir`'d.
4. Mounting does its best: it uses the detected filesystem type (mapping `ntfs`
   to `ntfs-3g`) and, if that fails, retries letting `mount` autodetect. There is
   no filesystem allow-list.
5. Resolves `search_path` relative to the filesystem root, case-insensitively by
   default (FAT/NTFS are case-insensitive).
6. On the first hit: copies the key to `output`, `chmod 600`, prints the source
   path and stops.

Every run scans **all** devices again, so when the service is re-triggered by a
newly plugged device, previously unavailable keys are discovered.

## Configuration

Validated against [`pe-key-scanner.schema.json`](./pe-key-scanner.schema.json).

| key | type | default | meaning |
| --- | --- | --- | --- |
| `output` | string | `"/run/pe-key-scanner/ssh.key"` | Where the found private key is stored (mode 600). |
| `temp_mount_dir` | path | `"/run/pe-key-scanner/mnt"` | Pool directory holding one temporary mount point per unmounted device. |
| `search_path` | string | `"LIUXUTOOLS/ssh.key"` | Path looked up under each filesystem root. |
| `stop_on_first` | bool | `true` | Stop after the first key. |
| `case_insensitive` | bool | `true` | Case-insensitive `search_path` matching. |
| `mount_options` | attrs string→string | `{}` | Extra mount options per fstype appended after `ro`, e.g. `{"vfat":"utf8=true"}`. |

Every key has a default, so an empty config `{}` is valid and uses the values
above. Example [`pe-key-scanner.json`](./pe-key-scanner.json):

```json
{
  "temp_mount_dir": "/run/pe-key-scanner/mnt",
  "search_path": "LIUXUTOOLS/ssh.key",
  "output": "/run/pe-key-scanner/ssh.key"
}
```

Mounts are always read-only and cleanup always runs. Cleanup is intentionally
conservative: temporary mount points are removed with `rmdir` only (never
`rm -rf`), so a volume whose `umount` failed can never have its contents
deleted. Cleanup problems (failed `umount`, non-empty mount point, pool not
empty) are printed as warnings and **never** change the exit code — a successful
scan still exits `0`.

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
`temp_mount_dir`, `search_path` and `output` — runs once at boot, and rescans on
device add.

Override only what you need; the rest keep their defaults:

```nix
services.pe-key-scanner = {
  enable = true;
  settings.output = "/persist/ssh.key";   # default: /run/pe-key-scanner/ssh.key
  service.onSuccess = [ "sshd.service" ]; # start-only consumers once a key is found
};
```

### Re-triggering `sops-install-secrets`

`sops-install-secrets.service` is a `oneshot` with `RemainAfterExit = true`, so
`OnSuccess=` (which only starts a unit) is a no-op once it is active. Use
`restartOnSuccess`, which runs `systemctl --no-block restart` after a successful
scan — i.e. whenever a plugged-in USB device yields the key:

```nix
services.pe-key-scanner = {
  enable = true;                            # restartOnDeviceAdd defaults to true
  service.restartOnSuccess = [ "sops-install-secrets.service" ];
};
```

`sops-install-secrets` then re-reads its manifest; with
`SOPS_RESTART_UNITS_VIA_SYSTEMCTL=1` (sops-nix's default) it also restarts the
consumer units that depend on those secrets.

### Options

- `services.pe-key-scanner.enable` — **the only required option**
- `package` — default `pkgs.pe-key-scanner`
- `settings` — rendered to `/etc/pe-key-scanner.json`, schema-validated at build time;
  empty by default, the program applies the defaults below
  - `settings.temp_mount_dir` — default `"/run/pe-key-scanner/mnt"`
  - `settings.search_path` — default `"LIUXUTOOLS/ssh.key"`
  - `settings.output` — default `"/run/pe-key-scanner/ssh.key"`
- `service.enable` — default `true`
- `service.startAtBoot` — default `true`, `WantedBy=multi-user.target`
- `service.restartOnDeviceAdd` — default `true`, udev (`SYSTEMD_WANTS=`) rerun on any block-device add
- `service.onSuccess` — default `[ ]`, `OnSuccess=` units activated after a successful scan (start-only)
- `service.restartOnSuccess` — default `[ ]`, units force-restarted after a successful scan (`systemctl --no-block restart`); use for `RemainAfterExit` oneshots like `sops-install-secrets.service`
- `service.after` / `service.wants` — default `[ ]`, extra unit dependencies
- `service.extraConfig` — default `{ }`, extra `serviceConfig` attributes

The unit is a plain `Type=oneshot` with no `RemainAfterExit`, so it returns to
`inactive` after each run. That is what allows udev to re-trigger it and lets
`OnSuccess=` fire. A failed scan (no key) does **not** activate `onSuccess` nor
run `restartOnSuccess`.
