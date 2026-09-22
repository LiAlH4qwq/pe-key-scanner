{
  lib,
  writers,
  symlinkJoin,
  coreutils,
  util-linux,
  ntfs3g,
  e2fsprogs,
  xfsprogs,
  btrfs-progs,
  f2fs-tools,
  dosfstools,
  exfatprogs,
}:

let
  runtimePath = lib.makeBinPath [
    coreutils
    util-linux
    ntfs3g
    e2fsprogs
    xfsprogs
    btrfs-progs
    f2fs-tools
    dosfstools
    exfatprogs
  ];

  script = writers.writeNuBin "pe-key-scanner" {
    makeWrapperArgs = [
      "--prefix"
      "PATH"
      ":"
      runtimePath
    ];
  } (builtins.readFile ../pe-key-scanner.nu);
in
symlinkJoin {
  name = "pe-key-scanner";

  paths = [ script ];

  postBuild = ''
    mkdir -p "$out/share/pe-key-scanner"
    cp ${../pe-key-scanner.json} "$out/share/pe-key-scanner/pe-key-scanner.json"
    cp ${../pe-key-scanner.schema.json} "$out/share/pe-key-scanner/pe-key-scanner.schema.json"
  '';

  meta = {
    description = "PECMD-style partition scanner that mounts filesystems and locates LIUXUTOOLS/ssh.key";
    mainProgram = "pe-key-scanner";
    platforms = lib.platforms.linux;
  };
}
