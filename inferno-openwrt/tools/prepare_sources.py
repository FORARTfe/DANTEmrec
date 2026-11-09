#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Freeze, vendor, hash and install the two source packages into an OpenWrt SDK.
Requires Python >=3.11, git, cargo, rustc, and a network-connected Linux host.
The first invocation resolves development branches; later invocations reuse the lock.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
from apply_port import apply

ROOT = Path(__file__).resolve().parents[1]
SPECS = {
    "inferno": ("inferno-openwrt", "https://github.com/teodly/inferno.git", "dev", "0.5.0"),
    "inferno-statime": ("inferno-statime", "https://github.com/teodly/statime.git", "inferno-dev", "0.4.0"),
}

def run(args: list[str], cwd: Path, capture: bool = True) -> str:
    env = dict(os.environ, CARGO_NET_GIT_FETCH_WITH_CLI="true")
    result = subprocess.run(args, cwd=cwd, env=env, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ""

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""): h.update(block)
    return h.hexdigest()

def locked_remote_packages(path: Path) -> list[tuple[str, str, str, str]]:
    lock = tomllib.loads(path.read_text())
    return sorted((p["name"], p["version"], p["source"], p.get("checksum", ""))
                  for p in lock["package"] if "source" in p)

def archive(tree: Path, output: Path, dirname: str, epoch: int) -> None:
    """Stable ownership, timestamps and traversal; preserve executable bits and symlinks."""
    def normalize(info: tarfile.TarInfo) -> tarfile.TarInfo:
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mtime = epoch
        if info.isfile(): info.mode = 0o755 if info.mode & 0o111 else 0o644
        if info.isdir(): info.mode = 0o755
        info.pax_headers = {}
        return info
    with tarfile.open(output, "w:xz", format=tarfile.PAX_FORMAT) as tar:
        tar.add(tree, arcname=dirname, recursive=False, filter=normalize)
        for folder, dirs, files in os.walk(tree):
            dirs[:] = sorted(d for d in dirs if d != ".git")
            for name in sorted(dirs + files):
                if name == ".git": continue
                path = Path(folder) / name
                relative = path.relative_to(tree)
                tar.add(path, arcname=dirname + "/" + relative.as_posix(), recursive=False, filter=normalize)

def check_statime(tree: Path) -> None:
    config = (tree / "statime-linux/src/config/mod.rs").read_text()
    for anchor in ["pub usrvclock_path:", "pub virtual_system_clock_base:", "pub slave_only:"]:
        if anchor not in config: raise RuntimeError("Statime fork configuration changed; review " + anchor)
    manifest = tomllib.loads((tree / "statime-linux/Cargo.toml").read_text())
    if not any(b.get("name") == "statime" for b in manifest.get("bin", [])):
        raise RuntimeError("Statime binary changed")

def prepare_one(key: str, work: Path, dist: Path, ref: str, cargo: str) -> dict:
    name, url, _, version_base = SPECS[key]
    if ref.startswith("-") or not ref.strip(): raise ValueError("invalid Git ref")
    tree = work / key
    tree.mkdir()
    print(f"Preparing {key} from {ref}", flush=True)
    run(["git", "init", "-q"], tree)
    run(["git", "remote", "add", "origin", url], tree)
    run(["git", "fetch", "--depth", "1", "origin", ref], tree, False)
    run(["git", "checkout", "--detach", "FETCH_HEAD"], tree, False)
    run(["git", "-c", "protocol.file.allow=never", "submodule", "update", "--init", "--recursive"], tree, False)
    revision = run(["git", "rev-parse", "HEAD"], tree)
    if not re.fullmatch(r"[0-9a-f]{40}", revision): raise RuntimeError("invalid resolved commit")
    epoch = int(run(["git", "show", "-s", "--format=%ct", "HEAD"], tree))
    date = run(["git", "show", "-s", "--format=%cs", "HEAD"], tree).replace("-", "")
    version = f"{version_base}.{date}.{revision[:12]}"
    original_lock = sha256(tree / "Cargo.lock")
    remote_before = locked_remote_packages(tree / "Cargo.lock")
    submodules = run(["git", "submodule", "status", "--recursive"], tree).splitlines()
    if key == "inferno": apply(tree, dist / "inferno-port.patch")
    else: check_statime(tree)
    if remote_before != locked_remote_packages(tree / "Cargo.lock"):
        raise RuntimeError("port changed a remote dependency pin")
    cargo_config = tree / ".cargo/config.toml"
    if cargo_config.exists() or (tree / ".cargo/config").exists():
        raise RuntimeError("upstream Cargo configuration exists; merge it explicitly after review")
    config = run([cargo, "vendor", "--locked", "--versioned-dirs", "vendor"], tree)
    # Cargo prints the source-replacement configuration, not progress, to stdout.
    tomllib.loads(config)
    cargo_config.parent.mkdir(exist_ok=True)
    cargo_config.write_text(config + '\n\n[net]\noffline = true\n')
    run([cargo, "metadata", "--frozen", "--format-version", "1"], tree)
    if remote_before != locked_remote_packages(tree / "Cargo.lock"):
        raise RuntimeError("dependency pins changed during vendoring")
    provenance = {
        "repository": url, "revision": revision, "submodules": submodules,
        "commit_epoch": epoch, "upstream_cargo_lock_sha256": original_lock,
        "prepared_cargo_lock_sha256": sha256(tree / "Cargo.lock"),
        "cargo": run([cargo, "--version"], tree), "port_version": "1",
        "port_file_sha256": {p.name: sha256(p) for p in sorted((ROOT / "port").glob("*.rs"))},
    }
    (tree / "OPENWRT-PROVENANCE.json").write_text(json.dumps(provenance, indent=2) + "\n")
    dirname = name + "-" + version
    filename = dirname + ".tar.xz"
    archive(tree, dist / filename, dirname, epoch)
    digest = sha256(dist / filename)
    source_mk = ("# Generated by tools/prepare_sources.py; retain with sources.lock.json.\n"
                 f"PKG_VERSION:={version}\nPKG_SOURCE:={filename}\n"
                 "PKG_SOURCE_URL:=file://$(DL_DIR)\n"
                 f"PKG_HASH:={digest}\n")
    (ROOT / "packages" / key / "source.mk").write_text(source_mk)
    return dict(provenance, version=version, archive=filename, sha256=digest)

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", required=True, type=Path)
    parser.add_argument("--cargo", default="cargo", help="host Cargo executable; use the SDK's Rust version")
    parser.add_argument("--inferno-ref")
    parser.add_argument("--statime-ref")
    parser.add_argument("--refresh", action="store_true", help="explicitly resolve branch tips again")
    args = parser.parse_args()
    sdk = args.sdk.resolve()
    if not (sdk / "include/package.mk").is_file(): raise RuntimeError("--sdk is not an extracted SDK/buildroot")
    if not (sdk / "feeds/packages/lang/rust/rust-package.mk").is_file():
        raise RuntimeError("install the matching OpenWrt packages feed before preparing sources")
    for key in SPECS:
        if (sdk / "package" / key).exists():
            raise RuntimeError(f"{sdk / 'package' / key} exists; back it up/remove it before reinstalling")
    for command in ["git", "rustc", args.cargo]:
        if shutil.which(command) is None: raise RuntimeError(f"required host command missing: {command}")
    lock_path = ROOT / "sources.lock.json"
    old = json.loads(lock_path.read_text()) if lock_path.exists() and not args.refresh else {}
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    manifest = {}
    with tempfile.TemporaryDirectory(prefix="inferno-src-") as temp:
        for key, (_, _, branch, _) in SPECS.items():
            explicit = args.inferno_ref if key == "inferno" else args.statime_ref
            ref = explicit or old.get(key, {}).get("revision", branch)
            manifest[key] = prepare_one(key, Path(temp), dist, ref, args.cargo)
    lock_path.write_text(json.dumps(manifest, indent=2) + "\n")
    (sdk / "dl").mkdir(exist_ok=True)
    for key, record in manifest.items():
        shutil.copy2(dist / record["archive"], sdk / "dl" / record["archive"])
        shutil.copytree(ROOT / "packages" / key, sdk / "package" / key)
    print("Prepared packages installed. Preserve dist/, sources.lock.json and source.mk files.")
    print("Next: make menuconfig; select inferno2pipe (optional: alsa-lib-pcm-inferno), then build.")

if __name__ == "__main__":
    try: main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"prepare_sources: {exc}", file=sys.stderr)
        sys.exit(1)
