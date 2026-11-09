# Inferno for OpenWrt: experimental source port

This kit adds OpenWrt packages and targeted resource-use changes to teodly/inferno.
It is an authored source overlay, not a prebuilt firmware image or a complete
vendored upstream checkout. Source preparation requires a network-connected host.

Status: 12 Python/shell/mock-build checks passed in the authoring environment.
Rust was not installed, so Rust tests, actual compilation, OpenWrt SDK builds,
package installation and Dante interoperability were not run. No CPU, latency,
binary-size or total-RSS improvement has been measured. See docs/VALIDATION.md.

The recipes deliberately allow only aarch64 and x86_64. Their Rust helper interface
was reviewed against OpenWrt packages branches openwrt-24.10 and openwrt-25.12;
that is not evidence of a successful build on either release. Other architectures,
including MIPS and 32-bit ARM, are outside this kit's declared scope.

## Packages

| Package | Purpose |
|---|---|
| inferno2pipe | Receive-only endpoint; writes interleaved signed 32-bit little-endian PCM to a FIFO, new file, or /dev/null. No ALSA dependency. |
| inferno-statime | Required modified Statime clock service; default PTPv1 follower, software timestamps and exported monotonic-raw virtual clock. |
| alsa-lib-pcm-inferno | Optional upstream ALSA virtual PCM plugin for transmit and receive. Requires alsa-lib and the OpenWrt audio support selected by that dependency. |

This is not an implementation of AES67, Dante Domain Manager, a router-wide audio
bridge, or automatic USB sound-card routing. The capture application is RX-only;
TX/RX use requires the optional ALSA plugin and an ALSA application. The optional
plugin's audio buffering remains controlled by that application. [S1, S8]

## Changes and tradeoffs

The two owned RX buffer constructors use a validated INFERNO_RX_BUFFER_SAMPLES
setting, default 65,536 instead of 524,288. For i32 sample storage, this changes
one owned channel ring's sample payload from 2 MiB to 256 KiB, an 87.5% reduction
in that allocation, not in process RSS. Metadata, collector storage, thread stacks
and the output pool are additional. ALSA's external buffers are unchanged. [S2]

The replacement capture frontend separates file/FIFO I/O from the protocol
runtime using a dedicated worker and a fixed pool of buffers. The callback does
not resize or allocate audio buffers and never waits for queue capacity. This is
not a lock-free queue or a hard real-time guarantee. Serialization is explicitly
S32_LE rather than upstream's CPU-native endianness. [S3]

An exhausted pool, failed output, absent FIFO reader or timed-out nonblocking
FIFO write stops capture with a visible error. Audio is not silently dropped to
continue at a false timestamp. Some data can already have been written before
failure, including a partial final frame on I/O failure; this is not a transactional
recording format. Regular-file kernel writes can still block: the worker isolates
them from protocol processing but cannot impose a kernel I/O deadline.

Default pool allocation is channels * block_frames * queue_blocks * 4 bytes:
2 * 4096 * 16 * 4 = 524,288 bytes at the default two channels. This represents an
upper bound of about 1.365 seconds of audio at 48 kHz when all blocks are full;
partially occupied blocks reduce the effective backlog. It is not a required
playout delay. The pool is capped at 32 MiB. Too-small block/queue settings can
exhaust the pool within a single callback burst. The original collector's 50 ms
polling cadence is unchanged, so the 10 ms advertised receive latency is not an
end-to-end capture-latency promise. [S4]

Release builds use opt-level=2, thin LTO, one codegen unit and stripped symbols.
The executable packages use panic=abort; the optional ALSA plugin retains unwind.
Overflow checks remain enabled. The recipes retain OpenWrt's cross-linker and
musl configuration rather than substituting a guessed target triple. These are
optimization choices to benchmark, not established speedups. [S5, S9]

## Build prerequisites

Use a Linux build host with the SDK matching the router's exact OpenWrt release,
target and ABI. Install its normal host prerequisites, Python 3.11 or newer, git,
and working Cargo/rustc compatible with the SDK Rust feed. Cargo and rustc must
both be on PATH; --cargo can select a specific Cargo executable. Network access
to GitHub, GitLab and the dependency registries is required for preparation.

Use the SDK's matching feed revisions. Do not replace a release feed with master.
The examples below assume an already extracted SDK and a writable SDK directory.

```sh
export SDK=/absolute/path/to/openwrt-sdk
cd "$SDK"
./scripts/feeds update -a
./scripts/feeds install -a

cd /absolute/path/to/inferno-openwrt
./tools/check.sh
python3 tools/prepare_sources.py --sdk "$SDK"

cd "$SDK"
make menuconfig
# Sound -> inferno2pipe: select as a module; inferno-statime is a dependency.
# Optional: Sound -> alsa-lib-pcm-inferno.
make defconfig
make package/inferno-statime/compile V=s -j2
make package/inferno/compile V=s -j2
```

The first preparation resolves Inferno's dev branch and Statime's inferno-dev
branch, checks out submodules, applies checked transformations, and vendors Cargo
dependencies. It records exact commits, submodule revisions, lockfile hashes and
archive hashes in sources.lock.json. It generates packages/*/source.mk and
copies self-contained source archives to the SDK's dl directory. Target Cargo
builds use --frozen and the vendored source configuration. [S6]

The delivered kit contains no invented commit pins. For an approved upstream
baseline, pass full commit IDs using --inferno-ref and --statime-ref on the first
preparation. Later runs reuse recorded revisions; --refresh explicitly selects
new branch tips. API drift causes preparation to stop for review rather than
silently accepting different upstream code.

Keep sources.lock.json, generated source.mk files, dist/ archives and the port
patch together. Preserve the SDK/feed/toolchain versions as well; a source lock
alone does not guarantee bit-identical binaries across toolchains. Preparation
refuses to overwrite existing SDK package/inferno or package/inferno-statime
folders: back them up and remove them explicitly before reinstalling the overlay.

Install the resulting packages from the SDK's bin/packages tree with the package
manager appropriate to the router's release, including dependencies. Do not copy
binaries from a different OpenWrt ABI. No .ipk or .apk binaries are included here.

## Enable on a lab network

Both services are disabled by default. First configure an existing OpenWrt logical
network named audio, with an IPv4 address on the isolated wired audio VLAN. This
kit neither creates that network nor changes the firewall. Connect a compatible
PTPv1 clock leader on that network; the supplied clock service is follower-only.
Do not run a second PTP service on the same interface/ports. [S1, S7]

```sh
uci set inferno-clock.main.network='audio'
uci set inferno-clock.main.enabled='1'
uci commit inferno-clock
uci set inferno.main.network='audio'
uci set inferno.main.channels='2'
uci set inferno.main.sample_rate='48000'
uci set inferno.main.enabled='1'
uci commit inferno
/etc/init.d/inferno-clock enable
/etc/init.d/inferno enable
/etc/init.d/inferno-clock start
/etc/init.d/inferno start
logread -e inferno
```

These settings initially discard audio at /dev/null. They do not create a
recording. Set routing/subscriptions from a compatible controller and match the
source sample rate; this port does not resample. Upstream capture pauses when
nothing is connected rather than generating an uninterrupted silence timeline.
RAM-backed state means subscriptions/settings must be restored after reboot
unless a persistent state directory is explicitly configured. [S1]

For a FIFO consumer, change only the output setting, start the service so that
it creates its private FIFO, then start a reader promptly:

```sh
uci set inferno.main.output='/var/run/inferno/audio.pcm'
uci commit inferno
/etc/init.d/inferno restart
# Example destination: a mounted external drive with sufficient free space.
cat /var/run/inferno/audio.pcm > /mnt/usb/capture-001.s32le
```

Start the reader before routing audio where possible. Until a reader is present,
received audio consumes the finite pool and can stop the service before the
5-second output timeout. procd may restart it within its bounded retry policy.
On failure, treat the output as an incomplete recording and begin a new capture;
there is no seamless resume or timestamp header. S32_LE at 48 kHz / 2 channels
requires 384,000 payload bytes/second, about 1.3824 GB/hour before filesystem
metadata. A regular-file output must be a new path writable by inferno; existing
regular files are refused to avoid truncation after a service restart.

The default state directory is /var/run/inferno/state. For persistence, create a
non-symlink directory on the chosen storage, assign it to inferno:inferno, and set
inferno.main.state_dir to its absolute path. Avoid router flash for continuous
audio recording; state persistence is a separate choice from audio output.

## Optional bidirectional ALSA endpoint

Select alsa-lib-pcm-inferno at build time. The example is installed at
/usr/share/inferno/asound.conf.example, not over an existing /etc/asound.conf.
Merge its pcm.inferno stanza into an appropriate ALSA configuration and edit
BIND_IP, channel counts and rate. Start inferno-clock before the ALSA application.
The application must be allowed to access /var/run/inferno-clock/clock.sock.

The example uses PROCESS_ID=1 and ALT_PORT=4460 to separate its control ports
from a simultaneous capture endpoint. An endpoint exists only while the ALSA
application opens it. Actual USB/SoC sound-card routing, duplex testing, clock
recovery and application buffering are deployment work, not supplied here. [S8]

## Network and security boundaries

Inferno runs as the dedicated inferno user; the clock service runs as root.
This is privilege separation, not a complete sandbox or a security audit of the
upstream packet parsers. Runtime directories and the clock socket are private to
the relevant user/group; the socket directory is setgid for group inheritance.

Do not expose these services on WAN. Use an isolated, trusted audio VLAN and
explicit ingress allowances for approved controllers, transmitters and clocks.
Upstream documents UDP 4455, 8700, 4400, 8800 and 5353, plus OS-allocated dynamic
receive ports. A firewall rule allowing only the fixed ports is insufficient.
Do not assume ordinary NAT or multicast routing will preserve operation. [S1]

The services do not alter firewall rules, sysctls, interrupt affinity or NTP
configuration. Realtime priority is off by default; realtime=1 grants the capture
process the limit needed for upstream's priority-80 RX thread and sets an RT CPU
time limit. Test its effect on routing and management responsiveness before use.
The virtual-clock configuration avoids deliberately steering the router's system
clock, but does not establish immunity to NTP interactions or clock discontinuities.
Clock-leader loss, freshness and recovery remain acceptance tests. [S7]

## Validation, provenance and licensing

Run ./tools/check.sh on a host with rustc to include the standalone Rust tests.
The script explicitly skips those tests when rustc is unavailable. It does not
replace a real SDK build or device tests. See docs/VALIDATION.md for the performed
checks and required acceptance scenarios, and docs/SOURCES.md for primary sources.

The overlay uses GPL-3.0-or-later, selecting that option from Inferno's upstream
dual license. Statime and vendored dependencies retain their own licenses.
See LICENSE, NOTICE and the retained source notices. This is unofficial and not
endorsed or certified by Audinate. Upstream calls Inferno highly experimental
and includes a distribution/patent disclaimer; this port does not remove those
limitations. [S1]
