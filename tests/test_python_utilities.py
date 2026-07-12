#!/usr/bin/env python3
"""Focused regression tests for the standalone Python utilities."""

import argparse
import io
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from datetime import date
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import force_uninstall_python_package as force_uninstall
import count_instr
import decode_waitcnt
import llm_usage
import sched_log_split
import split_ir_dump
import strip_mlir_loc


class ForceUninstallTests(unittest.TestCase):
    def test_metadata_inspection_does_not_import_distribution_code(self):
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            marker = temp / "imported"
            (temp / "codex_side_effect_dist.py").write_text(
                f"from pathlib import Path\nPath({str(marker)!r}).touch()\n",
                encoding="utf-8",
            )
            metadata = temp / "codex_side_effect_dist-1.0.dist-info"
            metadata.mkdir()
            (metadata / "METADATA").write_text(
                "Metadata-Version: 2.1\n"
                "Name: codex-side-effect-dist\n"
                "Version: 1.0\n",
                encoding="utf-8",
            )
            (metadata / "RECORD").write_text(
                "codex_side_effect_dist.py,,\n"
                "codex_side_effect_dist-1.0.dist-info/METADATA,,\n"
                "codex_side_effect_dist-1.0.dist-info/RECORD,,\n",
                encoding="utf-8",
            )

            pythonpath = os.pathsep.join(
                filter(None, (str(temp), os.environ.get("PYTHONPATH")))
            )
            with mock.patch.dict(os.environ, {"PYTHONPATH": pythonpath}):
                info = force_uninstall.inspect_distribution(
                    "codex-side-effect-dist", sys.executable
                )

            self.assertIsNotNone(info)
            self.assertEqual(info.name, "codex-side-effect-dist")
            self.assertFalse(marker.exists(), "metadata lookup imported package code")

    def test_user_site_distribution_paths_are_valid_removal_roots(self):
        with tempfile.TemporaryDirectory() as temp_name:
            user_base = Path(temp_name) / "user-base"
            site_packages = (
                user_base
                / "lib"
                / f"python{sys.version_info.major}.{sys.version_info.minor}"
                / "site-packages"
            )
            metadata = site_packages / "codex_user_dist-1.0.dist-info"
            metadata.mkdir(parents=True)
            module = site_packages / "codex_user_dist.py"
            module.write_text("VALUE = 1\n", encoding="utf-8")
            script = user_base / "bin" / "codex-user-dist"
            script.parent.mkdir()
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            (metadata / "METADATA").write_text(
                "Metadata-Version: 2.1\nName: codex-user-dist\nVersion: 1.0\n",
                encoding="utf-8",
            )
            (metadata / "RECORD").write_text(
                "codex_user_dist.py,,\n"
                "codex_user_dist-1.0.dist-info/METADATA,,\n"
                "codex_user_dist-1.0.dist-info/RECORD,,\n"
                "../../../bin/codex-user-dist,,\n",
                encoding="utf-8",
            )

            with mock.patch.dict(
                os.environ, {"PYTHONUSERBASE": str(user_base)}, clear=False
            ):
                info = force_uninstall.inspect_distribution(
                    "codex-user-dist", sys.executable
                )

            self.assertIsNotNone(info)
            paths = force_uninstall.validate_owned_paths(info)
            self.assertIn(module, paths)
            self.assertIn(script, paths)

    def test_removes_only_metadata_owned_files(self):
        with tempfile.TemporaryDirectory() as temp_name:
            site = Path(temp_name) / "site-packages"
            metadata = site / "demo-1.0.dist-info"
            metadata.mkdir(parents=True)
            module = site / "demo.py"
            unrelated = site / "unrelated.py"
            module.write_text("owned\n", encoding="utf-8")
            unrelated.write_text("keep\n", encoding="utf-8")
            meta_file = metadata / "METADATA"
            meta_file.write_text("Name: demo\n", encoding="utf-8")

            info = force_uninstall.DistributionInfo(
                "demo", "1.0", (module, meta_file), (site,)
            )
            paths = force_uninstall.validate_owned_paths(info)
            force_uninstall.remove_owned_paths(paths, info.install_roots)

            self.assertFalse(module.exists())
            self.assertFalse(metadata.exists())
            self.assertEqual(unrelated.read_text(encoding="utf-8"), "keep\n")
            self.assertTrue(site.is_dir(), "install root itself must never be removed")

    def test_refuses_install_root_and_paths_outside_it(self):
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            site = temp / "site-packages"
            stdlib_file = temp / "lib" / "python" / "os.py"
            site.mkdir()
            stdlib_file.parent.mkdir(parents=True)
            stdlib_file.touch()

            with self.assertRaises(force_uninstall.UninstallError):
                force_uninstall.validate_owned_paths(
                    force_uninstall.DistributionInfo("bad", "1", (site,), (site,))
                )
            with self.assertRaises(force_uninstall.UninstallError):
                force_uninstall.validate_owned_paths(
                    force_uninstall.DistributionInfo(
                        "bad", "1", (stdlib_file,), (site,)
                    )
                )

    def test_never_recursively_deletes_nonempty_owned_directory(self):
        with tempfile.TemporaryDirectory() as temp_name:
            site = Path(temp_name) / "site-packages"
            package = site / "demo"
            package.mkdir(parents=True)
            unowned = package / "local_config.py"
            unowned.write_text("keep\n", encoding="utf-8")
            info = force_uninstall.DistributionInfo(
                "demo", "1", (package,), (site,)
            )

            paths = force_uninstall.validate_owned_paths(info)
            with self.assertRaises(force_uninstall.UninstallError):
                force_uninstall.remove_owned_paths(paths, info.install_roots)
            self.assertEqual(unowned.read_text(encoding="utf-8"), "keep\n")

    def test_refuses_path_through_parent_symlink(self):
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            site = temp / "site-packages"
            outside = temp / "outside"
            site.mkdir()
            outside.mkdir()
            (site / "demo").symlink_to(outside, target_is_directory=True)
            victim = site / "demo" / "victim.py"
            victim.write_text("keep\n", encoding="utf-8")

            info = force_uninstall.DistributionInfo(
                "demo", "1", (victim,), (site,)
            )
            with self.assertRaises(force_uninstall.UninstallError):
                force_uninstall.validate_owned_paths(info)
            self.assertEqual((outside / "victim.py").read_text(encoding="utf-8"),
                             "keep\n")


class StripMlirLocationTests(unittest.TestCase):
    def test_loc_in_line_comment_is_ignored(self):
        source = (
            "// TODO: preserve loc( even though it is unmatched\n"
            "%0 = arith.constant 0 : i32 loc(#loc1)\n"
            "return\n"
        )
        self.assertEqual(
            strip_mlir_loc.strip_loc(source),
            "// TODO: preserve loc( even though it is unmatched\n"
            "%0 = arith.constant 0 : i32\n"
            "return\n",
        )

    def test_unmatched_annotation_does_not_consume_rest_of_file(self):
        source = "%0 = call @foo() loc(\nreturn %0 : i32\n"
        self.assertEqual(strip_mlir_loc.strip_loc(source), source)

    def test_parentheses_in_comment_do_not_balance_annotation(self):
        source = "%0 = call @foo() loc(\n// misleading )\nreturn %0 : i32\n"
        self.assertEqual(strip_mlir_loc.strip_loc(source), source)

    def test_unmatched_annotation_leaves_later_annotations_untouched(self):
        source = "loc(\n// unfinished\nreturn loc(#later)\n"
        self.assertEqual(strip_mlir_loc.strip_loc(source), source)

    def test_final_location_definition_without_newline_is_removed_cleanly(self):
        source = "%0 = arith.constant 0 : i32\n#loc1 = loc(\"file.mlir\":1:1)"
        self.assertEqual(
            strip_mlir_loc.strip_loc(source),
            "%0 = arith.constant 0 : i32\n",
        )


class SplitIrDumpTests(unittest.TestCase):
    SAMPLE = (
        "; *** IR Dump After InstCombinePass on [module] ***\n"
        "define void @foo() { ret void }\n"
    )

    def test_stages_and_publishes_into_new_directory(self):
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            source = temp / "dump.txt"
            output = temp / "split"
            source.write_text(self.SAMPLE, encoding="utf-8")

            count = split_ir_dump.split_file(str(source), str(output))

            self.assertEqual(count, 1)
            self.assertTrue((output / "0000_InstCombinePass.ll").is_file())
            self.assertIn("0000_InstCombinePass.ll",
                          (output / "index.txt").read_text(encoding="utf-8"))

    def test_publishes_over_existing_empty_directory(self):
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            source = temp / "dump.txt"
            output = temp / "split"
            source.write_text(self.SAMPLE, encoding="utf-8")
            output.mkdir()
            output.chmod(0o775)
            original_stat = output.stat()

            count = split_ir_dump.split_file(str(source), str(output))

            self.assertEqual(count, 1)
            self.assertTrue((output / "index.txt").is_file())
            published_stat = output.stat()
            self.assertEqual(published_stat.st_ino, original_stat.st_ino)
            self.assertEqual(published_stat.st_mode & 0o777, 0o775)

    def test_new_output_uses_normal_umask_directory_mode(self):
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            source = temp / "dump.txt"
            output = temp / "split"
            source.write_text(self.SAMPLE, encoding="utf-8")

            old_umask = os.umask(0o022)
            try:
                split_ir_dump.split_file(str(source), str(output))
            finally:
                os.umask(old_umask)

            self.assertEqual(output.stat().st_mode & 0o777, 0o755)

    def test_rejects_input_inside_output_without_modifying_it(self):
        with tempfile.TemporaryDirectory() as temp_name:
            output = Path(temp_name) / "split"
            output.mkdir()
            source = output / "index.txt"
            source.write_text(self.SAMPLE, encoding="utf-8")

            with self.assertRaises(ValueError):
                split_ir_dump.split_file(str(source), str(output))

            self.assertEqual(source.read_text(encoding="utf-8"), self.SAMPLE)
            self.assertEqual(list(output.iterdir()), [source])

    def test_refuses_to_overwrite_existing_generated_output(self):
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            source = temp / "dump.txt"
            source.write_text(self.SAMPLE, encoding="utf-8")
            output = temp / "split"
            output.mkdir()
            existing = output / "0000_InstCombinePass.ll"
            existing.write_text("keep\n", encoding="utf-8")

            with self.assertRaises(ValueError):
                split_ir_dump.split_file(str(source), str(output))
            self.assertEqual(existing.read_text(encoding="utf-8"), "keep\n")


class LlmUsageTests(unittest.TestCase):
    def test_default_range_includes_today(self):
        start, end = llm_usage.resolve_date_bounds(
            None, None, None, date(2026, 7, 11)
        )
        self.assertEqual(start, date(2026, 7, 9))
        self.assertEqual(end, date(2026, 7, 11))

    def test_start_only_range_ends_today(self):
        start, end = llm_usage.resolve_date_bounds(
            date(2026, 7, 1), None, None, date(2026, 7, 11)
        )
        self.assertEqual(start, date(2026, 7, 1))
        self.assertEqual(end, date(2026, 7, 11))

    def test_daily_query_does_not_use_a_future_end_for_today(self):
        today = date(2026, 7, 11)
        self.assertEqual(llm_usage.daily_query_bounds(today), (today, today))

    def test_fetch_uses_timeout(self):
        response = io.BytesIO(b'{"totalRequests": 0}')
        with mock.patch.object(
            llm_usage.urllib.request, "urlopen", return_value=response
        ) as urlopen:
            result = llm_usage.fetch_usage(
                date(2026, 7, 9), date(2026, 7, 10), "secret", timeout=4.5
            )
        self.assertEqual(result, {"totalRequests": 0})
        self.assertEqual(urlopen.call_args.kwargs["timeout"], 4.5)

    def test_http_400_is_not_suppressed(self):
        error = urllib.error.HTTPError(
            "https://example.invalid", 400, "Bad Request", {}, None
        )
        with mock.patch.object(
            llm_usage.urllib.request, "urlopen", side_effect=error
        ):
            with self.assertRaises(urllib.error.HTTPError):
                llm_usage.fetch_usage(
                    date(2026, 7, 9), date(2026, 7, 10), "secret"
                )


class CountInstructionsTests(unittest.TestCase):
    def test_counts_instruction_after_label(self):
        counts = count_instr.count_instructions(
            ["entry: s_mov_b32 s0, 0\n", ".Lnext: v_add_f32_e32 v0, v1, v2\n"]
        )
        self.assertEqual(counts, {"s_mov_b32": 1, "v_add_f32": 1})

    def test_handles_final_line_without_newline(self):
        counts = count_instr.count_instructions(["s_endpgm"])
        self.assertEqual(counts, {"s_endpgm": 1})


class DecodeWaitcntTests(unittest.TestCase):
    def test_accepts_signed_i32_and_unsigned_hex_bit_pattern(self):
        self.assertEqual(decode_waitcnt.parse_imm(str(-(1 << 31))), -(1 << 31))
        self.assertEqual(decode_waitcnt.parse_imm("0xFFFFFFFF"), (1 << 32) - 1)

    def test_rejects_values_outside_documented_domains(self):
        for value in (str(-(1 << 31) - 1), str(1 << 31), "0x100000000"):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    decode_waitcnt.parse_imm(value)

    def test_malformed_cli_input_is_an_argparse_error_without_traceback(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "decode_waitcnt.py"), "not-an-int"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid i32 immediate", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


class SchedLogSplitTests(unittest.TestCase):
    def test_splits_into_new_collision_safe_chunks(self):
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            source = temp / "schedule.log"
            source.write_text("preamble\nBEGIN one\nbody\nBEGIN two\n", encoding="utf-8")
            output = temp / "chunks"

            chunks = sched_log_split.split_file(source, r"^BEGIN", output)

            self.assertEqual(
                [chunk.name for chunk in chunks],
                ["schedule_1.log", "schedule_2.log", "schedule_3.log"],
            )
            self.assertEqual(chunks[0].read_text(encoding="utf-8"), "preamble\n")
            self.assertEqual(
                chunks[1].read_text(encoding="utf-8"), "BEGIN one\nbody\n"
            )
            self.assertEqual(chunks[2].read_text(encoding="utf-8"), "BEGIN two\n")

    def test_refuses_existing_or_stale_chunks_without_modifying_them(self):
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            source = temp / "schedule.log"
            source.write_text("BEGIN replacement\n", encoding="utf-8")
            output = temp / "chunks"
            output.mkdir()
            stale = output / "schedule_9.log"
            stale.write_text("keep\n", encoding="utf-8")

            with self.assertRaises(FileExistsError):
                sched_log_split.split_file(source, r"^BEGIN", output)

            self.assertEqual(stale.read_text(encoding="utf-8"), "keep\n")
            self.assertEqual(list(output.iterdir()), [stale])


if __name__ == "__main__":
    unittest.main()
