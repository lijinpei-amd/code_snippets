#!/usr/bin/env python3
"""Regression tests for the Claude and Codex publish guards."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
HOOKS = {
    "claude": REPO_ROOT / "dotfiles/claude/dot-claude/hooks/confirm-publish.sh",
    "codex": REPO_ROOT / "dotfiles/codex/dot-codex/hooks/confirm-publish.sh",
}


def git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )


class PublishGuardRangeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.repo = root / "repo"
        self.remote_a = root / "remote-a.git"
        self.remote_b = root / "remote-b.git"

        subprocess.run(["git", "init", "--bare", str(self.remote_a)], check=True,
                       capture_output=True)
        subprocess.run(["git", "init", "--bare", str(self.remote_b)], check=True,
                       capture_output=True)
        subprocess.run(["git", "init", str(self.repo)], check=True,
                       capture_output=True)
        git(self.repo, "config", "user.name", "Publish Guard Test")
        git(self.repo, "config", "user.email", "publish-guard@example.invalid")
        git(self.repo, "config", "push.default", "current")
        git(self.repo, "branch", "-M", "main")
        git(self.repo, "remote", "add", "A", str(self.remote_a))
        git(self.repo, "remote", "add", "B", str(self.remote_b))

        (self.repo / "file.txt").write_text("base\n", encoding="utf-8")
        git(self.repo, "add", "file.txt")
        git(self.repo, "commit", "-m", "Initial commit")
        (self.repo / "file.txt").write_text(
            "base\nissue\nfollow-up\n", encoding="utf-8"
        )
        git(self.repo, "add", "file.txt")
        git(self.repo, "commit", "-m", "Fixes #4242")
        # Deliberately do not configure an upstream. The commit is reachable from
        # remote A, but pushing the current branch to empty remote B would still
        # publish it there.
        git(self.repo, "push", "A", "main")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def invoke(self, hook: Path, command: str) -> subprocess.CompletedProcess[str]:
        payload = json.dumps({
            "cwd": str(self.repo),
            "tool_input": {"command": command},
        })
        return subprocess.run(
            ["bash", str(hook)],
            input=payload,
            capture_output=True,
            text=True,
            env=os.environ.copy(),
            start_new_session=True,  # Ensure the Codex hook cannot prompt /dev/tty.
            timeout=10,
            check=False,
        )

    def make_other_branch_pending(self) -> None:
        """Create an issue-bearing update on an existing remote branch."""
        git(self.repo, "branch", "other")
        git(self.repo, "push", "A", "other")
        git(self.repo, "checkout", "other")
        (self.repo / "other.txt").write_text("pending\n", encoding="utf-8")
        git(self.repo, "add", "other.txt")
        git(self.repo, "commit", "-m", "Fixes GH-5150 on another branch")
        git(self.repo, "checkout", "main")

    def assert_guarded(self, command: str, reason: str) -> None:
        for name, hook in HOOKS.items():
            with self.subTest(hook=name, command=command):
                result = self.invoke(hook, command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("permissionDecision", result.stdout)
                self.assertIn(reason, result.stdout)

    def test_explicit_remote_without_upstream_fails_closed(self) -> None:
        for name, hook in HOOKS.items():
            with self.subTest(hook=name):
                result = self.invoke(hook, "git push B")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("permissionDecision", result.stdout)
                self.assertIn("no upstream", result.stdout)

    def test_configured_destination_scans_only_its_range(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        (self.repo / "file.txt").write_text("base\nsafe\n", encoding="utf-8")
        git(self.repo, "add", "file.txt")
        git(self.repo, "commit", "-m", "Routine local change")

        for name, hook in HOOKS.items():
            for command in ("git push A", "git push"):
                with self.subTest(hook=name, command=command):
                    result = self.invoke(hook, command)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_issue_reference_on_configured_destination_is_caught(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        (self.repo / "file.txt").write_text("base\nissue\n", encoding="utf-8")
        git(self.repo, "add", "file.txt")
        git(self.repo, "commit", "-m", "Follow-up for GH-9000")

        for name, hook in HOOKS.items():
            with self.subTest(hook=name):
                result = self.invoke(hook, "git push A")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("permissionDecision", result.stdout)
                self.assertIn("references a GitHub issue", result.stdout)

    def test_explicit_upstream_does_not_scan_a_different_push_remote(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        git(self.repo, "config", "branch.main.pushRemote", "B")
        (self.repo / "file.txt").write_text("base\npush remote\n", encoding="utf-8")
        git(self.repo, "add", "file.txt")
        git(self.repo, "commit", "-m", "Related to GH-7777")
        # Make @{push}..HEAD empty while A/main..HEAD still contains the issue
        # reference. An explicit `git push A` must scan A, not @{push} (B).
        git(self.repo, "push", "B", "main")

        for name, hook in HOOKS.items():
            with self.subTest(hook=name):
                result = self.invoke(hook, "git push A")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("permissionDecision", result.stdout)
                self.assertIn("references a GitHub issue", result.stdout)

    def test_repo_destination_override_fails_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")

        for name, hook in HOOKS.items():
            for command in (
                "git push --dry-run --repo=B",
                "git push --dry-run --repo B",
                "git push --dry-run --rep=B",
                "git push --dry-run --rep B",
            ):
                with self.subTest(hook=name, command=command):
                    result = self.invoke(hook, command)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("permissionDecision", result.stdout)
                    self.assertIn("--repo destination override", result.stdout)

        # These are not hypothetical spellings: Git itself accepts both forms
        # of the abbreviated option and would target the otherwise-empty B.
        git(self.repo, "push", "--dry-run", "--rep=B")
        git(self.repo, "push", "--dry-run", "--rep", "B")

    def test_matching_push_default_fails_closed_for_other_branches(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        self.make_other_branch_pending()
        git(self.repo, "config", "push.default", "matching")

        preview = git(self.repo, "push", "--dry-run", "--porcelain", "A")
        self.assertIn("refs/heads/other", preview.stdout + preview.stderr)
        for name, hook in HOOKS.items():
            with self.subTest(hook=name):
                result = self.invoke(hook, "git push A")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("permissionDecision", result.stdout)
                self.assertIn("push.default=matching", result.stdout)

    def test_configured_remote_push_refspec_fails_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        self.make_other_branch_pending()
        git(self.repo, "config", "remote.A.push", "refs/heads/other:refs/heads/other")

        preview = git(self.repo, "push", "--dry-run", "--porcelain", "A")
        self.assertIn("refs/heads/other", preview.stdout + preview.stderr)
        for name, hook in HOOKS.items():
            with self.subTest(hook=name):
                result = self.invoke(hook, "git push A")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("permissionDecision", result.stdout)
                self.assertIn("configured push refspecs", result.stdout)

    def test_single_branch_push_default_modes_remain_silent(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        for mode in ("current", "simple", "upstream", "tracking"):
            git(self.repo, "config", "push.default", mode)
            for name, hook in HOOKS.items():
                with self.subTest(mode=mode, hook=name):
                    result = self.invoke(hook, "git push A")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_command_local_matching_config_fails_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        self.make_other_branch_pending()

        preview = git(
            self.repo,
            "-c", "push.default=matching",
            "push", "--dry-run", "--porcelain", "A",
        )
        self.assertIn("refs/heads/other", preview.stdout + preview.stderr)
        self.assert_guarded(
            "git -c push.default=matching push --dry-run A",
            "unmodeled global options",
        )

    def test_repository_selection_overrides_fail_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        # Git accepts both forms and uses the final -C, while the old hook used
        # only the first. The environment form bypassed textual -C parsing too.
        git(self.repo, "-C", ".", "push", "--dry-run", "A")
        multiple_c = f"git -C {self.repo} -C . push --dry-run A"
        self.assert_guarded(multiple_c, "multiple -C")

        env = os.environ.copy()
        env.update({"GIT_DIR": str(self.repo / ".git"), "GIT_WORK_TREE": str(self.repo)})
        subprocess.run(
            ["git", "push", "--dry-run", "A"],
            cwd=self.repo,
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        inline_env = (
            f"GIT_DIR={self.repo / '.git'} GIT_WORK_TREE={self.repo} "
            "git push --dry-run A"
        )
        self.assert_guarded(inline_env, "Command-local Git environment")

        self.assert_guarded(
            f"git --git-dir={self.repo / '.git'} --work-tree={self.repo} push --dry-run A",
            "unmodeled global options",
        )
        git_path = shutil.which("git")
        self.assertIsNotNone(git_path)
        self.assert_guarded(
            f"{git_path} push --dry-run A",
            "path-qualified Git invocation",
        )

    def test_nonpublishing_git_forms_remain_silent(self) -> None:
        git_path = shutil.which("git")
        self.assertIsNotNone(git_path)
        commands = (
            "git status --short",
            "git log -1 --oneline",
            f"{git_path} status --short",
            "echo git status",
            "git -c color.ui=false status --short",
            "command git status --short",
        )
        for name, hook in HOOKS.items():
            for command in commands:
                with self.subTest(hook=name, command=command):
                    result = self.invoke(hook, command)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_one_canonical_dash_c_push_remains_silent(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        command = f"git -C {self.repo} push A"
        for name, hook in HOOKS.items():
            with self.subTest(hook=name):
                result = self.invoke(hook, command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")

    def test_quoted_dash_c_path_with_spaces_fails_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        spaced_repo = self.repo.with_name("repo with spaces")
        self.repo.rename(spaced_repo)
        self.repo = spaced_repo

        # Git itself accepts the quoted path and reaches the real repository.
        git(self.repo, "push", "--dry-run", "A")
        self.assert_guarded(
            f'git -C "{self.repo}" push --dry-run A',
            "later push token",
        )

    def test_quoted_git_and_push_tokens_fail_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        git_path = shutil.which("git")
        self.assertIsNotNone(git_path)
        commands = (
            '"git" push --dry-run A',
            f"'{git_path}' push --dry-run A",
            'git "push" --dry-run A',
        )
        for command in commands:
            subprocess.run(
                ["bash", "-c", command],
                cwd=self.repo,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assert_guarded(command, "Noncanonical")

    def test_dangerous_long_option_abbreviations_fail_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        self.make_other_branch_pending()

        preview = git(self.repo, "push", "--dry-run", "--porcelain", "--br", "A")
        self.assertIn("refs/heads/other", preview.stdout + preview.stderr)
        self.assert_guarded("git push --dry-run --br A", "multiple branches or tags")

        deleted = git(
            self.repo, "push", "--dry-run", "--porcelain", "--del", "A", "main"
        )
        self.assertIn("[deleted]", deleted.stdout + deleted.stderr)
        self.assert_guarded("git push --dry-run --del A main", "deletes")
        self.assert_guarded("git push -nd A main", "deletes")

        for option, reason in (
            ("--al", "multiple branches or tags"),
            ("--mir", "deletes, prunes, or mirrors"),
            ("--pru", "deletes, prunes, or mirrors"),
            ("--ta", "multiple branches or tags"),
            ("--force-w", "Force push"),
            ("--force-with-l", "Force push"),
            ("--force-i", "Force push"),
            ("--force-if-i", "Force push"),
        ):
            self.assert_guarded(f"git push --dry-run {option} A", reason)

    def test_configured_alias_cannot_hide_multi_branch_push(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        self.make_other_branch_pending()
        git(self.repo, "config", "alias.pub", "push --branches")

        preview = git(self.repo, "pub", "--dry-run", "--porcelain", "A")
        self.assertIn("refs/heads/other", preview.stdout + preview.stderr)
        self.assert_guarded("git pub --dry-run A", "Configured Git alias")

    def test_pushurl_redirect_fails_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        git(self.repo, "config", "remote.A.pushurl", str(self.remote_b))

        preview = git(self.repo, "push", "--dry-run", "--porcelain", "A")
        self.assertIn("[new branch]", preview.stdout + preview.stderr)
        self.assert_guarded("git push A", "pushurl")

    def test_multiple_remote_urls_fail_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        git(self.repo, "config", "--add", "remote.A.url", str(self.remote_b))
        urls = git(self.repo, "remote", "get-url", "--push", "--all", "A")
        self.assertEqual(len(urls.stdout.splitlines()), 2)
        self.assert_guarded("git push A", "multiple fetch or push destinations")

    def test_push_instead_of_redirect_fails_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        git(
            self.repo,
            "config",
            f"url.{self.remote_b}.pushInsteadOf",
            str(self.remote_a),
        )
        preview = git(self.repo, "push", "--dry-run", "--porcelain", "A")
        self.assertIn("[new branch]", preview.stdout + preview.stderr)
        self.assert_guarded("git push A", "effective push URL differs")

    def test_remote_mirror_configuration_fails_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        self.make_other_branch_pending()
        git(self.repo, "config", "remote.A.mirror", "true")

        preview = git(self.repo, "push", "--dry-run", "--porcelain", "A")
        self.assertIn("refs/heads/other", preview.stdout + preview.stderr)
        self.assert_guarded("git push A", "configured as a mirror")

    def test_url_rewrite_scans_the_effective_destination(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        git(
            self.repo,
            "config",
            f"url.{self.remote_b}.insteadOf",
            str(self.remote_a),
        )

        preview = git(self.repo, "push", "--dry-run", "--porcelain", "A")
        self.assertIn("[new branch]", preview.stdout + preview.stderr)
        self.assert_guarded("git push A", "references a GitHub issue")

    def test_actual_remote_oid_wins_over_stale_tracking_ref(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        base_oid = git(self.repo, "rev-parse", "HEAD^").stdout.strip()
        local_tracking = git(self.repo, "rev-parse", "A/main").stdout.strip()
        self.assertEqual(local_tracking, git(self.repo, "rev-parse", "HEAD").stdout.strip())

        # Rewind the bare remote without fetching, leaving refs/remotes/A/main
        # stale at HEAD. The issue commit will be republished by the next push.
        git(self.remote_a, "update-ref", "refs/heads/main", base_oid)
        preview = git(self.repo, "push", "--dry-run", "--porcelain", "A")
        self.assertIn("refs/heads/main", preview.stdout + preview.stderr)
        self.assert_guarded("git push A", "references a GitHub issue")

    def test_recursive_submodule_push_modes_fail_closed(self) -> None:
        git(self.repo, "branch", "--set-upstream-to=A/main", "main")
        self.assert_guarded(
            "git push --recurse-submodules=on-demand A",
            "Recursive submodule pushing",
        )

        git(self.repo, "config", "push.recurseSubmodules", "on-demand")
        self.assert_guarded("git push A", "recursively push submodule")
        git(self.repo, "config", "--unset", "push.recurseSubmodules")
        git(self.repo, "config", "submodule.recurse", "true")
        self.assert_guarded("git push A", "recursively push submodule")


if __name__ == "__main__":
    unittest.main()
