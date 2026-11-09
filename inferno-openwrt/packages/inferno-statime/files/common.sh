#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
inferno_fail() {
	logger -t inferno "$*"
	return 1
}
inferno_uint() {
	case "$1" in ''|*[!0-9]*|0[0-9]*) return 1;; esac
	[ "${#1}" -le 9 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}
inferno_one_line() {
	case "$1" in *'
'*) return 1;; esac
}
inferno_name() {
	inferno_one_line "$1" || return 1
	LC_ALL=C printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9_. -]{1,31}$'
}
inferno_device() {
	inferno_one_line "$1" || return 1
	LC_ALL=C printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9_.:-]{1,15}$'
}
inferno_network() {
	inferno_one_line "$1" || return 1
	LC_ALL=C printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9_]{1,32}$'
}
inferno_runtime_dir() {
	# Only fixed /var/run paths are passed here; never chown an arbitrary UCI path.
	[ ! -L "$1" ] || { inferno_fail "Refusing symlink runtime directory: $1"; return 1; }
	mkdir -p "$1" && chown "$2" "$1" && chmod "$3" "$1"
}
