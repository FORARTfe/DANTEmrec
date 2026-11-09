ALSAmrec Dante fork 0.1.0

Experimental source integration for OpenWrt; not a verified hardware deployment.
This is a separate native-Dante fork, based on the workflow in the supplied
ALSAmrec installer v3.1. The original installer is retained unchanged under
reference/ and is not installed or modified by this kit.

Contents

The standalone installer installs the same files as packages/luci-app-alsamrec-dante:
UCI configuration, a procd service, a storage-monitor/recorder, a CLI, an rpcd
backend with scoped ACLs, a JavaScript LuCI page, and a block-hotplug wake hook.
The existing Inferno source kit is included unchanged in inferno-openwrt/.
No prebuilt Inferno binaries, OpenWrt packages, firmware or AES67 kernel modules
are included. Upstream sources and dependencies still require preparation.

LuCI location: Services -> ALSAmrec Dante.
CLI: alsamrec-dantectl START|STOP|STATUS|PROBE.
Configuration: /etc/config/alsamrec_dante, named section main.

What changes from the supplied ALSA installer

The first ALSA capture device is replaced with an explicit native-Dante endpoint.
Channel count and sample rate are configured rather than inferred from ALSA
hardware limits. The exFAT/raw-recording workflow is retained: exactly one exFAT
volume is required, with a default 100 MiB free-space reserve. Block metadata,
not filesystem formatting, is used to identify candidate volumes. No disk is
formatted. An already-mounted volume is refused, not taken over.

The mount is private to this service at /var/run/alsamrec-dante/disk. A new unique
session directory is created under ALSAmrec-Dante on the volume. Each contains
capture.s32le, session.json and events.jsonl. The PCM file is created lazily when
audio is written. Samples are interleaved signed 32-bit little-endian integers.
Metadata records rate, channels, wall-clock timestamps, ending reason, byte count
and any partial final frame. Events indicate observed growth, waiting and stalls;
they do not measure sample-accurate discontinuities or validate every channel.

The supervisor and clock process run as root; the Inferno audio process is
launched as inferno:inferno using start-stop-daemon. No new unauthenticated CGI is
installed. The existing /cgi-bin/cm and the original recorder remain untouched;
this does not secure or disable an existing CGI deployment. No generic shell
execution is exposed by the new RPC object. No firewall, NTP, sysctl, network,
ALSA configuration or original service is automatically changed.

Building with the matching OpenWrt SDK

Use a Linux build host with Python 3.11+, Cargo/rustc, Git, and the SDK/feed
revisions for the intended firmware. The inherited Inferno package recipes
currently permit aarch64 and x86_64 only. These are declared targets, not tested
builds. See inferno-openwrt/README.md for full build/provenance requirements.

```sh
export SDK=/absolute/path/to/openwrt-sdk
cd "$SDK"
./scripts/feeds update -a
./scripts/feeds install -a

cd /absolute/path/to/alsamrec-dante
./tools/check.sh
python3 inferno-openwrt/tools/prepare_sources.py --sdk "$SDK"
# Do not overwrite an existing SDK package directory without reviewing it.
test ! -e "$SDK/package/luci-app-alsamrec-dante" && \
    cp -a packages/luci-app-alsamrec-dante "$SDK/package/"

cd "$SDK"
make menuconfig
# Select LuCI -> Applications -> luci-app-alsamrec-dante.
# Its dependencies include inferno2pipe and inferno-statime.
make defconfig
make package/inferno-statime/compile V=s -j2
make package/inferno/compile V=s -j2
make package/luci-app-alsamrec-dante/compile V=s -j2
```

Source preparation records the actual resolved upstream revisions and vendored
archive hashes. Keep its sources.lock.json, generated archives, SDK/feed revisions
and full logs. No fabricated or verified upstream commit pin is supplied here.
Install the resulting packages and their dependencies using the target release's
package manager. Do not mix firmware ABIs or force incompatible kernel packages.

Standalone installer alternative

Use either the LuCI package above or this installer, not both. The installer is
self-contained for the integration files only. It requires the compiled
inferno2pipe and inferno-statime packages already installed on the router and
checks for the modified frontend's --queue-blocks option. It does not download an
arbitrary executable or assume an upstream binary will work on OpenWrt.

```sh
# On a host: inspect the exact installation payload without touching services.
sh installer-dante.sh --extract /tmp/alsamrec-dante-inspect

# On the target, after the two compiled Inferno packages have been installed:
sh installer-dante.sh
# Or, with all system dependencies already provisioned:
sh installer-dante.sh --no-deps
```

Normal installation uses apk when present, otherwise opkg, to install rpcd,
luci-base, jshn, jsonfilter, block-mount, kmod-fs-exfat and kmod-usb-storage.
Custom firmware must provide start-stop-daemon with -c support, stat -c, mktemp,
mount, df, awk and standard shell utilities. Board-specific storage-host drivers
must also be present. The installer checks commands but cannot validate hardware.
Existing integration files are backed up; existing Dante UCI configuration is
preserved. It restarts rpcd, so existing LuCI sessions may need to reconnect.
It does not reboot or start recording. A fresh configuration is disabled.

Initial configuration and operation

Create an isolated wired audio network through your normal OpenWrt network
configuration first. The default logical name is audio; select the actual logical
network in LuCI. A compatible PTPv1 clock leader must be present. The supplied
clock configuration is follower-only, software-timestamped, and exports a
monotonic_raw virtual clock rather than intentionally steering the system clock.
The interface must have IPv4. [S2, S4]

Stop the original ALSA recorder before testing the alternative. Stop the generic
inferno and inferno-clock services too if they were enabled for previous tests.
The new service owns its own clock instance and refuses to run while those
conflicting procd services are active. Manually launched competing processes are
not comprehensively detected. Do not run another PTP daemon on the same ports.
No original service is stopped by installation.

```sh
# On the router, only when intentionally switching away from the ALSA workflow:
/etc/init.d/autorecorder stop
/etc/init.d/autorecorder disable
# Stop/disable inferno and inferno-clock too if previously enabled.

uci set alsamrec_dante.main.network='audio'
uci set alsamrec_dante.main.channels='2'
uci set alsamrec_dante.main.sample_rate='48000'
uci commit alsamrec_dante
alsamrec-dantectl PROBE
alsamrec-dantectl START
alsamrec-dantectl STATUS
```

START persists enablement and enables boot startup. STOP persists disablement,
stops the capture/clock service and attempts a normal unmount. START on an
already-running monitor does not clear a latched error: use STOP then START.
Direct init start obeys the saved enabled flag. Save & Apply or interface changes
restart the service when enabled, ending the current recording and creating a
new segment. Do not change settings during an uninterrupted take.

Insert exactly one exFAT volume that is not mounted by fstab/blockd or any other
recorder. If existing OpenWrt automount rules claim it, adjust those rules yourself
before using this fork; the installer does not rewrite them. The endpoint is
launched only once disk, free space, network and clock socket prerequisites are
present. Route its channels from a transmitter using Dante Controller or another
compatible controller. The LuCI page controls the recorder but does not implement
transmitter discovery, channel subscriptions or a routing matrix. [S2]

Clock-socket presence is not lock verification. LuCI deliberately says PTP lock
is not measured. RECORDING means the PCM file grew since the previous poll;
WAITING_AUDIO and STALLED distinguish no growth from an active transfer. A
stale status is not shown as healthy. Buffer/write failures and low space latch
an error instead of silently restarting a stream into the same file. Removal
and I/O failures can leave incomplete PCM and metadata. STOP and verify no
remaining mount before unplugging storage.

The underlying monitor mountpoint is root-only when not mounted, so the
unprivileged receiver cannot continue writing into router RAM after unmount.
Audio and metadata go to external storage; service status and subscription state
are RAM-backed. Subscriptions must be restored after a reboot. A receiver may
pause its media timeline when no channels are connected, rather than inserting
silence. This fork neither fixes that behavior nor guarantees a continuous
wall-clock recording timeline. [S2]

At 48 kHz, two S32_LE channels require 384,000 PCM bytes/s, or 1.3824 GB/hour;
32 channels require 6,144,000 bytes/s, or 22.1184 GB/hour. These are payload
calculations, not a storage-speed benchmark. The sample rate must match sources;
no resampling is provided. The inherited buffer defaults and 50 ms collector
cadence are documented in inferno-openwrt/README.md.

Security and rollback

Use authenticated LuCI on a trusted management network and isolate audio peers.
This kit does not open any network ports. Inferno requires its documented control
ports and dynamically allocated receive ports; a fixed-port-only rule is not
sufficient. Treat upstream packet parsing and the clock daemon as unaudited here.
Do not expose the audio endpoint or management UI to the WAN. [S2]

To switch back, run alsamrec-dantectl STOP, verify the private disk is unmounted,
and then enable/start your original autorecorder service. The original files
have not been overwritten. Uninstall a package with the package manager; for a
standalone install use tools/uninstall-standalone.sh. Recordings and the original
ALSA installation are never removed by that script.

Read docs/VALIDATION.md before accepting the fork, docs/AES67-ASSESSMENT.md for
the separate AES67 option, and docs/SOURCES.md for primary-source references.
