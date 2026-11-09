# Validation record and acceptance checklist

Prepared: 2026-11-09. This record applies to the source overlay in this archive,
not to a compiled or deployed OpenWrt package.

## Checks actually performed

Command: ./tools/check.sh

The 12 Python unittest cases passed. They exercise the following areas:

| Area | What was checked | What this does not establish |
|---|---|---|
| Source transformation | Reviewed API anchors in synthetic source fixtures; both owned RX constructors; preservation of remote dependency pins; rejection of repeat application/API drift; generated patch reproduces fixture changes | Successful patching or building of a complete downloaded upstream checkout |
| Source archive | Stable tar output and inclusion of submodule source content in a local fixture | Full remote source preparation, registry availability, or end-to-end vendoring |
| Make recipes | GNU make expansion with a mock Rust helper and mock Cargo; expected cross-build environment/profile arguments; executable and ALSA package branches | Correct operation in a real SDK, compiler/linker success or installable package metadata |
| Service scripts | BusyBox ash syntax; disabled-service behavior; numeric/name validation including newline/TOML-injection rejection; disabled and non-system-clock defaults | Real procd lifecycle, UCI/network resolution, account permissions or runtime clock connectivity |

The captured output is docs/host-checks.txt. It explicitly states that Rust tests
were skipped because rustc was not installed. A follow-up run after documentation
changes used the same host checks.

The code includes five standalone output-module tests and two receive-buffer
validation tests. They were not compiled or executed here. Running check.sh on a
host with rustc invokes them. Sink behavior involving libc and real FIFO/file I/O
also needs integration testing; it is not covered by these standalone modules.

The environment did not have Cargo, rustc, an OpenWrt SDK or Dante devices. Web
access allowed source inspection, but a complete repository checkout and remote
source preparation were not performed in the execution container. No upstream
commit was fabricated or represented as tested.

## Required before a deployment is accepted

1. Build and provenance

Prepare sources on the intended build host. Retain sources.lock.json, source.mk,
vendored source archives, generated patch, SDK and feed revisions, compiler
versions and full V=s build logs. Run all Rust tests and compile both the capture
and clock packages. Build the optional ALSA package separately when required.
Inspect the binary architecture, dynamic interpreter and linked libraries.
Install on the exact matching OpenWrt release/target; verify package dependencies,
the inferno account, service defaults and normal removal/reinstallation.

2. Clock and network behavior

Use an isolated wired VLAN and a compatible PTPv1 leader. Verify clock export,
Unix socket permissions, discovery, subscription and actual samples with known
source material. Confirm the router's administrative/system clock is not being
steered by this service. Test system-time steps, leader loss/re-election, daemon
restart, interface down/up and IP changes. There is no added clock-freshness
watchdog; stale-clock behavior and recovery cannot be presumed correct.

3. Audio correctness and resource use

Compare interleaved S32_LE output against a known channel-identifiable source.
Test selected sample rates and channel counts, packet loss/reordering, multicast
where used, and disconnection/reconnection. Record CPU load, RSS, binary/installed
size, packet loss and measured end-to-end latency under normal and congested
router workloads. Compare against an unmodified upstream build with the same
compiler, dependencies, clock configuration and workload. Do not infer process
memory reduction from the ring payload calculation alone.

4. Output and shutdown failures

Test a FIFO with no reader, a slow reader and a disconnected reader; full or
removed storage; a pre-existing regular file; a symlink output; startup without
a clock; SIGTERM while waiting for a clock and during capture; and repeated
failures until procd's retry limit. Confirm visible failure, bounded user-space
allocation and no accidental truncation of an existing recording. A failing
recording may end with partial data. A regular-file write may be stuck in kernel
I/O; the async shutdown timer is not a guarantee that synchronous upstream joins
can be interrupted. The service manager's termination timeout is a fallback.

5. Security and operational impact

Verify that WAN ingress remains closed and only authorized audio-network peers
can reach the service, including dynamic receive ports. Confirm no changes to
firewall, NTP, sysctl or unrelated audio configuration. Review upstream parsers
separately; this port is not a security audit. Test the realtime-priority option
only with administrative access preserved and observe routing responsiveness.
For ALSA, validate duplex operation, host application buffer handling and access
to the clock socket using the actual application account.

## Claims intentionally not made

No successful Rust compilation, OpenWrt build, production readiness, Audinate
certification, full Dante compatibility, hard realtime operation, seamless
clock failover, low-latency threshold, flash footprint or CPU/RSS benchmark is
claimed. The generated port is a starting point for those verifications.
