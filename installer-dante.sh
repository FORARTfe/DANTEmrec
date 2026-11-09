#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# ALSAmrec Dante fork v0.1.0. Experimental; not a verified device installation.
# Original recorder workflow: J. Bruce Fields, 2024.
# Original ALSAmrec LuCI/CGI/OpenWrt work: FORART, 2025-26.
# This separate fork does not overwrite the original recorder or CGI endpoint.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
MODE=install
DEST=
DEPS=1
case "${1:-}" in
    --extract)
        [ "$#" -eq 2 ] || { echo 'Usage: installer-dante.sh --extract /absolute/directory' >&2; exit 2; }
        MODE=extract
        DEST=${2%/}
        case "$DEST" in ''|/) echo 'Extraction requires a non-root directory' >&2; exit 2;; /*) ;; *) echo 'Use an absolute extraction path' >&2; exit 2;; esac
        mkdir -p "$DEST"
        ;;
    --no-deps) [ "$#" -eq 1 ] || exit 2; DEPS=0 ;;
    '') [ "$#" -eq 0 ] || exit 2 ;;
    *) echo 'Usage: installer-dante.sh [--no-deps | --extract /absolute/directory]' >&2; exit 2 ;;
esac

if [ "$MODE" = install ]; then
    [ "$(id -u)" = 0 ] || { echo 'Run as root on OpenWrt' >&2; exit 1; }
    [ -r /etc/openwrt_release ] || { echo 'Not an OpenWrt installation; use --extract for inspection' >&2; exit 1; }
    case "$(uname -m)" in aarch64|x86_64) ;; *) echo 'The supplied Inferno source port currently targets aarch64 and x86_64 only' >&2; exit 1;; esac
    [ -x /usr/bin/inferno2pipe ] && [ -x /usr/sbin/inferno-statime ] || {
        echo 'First build and install inferno2pipe and inferno-statime from the included source kit.' >&2
        echo 'This installer contains no prebuilt network-audio binaries.' >&2
        exit 1
    }
    /usr/bin/inferno2pipe --help 2>&1 | grep -q -- '--queue-blocks' || {
        echo 'The installed inferno2pipe is not the required OpenWrt frontend' >&2; exit 1;
    }
    if ubus call service list '{"name":"alsamrec-dante"}' 2>/dev/null | jsonfilter -e '@.*.instances.*.running' | grep -qx true; then
        echo 'Stop the existing Dante fork before upgrading it' >&2; exit 1
    fi
    if [ "$DEPS" = 1 ]; then
        packages='rpcd luci-base jshn jsonfilter block-mount kmod-fs-exfat kmod-usb-storage'
        if command -v apk >/dev/null 2>&1; then
            apk update && apk add $packages
        elif command -v opkg >/dev/null 2>&1; then
            opkg update && opkg install $packages
        else
            echo 'No supported package manager; use --no-deps after provisioning dependencies' >&2; exit 1
        fi
    fi
    for cmd in ubus uci jsonfilter block start-stop-daemon stat mktemp; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 1; }
    done
    [ -r /usr/share/libubox/jshn.sh ] || { echo 'Missing jshn library' >&2; exit 1; }
    id inferno >/dev/null 2>&1 || { echo 'Missing inferno service account from inferno-statime package' >&2; exit 1; }
fi

STAMP=$(date +%s)
write_file() {
    rel=$1; mode=$2
    target="$DEST$rel"
    # Preserve user configuration on reinstall; consume this heredoc regardless.
    if [ "$rel" = /etc/config/alsamrec_dante ] && [ -e "$target" ]; then
        cat >/dev/null
        return 0
    fi
    [ ! -L "$target" ] || { echo "Refusing symlink destination: $target" >&2; exit 1; }
    mkdir -p "$(dirname "$target")"
    if [ -e "$target" ]; then
        backup="${target}.bak-alsamrec-dante-${STAMP}"
        [ ! -e "$backup" ] || { echo "Backup already exists: $backup" >&2; exit 1; }
        cp -p "$target" "$backup"
    fi
    tmp=$(mktemp "${target}.new.XXXXXX")
    cat > "$tmp"
    chmod "$mode" "$tmp"
    mv "$tmp" "$target"
}

write_file '/etc/config/alsamrec_dante' 0600 <<'PAYLOAD_BE6AEB931A91DEE8'
config recorder 'main'
    option enabled '0'
    option network 'audio'
    option name 'ALSAmrec-Dante'
    option channels '2'
    option sample_rate '48000'
    option min_free_mib '100'
    option poll_seconds '2'
    option latency_ns '10000000'
    option rx_buffer_samples '65536'
    option block_frames '4096'
    option queue_blocks '16'
    option log_level 'info'
PAYLOAD_BE6AEB931A91DEE8

write_file '/etc/hotplug.d/block/49-alsamrec-dante' 0755 <<'PAYLOAD_3F17EFA12588B7AA'
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# A wake hint only; never enables, restarts, or changes the original recorder.
/etc/init.d/alsamrec-dante wake >/dev/null 2>&1 || true
PAYLOAD_3F17EFA12588B7AA

write_file '/etc/init.d/alsamrec-dante' 0755 <<'PAYLOAD_E0D66CD61C419BBF'
#!/bin/sh /etc/rc.common
# SPDX-License-Identifier: GPL-3.0-only
START=96
STOP=9
USE_PROCD=1
extra_command "wake" "Wake the removable-storage monitor"

start_service() {
    . /usr/lib/alsamrec-dante/common.sh
    ad_load
    [ "$AD_ENABLED" = 1 ] || return 0
    ad_validate && ad_prerequisites && ad_conflict || return 1
    ad_network || { ad_error 'Audio network needs an IPv4 address'; return 1; }
    ad_runtime || return 1
    umask 077
    cat > "$AD_RUN/statime.toml.new" <<CONFIG
loglevel = "$AD_LOG"
sdo-id = 0
domain = 0
slave-only = true
priority1 = 251
virtual-system-clock = true
virtual-system-clock-base = "monotonic_raw"
usrvclock-export = true
usrvclock-path = "$AD_CLOCK"

[[port]]
interface = "$AD_DEVICE"
network-mode = "ipv4"
hardware-clock = "none"
protocol-version = "PTPv1"
CONFIG
    mv "$AD_RUN/statime.toml.new" "$AD_RUN/statime.toml" || return 1
    procd_open_instance clock
    procd_set_param command /usr/libexec/alsamrec-dante-clock
    procd_set_param limits core="0 0" nofile="256 256"
    procd_set_param respawn 3600 5 3
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param term_timeout 5
    procd_set_param file /etc/config/alsamrec_dante
    procd_set_param netdev "$AD_DEVICE"
    procd_close_instance

    procd_open_instance recorder
    procd_set_param command /usr/sbin/alsamrec-dante-recorder
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param limits core="0 0" nofile="256 256" rtprio="0 0"
    procd_set_param term_timeout 15
    # Deliberately no respawn: unhandled recording failures must not loop silently.
    procd_set_param file /etc/config/alsamrec_dante
    procd_set_param netdev "$AD_DEVICE"
    procd_close_instance
}
reload_service() { /etc/init.d/alsamrec-dante restart; }
wake() { procd_send_signal alsamrec-dante recorder HUP; }
service_triggers() {
    local network
    config_load alsamrec_dante
    config_get network main network audio
    procd_add_reload_trigger alsamrec_dante
    procd_add_interface_trigger 'interface.*' "$network" /etc/init.d/alsamrec-dante reload
}
PAYLOAD_E0D66CD61C419BBF

write_file '/usr/lib/alsamrec-dante/common.sh' 0644 <<'PAYLOAD_9BFF81D553B41D07'
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Separate native-Dante fork of the ALSAmrec v3.1 workflow.
# Original workflow: J. Bruce Fields; OpenWrt/LuCI work: FORART.
AD_RUN=/var/run/alsamrec-dante
AD_MNT=/var/run/alsamrec-dante/disk
AD_CLOCK=/var/run/alsamrec-dante/clock/clock.sock
AD_CAPTURE=/usr/bin/inferno2pipe
AD_SERVICE=alsamrec-dante

ad_error() { printf '%s\n' "$*" >&2; }
ad_uint() {
    case "$1" in ''|*[!0-9]*|0[0-9]*) return 1;; esac
    [ "${#1}" -le 9 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}
ad_token() {
    case "$1" in *'
'*) return 1;; esac
    LC_ALL=C printf '%s\n' "$1" | LC_ALL=C grep -Eq "$2"
}
ad_load() {
    . /lib/functions.sh
    config_load alsamrec_dante
    config_get AD_ENABLED main enabled 0
    config_get AD_NETWORK main network audio
    config_get AD_NAME main name ALSAmrec-Dante
    config_get AD_CHANNELS main channels 2
    config_get AD_RATE main sample_rate 48000
    config_get AD_FREE main min_free_mib 100
    config_get AD_POLL main poll_seconds 2
    config_get AD_LATENCY main latency_ns 10000000
    config_get AD_RING main rx_buffer_samples 65536
    config_get AD_BLOCK main block_frames 4096
    config_get AD_QUEUE main queue_blocks 16
    config_get AD_LOG main log_level info
}
ad_validate() {
    case "$AD_ENABLED" in 0|1) ;; *) ad_error 'enabled must be 0 or 1'; return 1;; esac
    ad_token "$AD_NETWORK" '^[A-Za-z0-9_]{1,32}$' || { ad_error 'Invalid logical network'; return 1; }
    ad_token "$AD_NAME" '^[A-Za-z0-9_. -]{1,31}$' || { ad_error 'Invalid endpoint name'; return 1; }
    ad_uint "$AD_CHANNELS" 1 32 && ad_uint "$AD_FREE" 100 1048576 &&
    ad_uint "$AD_POLL" 1 5 && ad_uint "$AD_LATENCY" 1000000 40000000 &&
    ad_uint "$AD_BLOCK" 256 65536 && ad_uint "$AD_QUEUE" 2 64 || {
        ad_error 'Out-of-range numeric setting'; return 1;
    }
    case "$AD_RATE" in 44100|48000|88200|96000|176400|192000) ;; *) ad_error 'Unsupported rate'; return 1;; esac
    case "$AD_RING" in 65536|131072|262144|524288) ;; *) ad_error 'Unsupported ring size'; return 1;; esac
    case "$AD_LOG" in error|warn|info|debug|trace) ;; *) ad_error 'Invalid log level'; return 1;; esac
    [ "$((AD_CHANNELS * AD_BLOCK * AD_QUEUE * 4))" -le 33554432 ] || {
        ad_error 'Output pool exceeds 32 MiB'; return 1;
    }
    # Reserve at least two polling intervals of PCM in addition to the 100 MiB floor.
    [ "$((AD_FREE * 1048576))" -ge "$((AD_CHANNELS * AD_RATE * 4 * AD_POLL * 2))" ] || {
        ad_error 'Increase free-space reserve or reduce polling interval'; return 1;
    }
}
ad_network() {
    . /lib/functions/network.sh
    network_flush_cache
    AD_DEVICE=; AD_IP=
    network_get_device AD_DEVICE "$AD_NETWORK" && network_get_ipaddr AD_IP "$AD_NETWORK" &&
    ad_token "$AD_DEVICE" '^[A-Za-z0-9_.:-]{1,15}$' && [ -n "$AD_IP" ]
}
ad_service_running() {
    # The service name is always a fixed internal constant, never an RPC argument.
    ubus call service list "{\"name\":\"$1\"}" 2>/dev/null |
        jsonfilter -e '@.*.instances.*.running' 2>/dev/null | grep -qx true
}
ad_conflict() {
    local service
    for service in autorecorder inferno inferno-clock; do
        if ad_service_running "$service"; then
            ad_error "Stop the existing $service service before starting this fork"
            return 1
        fi
    done
}
ad_prerequisites() {
    local cmd help
    [ -x "$AD_CAPTURE" ] && [ -x /usr/sbin/inferno-statime ] || {
        ad_error 'Install the compiled inferno2pipe and inferno-statime packages first'; return 1;
    }
    for cmd in ubus uci jsonfilter block start-stop-daemon stat mktemp; do
        command -v "$cmd" >/dev/null 2>&1 || { ad_error "Missing command: $cmd"; return 1; }
    done
    [ -r /usr/share/libubox/jshn.sh ] || { ad_error 'Missing jshn'; return 1; }
    id inferno >/dev/null 2>&1 || { ad_error 'Missing inferno service account'; return 1; }
    help=$("$AD_CAPTURE" --help 2>&1) || { ad_error 'inferno2pipe cannot run on this target'; return 1; }
    printf '%s\n' "$help" | grep -q -- '--queue-blocks' || {
        ad_error 'Requires the supplied OpenWrt capture frontend, not unmodified upstream'; return 1;
    }
    stat -c %s /etc/config/alsamrec_dante >/dev/null 2>&1 || {
        ad_error 'stat -c support is required'; return 1;
    }
}
ad_exfat_devices() {
    # Do not execute or source block output. Ignore labels and all other metadata.
    block info 2>/dev/null | awk '
        / TYPE="exfat"([[:space:]]|$)/ {
            dev=$1; sub(/:$/, "", dev)
            if (dev ~ /^\/dev\/[A-Za-z0-9_.-]+$/ && !seen[dev]++) print dev
        }'
}
ad_single_disk() {
    local list count
    list=$(ad_exfat_devices)
    count=$(printf '%s\n' "$list" | awk 'NF { n++ } END { print n+0 }')
    [ "$count" -eq 1 ] && [ -b "$list" ] || return 1
    printf '%s\n' "$list"
}
ad_mount_source() { awk -v p="$AD_MNT" '$2==p { print $1; exit }' /proc/mounts; }
ad_disk_mounted() { awk -v d="$1" '$1==d { found=1 } END { exit !found }' /proc/mounts; }
ad_free_kib() { df -Pk "$AD_MNT" 2>/dev/null | awk 'NR==2 { print $4 }'; }
ad_size() {
    local n
    n=$(stat -c %s "$1" 2>/dev/null) || n=0
    case "$n" in ''|*[!0-9]*) n=0;; esac
    printf '%s\n' "$n"
}
ad_runtime() {
    local p
    for p in "$AD_RUN" "$AD_RUN/clock" "$AD_RUN/state" "$AD_MNT"; do
        [ ! -L "$p" ] || { ad_error "Refusing runtime symlink: $p"; return 1; }
        mkdir -p "$p" || return 1
    done
    chown root:inferno "$AD_RUN" "$AD_RUN/clock" || return 1
    chmod 0750 "$AD_RUN" || return 1
    chmod 2770 "$AD_RUN/clock" || return 1
    chown inferno:inferno "$AD_RUN/state" && chmod 0700 "$AD_RUN/state" || return 1
    if [ -z "$(ad_mount_source)" ]; then
        chown root:root "$AD_MNT" && chmod 0700 "$AD_MNT" || return 1
    fi
}
PAYLOAD_9BFF81D553B41D07

write_file '/usr/libexec/alsamrec-dante-clock' 0755 <<'PAYLOAD_C3F21BC3F0DD2C7A'
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
umask 007
export TOKIO_WORKER_THREADS=1
rm -f /var/run/alsamrec-dante/clock/clock.sock || exit 1
exec /usr/sbin/inferno-statime -c /var/run/alsamrec-dante/statime.toml
PAYLOAD_C3F21BC3F0DD2C7A

write_file '/usr/libexec/rpcd/alsamrec-dante' 0755 <<'PAYLOAD_22FF20EA0BAB8C78'
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
PATH=/usr/sbin:/usr/bin:/sbin:/bin
CTL=/usr/sbin/alsamrec-dantectl
case "${1:-}" in
    list) printf '%s\n' '{"status":{},"start":{},"stop":{},"probe":{}}' ;;
    call)
        case "${2:-}" in
            status) exec "$CTL" STATUS ;;
            probe) exec "$CTL" PROBE ;;
            start|stop)
                output=$("$CTL" "$2" 2>&1); rc=$?
                . /usr/share/libubox/jshn.sh
                json_init
                [ "$rc" -eq 0 ] && json_add_boolean success 1 || json_add_boolean success 0
                json_add_string message "$output"
                json_dump
                ;;
            *) printf '%s\n' '{"success":false,"message":"Unknown method"}'; exit 1 ;;
        esac ;;
    *) exit 1 ;;
esac
PAYLOAD_22FF20EA0BAB8C78

write_file '/usr/sbin/alsamrec-dante-recorder' 0755 <<'PAYLOAD_88057301E7C133AF'
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Root owns the storage lifecycle; the network-audio receiver runs as inferno.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
. /usr/lib/alsamrec-dante/common.sh
. /usr/share/libubox/jshn.sh
ad_load
ad_validate && ad_runtime || exit 1
AD_CHILD=; AD_CHILD_START=; AD_DISK=; AD_SESSION=; AD_OUT=; AD_LAST_STATE=
AD_BYTES=0; AD_PREV=0; AD_STARTED=0; AD_SLEEP=; AD_STOPPING=0; AD_STOP_REQUESTED=0

write_state() {
    local state="$1" message="$2"
    json_init
    json_add_string state "$state"
    json_add_string message "$message"
    json_add_int updated "$(date +%s)"
    json_add_string file "$AD_OUT"
    json_add_string disk "$AD_DISK"
    # Strings avoid 32-bit JSON integer overflow on multi-gigabyte captures.
    json_add_string bytes "$AD_BYTES"
    json_add_string pid "$AD_CHILD"
    json_add_string pcm_format S32_LE
    json_add_int channels "$AD_CHANNELS"
    json_add_int sample_rate "$AD_RATE"
    json_add_string ptp_lock not_measured
    json_dump > "$AD_RUN/status.json.new" && mv "$AD_RUN/status.json.new" "$AD_RUN/status.json"
    if [ "$state" != "$AD_LAST_STATE" ]; then
        logger -t alsamrec-dante "$state: $message"
        if [ -n "$AD_SESSION" ] && [ "$(ad_mount_source)" = "$AD_DISK" ]; then
            json_dump >> "$AD_SESSION/events.jsonl" 2>/dev/null || true
        fi
    fi
    AD_LAST_STATE=$state
}
write_metadata() {
    local ending="$1"
    [ -n "$AD_SESSION" ] && [ "$(ad_mount_source)" = "$AD_DISK" ] || return 0
    AD_BYTES=$(ad_size "$AD_OUT")
    json_init
    json_add_string schema alsamrec-dante-session-v1
    json_add_string backend inferno_native_dante
    json_add_string name "$AD_NAME"
    json_add_string logical_network "$AD_NETWORK"
    json_add_string pcm_file capture.s32le
    json_add_string pcm_format S32_LE
    json_add_int channels "$AD_CHANNELS"
    json_add_int sample_rate "$AD_RATE"
    json_add_int started_epoch "$AD_STARTED"
    json_add_int updated_epoch "$(date +%s)"
    json_add_string ending "$ending"
    json_add_string bytes "$AD_BYTES"
    json_add_string complete_frames "$((AD_BYTES / (AD_CHANNELS * 4)))"
    json_add_int trailing_partial_frame_bytes "$((AD_BYTES % (AD_CHANNELS * 4)))"
    json_add_string clock_note 'PTP lock not measured; timestamps use the host wall clock'
    json_add_string continuity_note 'File growth is not proof of valid audio on every channel. Unsubscribed time may be omitted; inspect events.jsonl.'
    json_dump > "$AD_SESSION/session.json.new" && mv "$AD_SESSION/session.json.new" "$AD_SESSION/session.json"
}
child_owned() {
    [ -n "$AD_CHILD" ] && [ -n "$AD_CHILD_START" ] || return 1
    [ "$(awk '{print $22}' "/proc/$AD_CHILD/stat" 2>/dev/null)" = "$AD_CHILD_START" ]
}
child_alive() {
    child_owned && kill -0 "$AD_CHILD" 2>/dev/null || return 1
    # A terminated child can remain a zombie until reaped.
    [ "$(awk '{print $3}' "/proc/$AD_CHILD/stat" 2>/dev/null)" != Z ]
}
stop_capture() {
    local reason="$1" n=0 rc=0
    if [ -n "$AD_CHILD" ]; then
        child_owned && kill -TERM "$AD_CHILD" 2>/dev/null || true
        while child_alive && [ "$n" -lt 10 ]; do sleep 1; n=$((n+1)); done
        if child_alive; then
            kill -KILL "$AD_CHILD" 2>/dev/null || true
            reason="${reason}_forced"
        fi
        wait "$AD_CHILD" 2>/dev/null || rc=$?
        [ "$rc" -eq 0 ] || reason="${reason}_exit_${rc}"
        AD_CHILD=; AD_CHILD_START=
    fi
    write_metadata "$reason" || logger -t alsamrec-dante 'Could not finalize metadata'
}
release_disk() {
    local mounted
    mounted=$(ad_mount_source)
    if [ -n "$mounted" ]; then
        [ -n "$AD_DISK" ] && [ "$mounted" = "$AD_DISK" ] || return 1
        # Never lazy-unmount and never unmount any unrelated mountpoint.
        umount "$AD_MNT" || return 1
    fi
    rm -f "$AD_RUN/mounted-device"
    AD_DISK=; AD_SESSION=; AD_OUT=; AD_BYTES=0; AD_PREV=0
}
on_term() {
    [ "$AD_STOPPING" = 0 ] || return
    AD_STOPPING=1
    trap '' TERM INT HUP
    [ -z "$AD_SLEEP" ] || kill "$AD_SLEEP" 2>/dev/null || true
    stop_capture stopped
    if release_disk; then
        write_state STOPPED 'Stopped; private recording filesystem is unmounted'
    else
        write_state UNMOUNT_FAILED 'Capture stopped but disk remains mounted; do not unplug it'
    fi
    rmdir "$AD_RUN/recorder.lock" 2>/dev/null || true
    exit 0
}
snooze() {
    [ "$AD_STOP_REQUESTED" = 0 ] || on_term
    sleep "$AD_POLL" & AD_SLEEP=$!
    wait "$AD_SLEEP" 2>/dev/null || true
    AD_SLEEP=
    [ "$AD_STOP_REQUESTED" = 0 ] || on_term
}
fault() {
    stop_capture error
    write_state ERROR "$1"
    release_disk || write_state UNMOUNT_FAILED 'Recording failed and unmount failed; inspect disk before unplugging'
    # Latch the error. START on an already running monitor cannot clear it; STOP/START does.
    while :; do snooze; done
}

# procd is the only launcher. A stale lock after SIGKILL requires an operator check.
mkdir "$AD_RUN/recorder.lock" 2>/dev/null || { ad_error 'Recorder lock exists; inspect the old process before removing it'; exit 1; }
# Defer cleanup until PID bookkeeping is complete; do not interrupt child launch.
trap 'AD_STOP_REQUESTED=1' INT TERM
trap ':' HUP
# Recover only a mount explicitly marked as owned by this service.
if [ -r "$AD_RUN/mounted-device" ]; then
    AD_DISK=$(cat "$AD_RUN/mounted-device")
    ad_token "$AD_DISK" '^/dev/[A-Za-z0-9_.-]+$' && release_disk || fault 'Cannot recover prior owned mount'
fi
[ -z "$(ad_mount_source)" ] || fault 'Private mountpoint is occupied by an unowned mount'
write_state WAITING_DISK 'Waiting for exactly one unmounted exFAT volume'

while :; do
    [ "$AD_STOP_REQUESTED" = 0 ] || on_term
    ad_conflict >/dev/null 2>&1 || fault 'Conflicting ALSA/Inferno service is running'
    if [ -n "$AD_CHILD" ]; then
        if [ ! -b "$AD_DISK" ] || [ "$(ad_mount_source)" != "$AD_DISK" ]; then
            stop_capture disk_removed
            release_disk || fault 'Disk removed but filesystem could not be unmounted'
            write_state WAITING_DISK 'Disk removed; last recording may be incomplete'
            snooze; continue
        fi
        child_alive || fault 'Capture process exited; inspect logread and restart manually'
        free=$(ad_free_kib)
        case "$free" in ''|*[!0-9]*) fault 'Cannot determine free space';; esac
        [ "$free" -gt "$((AD_FREE * 1024))" ] || fault 'Free-space reserve reached; recording stopped'
        AD_BYTES=$(ad_size "$AD_OUT")
        if [ "$AD_BYTES" -gt "$AD_PREV" ]; then
            write_state RECORDING 'PCM file is growing; channel integrity and PTP lock are not measured'
        elif [ "$AD_BYTES" -eq 0 ]; then
            write_state WAITING_AUDIO 'Endpoint starting or no routed audio; configure subscriptions in Dante Controller'
        else
            write_state STALLED 'No file growth during the last poll; the recording timeline may have a gap'
        fi
        AD_PREV=$AD_BYTES
        snooze; continue
    fi
    if ! ad_network; then
        write_state WAITING_NETWORK 'Logical audio network has no IPv4 address'; snooze; continue
    fi
    if [ ! -S "$AD_CLOCK" ]; then
        write_state WAITING_CLOCK 'Clock socket absent; socket presence alone would not prove synchronization'
        snooze; continue
    fi
    disk=$(ad_single_disk) || {
        write_state WAITING_DISK 'Connect exactly one exFAT volume; none or multiple detected'
        snooze; continue
    }
    if ad_disk_mounted "$disk"; then
        write_state DISK_BUSY 'Selected exFAT volume is already mounted; no existing mount will be taken over'
        snooze; continue
    fi
    AD_DISK=$disk
    uid=$(id -u inferno); gid=$(id -g inferno)
    # Record ownership before mounting so a terminated mount can be reconciled.
    printf '%s\n' "$AD_DISK" > "$AD_RUN/mounted-device"
    if ! mount -t exfat -o "uid=$uid,gid=$gid,fmask=0177,dmask=0077,nodev,nosuid,noexec" "$AD_DISK" "$AD_MNT"; then
        rm -f "$AD_RUN/mounted-device"; AD_DISK=
        write_state MOUNT_FAILED 'Cannot mount exFAT volume; check filesystem and kernel support'
        snooze; continue
    fi
    free=$(ad_free_kib)
    case "$free" in ''|*[!0-9]*) fault 'Cannot determine free space after mount';; esac
    if [ "$free" -le "$((AD_FREE * 1024))" ]; then
        release_disk || fault 'Cannot release low-space disk'
        write_state LOW_SPACE 'Disk has insufficient free space; waiting without creating a recording'
        snooze; continue
    fi
    [ ! -L "$AD_MNT/ALSAmrec-Dante" ] || fault 'Refusing symlink session directory'
    mkdir -p "$AD_MNT/ALSAmrec-Dante" || fault 'Cannot create session directory'
    AD_SESSION=$(mktemp -d "$AD_MNT/ALSAmrec-Dante/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || fault 'Cannot allocate unique session directory'
    AD_OUT="$AD_SESSION/capture.s32le"
    AD_STARTED=$(date +%s); AD_BYTES=0; AD_PREV=0
    write_metadata in_progress || fault 'Cannot create metadata'
    export INFERNO_BIND_IP="$AD_DEVICE" INFERNO_NAME="$AD_NAME"
    export INFERNO_SAMPLE_RATE="$AD_RATE" INFERNO_RX_LATENCY_NS="$AD_LATENCY" INFERNO_TX_LATENCY_NS="$AD_LATENCY"
    export INFERNO_RX_BUFFER_SAMPLES="$AD_RING" INFERNO_CLOCK_PATH="$AD_CLOCK"
    export INFERNO_STATE_DIR="$AD_RUN/state" HOME="$AD_RUN/state" RUST_LOG="$AD_LOG" RUST_BACKTRACE=0
    # Without -b, start-stop-daemon execs the receiver in this child process.
    start-stop-daemon -S -c inferno:inferno -x "$AD_CAPTURE" -- \
        --channels-count "$AD_CHANNELS" --output "$AD_OUT" \
        --block-frames "$AD_BLOCK" --queue-blocks "$AD_QUEUE" \
        --output-timeout-ms 5000 --startup-timeout-s 60 &
    AD_CHILD=$!
    AD_CHILD_START=$(awk '{print $22}' "/proc/$AD_CHILD/stat" 2>/dev/null)
    write_state WAITING_AUDIO 'Capture launched; waiting for clock startup and subscribed audio'
    snooze
done
PAYLOAD_88057301E7C133AF

write_file '/usr/sbin/alsamrec-dantectl' 0755 <<'PAYLOAD_A15173F74A6F4A88'
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /usr/lib/alsamrec-dante/common.sh
. /usr/share/libubox/jshn.sh

status_json() {
    local data running clock enabled state updated now mounted
    data=$(ubus call service list '{"name":"alsamrec-dante"}' 2>/dev/null)
    running=$(printf '%s' "$data" | jsonfilter -e '@["alsamrec-dante"].instances.recorder.running' 2>/dev/null)
    clock=$(printf '%s' "$data" | jsonfilter -e '@["alsamrec-dante"].instances.clock.running' 2>/dev/null)
    enabled=$(uci -q get alsamrec_dante.main.enabled)
    [ "$running" = true ] && running=1 || running=0
    [ "$clock" = true ] && clock=1 || clock=0
    [ "$enabled" = 1 ] && enabled=1 || enabled=0
    json_init
    if [ -r "$AD_RUN/status.json" ]; then
        json_load "$(cat "$AD_RUN/status.json")" 2>/dev/null || json_init
    fi
    json_get_var state state
    json_get_var updated updated
    now=$(date +%s)
    case "$updated" in ''|*[!0-9]*) updated=0;; esac
    if [ "$running" = 0 ]; then
        case "$state" in ERROR|UNMOUNT_FAILED) ;;
        *)
            if [ "$enabled" = 1 ]; then
                json_add_string state NOT_RUNNING
                json_add_string message 'Enabled but monitor is not running; inspect configuration, network and system log'
            else
                json_add_string state STOPPED
                json_add_string message 'Disabled; no recording monitor is running'
            fi ;;
        esac
    elif [ "$state" != ERROR ] && [ "$state" != UNMOUNT_FAILED ] && { [ "$((now - updated))" -gt 20 ] || [ "$((now - updated))" -lt 0 ]; }; then
        json_add_string state STATUS_STALE
        json_add_string message 'Monitor exists but its status is stale; do not assume recording is healthy'
    fi
    json_add_boolean running "$running"
    json_add_boolean enabled "$enabled"
    json_add_boolean clock_process_running "$clock"
    [ -S "$AD_CLOCK" ] && json_add_boolean clock_socket_present 1 || json_add_boolean clock_socket_present 0
    json_add_string ptp_lock not_measured
    mounted=$(ad_mount_source)
    json_add_string private_mount_source "$mounted"
    [ -n "$mounted" ] && json_add_boolean private_mount_present 1 || json_add_boolean private_mount_present 0
    json_add_string note 'File growth does not verify every channel, packet continuity or clock synchronization'
    json_dump
}
probe_json() {
    local check rc=0 network_ready=0 devices dev
    ad_load
    check=$(ad_validate 2>&1) || rc=1
    [ "$rc" = 0 ] && check=$(ad_prerequisites 2>&1) || rc=1
    if [ "$rc" = 0 ]; then check=$(ad_conflict 2>&1) || rc=1; fi
    ad_network && network_ready=1
    devices=$(ad_exfat_devices)
    json_init
    [ "$rc" = 0 ] && json_add_boolean success 1 || json_add_boolean success 0
    json_add_string message "${check:-Local prerequisites present; this is not an audio or PTP-lock test}"
    json_add_boolean network_ready "$network_ready"
    json_add_string network "$AD_NETWORK"
    json_add_string device "${AD_DEVICE:-}"
    json_add_string ipv4 "${AD_IP:-}"
    json_add_string channels "$AD_CHANNELS"
    json_add_string sample_rate "$AD_RATE"
    json_add_string pcm_format S32_LE
    json_add_array exfat_devices
    for dev in $devices; do json_add_string '' "$dev"; done
    json_close_array
    json_add_string private_mount_source "$(ad_mount_source)"
    json_add_string ptp_lock not_measured
    json_add_string routing 'Use Dante Controller or a separately deployed compatible controller; this page is not a routing matrix'
    json_dump
}
need_root() { [ "$(id -u)" = 0 ] || { ad_error 'Root privileges required'; return 1; }; }
cmd=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
case "$cmd" in
    STATUS) status_json ;;
    PROBE) probe_json ;;
    START)
        need_root || exit 1
        ad_load
        ad_validate && ad_prerequisites && ad_conflict && ad_network || exit 1
        if ad_service_running alsamrec-dante; then
            echo 'Service already active. For a latched error, STOP and then START.'; exit 0
        fi
        uci set alsamrec_dante.main.enabled=1 && uci commit alsamrec_dante || exit 1
        /etc/init.d/alsamrec-dante enable || exit 1
        if ! /etc/init.d/alsamrec-dante start; then
            uci set alsamrec_dante.main.enabled=0; uci commit alsamrec_dante
            ad_error 'Service start failed; inspect logread'; exit 1
        fi
        echo 'Start requested; enabled for boot. Recording still requires storage, clock and routed audio.'
        ;;
    STOP)
        need_root || exit 1
        uci set alsamrec_dante.main.enabled=0 && uci commit alsamrec_dante || exit 1
        /etc/init.d/alsamrec-dante disable || exit 1
        /etc/init.d/alsamrec-dante stop || exit 1
        if [ -n "$(ad_mount_source)" ]; then
            ad_error 'Service stopped but private filesystem remains mounted; do not unplug it'; exit 1
        fi
        echo 'Stopped and disabled for boot. Check any other mounts before removing storage.'
        ;;
    *) ad_error 'Usage: alsamrec-dantectl START|STOP|STATUS|PROBE'; exit 1 ;;
esac
PAYLOAD_A15173F74A6F4A88

write_file '/usr/share/luci/menu.d/luci-app-alsamrec-dante.json' 0644 <<'PAYLOAD_A6256870CD936B07'
{
  "admin/services/alsamrec-dante": {
    "title": "ALSAmrec Dante",
    "order": 65,
    "action": {
      "type": "view",
      "path": "alsamrec-dante/main"
    },
    "depends": {
      "acl": [
        "luci-app-alsamrec-dante"
      ],
      "uci": {
        "alsamrec_dante": true
      }
    }
  }
}
PAYLOAD_A6256870CD936B07

write_file '/usr/share/rpcd/acl.d/luci-app-alsamrec-dante.json' 0644 <<'PAYLOAD_EE4354CABE2122FB'
{
  "luci-app-alsamrec-dante": {
    "description": "Control the separate ALSAmrec native-Dante recorder",
    "read": {
      "ubus": {
        "alsamrec-dante": [
          "status",
          "probe"
        ]
      },
      "uci": [
        "alsamrec_dante"
      ]
    },
    "write": {
      "ubus": {
        "alsamrec-dante": [
          "start",
          "stop"
        ]
      },
      "uci": [
        "alsamrec_dante"
      ]
    }
  }
}
PAYLOAD_EE4354CABE2122FB

write_file '/www/luci-static/resources/view/alsamrec-dante/main.js' 0644 <<'PAYLOAD_C246FD69B4F6FD2A'
'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require form';
'require tools.widgets as widgets';

// SPDX-License-Identifier: GPL-3.0-only
// ALSAmrec v3.1 workflow: J. Bruce Fields / FORART. Separate Dante view.
var callStatus = rpc.declare({ object: 'alsamrec-dante', method: 'status' });
var callStart = rpc.declare({ object: 'alsamrec-dante', method: 'start' });
var callStop = rpc.declare({ object: 'alsamrec-dante', method: 'stop' });
var callProbe = rpc.declare({ object: 'alsamrec-dante', method: 'probe' });

return view.extend({
    render: function() {
        var readonly = !L.hasViewPermission();
        var status = E('span', {}, _('Loading'));
        var message = E('p');
        var details = E('pre', { 'style': 'white-space:pre-wrap;overflow-wrap:anywhere' });
        var probe = E('pre', { 'style': 'white-space:pre-wrap;display:none' });
        var buttons = [];
        function refresh() {
            return callStatus().then(function(s) {
                status.textContent = s.state || _('Unknown');
                message.textContent = s.message || '';
                var bytes = Number(s.bytes || 0);
                var fields = [
                    _('Monitor running: ') + (s.running ? _('yes') : _('no')),
                    _('Enabled for boot: ') + (s.enabled ? _('yes') : _('no')),
                    _('Clock process: ') + (s.clock_process_running ? _('running') : _('not running')),
                    _('Clock socket: ') + (s.clock_socket_present ? _('present') : _('absent')),
                    _('PTP lock: not measured'),
                    _('Private disk mount: ') + (s.private_mount_source || _('not mounted')),
                    _('File: ') + (s.file || '-'),
                    _('Written: ') + (Number.isFinite(bytes) ? (bytes / 1048576).toFixed(2) + ' MiB' : '-'),
                    _('PCM: ') + (s.channels || '-') + ' ch / ' + (s.sample_rate || '-') + ' Hz / S32_LE'
                ];
                details.textContent = fields.join('\n');
            }).catch(function(err) {
                status.textContent = _('RPC error');
                message.textContent = String(err);
            });
        }
        function action(fn, isProbe) {
            buttons.forEach(function(b) { b.disabled = true; });
            return fn().then(function(res) {
                if (isProbe) {
                    probe.style.display = '';
                    probe.textContent = JSON.stringify(res, null, 2);
                } else {
                    ui.addNotification(null, E('p', {}, res.message || _('Request completed')),
                        res.success === false ? 'warning' : 'info');
                }
                return refresh();
            }).catch(function(err) {
                ui.addNotification(null, E('p', {}, String(err)), 'danger');
            }).then(function() {
                buttons.forEach(function(b, i) { b.disabled = readonly && i < 2; });
            });
        }
        [
            [_('START / enable at boot'), callStart, false, 'cbi-button-action'],
            [_('STOP / disable at boot'), callStop, false, 'cbi-button-negative'],
            [_('PROBE prerequisites'), callProbe, true, 'cbi-button-neutral']
        ].forEach(function(item, index) {
            buttons.push(E('button', {
                'class': 'btn cbi-button ' + item[3],
                'style': 'margin-right:.5em;margin-bottom:.5em',
                'disabled': readonly && index < 2,
                'click': function(ev) { ev.preventDefault(); return action(item[1], item[2]); }
            }, item[0]));
        });

        var m = new form.Map('alsamrec_dante', _('ALSAmrec Dante settings'),
            _('Experimental native-Dante capture. Save and apply settings before START. Applying changes while running restarts capture and creates a new recording segment.'));
        var s = m.section(form.NamedSection, 'main', 'recorder');
        s.addremove = false;
        s.tab('input', _('Audio network'));
        s.tab('storage', _('Recording'));
        s.tab('buffers', _('Buffers and diagnostics'));
        var o = s.taboption('input', widgets.NetworkSelect, 'network', _('Logical audio network'),
            _('Use an existing, isolated wired IPv4 audio network. Firewall and network settings are not changed.'));
        o.multiple = false; o.nocreate = true; o.rmempty = false;
        o = s.taboption('input', form.Value, 'name', _('Endpoint name'));
        o.rmempty = false;
        o.validate = function(section, value) {
            return /^[A-Za-z0-9_. -]{1,31}$/.test(value) || _('Use 1-31 ASCII letters, digits, spaces, dots, underscores or hyphens.');
        };
        o = s.taboption('input', form.Value, 'channels', _('Receive channels'));
        o.datatype = 'range(1,32)'; o.rmempty = false;
        o = s.taboption('input', form.ListValue, 'sample_rate', _('Sample rate'),
            _('Must match the transmitters. No resampling is performed.'));
        ['44100', '48000', '88200', '96000', '176400', '192000'].forEach(function(v) { o.value(v, v + ' Hz'); });
        o.rmempty = false;
        o = s.taboption('storage', form.Value, 'min_free_mib', _('Free-space reserve (MiB)'),
            _('Recording stops when the reserve is reached. At least two polling intervals of PCM must also fit in the reserve.'));
        o.datatype = 'range(100,1048576)'; o.rmempty = false;
        o = s.taboption('storage', form.Value, 'poll_seconds', _('Storage polling interval (seconds)'));
        o.datatype = 'range(1,5)'; o.rmempty = false;
        o = s.taboption('buffers', form.ListValue, 'rx_buffer_samples', _('Receive ring (samples/channel)'));
        ['65536', '131072', '262144', '524288'].forEach(function(v) { o.value(v); });
        o.rmempty = false;
        o = s.taboption('buffers', form.Value, 'block_frames', _('Writer block size (frames)'));
        o.datatype = 'range(256,65536)'; o.rmempty = false;
        o = s.taboption('buffers', form.Value, 'queue_blocks', _('Preallocated writer blocks'),
            _('The server rejects pools larger than 32 MiB. Undersized pools may fail on a single callback burst.'));
        o.datatype = 'range(2,64)'; o.rmempty = false;
        o = s.taboption('buffers', form.Value, 'latency_ns', _('Advertised latency (nanoseconds)'),
            _('Not an end-to-end latency guarantee; the inherited collector polls at 50 ms.'));
        o.datatype = 'range(1000000,40000000)'; o.rmempty = false;
        o = s.taboption('buffers', form.ListValue, 'log_level', _('Log level'));
        ['error', 'warn', 'info', 'debug', 'trace'].forEach(function(v) { o.value(v); });
        o.rmempty = false;

        return m.render().then(function(settings) {
            refresh();
            poll.add(refresh, 5);
            return E('div', {}, [
                E('h2', {}, _('ALSAmrec Dante')),
                E('p', {}, _('Separate from the working ALSA recorder. One unmounted exFAT volume is required. START persists boot enablement; STOP disables it and attempts a normal unmount.')),
                E('div', { 'class': 'cbi-section' }, [
                    E('h3', {}, _('Status')), status, message, details,
                    E('div', {}, buttons), probe,
                    E('p', {}, _('A running process, a clock socket or a growing file does not prove synchronized, complete audio on every channel.'))
                ]),
                settings,
                E('div', { 'class': 'cbi-section' }, [
                    E('h3', {}, _('Routing and output')),
                    E('p', {}, _('Route transmitter channels to this endpoint with Dante Controller or a separately deployed compatible controller. This page does not discover transmitters or implement a routing matrix.')),
                    E('p', {}, _('Each session contains capture.s32le, session.json and events.jsonl under ALSAmrec-Dante on the disk. Subscriptions are RAM-backed and must be restored after reboot. Stop and confirm the disk is unmounted before unplugging it.')),
                    E('h3', {}, _('AES67 is a separate backend')),
                    E('p', {}, _('aes67-linux-daemon receives AES67 RTP streams through its RAVENNA kernel driver and exposes an ALSA capture device. It is not a native-Dante substitute and is not installed or managed by this page. See the included AES67 assessment.'))
                ])
            ]);
        });
    }
});
PAYLOAD_C246FD69B4F6FD2A

if [ "$MODE" = extract ]; then
    echo "Extracted source payload under $DEST; no dependencies installed or services changed."
    exit 0
fi
# A fresh install stays disabled. Reinstall preserves its saved configuration.
if [ "$(uci -q get alsamrec_dante.main.enabled)" != 1 ]; then
    /etc/init.d/alsamrec-dante disable
fi
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
/etc/init.d/rpcd restart
printf '%s\n' \
    'Installed: LuCI -> Services -> ALSAmrec Dante' \
    'CLI: alsamrec-dantectl START|STOP|STATUS|PROBE' \
    'Configure the existing audio network, channels and sample rate before START.' \
    'START enables boot startup; STOP disables it. No recording was started by this installer.' \
    'Original ALSA recorder, CGI, firewall, NTP and /etc/asound.conf were not modified.'
