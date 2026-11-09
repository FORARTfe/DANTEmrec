# SPDX-License-Identifier: GPL-3.0-or-later
"""Host-side contract tests. These do NOT constitute an OpenWrt/Rust build."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import unittest
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from apply_port import apply
from prepare_sources import archive, locked_remote_packages

class SourceTransformTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tree = Path(self.tmp.name) / "tree"
        self.tree.mkdir()
        self.files = {
            "inferno2pipe/src/main.rs": "DeviceServer::start(settings).await\nreceive_with_callback\nsettings.make_tx_channels(0)\n",
            "inferno2pipe/Cargo.toml": '[package]\nname = "inferno2pipe"\nversion = "0.1.0"\n[dependencies]\nlog = "0.4"\n',
            "Cargo.lock": '''version = 3
[[package]]
name = "inferno2pipe"
version = "0.1.0"
dependencies = [
 "log",
]
[[package]]
name = "libc"
version = "0.2.177"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "fixture-not-a-real-package-checksum"
[[package]]
name = "log"
version = "0.4.28"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "fixture-not-a-real-package-checksum"
''',
            "inferno_aoip/src/device_server/mod.rs": 'pub use settings::Settings;\n' +
                'let buffering = OwnedBuffering::new(524288 /*TODO*/, 4800 /*TODO*/, Arc::new(col));\n' * 2,
            "inferno_aoip/src/device_server/samples_collector.rs": 'const BUFFER_SIZE: usize = 65536;\nFnMut(usize, &Vec<Vec<Sample>>)\n',
            "inferno_aoip/src/common.rs": 'pub type Sample = i32;\n',
            "inferno_aoip/src/state_storage.rs": 'let dir = AppDirs::new(Some("inferno_aoip"), false).unwrap().state_dir.to_str().unwrap().to_owned()\n',
        }
        for name, data in self.files.items():
            path = self.tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)
    def tearDown(self): self.tmp.cleanup()
    def test_dependency_pins_preserved(self):
        before = locked_remote_packages(self.tree / "Cargo.lock")
        apply(self.tree)
        self.assertEqual(before, locked_remote_packages(self.tree / "Cargo.lock"))
        data = tomllib.loads((self.tree / "Cargo.lock").read_text())
        app = next(p for p in data["package"] if p["name"] == "inferno2pipe")
        self.assertEqual(sorted(app["dependencies"]), ["libc", "log"])
        self.assertEqual(tomllib.loads((self.tree / "inferno2pipe/Cargo.toml").read_text())["dependencies"]["libc"], "=0.2.177")
    def test_both_owned_rx_buffers_patched(self):
        apply(self.tree)
        content = (self.tree / "inferno_aoip/src/device_server/mod.rs").read_text()
        self.assertEqual(content.count("openwrt_buffer::samples()"), 2)
        self.assertNotIn("new(524288", content)
        self.assertIn("INFERNO_STATE_DIR", (self.tree / "inferno_aoip/src/state_storage.rs").read_text())
    def test_upstream_api_drift_rejected(self):
        (self.tree / "inferno_aoip/src/device_server/samples_collector.rs").write_text("changed API")
        with self.assertRaises(RuntimeError): apply(self.tree)
    def test_second_application_rejected(self):
        apply(self.tree)
        with self.assertRaises(RuntimeError): apply(self.tree)
    def test_patch_reproduces_transformation(self):
        if not shutil.which("patch"): self.skipTest("patch unavailable")
        original = Path(self.tmp.name) / "original"
        shutil.copytree(self.tree, original)
        patch = Path(self.tmp.name) / "port.patch"
        apply(self.tree, patch)
        subprocess.run(["patch", "--batch", "-p1", "-i", str(patch)], cwd=original,
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for path in self.tree.rglob("*"):
            if path.is_file(): self.assertEqual(path.read_bytes(), (original / path.relative_to(self.tree)).read_bytes())

class ArchiveTests(unittest.TestCase):
    def test_archive_is_stable_and_keeps_submodule_sources(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            tree = root / "source"
            (tree / "submodule").mkdir(parents=True)
            (tree / ".git").mkdir()
            (tree / ".git/config").write_text("not distributable")
            (tree / "submodule/.git").write_text("gitdir: ../.git/modules/x")
            (tree / "submodule/lib.rs").write_text("// complete source\n")
            (tree / "run").write_text("#!/bin/sh\n")
            (tree / "run").chmod(0o755)
            (tree / "link").symlink_to("submodule/lib.rs")
            a, b = root / "a.tar.xz", root / "b.tar.xz"
            archive(tree, a, "package-1", 123456789)
            os.utime(tree / "run", (987654321, 987654321))
            archive(tree, b, "package-1", 123456789)
            self.assertEqual(hashlib.sha256(a.read_bytes()).digest(), hashlib.sha256(b.read_bytes()).digest())
            with tarfile.open(a) as tar:
                self.assertFalse(any(".git" in name.split("/") for name in tar.getnames()))
                self.assertIn("package-1/submodule/lib.rs", tar.getnames())
                self.assertTrue(tar.getmember("package-1/link").issym())
                self.assertEqual(tar.getmember("package-1/run").mode, 0o755)

class ShellTests(unittest.TestCase):
    def shell(self, command: str, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["busybox", "ash", "-c", command, "test", *args], text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def valid(self, fn: str, *args: str) -> bool:
        common = ROOT / "packages/inferno-statime/files/common.sh"
        result = self.shell('. "$1"; shift; fn="$1"; shift; "$fn" "$@"', str(common), fn, *args)
        return result.returncode == 0
    def test_all_service_scripts_parse_as_busybox_ash(self):
        paths = list((ROOT / "packages").glob("*/files/*.init"))
        paths += [ROOT / "packages/inferno-statime/files/common.sh", ROOT / "packages/inferno-statime/files/inferno-clock-run"]
        for path in paths:
            subprocess.run(["busybox", "ash", "-n", str(path)], check=True)
    def test_numeric_limits(self):
        for x in ["1", "2", "32"]: self.assertTrue(self.valid("inferno_uint", x, "1", "32"))
        for x in ["", "0", "33", "-1", "02", "999999999999999999999", "2;id"]:
            self.assertFalse(self.valid("inferno_uint", x, "1", "32"))
    def test_names_and_toml_injection_rejected(self):
        for x in ["br-audio", "eth0.40"]: self.assertTrue(self.valid("inferno_device", x))
        for x in ['br-audio"', "br-audio\ninterface=evil", "$(id)", "1234567890123456"]:
            self.assertFalse(self.valid("inferno_device", x))
        self.assertTrue(self.valid("inferno_name", "Inferno OpenWrt"))
        self.assertFalse(self.valid("inferno_name", "ok\nmalicious"))
        self.assertFalse(self.valid("inferno_name", "x" * 32))
    def test_defaults_disabled_and_clock_non_system(self):
        for p in [ROOT / "packages/inferno/files/inferno.config", ROOT / "packages/inferno-statime/files/inferno-clock.config"]:
            self.assertIn("option enabled '0'", p.read_text())
        clock = (ROOT / "packages/inferno-statime/files/inferno-clock.init").read_text()
        self.assertIn('virtual-system-clock = true', clock)
        self.assertIn('virtual-system-clock-base = "monotonic_raw"', clock)
        self.assertIn('slave-only = true', clock)
        self.assertIn('root:inferno 2770', clock)
    def test_disabled_services_do_not_touch_runtime(self):
        for path in (ROOT / "packages").glob("*/files/*.init"):
            cmd = 'config_load() { :; }; config_get_bool() { eval "$1=0"; }; . "$1"; start_service'
            result = self.shell(cmd, str(path))
            self.assertEqual(result.returncode, 0, result.stderr)

class BuildRecipeTests(unittest.TestCase):
    def test_recipes_pass_expected_cross_build_arguments_to_mock_cargo(self):
        # Exercise GNU make expansion and shell syntax, NOT real compilation.
        for package in ["inferno", "inferno-statime"]:
            with self.subTest(package=package), tempfile.TemporaryDirectory() as temp:
                t = Path(temp)
                (t / "include").mkdir()
                rust = t / "feeds/packages/lang/rust"
                rust.mkdir(parents=True)
                (t / "rules.mk").write_text(f"INCLUDE_DIR:={t}/include\n")
                (t / "include/package.mk").write_text("define BuildPackage\nendef\n")
                (rust / "rust-package.mk").write_text('CARGO_PKG_VARS= CARGO_PROFILE_RELEASE_OPT_LEVEL=z CARGO_PROFILE_RELEASE_PANIC=unwind\n')
                (t / "build").mkdir()
                (t / "bin").mkdir()
                log = t / "calls.jsonl"
                cargo = t / "bin/cargo"
                cargo.write_text('#!' + sys.executable + '\nimport os,sys,json\nwith open(os.environ["CALL_LOG"],"a") as f:\n f.write(json.dumps({"args":sys.argv[1:],"opt":os.getenv("CARGO_PROFILE_RELEASE_OPT_LEVEL"),"panic":os.getenv("CARGO_PROFILE_RELEASE_PANIC"),"lto":os.getenv("CARGO_PROFILE_RELEASE_LTO")})+"\\n")\n')
                cargo.chmod(0o755)
                harness = t / "harness.mk"
                harness.write_text(f'include {ROOT}/packages/{package}/Makefile\nrun:\n\t$(Build/Compile)\n')
                env = dict(os.environ, PATH=str(t / "bin") + ":" + os.environ["PATH"], CALL_LOG=str(log))
                subprocess.run(["make", "--no-print-directory", "-f", str(harness), "run", f"TOPDIR={t}",
                                f"PKG_BUILD_DIR={t / 'build'}", f"STAGING_DIR={t / 'staging'}",
                                "CONFIG_PACKAGE_inferno2pipe=m", "CONFIG_PACKAGE_alsa-lib-pcm-inferno=m"],
                               cwd=t, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                calls = [json.loads(x) for x in log.read_text().splitlines()]
                self.assertEqual(len(calls), 2 if package == "inferno" else 1)
                for call in calls:
                    self.assertIn("--frozen", call["args"])
                    self.assertEqual(call["opt"], "2")
                    self.assertEqual(call["lto"], "thin")
                self.assertEqual(calls[0]["panic"], "abort")
                if package == "inferno": self.assertEqual(calls[1]["panic"], "unwind")

if __name__ == "__main__": unittest.main(verbosity=2)
