#!/usr/bin/env nu

# pe-key-scanner -- scan every block-device partition and bare disk, mount what
# is not yet mounted (always read-only), and look for an SSH private key at a
# configured path (default `LIUXUTOOLS/ssh.key`). PECMD-style: find the key on
# whatever disk it lives on. Behaviour is driven entirely by a JSON config file.
#
# Requires root: mounting arbitrary filesystems needs CAP_SYS_ADMIN.

const DEFAULT_SEARCH_PATH = "LIUXUTOOLS/ssh.key"

const DEFAULT_TEMP_MOUNT_DIR = "/run/pe-key-scanner/mnt"

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
    let kind = ($raw | describe)
    if not ($kind | str starts-with "record") {
        error make { msg: $"config must be a JSON object, got ($kind)" }
    }
    let output = ($raw | get -o output | default $DEFAULT_OUTPUT)
    let output_kind = (try { $output | path type } catch { null })
    if $output_kind == "dir" {
        error make { msg: $"config `output` must be a file path, got a directory: ($output)" }
    }
    let temp_mount_dir = ($raw | get -o temp_mount_dir | default $DEFAULT_TEMP_MOUNT_DIR)
    if ((try { $temp_mount_dir | path type } catch { null }) == "file") {
        error make { msg: $"config `temp_mount_dir` must be a directory, got a file: ($temp_mount_dir)" }
    }
    {
        temp_mount_dir: $temp_mount_dir
        search_path: ($raw | get -o search_path | default $DEFAULT_SEARCH_PATH)
        output: $output
        stop_on_first: ($raw | get -o stop_on_first | default true)
        case_insensitive: ($raw | get -o case_insensitive | default true)
        mount_options: ($raw | get -o mount_options | default {})
    }
}

# All candidate block devices: partitions and bare disks. De-duplicated by
# device name. Swap and encrypted (crypto_*) devices are skipped, since they
# cannot be mounted without first being activated.
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
    | where {|d| (($d.type == "part") or ($d.type == "disk")) and ($d.fstype? | default "") != "swap" and (not (($d.fstype? | default "") | str starts-with "crypto_")) }
    | uniq-by name
}

# Map a detected fstype to the `mount -t` argument (ntfs needs the ntfs-3g
# helper). An empty result means "let mount autodetect".
def "mount-fs" [fstype: any] {
    if ($fstype | is-empty) { "" } else if $fstype == "ntfs" { "ntfs-3g" } else { $fstype }
}

# Try to mount `dev` at `dir`, read-only. Uses the detected fstype when known and
# falls back to autodetection before giving up, so it does its best to mount
# whatever it can. Returns a `complete`-style record.
def "attempt-mount" [dev: string, dir: string, fstype: any, opt: string] {
    let fs = (mount-fs $fstype)
    let first = (
        if ($fs | is-empty) {
            ^mount -o $opt $dev $dir | complete
        } else {
            ^mount -t $fs -o $opt $dev $dir | complete
        }
    )
    if $first.exit_code == 0 or ($fs | is-empty) {
        return $first
    }
    ^mount -o $opt $dev $dir | complete
}

# Compose the `-o` option string for a filesystem (always read-only).
def "mount-opt" [cfg: record, fstype: any] {
    let extra = (
        if ($fstype | is-empty) { "" } else { $cfg.mount_options | get -o $fstype | default "" }
    )
    if ($extra | is-empty) { "ro" } else { $"ro,($extra)" }
}

# Resolve a relative path under `root`, optionally case-insensitively. Every
# intermediate component must be a real directory and the leaf a real file, so
# symlinked components cannot redirect the lookup out of the scanned tree.
def "resolve-key" [root: string, rel: string, ci: bool] {
    let root_ok = (try { $root | path exists } catch { false })
    if not $root_ok { return null }
    let parts = ($rel | path split)
    if ($parts | is-empty) { return null }
    let last_idx = (($parts | length) - 1)
    mut cur = $root
    for part in ($parts | enumerate) {
        let entries = (try { ls -a $cur } catch { [] })
        let hit = (
            $entries
            | where {|e|
                let b = ($e.name | path basename)
                if $ci { $b =~ ("(?i)^" + ($part.item | str escape-regex) + "$") } else { $b == $part.item }
            }
            | get -o name
            | first
        )
        if $hit == null { return null }
        let kind = (try { $hit | path type } catch { null })
        if $part.index == $last_idx {
            return (if $kind == "file" { $hit } else { null })
        }
        if $kind != "dir" { return null }
        $cur = $hit
    }
    null
}

def "mountpoints-of" [d: record] {
    $d.mountpoints? | default [] | where {|m| $m != null and $m != "[SWAP]" }
}

# Persist a found key to `out`. Must be called while the source is still
# readable, i.e. before a temporary mount is torn down. Fails loudly if the key
# cannot be copied or its permissions set, so a scan never reports success
# without the key actually being stored.
def "store-key" [src: string, out: string] {
    if ($src | path expand) != ($out | path expand) {
        let r = (^cp -f $src $out | complete)
        if $r.exit_code != 0 {
            error make { msg: $"failed to copy key to ($out): ($r.stderr | str trim)" }
        }
    }
    let c = (^chmod 600 $out | complete)
    if $c.exit_code != 0 {
        error make { msg: $"failed to chmod 600 ($out): ($c.stderr | str trim)" }
    }
}

# Best-effort teardown of one temporary mount point: unmount, then remove the
# now-empty directory. This is deliberately *not* recursive, so a failed
# unmount can never delete the mounted volume's contents. Any problem is only
# a warning and never changes the exit code.
def "cleanup-mount" [dir: string] {
    let u = (^umount $dir | complete)
    if $u.exit_code != 0 {
        print -e $"warning: umount ($dir) failed, leaving it alone: ($u.stderr | str trim)"
        return
    }
    let r = (^rmdir $dir | complete)
    if $r.exit_code != 0 {
        print -e $"warning: could not remove temp mount point ($dir): ($r.stderr | str trim)"
    }
}

# Best-effort removal of the now-empty temp mount pool (rmdir only, never -r).
def "cleanup-pool" [pool: string] {
    let r = (^rmdir $pool | complete)
    if $r.exit_code != 0 {
        print -e $"warning: could not remove temp mount pool ($pool): ($r.stderr | str trim)"
    }
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
                    action: (if ($mps | is-not-empty) {
                        "scan (already mounted)"
                    } else {
                        "mount + scan"
                    })
                    mountpoints: (if ($mps | is-not-empty) {
                        $mps | str join ", "
                    } else {
                        $cfg.temp_mount_dir | path join $d.name
                    })
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
    mut pool_created = false
    let pool = $cfg.temp_mount_dir

    for d in $partitions {
        if ($found | is-not-empty) and $cfg.stop_on_first { break }

        let dev = $"/dev/($d.name)"
        let mps = (mountpoints-of $d)
        let label = ($d.label | default "")

        if ($mps | is-not-empty) {
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
                if $key != null and ($found | is-empty) {
                    store-key $key $cfg.output
                    $found = $key
                }
            }
        } else {
            if not $pool_created {
                let mk = (^mkdir -p $pool | complete)
                if $mk.exit_code == 0 {
                    ^chmod 700 $pool | complete | ignore
                    $pool_created = true
                } else {
                    print -e $"warning: cannot create temp mount pool ($pool): ($mk.stderr | str trim)"
                }
            }

            # Each device gets its own mount point inside the pool; the pool
            # itself is never used as a mount point and is only ever rmdir'd.
            let dir = ($pool | path join $d.name)
            let mkdir_res = (^mkdir -p $dir | complete)
            let opt = (mount-opt $cfg $d.fstype)
            let res = (
                if $mkdir_res.exit_code == 0 {
                    attempt-mount $dev $dir $d.fstype $opt
                } else {
                    {
                        exit_code: 1
                        stdout: ""
                        stderr: $"cannot create mount point ($dir): ($mkdir_res.stderr | str trim)"
                    }
                }
            )

            if $res.exit_code == 0 {
                let key = (resolve-key $dir $cfg.search_path $cfg.case_insensitive)
                if $verbose { print -e $"mount ($dev) -> ($dir): (if $key == null { 'no key' } else { $key })" }
                # Copy while still mounted: the mount point is torn down below.
                if $key != null and ($found | is-empty) {
                    store-key $key $cfg.output
                    $found = $key
                }
                cleanup-mount $dir
                $results = ($results | append {
                    device: $dev
                    fstype: $d.fstype
                    label: $label
                    location: $dir
                    mounted: false
                    status: (if $key == null { "not-found" } else { "FOUND" })
                    key: $key
                })
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

    if $pool_created {
        cleanup-pool $pool
    }

    if ($found | is-not-empty) {
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
