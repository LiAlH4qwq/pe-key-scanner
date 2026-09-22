{
  description = "pe-key-scanner: PECMD-style partition scanner that mounts filesystems and finds LIUXUTOOLS/ssh.key";

  inputs = {
    systems.url = "github:nix-systems/default-linux";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (
      flake@{ config, withSystem, ... }:
      {
        systems = import inputs.systems;

        flake = {
          overlays = {
            default = config.flake.overlays.pe-key-scanner;
            pe-key-scanner = (
              _: prev:
              withSystem prev.stdenv.hostPlatform.system (
                { config, ... }: {
                  pe-key-scanner = config.packages.pe-key-scanner;
                }
              )
            );
          };

          nixosModules = {
            default = config.flake.nixosModules.pe-key-scanner;
            pe-key-scanner =
              { lib, pkgs, ... }:
              {
                imports = [ ./nix/module.nix ];
                services.pe-key-scanner.package = lib.mkDefault (
                  withSystem pkgs.stdenv.hostPlatform.system ({ config, ... }: config.packages.pe-key-scanner)
                );
              };
          };
        };

        perSystem =
          { config, pkgs, ... }:
          {
            packages.pe-key-scanner = pkgs.callPackage ./nix/package.nix { };
            packages.default = config.packages.pe-key-scanner;

            checks.pe-key-scanner = config.packages.pe-key-scanner;
            checks.default = config.checks.pe-key-scanner;

            formatter = pkgs.nixfmt;
          };
      }
    );
}
