#!/usr/bin/env nu

# pe-key-scanner -- scan every block-device partition, mount what is not yet
# mounted (read-only), and look for an SSH private key at a configured path
# (default `LIUXUTOOLS/ssh.key`). PECMD-style: find the key on whatever disk it
# lives on. Behaviour is driven entirely by a JSON config file.
#
# Requires root: mounting arbitrary filesystems needs CAP_SYS_ADMIN.

const DEFAULT_FILESYSTEMS = [
    "vfat"
    "exfat"
    "ntfs"
    "ntfs3"
    "ext4"
    "ext3"
    "ext2"
    "btrfs"
    "xfs"
    "f2fs"
    "hfsplus"
    "iso9660"
]

const DEFAULT_SEARCH_PATH = "LIUXUTOOLS/ssh.key"

const DEFAULT_TEMP_MOUNTS = ["/run/pe-key-scanner/mnt"]

const DEFAULT_OUTPUT = "/run/pe-key-scanner/ssh.key"

# Recursively flatten `lsblk --json` blockdevices (nested under `children`).
def "flatten-devices" []: list -> list {
    each {|d|
        let rest = (
            if ($d | get -o children | default [] | is-not-empty) {
                $d.children | flatten-devices
            } else {
                []
            }
        )
        [($d | reject -o children) ...$rest]
    } | flatten
}

# Read, normalise and validate the JSON config.
def "load-config" [path: path] {
    if not ($path | path exists) {
        error make { msg: $"config file not found: ($path)" }
    }
    let raw = (open --raw $path | from json)
    let output = ($raw | get -o output | default $DEFAULT_OUTPUT)
    if ($output | path type) == "dir" {
        error make { msg: $"config `output` must be a file path, got a directory: ($output)" }
    }
    let temp_mounts = ($raw | get -o temp_mounts | default $DEFAULT_TEMP_MOUNTS)
    if ($temp_mounts | is-empty) {
        error make { msg: "config `temp_mounts` must contain at least one directory" }
    }
    {
        temp_mounts: $temp_mounts
        search_path: ($raw | get -o search_path | default $DEFAULT_SEARCH_PATH)
        output: $output
        filesystems: ($raw | get -o filesystems | default $DEFAULT_FILESYSTEMS)
        read_only: ($raw | get -o read_only | default true)
        scan_mounted: ($raw | get -o scan_mounted | default true)
        stop_on_first: ($raw | get -o stop_on_first | default true)
        cleanup: ($raw | get -o cleanup | default true)
        case_insensitive: ($raw | get -o case_insensitive | default true)
        mount_options: ($raw | get -o mount_options | default {})
    }
}

# All candidate partitions (type=part), filtered by filesystem and de-duplicated
# by UUID so btrfs multi-subvolume mounts are not scanned repeatedly.
def "get-partitions" [cfg: record] {
    let all = (
        try {
            ^lsblk -J -o NAME,FSTYPE,SIZE,TYPE,LABEL,UUID,MOUNTPOINTS
            | from json
            | get blockdevices
            | flatten-devices
        } catch {|e|
            error make { msg: $"failed to enumerate block devices: ($e.msg)" }
        }
    )
    $all
    | where {|d| ($d.type == "part") and ($d.fstype != null) and ($d.fstype in $cfg.filesystems) and (not ($d.fstype | str starts-with "crypto_")) }
    | uniq-by uuid
}

# Map a detected fstype to the `mount -t` argument (ntfs needs the ntfs-3g helper).
def "mount-fs" [fstype: string] {
    if $fstype == "ntfs" { "ntfs-3g" } else { $fstype }
}

# Compose the `-o` option string for a filesystem.
def "mount-opt" [cfg: record, fstype: string] {
    let base = (if $cfg.read_only { "ro" } else { "rw" })
    let extra = ($cfg.mount_options | get -o $fstype | default "")
    if ($extra | is-empty) { $base } else { $"($base),($extra)" }
}

# Resolve a relative path under `root`, optionally case-insensitively, without
# ever following a symlink out of the tree. Returns the absolute file path or null.
def "resolve-key" [root: string, rel: string, ci: bool] {
    if not ($root | path exists) { return null }
    mut cur = $root
    for part in ($rel | path split) {
        let entries = (try { ls -a $cur } catch { [] })
        let hit = (
            $entries
            | where {|e|
                let b = ($e.name | path basename)
                if $ci { $b =~ ("(?i)^" + ($part | str escape-regex) + "$") } else { $b == $part }
            }
            | get -o name
            | first
        )
        if $hit == null { return null }
        $cur = $hit
    }
    if (($cur | path type) == "file") { $cur } else { null }
}

def "mountpoints-of" [d: record] {
    $d.mountpoints? | default [] | where {|m| $m != null and $m != "[SWAP]" }
}

def main [
    --config(-c): path = "pe-key-scanner.json" # JSON configuration file
    --dry-run # List the scan plan without mounting anything
    --verbose(-v) # Print per-device progress to stderr
] {
    if not $dry_run and (^id -u | str trim) != "0" {
        error make { msg: "pe-key-scanner must run as root (mounting requires CAP_SYS_ADMIN)" }
    }

    let cfg = (load-config $config)
    let partitions = (get-partitions $cfg)

    if $dry_run {
        print (
            $partitions
            | each {|d|
                let mps = (mountpoints-of $d)
                {
                    device: $"/dev/($d.name)"
                    fstype: $d.fstype
                    label: ($d.label | default "")
                    size: $d.size
                    action: (if ($mps | is-not-empty) and $cfg.scan_mounted {
                        "scan (already mounted)"
                    } else if ($mps | is-not-empty) {
                        "skip (mounted, scan_mounted=false)"
                    } else {
                        "mount + scan"
                    })
                    mountpoints: ($mps | str join ", ")
                }
            }
            | table -e
        )
        return
    }

    let outdir = ($cfg.output | path dirname)
    if ($outdir | is-not-empty) {
        ^mkdir -p $outdir
        ^chmod 700 $outdir
    }

    mut results = []
    mut found = ""
    mut temp_idx = 0

    for d in $partitions {
        if ($found | is-not-empty) and $cfg.stop_on_first { break }

        let dev = $"/dev/($d.name)"
        let mps = (mountpoints-of $d)
        let label = ($d.label | default "")

        if ($mps | is-not-empty) {
            if not $cfg.scan_mounted {
                if $verbose { print -e $"skip ($dev): mounted and scan_mounted=false" }
                continue
            }
            for mp in $mps {
                let key = (resolve-key $mp $cfg.search_path $cfg.case_insensitive)
                if $verbose { print -e $"scan ($dev) at ($mp): (if $key == null { 'no key' } else { $key })" }
                $results = ($results | append {
                    device: $dev
                    fstype: $d.fstype
                    label: $label
                    location: $mp
                    mounted: true
                    status: (if $key == null { "not-found" } else { "FOUND" })
                    key: $key
                })
                if $key != null { $found = $key }
            }
        } else {
            let dir = ($cfg.temp_mounts | get ($temp_idx mod ($cfg.temp_mounts | length)))
            $temp_idx = ($temp_idx + 1)
            ^mkdir -p $dir

            let fs = (mount-fs $d.fstype)
            let opt = (mount-opt $cfg $d.fstype)
            let res = (^mount -t $fs -o $opt $dev $dir | complete)

            if $res.exit_code == 0 {
                let key = (resolve-key $dir $cfg.search_path $cfg.case_insensitive)
                if $verbose { print -e $"mount ($dev) -> ($dir): (if $key == null { 'no key' } else { $key })" }
                if $cfg.cleanup {
                    ^umount $dir | complete | ignore
                    ^rmdir $dir | complete | ignore
                }
                $results = ($results | append {
                    device: $dev
                    fstype: $d.fstype
                    label: $label
                    location: $dir
                    mounted: false
                    status: (if $key == null { "not-found" } else { "FOUND" })
                    key: $key
                })
                if $key != null { $found = $key }
            } else {
                let err = ($res.stderr | str trim | str replace -a "\n" " ")
                if $verbose { print -e $"mount ($dev) failed: ($err)" }
                $results = ($results | append {
                    device: $dev
                    fstype: $d.fstype
                    label: $label
                    location: $dir
                    mounted: false
                    status: "mount-failed"
                    key: null
                })
            }
        }
    }

    if ($found | is-not-empty) {
        ^cp -f $found $cfg.output
        ^chmod 600 $cfg.output
        print $"FOUND ($found)"
        print $"stored key -> ($cfg.output)"
        if ($results | where status == "FOUND" | length) > 1 {
            print (($results | where status == "FOUND" | select device location key) | table -e)
        }
        return
    }

    print "no SSH key found"
    if ($results | is-not-empty) {
        print (($results | select device fstype label location status) | table -e)
    }
    exit 1
}
