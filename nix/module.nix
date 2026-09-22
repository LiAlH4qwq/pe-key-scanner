{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.pe-key-scanner;

  jsonFormat = pkgs.formats.json { };

  # Defaults live in the program (see pe-key-scanner.nu / the JSON schema), so
  # an empty settings set is valid and only `enable = true;` is needed.
  settingsFile = jsonFormat.generate "pe-key-scanner.json" cfg.settings;

  schemaFile = "${cfg.package}/share/pe-key-scanner/pe-key-scanner.schema.json";

  # Validate the settings against the packaged JSON schema at build time, so a
  # typo fails `nixos-rebuild switch` instead of the service at runtime.
  validatedSettings =
    pkgs.runCommand "pe-key-scanner.json"
      {
        nativeBuildInputs = [ pkgs.check-jsonschema ];
      }
      ''
        check-jsonschema --schemafile ${schemaFile} ${settingsFile}
        cp ${settingsFile} $out
      '';

  # Trigger on any block-device add. Bare disks as well as partitions are
  # scanned, and every run is a full rescan, so no DEVTYPE filter is applied.
  udevRule = ''
    SUBSYSTEM=="block", ACTION=="add", TAG+="systemd", ENV{SYSTEMD_WANTS}+="pe-key-scanner.service"
  '';
in
{
  options.services.pe-key-scanner = {
    enable = lib.mkEnableOption "the pe-key-scanner partition key scanner";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pe-key-scanner;
      defaultText = lib.literalExpression "pkgs.pe-key-scanner";
      description = "Package providing the `pe-key-scanner` executable and JSON schema.";
    };

    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = ''
        Configuration rendered to {file}`/etc/pe-key-scanner.json` and passed to
        the scanner. Validated against the packaged
        {file}`pe-key-scanner.schema.json` at build time.

        Every key has a default (`temp_mount_dir`, `search_path`, `output`), so an
        empty set is valid; only `enable = true` is needed. Set keys here to
        override the defaults.
      '';
      example = lib.literalExpression ''
        {
          search_path = "LIUXUTOOLS/ssh.key";
          output = "/persist/ssh.key";
        }
      '';
    };

    service = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to install the systemd service.";
      };

      startAtBoot = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the scanner once during boot (`WantedBy=multi-user.target`).";
      };

      restartOnDeviceAdd = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Re-run the scanner whenever any block device is added (e.g. a USB
          disk is plugged in). Implemented with a udev rule that pulls the unit
          in via `SYSTEMD_WANTS=`; every run is a full rescan of all partitions
          and bare disks, so newly available keys are discovered.
        '';
      };

      onSuccess = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Units activated via `OnSuccess=` after the scanner completes
          successfully (i.e. a key was found). Use this to re-trigger consumers.

          Note: this only *starts* a unit, so it is a no-op for `oneshot` units
          with `RemainAfterExit = true` (e.g. `sops-install-secrets.service`)
          that are already active — use {option}`restartOnSuccess` for those.
        '';
        example = [ "sshd.service" ];
      };

      restartOnSuccess = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Units force-restarted (`systemctl --no-block restart`) after the
          scanner completes successfully. Unlike {option}`onSuccess`, this also
          re-runs `oneshot` units that stay active via `RemainAfterExit`, such as
          `sops-install-secrets.service`.
        '';
        example = [ "sops-install-secrets.service" ];
      };

      after = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra `After=` dependencies for the scanner unit.";
      };

      wants = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra `Wants=` dependencies for the scanner unit.";
      };

      extraConfig = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra attributes merged into the service's `serviceConfig`.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."pe-key-scanner.json".source = validatedSettings;

    systemd.services.pe-key-scanner = lib.mkIf cfg.service.enable {
      description = "pe-key-scanner: locate LIUXUTOOLS/ssh.key across all partitions";

      wantedBy = lib.optional cfg.service.startAtBoot "multi-user.target";
      after = [ "local-fs.target" ] ++ cfg.service.after;
      wants = cfg.service.wants;

      unitConfig = {
        StartLimitIntervalSec = 0;
      }
      // lib.optionalAttrs (cfg.service.onSuccess != [ ]) {
        OnSuccess = cfg.service.onSuccess;
      };

      serviceConfig = {
        Type = "oneshot";
        # Deliberately no RemainAfterExit: the unit returns to `inactive` after
        # each run so it can be re-triggered by udev and so `OnSuccess=` fires.

        ExecStart = "${cfg.package}/bin/pe-key-scanner --config /etc/pe-key-scanner.json";

        # Mounting arbitrary filesystems needs CAP_SYS_ADMIN and a shared mount
        # namespace; keep the sandbox out of the way.
        PrivateMounts = false;
        ProtectSystem = false;
        ProtectHome = false;

        # Safety net for mounts left behind by an interrupted scan.
        ExecStopPost = [ "-${pkgs.util-linux}/bin/umount -R /run/pe-key-scanner" ];
      }
      // lib.optionalAttrs (cfg.service.restartOnSuccess != [ ]) {
        # Runs only when ExecStart succeeds (a key was found). `--no-block`
        # avoids an ordering deadlock while this unit is still activating.
        ExecStartPost = map (
          u: "-${config.systemd.package}/bin/systemctl --no-block restart ${u}"
        ) cfg.service.restartOnSuccess;
      }
      // cfg.service.extraConfig;
    };

    services.udev.extraRules = lib.mkIf cfg.service.restartOnDeviceAdd udevRule;
  };
}
