Validation record - ALSAmrec Dante fork 0.1.0

Scope and result

On 2026-11-09, ./tools/check.sh completed 34 fork tests and 12 inherited
Inferno-port tests successfully: 46 host-side checks in total. The complete
output is retained in host-checks.txt. Rust unit tests were explicitly skipped
because rustc is not installed. No compiled OpenWrt binary/package is included.

These results establish limited source and mocked-lifecycle properties, not
successful deployment, audio interoperability, synchronization or reliability.
The supplied ALSA installer is retained byte-for-byte under reference/; its
reported working status is the user's statement, not a test repeated here.

What was actually exercised

The fork tests cover BusyBox shell syntax, JSON/ACL allowlists, deterministic
installer payload extraction and file modes, configuration preservation, refusal
to install on a non-OpenWrt host, and preservation of the original installer.
They exercise input validation, numeric limits, buffer-pool bounds, free-space
reserve arithmetic, newline/command/TOML injection rejection, exFAT metadata
parsing and service-conflict handling.

A Node-based frontend test checks the LuCI view's RPC declarations, form and
polling contract, read-only controls and safe text insertion using mocked LuCI
objects. It is not a real LuCI/browser rendering or session-authentication test.

Lifecycle tests launch host processes with mocked mount/block/clock/privilege
interfaces and synthetic PCM output. They cover waiting for disk/audio, stop and
metadata finalization, low-space handling, a failed capture, stalled output,
unmount failure, service conflict and unique recording names. The fixture uses
regular files instead of real block devices, a local Unix socket instead of a
PTP clock and a test double instead of OpenWrt's jshn/ubus/UCI runtime. No physical
filesystem is mounted and no real privilege-drop assertion is established.

Status tests distinguish the recorder instance from the clock instance, missing
processes, stale status and latched errors. They verify that no PTP-lock result
is invented. A growing PCM file does not establish valid samples, continuity,
clock lock or complete channel subscription.

The 12 inherited checks cover guarded source transformations, both receive-ring
constructors, dependency-pin preservation, stable archives, shell syntax/defaults
and invocation of mock Cargo through the package recipes. They do not compile
Rust code or resolve actual upstream dependencies. The inherited kit's separate
validation report describes its own limitations.

Additional packaging checks

The standalone uninstall script was checked with BusyBox sh -n. The included
original source kit and original installer were checked against their SHA-256
manifests. The delivery archive contents were verified against MANIFEST.sha256.
These are integrity checks, not an independent security audit or signature.

Not performed

No OpenWrt SDK/buildroot compilation, Rust compilation, real package installation,
OpenWrt boot/procd/rpcd execution, browser rendering, actual filesystem mounting,
physical disk-failure testing, native-Dante routing, PTP synchronization, AES67
interoperability, RAVENNA kernel-module build, throughput/RSS benchmarking or
long-duration recording was performed. No specific router or transmitter was
provided. The declared aarch64/x86_64 targets are not certified working targets.

Acceptance checklist on the intended router

1. Build and provenance. Record the exact firmware, architecture, kernel, SDK,
   feeds, toolchain and resolved Inferno/Statime revisions. Build all selected
   packages without forced dependencies. Keep source locks, hashes and full logs.
   Confirm the capture help includes --queue-blocks and the service account
   exists. Run the binary with the actual musl/toolchain ABI.

2. Installation and isolation. Verify the original ALSAmrec files have unchanged
   checksums. Confirm a fresh Dante install is disabled and makes no firewall,
   NTP, network, CGI or ALSA configuration changes. Confirm the original recorder
   and generic inferno/inferno-clock services cannot run concurrently through
   their managed services. Check the audio network's actual multicast behavior.

3. LuCI and authorization. Test the page in the actual LuCI/browser version,
   including Save & Apply, reconnect after rpcd restart, read-only accounts and
   denied direct mutation RPC calls. Confirm only the intended UCI package and
   four methods are exposed. An existing original CGI is outside this fork's
   security boundary and is not secured by this installation.

4. Permissions and storage. Verify the root supervisor/clock and inferno-owned
   capture processes, socket group/permissions and exFAT mount options. Confirm
   there is exactly one eligible volume, no competing automount and no fallback
   recording into router RAM. Test no disk, multiple disks, busy/mounted disk,
   read-only/corrupt disk, almost-full disk, slow writes, file limits and removal.
   Confirm STOP unmounts normally before unplugging and session metadata matches
   file size, format, channel count and partial-frame information.

5. Clock and audio. Use known, distinguishable signals on every subscribed
   channel. Compare captured samples/channel ordering with a trusted receiver.
   Validate actual clock lock with an external/appropriate diagnostic; this
   fork has no PTP-lock telemetry. Exercise clock-leader loss/re-election, link
   loss, source restart, re-subscription and unrouted channels. Determine how
   missing media affects the recording timeline. Do not infer lock from the
   clock socket, a running process or file growth.

6. Lifecycle and resources. Test hotplug, reboot, startup before interface
   readiness, applying settings during capture, STOP/START after errors, full
   disk and forced termination. Check that subscriptions are restored after
   reboot and segments are unique. Benchmark CPU, RAM, disk throughput, sample
   integrity and long recordings at the intended channel/rate settings; no
   measured performance improvement or end-to-end latency is claimed here.

7. AES67 alternative. Treat the separate assessment as a porting plan, not
   delivered AES67 support. Build the real matching RAVENNA kernel module and
   daemon, validate AES67 capability/flows on each transmitter, explicit sink
   maps and PTP lock, and keep the unauthenticated HTTP interface off untrusted
   networks. Do not enable a competing capture streamer on the same ALSA device.

Known operational limitations

An uninterruptible kernel I/O stall may prevent timely shutdown despite the
normal termination grace period. Abrupt disk removal or power loss can leave
partial PCM and incomplete metadata. The monitor's root-owned lock deliberately
prevents a second capture after an unclean kill: after stopping the service,
inspect the process table and private mount, resolve any remaining capture or
mount safely, and only then remove an empty stale recorder.lock directory.
Never remove that lock while capture is active.

Settings changes end the current segment. There is no routing matrix, resampling,
clock-lock measurement, persistent subscription export or sample-level gap log.
The receive-ring and output-buffer changes are engineering choices awaiting
measurement on the intended router, not production reliability guarantees.
