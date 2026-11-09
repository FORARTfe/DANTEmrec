Source register

Review date: 2026-11-09. Only primary project/vendor/OpenWrt sources are used.
The URLs below identify reviewed pages or moving branches, not verified build
pins. The source preparation tool records actual pins when run on a connected
build host. Full remote source preparation was not possible in this container.

S1. User-supplied installer.sh: ALSAmrec installer v3.1, 548 file lines in the
conversation source view. Retained unchanged as reference/installer-alsa-v3.1.sh.
See reference/SHA256SUMS. Relevant sections: ALSA device detection (91-105),
exFAT selection (108-118), capture/free-space/format handling (163-195), CLI
(199-274), CGI (310-339), rpcd (342-411), LuCI/menu/ACL (413-518).

S2. Inferno README: protocols, controller support, maturity, recording pauses,
clock dependency, runtime/network caveats.
```
https://raw.githubusercontent.com/teodly/inferno/dev/README.md
```
S3. Inferno settings implementation: interface/name/rate environment settings.
```
https://raw.githubusercontent.com/teodly/inferno/dev/inferno_aoip/src/device_server/settings.rs
```
S4. Modified Statime PTPv1 example: virtual clock and transport settings.
```
https://raw.githubusercontent.com/teodly/statime/inferno-dev/inferno-ptpv1.toml
```
S5. OpenWrt procd shell API: instances, resource limits, triggers, signals.
```
https://raw.githubusercontent.com/openwrt/openwrt/main/package/system/procd/files/procd.sh
```
S6. OpenWrt rpcd executable-plugin implementation and package definition.
```
https://lxr.openwrt.org/source/rpcd/plugin.c
https://raw.githubusercontent.com/openwrt/openwrt/main/package/system/rpcd/Makefile
```
S7. LuCI form and core APIs. Source review, not browser/runtime validation.
```
https://raw.githubusercontent.com/openwrt/luci/master/modules/luci-base/htdocs/luci-static/resources/form.js
https://raw.githubusercontent.com/openwrt/luci/openwrt-24.10/modules/luci-base/htdocs/luci-static/resources/luci.js
```
S8. AES67 daemon main README: architecture, kernel module, source/sink data paths,
HTTP binding, capture exclusion by the streamer, driver compatibility notes.
```
https://github.com/bondagit/aes67-linux-daemon
```
S9. AES67 project interoperability tests: AVIO devices, 48 kHz/L24 profile,
multicast creation and RAVENNA capture example.
```
https://raw.githubusercontent.com/bondagit/aes67-linux-daemon/master/DEVICES.md
```
S10. AES67 daemon API and configuration: PTP states, channel maps, REST endpoints,
HTTP authentication/TLS limitation.
```
https://raw.githubusercontent.com/bondagit/aes67-linux-daemon/master/daemon/README.md
```
S11. AES67 daemon build options and dependencies.
```
https://raw.githubusercontent.com/bondagit/aes67-linux-daemon/master/daemon/CMakeLists.txt
```
S12. Audinate current controller documentation: device-dependent RTP capability,
AES67 48/96 kHz modes and native Dante versus AES67 transport.
```
https://dev.audinate.com/GA/dante-controller/userguide/webhelp/content/rtp_config_tab.htm
https://dev.audinate.com/GA/dante-controller/userguide/webhelp/content/creating_aes67_or_st2110-30_rtp_transmit_flows.htm
```
S13. Audinate clock capability guidance (page dated 2026-04-17) and AES67
interoperability note (updated 2026-05-11).
```
https://support.getdante.com/hc/en-gb/articles/5508252986655-Dante-Devices-PTP-Clocking-Support
https://support.getdante.com/hc/en-gb/articles/5508253040927-AES67-Interoperability
```
S14. OpenWrt kernel-package implementation: version/vermagic dependency.
```
https://raw.githubusercontent.com/openwrt/openwrt/main/include/kernel.mk
```
S15. AES67 HTTP implementation: REST handlers and CORS behavior.
```
https://raw.githubusercontent.com/bondagit/aes67-linux-daemon/master/daemon/http_server.cpp
```

The original source port has a separate, retained inferno-openwrt/docs/SOURCES.md.
