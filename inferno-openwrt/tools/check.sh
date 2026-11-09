#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -v
if command -v rustc >/dev/null 2>&1; then
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT HUP INT TERM
	rustc --edition=2021 --test port/output.rs -o "$tmp/output-tests"
	"$tmp/output-tests"
	rustc --edition=2021 --test port/openwrt_buffer.rs -o "$tmp/buffer-tests"
	"$tmp/buffer-tests"
else
	printf '%s\n' 'SKIPPED: Rust unit tests (rustc not installed).'
fi
printf '%s\n' 'This check does not compile an OpenWrt package or test a Dante network.'
