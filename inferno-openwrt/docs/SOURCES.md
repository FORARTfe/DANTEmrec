# Primary sources and review scope

Inspected through web access on 2026-11-09. Branch URLs identify reviewed APIs,
not immutable tested releases. Actual revisions are recorded only when the
preparation tool completes on a network-connected build host. Source comments
and incomplete upstream features are not interoperability guarantees.

S1. Inferno upstream README: scope, experimental status, clock requirement,
network ports, usage, licensing and distribution disclaimer.
`https://raw.githubusercontent.com/teodly/inferno/dev/README.md`

S2. Inferno device server: both 524,288-sample owned RX buffers, callback API,
external ALSA buffers and current RX/TX latency-field mismatch.
`https://raw.githubusercontent.com/teodly/inferno/dev/inferno_aoip/src/device_server/mod.rs`
Sample representation and ring implementation:
`https://raw.githubusercontent.com/teodly/inferno/dev/inferno_aoip/src/common.rs`
`https://raw.githubusercontent.com/teodly/inferno/dev/inferno_aoip/src/ring_buffer.rs`

S3. Original capture frontend: native-endian serialization, synchronous writes
in the callback, expandable byte buffer and default debug logging.
`https://raw.githubusercontent.com/teodly/inferno/dev/inferno2pipe/src/main.rs`
`https://raw.githubusercontent.com/teodly/inferno/dev/inferno2pipe/Cargo.toml`

S4. Samples collector: 50 ms cadence, callback signature and 65,536-frame scratch
capacity. This port does not change the collector's timing or loss handling.
`https://raw.githubusercontent.com/teodly/inferno/dev/inferno_aoip/src/device_server/samples_collector.rs`

S5. OpenWrt Rust packaging: SDK cross-linker, target derivation, musl/link flags
and build environment. The kit uses these helpers instead of a hand-coded triple.
`https://raw.githubusercontent.com/openwrt/packages/openwrt-24.10/lang/rust/rust-package.mk`
`https://raw.githubusercontent.com/openwrt/packages/openwrt-24.10/lang/rust/rust-values.mk`
`https://raw.githubusercontent.com/openwrt/packages/openwrt-25.12/lang/rust/rust-package.mk`
`https://raw.githubusercontent.com/openwrt/packages/openwrt-25.12/lang/rust/rust-values.mk`

S6. Cargo vendor documentation: configuration output, vendoring of registry/git
sources, --locked and --frozen semantics.
`https://doc.rust-lang.org/cargo/commands/cargo-vendor.html`

S7. Required Statime fork: PTPv1, virtual clock, monotonic_raw clock base,
usrvclock export, follower-only configuration and software timestamp selection.
`https://raw.githubusercontent.com/teodly/statime/inferno-dev/inferno-ptpv1.toml`
`https://raw.githubusercontent.com/teodly/statime/inferno-dev/statime-linux/src/config/mod.rs`
`https://raw.githubusercontent.com/teodly/statime/inferno-dev/statime-linux/src/main.rs`
`https://raw.githubusercontent.com/teodly/statime/inferno-dev/statime-linux/Cargo.toml`

S8. Optional ALSA plugin: virtual PCM operation, RX/TX configuration, alternate
ports, process IDs and example configuration.
`https://raw.githubusercontent.com/teodly/inferno/dev/alsa_pcm_inferno/README.md`
`https://raw.githubusercontent.com/teodly/inferno/dev/alsa_pcm_inferno/Cargo.toml`
`https://raw.githubusercontent.com/teodly/inferno/dev/alsa_pcm_inferno/asoundrc.sample`
OpenWrt ALSA dependency packaging:
`https://raw.githubusercontent.com/openwrt/packages/openwrt-24.10/libs/alsa-lib/Makefile`

S9. Cargo profile reference: optimization levels, LTO, codegen units, stripping,
panic strategy and environment overrides. Profile choices require benchmarking.
`https://doc.rust-lang.org/cargo/reference/profiles.html`

S10. Upstream integration points retained or adapted by this kit.
`https://raw.githubusercontent.com/teodly/inferno/dev/inferno_aoip/src/state_storage.rs`
`https://raw.githubusercontent.com/teodly/inferno/dev/inferno_aoip/src/device_server/settings.rs`
`https://raw.githubusercontent.com/teodly/inferno/dev/inferno_aoip/src/device_server/flows_rx.rs`
`https://raw.githubusercontent.com/teodly/inferno/dev/.gitmodules`
`https://raw.githubusercontent.com/teodly/statime/inferno-dev/.gitmodules`

Numbers such as the 87.5% ring-payload reduction and the default pool capacity are
arithmetic on reviewed upstream constants and this kit's settings. They are not
measurements. Generated code, configuration choices and host tests are contained
in this archive and are not upstream guarantees.
