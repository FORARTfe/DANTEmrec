#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Apply narrowly checked source transformations; refuse unexpected upstream APIs."""
from __future__ import annotations
import argparse
import difflib
from pathlib import Path
import re
import shutil
import tomllib

ROOT = Path(__file__).resolve().parents[1]

def replace_exact(path: Path, old: str, new: str, count: int = 1) -> None:
    text = path.read_text()
    found = text.count(old)
    if found != count:
        raise RuntimeError(f"{path}: expected {count} reviewed anchors, found {found}; review upstream changes")
    path.write_text(text.replace(old, new))

def apply(tree: Path, patch_output: Path | None = None) -> None:
    paths = ["inferno2pipe/src/main.rs", "inferno2pipe/src/output.rs", "inferno2pipe/src/sink.rs",
             "inferno2pipe/Cargo.toml", "Cargo.lock", "inferno_aoip/src/device_server/mod.rs",
             "inferno_aoip/src/device_server/openwrt_buffer.rs", "inferno_aoip/src/state_storage.rs"]
    before = {p: (tree / p).read_text() if (tree / p).exists() else "" for p in paths}
    main = before["inferno2pipe/src/main.rs"]
    required = ["DeviceServer::start(settings).await", "receive_with_callback", "settings.make_tx_channels(0)"]
    if not all(s in main for s in required):
        raise RuntimeError("inferno2pipe API differs from the reviewed source")
    collector = (tree / "inferno_aoip/src/device_server/samples_collector.rs").read_text()
    if "const BUFFER_SIZE: usize = 65536;" not in collector or "FnMut(usize, &Vec<Vec<Sample>>)" not in collector:
        raise RuntimeError("collector API/capacity changed; review receive sizing")
    common = (tree / "inferno_aoip/src/common.rs").read_text()
    if "pub type Sample = i32;" not in common:
        raise RuntimeError("sample representation changed")
    mod = tree / "inferno_aoip/src/device_server/mod.rs"
    # Both owned-buffer APIs get the limit; ALSA's externally provided buffers are untouched.
    replace_exact(mod, "OwnedBuffering::new(524288 /*TODO*/, 4800 /*TODO*/, Arc::new(col))",
                  "OwnedBuffering::new(openwrt_buffer::samples(), 4800 /*TODO*/, Arc::new(col))", 2)
    replace_exact(mod, "pub use settings::Settings;", "pub use settings::Settings;\nmod openwrt_buffer;")
    replace_exact(tree / "inferno_aoip/src/state_storage.rs",
                  'let dir = AppDirs::new(Some("inferno_aoip"), false).unwrap().state_dir.to_str().unwrap().to_owned()',
                  'let dir = std::env::var("INFERNO_STATE_DIR").unwrap_or_else(|_|\n'
                  '      AppDirs::new(Some("inferno_aoip"), false).unwrap().state_dir.to_str().unwrap().to_owned())')
    for name in ["main.rs", "output.rs", "sink.rs"]:
        shutil.copyfile(ROOT / "port" / name, tree / "inferno2pipe/src" / name)
    shutil.copyfile(ROOT / "port/openwrt_buffer.rs", mod.parent / "openwrt_buffer.rs")
    # libc is already pinned by this workspace. Add a direct edge, not a new version.
    lock_path = tree / "Cargo.lock"
    lock = tomllib.loads(lock_path.read_text())
    libc = [p for p in lock["package"] if p["name"] == "libc"]
    if len(libc) != 1 or not libc[0]["version"].startswith("0.2."):
        raise RuntimeError("expected one locked libc 0.2 version; review dependency graph")
    manifest = tree / "inferno2pipe/Cargo.toml"
    parsed = tomllib.loads(manifest.read_text())
    if "libc" in parsed.get("dependencies", {}):
        raise RuntimeError("upstream now has a direct libc dependency; review port")
    replace_exact(manifest, "[dependencies]\n", f'[dependencies]\nlibc = "={libc[0]["version"]}"\n')
    text = lock_path.read_text()
    pattern = r'(\[\[package\]\]\nname = "inferno2pipe"\n.*?dependencies = \[\n)(.*?)(\n\])'
    matches = list(re.finditer(pattern, text, flags=re.S))
    if len(matches) != 1:
        raise RuntimeError("cannot identify inferno2pipe lockfile dependency block")
    match = matches[0]
    block = match.group(2)
    if '"libc"' in block:
        raise RuntimeError("unexpected libc edge in original lockfile")
    text = text[:match.start(2)] + block + '\n "libc",' + text[match.end(2):]
    lock_path.write_text(text)
    tomllib.loads(text)
    if patch_output is not None:
        chunks = []
        for path in paths:
            after = (tree / path).read_text()
            chunks.extend(difflib.unified_diff(before[path].splitlines(True), after.splitlines(True),
                                               fromfile="a/" + path if before[path] else "/dev/null",
                                               tofile="b/" + path))
        patch_output.parent.mkdir(parents=True, exist_ok=True)
        patch_output.write_text("".join(chunks))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tree", type=Path)
    parser.add_argument("--patch-output", type=Path)
    args = parser.parse_args()
    apply(args.tree, args.patch_output)
