AES67 assessment for ALSAmrec and Inferno

Reviewed on 2026-11-09 using the public sources in SOURCES.md. This is a source
and architecture review, not a hardware interoperability test or an OpenWrt port
of aes67-linux-daemon. Branch contents can change; no release/version equivalence
or successful build is inferred from a README.

Conclusion

bondagit/aes67-linux-daemon is useful as a separate ALSAmrec input backend when
the transmitting equipment can emit compatible AES67 RTP streams. It is not a
replacement for Inferno when native Dante is required. Conversely, Inferno is
not a drop-in media driver for aes67-linux-daemon. The delivered LuCI page
manages only the native-Dante fork, not the AES67 daemon.

What the projects actually implement

Inferno implements the reverse-engineered native Dante protocol and supports
compatible controller operations. Its upstream documentation explicitly lists
AES67 audio as unsupported and describes the project as highly experimental.
Clock protocol support does not by itself add support for AES67 media transport.
The generated capture path is entirely userspace and outputs PCM without needing
an ALSA sound device. The supplied package's clock configuration uses PTPv1. [S2]

aes67-linux-daemon controls MergingRavennaALSA.ko through a netlink interface.
The kernel module handles RTP media, PTP synchronization and a virtual ALSA
capture/playback device. The userspace daemon supplies configuration, REST,
SDP/SAP and optional RAVENNA discovery; it is not itself an ALSA plugin that can
be pointed at any arbitrary PCM endpoint. Matching driver/daemon versions are
important: upstream documents protocol compatibility changes between versions.
Its HTTP streamer captures the RAVENNA device, so it must not compete with
ALSAmrec for the same capture endpoint. [S8]

Where it fits the existing ALSA project

The supplied ALSAmrec installer already records with arecord and therefore has
a natural integration point for a virtual RAVENNA capture device. However, its
first-card selection and maximum-parameter probing are not a deterministic
network-stream profile. They should be replaced, for an AES67-specific fork,
with an explicit PCM identifier, sample format, rate and channel map agreed with
the configured sink. This is a proposed adaptation; the attached working ALSA
installer has deliberately not been patched. [S1, S10]

A suitable initial laboratory profile is two channels, 48 kHz, L24 RTP with 48
samples per packet (1 ms). The repository's interoperability guide documents
48 kHz/L24 tests and Dante AVIO transmitters. Enable AES67 on the transmitter,
create an AES67 multicast flow, discover/import its SDP in the daemon and create
a matching sink. The guide uses plughw:RAVENNA for capture. [S9]

After separately verifying a locked clock, a configured sink and mounted
external storage, the corresponding raw capture command is:

```sh
arecord -D plughw:RAVENNA -c 2 -r 48000 -f S24_3LE -t raw \
  /path/on/already-mounted-external-storage/aes67-test.raw
```

The destination is an example, not a mount performed by this kit. Unlike the
native-Dante fork's S32_LE files, this example produces packed 24-bit little-endian
PCM. Preserve the selected format/rate/channel count in the filename or metadata.
Using plughw can invoke ALSA format conversion; it is not a claim of a direct
hardware-format or bit-perfect path. Validate against the actual driver and sink.

The daemon provides GET /api/ptp/status, /api/sinks and /api/sink/status/:id for
readiness/diagnostics. A future LuCI backend could use these through a fixed,
allowlisted localhost RPC adapter; this delivery does not implement that adapter
or claim those endpoints have been tested against a running daemon. [S10]

Dante compatibility boundaries

Do not equate the Dante brand with AES67 capability. Audinate says support must
be exposed by the device/firmware. Native Dante transport remains distinct even
when a device also has AES67 mode. A compatible source must actually create an
AES67 flow; ordinary native-Dante subscriptions do not turn into AES67 RTP. [S12]

Do not impose an obsolete universal 48 kHz-only rule either: the current Dante
Controller RTP Config documentation describes AES67 at 48 or 96 kHz on supporting
devices, with availability depending on device capabilities. The 48 kHz profile
above is a conservative starting test profile, not the universal protocol limit.
The current PTP capabilities guide must also be checked for the specific device;
PTPv2 clock support alone does not prove AES67 RTP support. [S12, S13]

For Dante-native-only endpoints, including devices/software without an exposed
AES67 mode, retain Inferno or another native-Dante endpoint. The reviewed Inferno
comparison specifically distinguishes its DVS/Via/native-Dante coverage from the
AES67 daemon. That is an upstream compatibility claim, not a test of your devices.
[S2]

OpenWrt work required for the AES67 alternative

This is a separate port, not just an additional LuCI page. Build and package
MergingRavennaALSA.ko against the exact target kernel/configuration and pair it
with the appropriate daemon sources/public headers. OpenWrt's kernel-package
machinery encodes a kernel version/vermagic dependency; do not bypass it to load
a module from another image. A reproducible full buildroot matching the deployed
firmware is the safer basis for this kernel-facing work. [S14]

The daemon is C++17 and requires Boost components. Its CMake options allow an
initial reduced-feature port with:

```text
-DENABLE_TESTS=OFF
-DFAKE_DRIVER=OFF
-DWITH_SYSTEMD=OFF
-DWITH_STREAMER=OFF
-DWITH_NMOS=OFF
-DWITH_AVAHI=OFF
```

These are proposed build choices, not tested build instructions. Disabling the
streamer removes its AAC/FAAC dependency; it does not remove the real RAVENNA
kernel module requirement. Avahi can be re-enabled when RAVENNA mDNS discovery
is required. FAKE_DRIVER mode is for daemon tests, not receiving real audio.
OpenWrt service supervision would need a procd wrapper instead of the supplied
systemd integration. [S11, S8]

The daemon's embedded HTTP server explicitly lacks authentication and HTTPS; its
implementation also enables broad CORS. Keep it on localhost, for example with
the supported -a 127.0.0.1 option, and use authenticated management mediation or
an SSH tunnel for administration. Do not expose its management port directly to
untrusted networks. The generated native-Dante LuCI RPC does not proxy it. [S10,
S15, S8]

Using Inferno with aes67-linux-daemon

There is no directly reusable media-backend interface between these two projects
in the reviewed architecture. Replacing the daemon's netlink driver manager with
Inferno is substantial integration work, not a configuration switch. A separate
PCM bridge could conceptually connect an Inferno receive/playback endpoint to
RAVENNA ALSA, but the bridge would need to handle two clock domains, buffering,
latency, drift and potentially adaptive resampling. It would also need explicit
channel routing and error reporting. No such bridge is included or verified.
This is an engineering inference from the two architectures, not an upstream
feature claim. [S2, S8, S10]

Practical selection

Use the supplied Inferno fork for experiments that need native Dante and avoid
an out-of-tree audio kernel driver. Evaluate the AES67/RAVENNA path separately
when all required sources can generate AES67, especially when retaining the
ALSA/arecord architecture is the priority. Neither conclusion establishes
production reliability or successful OpenWrt operation without target tests.
