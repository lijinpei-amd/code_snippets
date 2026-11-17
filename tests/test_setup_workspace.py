import contextlib
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import venv
from pathlib import Path
from unittest import mock

from workspace import setup_workspace as subject


class SetupWorkspaceTests(unittest.TestCase):
    def setUp(self):
        # Keep tests independent of the real repos.txt beside the script; tests
        # that need entries patch REPOS_LIST again.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        manifest = Path(tmp.name) / "repos.txt"
        manifest.write_text("")
        patcher = mock.patch.object(subject, "REPOS_LIST", manifest)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_initial_setup_without_force_rejects_any_existing_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "workspaces"
            empty = base / "empty"
            empty.mkdir(parents=True)
            workspace = base / "job"
            workspace.mkdir()
            marker = workspace / "keep"
            marker.write_text("keep")
            file_path = base / "file"
            file_path.write_text("keep file")

            with (
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(subject, "discover_repos", return_value=[]),
            ):
                for identifier in ("empty", "job", "file"):
                    with self.subTest(identifier=identifier):
                        with self.assertRaisesRegex(
                            subject.WorkspaceError, "use --force"
                        ):
                            subject.setup_workspace(identifier, base)

            self.assertEqual(list(empty.iterdir()), [])
            self.assertEqual(marker.read_text(), "keep")
            self.assertEqual(file_path.read_text(), "keep file")

    def test_force_clears_registrations_when_workspace_directory_is_gone(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "central" / "project"
            self.make_repo_with_origin_head(repo)
            base = root / "workspaces"
            workspace = base / "job"
            worktree = workspace / repo.name
            self.git("worktree", "add", "--detach", worktree, cwd=repo)
            shutil.rmtree(workspace)

            def run_git_only(cmd, **_kwargs):
                if cmd[0] == "git":
                    subprocess.run(cmd, check=True, capture_output=True)

            with (
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(subject, "discover_repos", return_value=[repo]),
                mock.patch.object(subject, "run", side_effect=run_git_only),
                mock.patch.object(subject, "validate_workspace_venv"),
                mock.patch.object(subject, "activate_venv"),
                mock.patch.object(subject, "post_setup"),
            ):
                subject.setup_workspace(
                    "job", base, force=True, run_venv_setup=False
                )

            self.assertEqual((worktree / "tracked").read_text(), "content\n")
            subject.validate_linked_worktree(worktree, repo)

    def test_update_force_flag_reaches_add_worktree(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp).resolve() / "workspaces"
            workspace = base / "job"
            workspace.mkdir(parents=True)
            repo = Path(tmp) / "central" / "project"
            argv = ["setup_workspace.py", "-u", "-f", "-p", str(base), "job"]

            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(subject, "discover_repos", return_value=[repo]),
                mock.patch.object(
                    subject, "add_worktree", return_value=None
                ) as add_worktree,
            ):
                subject.main()

            add_worktree.assert_called_once_with(workspace, repo, force=True)

    def test_invalid_identifiers_are_rejected_before_repo_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "workspaces"
            victim = root / "victim"
            victim.mkdir()
            marker = victim / "keep"
            marker.write_text("keep")

            invalid = [
                "",
                ".",
                "..",
                "nested/name",
                "name/",
                "./name",
                str(base / "absolute"),
                "bad\0name",
                "bad\nname",
                "bad\tname",
                "bad\x85name",
            ]
            with mock.patch.object(subject, "ensure_repos") as ensure_repos:
                for identifier in invalid:
                    with self.subTest(identifier=identifier):
                        with self.assertRaises(subject.WorkspaceError):
                            subject.setup_workspace(identifier, base, force=True)

            ensure_repos.assert_not_called()
            self.assertEqual(marker.read_text(), "keep")

    def test_workspace_symlink_is_rejected_before_repo_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "workspaces"
            outside = root / "outside"
            base.mkdir()
            outside.mkdir()
            (base / "redirect").symlink_to(outside, target_is_directory=True)

            with mock.patch.object(subject, "ensure_repos") as ensure_repos:
                with self.assertRaises(subject.WorkspaceError):
                    subject.setup_workspace("redirect", base, force=True)

            ensure_repos.assert_not_called()
            self.assertTrue(outside.is_dir())

    def test_relative_base_produces_absolute_git_worktree_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "central" / "project"
            repo.mkdir(parents=True)
            self.git("init", "--initial-branch=main", cwd=repo)
            old_cwd = Path.cwd()
            os.chdir(root)
            try:
                with (
                    mock.patch.object(subject, "ensure_repos"),
                    mock.patch.object(
                        subject, "discover_repos", side_effect=[[repo], [repo]]
                    ),
                    mock.patch.object(
                        subject, "find_default_upstream_ref", return_value="origin/main"
                    ),
                    mock.patch.object(subject, "run") as run,
                    mock.patch.object(subject, "validate_workspace_venv"),
                    mock.patch.object(subject, "activate_venv"),
                    mock.patch.object(subject, "post_setup"),
                ):
                    subject.setup_workspace(
                        "job", Path("relative-workspaces"), run_venv_setup=False
                    )
            finally:
                os.chdir(old_cwd)

            commands = [call.args[0] for call in run.call_args_list]
            worktree_command = next(cmd for cmd in commands if "worktree" in cmd)
            worktree_path = Path(worktree_command[-2])
            self.assertTrue(worktree_path.is_absolute())
            self.assertEqual(
                worktree_path,
                (root / "relative-workspaces" / "job" / "project").resolve(),
            )

    def test_worktree_registration_and_removal_support_newline_in_base_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "central" / "project"
            repo.mkdir(parents=True)
            self.git("init", "--initial-branch=main", cwd=repo)
            self.git("config", "user.name", "Workspace Test", cwd=repo)
            self.git("config", "user.email", "workspace@example.invalid", cwd=repo)
            (repo / "tracked").write_text("content\n")
            self.git("add", "tracked", cwd=repo)
            self.git("commit", "-m", "initial", cwd=repo)

            workspace = root / "base\nwith-newline" / "job"
            workspace.mkdir(parents=True)
            worktree = workspace / repo.name
            self.git("worktree", "add", "--detach", worktree, cwd=repo)

            self.assertIn(
                worktree.resolve(),
                subject.registered_worktree_paths(repo),
            )
            self.assertEqual(
                subject.remove_worktrees(workspace, [repo]),
                [worktree],
            )
            self.assertNotIn(
                worktree.resolve(),
                subject.registered_worktree_paths(repo),
            )
            self.assertFalse(worktree.exists())

    def test_force_removal_rejects_symlink_to_another_registered_worktree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "central" / "project"
            repo.mkdir(parents=True)
            self.git("init", "--initial-branch=main", cwd=repo)
            self.git("config", "user.name", "Workspace Test", cwd=repo)
            self.git("config", "user.email", "workspace@example.invalid", cwd=repo)
            (repo / "tracked").write_text("content\n")
            self.git("add", "tracked", cwd=repo)
            self.git("commit", "-m", "initial", cwd=repo)

            outside = root / "outside-worktree"
            self.git("worktree", "add", "--detach", outside, cwd=repo)
            dirty = outside / "keep-dirty"
            dirty.write_text("do not delete\n")

            workspace = root / "workspaces" / "job"
            workspace.mkdir(parents=True)
            redirected = workspace / repo.name
            redirected.symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(subject.WorkspaceError, "symbolic-link"):
                subject.remove_worktrees(workspace, [repo])

            self.assertTrue(redirected.is_symlink())
            self.assertEqual(dirty.read_text(), "do not delete\n")
            self.assertIn(outside.resolve(), subject.registered_worktree_paths(repo))

    def test_existing_clone_is_fetched_pruned_and_origin_head_refreshed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            remote = root / "remote.git"
            seed = root / "seed"
            repos = root / "repos"
            central = repos / "remote"
            repos_list = root / "repos.txt"

            self.git("init", "--bare", "--initial-branch=main", remote)
            self.git("init", "--initial-branch=main", seed)
            self.git("config", "user.name", "Workspace Test", cwd=seed)
            self.git("config", "user.email", "workspace@example.invalid", cwd=seed)
            (seed / "version").write_text("main\n")
            self.git("add", "version", cwd=seed)
            self.git("commit", "-m", "main", cwd=seed)
            self.git("remote", "add", "origin", remote, cwd=seed)
            self.git("push", "-u", "origin", "main", cwd=seed)

            repos.mkdir()
            self.git("clone", "--no-checkout", remote, central)
            self.assertEqual(
                self.git(
                    "symbolic-ref", "--short", "refs/remotes/origin/HEAD", cwd=central
                ).stdout.strip(),
                "origin/main",
            )

            self.git("checkout", "-b", "trunk", cwd=seed)
            (seed / "version").write_text("trunk\n")
            self.git("commit", "-am", "trunk", cwd=seed)
            self.git("push", "origin", "trunk", cwd=seed)
            self.git(
                f"--git-dir={remote}", "symbolic-ref", "HEAD", "refs/heads/trunk"
            )
            self.git("push", "origin", "--delete", "main", cwd=seed)
            trunk_commit = self.git("rev-parse", "HEAD", cwd=seed).stdout.strip()
            repos_list.write_text(f"{remote}\n")

            with (
                mock.patch.object(subject, "REPOS_DIR", repos),
                mock.patch.object(subject, "REPOS_LIST", repos_list),
            ):
                subject.ensure_repos(*subject.load_components())

            self.assertEqual(
                subject.find_default_upstream_ref(central),
                "origin/trunk",
            )
            self.assertEqual(
                self.git("rev-parse", "origin/trunk", cwd=central).stdout.strip(),
                trunk_commit,
            )
            stale_main = self.git(
                "show-ref",
                "--verify",
                "--quiet",
                "refs/remotes/origin/main",
                cwd=central,
                check=False,
            )
            self.assertNotEqual(stale_main.returncode, 0)

    def test_refresh_failure_is_fatal(self):
        repo = Path("central/project")
        failure = subprocess.CalledProcessError(1, ["git", "fetch"])
        with mock.patch.object(subject, "run", side_effect=failure):
            with self.assertRaisesRegex(subject.WorkspaceError, "failed to refresh"):
                subject.refresh_repo(repo)

    def test_missing_manifest_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repos = root / "repos"
            missing_manifest = root / "missing-repos.txt"

            with (
                mock.patch.object(subject, "REPOS_DIR", repos),
                mock.patch.object(subject, "REPOS_LIST", missing_manifest),
            ):
                with self.assertRaisesRegex(subject.WorkspaceError, "does not exist"):
                    subject.setup_workspace("job", root / "workspaces")

            self.assertFalse(repos.exists())

    def test_duplicate_manifest_basenames_are_rejected_before_repo_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repos = root / "repos"
            repos_list = root / "repos.txt"
            repos_list.write_text(
                "https://example.invalid/one/project.git\n"
                "https://example.invalid/two/project.git\n"
            )

            with (
                mock.patch.object(subject, "REPOS_DIR", repos),
                mock.patch.object(subject, "REPOS_LIST", repos_list),
            ):
                with self.assertRaisesRegex(
                    subject.WorkspaceError, "duplicate repository basename"
                ):
                    subject.ensure_repos(*subject.load_components())

            self.assertFalse(repos.exists())

    def test_existing_clone_origin_must_match_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repos = root / "repos"
            target = repos / "project"
            target.mkdir(parents=True)
            repos_list = root / "repos.txt"
            repos_list.write_text("https://example.invalid/expected/project.git\n")

            with (
                mock.patch.object(subject, "REPOS_DIR", repos),
                mock.patch.object(subject, "REPOS_LIST", repos_list),
                mock.patch.object(
                    subject,
                    "get_origin_url",
                    return_value="https://example.invalid/wrong/project.git",
                ),
                mock.patch.object(subject, "refresh_repo") as refresh_repo,
            ):
                with self.assertRaisesRegex(subject.WorkspaceError, "does not match"):
                    subject.ensure_repos(*subject.load_components())

            refresh_repo.assert_not_called()

    def test_existing_project_directory_must_be_registered_to_expected_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            repo = root / "central" / "project"
            (workspace / "project").mkdir(parents=True)
            repo.mkdir(parents=True)

            with (
                mock.patch.object(
                    subject, "registered_worktree_paths", return_value=set()
                ),
                mock.patch.object(subject, "run") as run,
            ):
                with self.assertRaisesRegex(subject.WorkspaceError, "not a worktree"):
                    subject.add_worktree(workspace, repo)

            run.assert_not_called()

    def test_add_worktree_force_recovers_missing_registration_without_pruning_siblings(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "central" / "project"
            self.make_repo_with_origin_head(repo)

            workspace = root / "workspaces" / "job"
            workspace.mkdir(parents=True)
            worktree = workspace / repo.name
            sibling = root / "workspaces" / "sibling" / repo.name
            self.git("worktree", "add", "--detach", worktree, cwd=repo)
            self.git("worktree", "lock", worktree, cwd=repo)
            self.git("worktree", "add", "--detach", sibling, cwd=repo)
            shutil.rmtree(worktree)
            shutil.rmtree(sibling)

            with self.assertRaisesRegex(subject.WorkspaceError, "rerun with --force"):
                subject.add_worktree(workspace, repo)
            self.assertIn(worktree.resolve(), subject.registered_worktree_paths(repo))

            self.assertEqual(
                subject.add_worktree(workspace, repo, force=True), "project"
            )

            self.assertEqual((worktree / "tracked").read_text(), "content\n")
            subject.validate_linked_worktree(worktree, repo)
            self.assertIn(
                sibling.resolve(), subject.registered_worktree_paths(repo)
            )
            self.assertFalse(sibling.exists())
            self.assertEqual(subject.pending_projects(workspace), {"project"})

    def test_stale_registration_does_not_authenticate_replacement_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "central" / "project"
            workspace = root / "workspaces" / "job"
            worktree = workspace / repo.name
            repo.mkdir(parents=True)
            workspace.mkdir(parents=True)
            self.git("init", "--initial-branch=main", cwd=repo)
            self.git("config", "user.name", "Workspace Test", cwd=repo)
            self.git("config", "user.email", "workspace@example.invalid", cwd=repo)
            (repo / "tracked").write_text("content\n")
            self.git("add", "tracked", cwd=repo)
            self.git("commit", "-m", "initial", cwd=repo)
            self.git("worktree", "add", "--detach", worktree, cwd=repo)

            shutil.rmtree(worktree)
            worktree.mkdir()
            self.git("init", "--initial-branch=main", cwd=worktree)
            marker = worktree / "unrelated"
            marker.write_text("preserve me\n")
            self.assertIn(
                worktree.resolve(), subject.registered_worktree_paths(repo)
            )

            with self.assertRaisesRegex(
                subject.WorkspaceError, "not expected repository"
            ):
                subject.add_worktree(workspace, repo)

            base = workspace.parent
            with (
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(
                    subject, "discover_repos", return_value=[repo]
                ),
            ):
                with self.assertRaisesRegex(
                    subject.WorkspaceError, "not expected repository"
                ):
                    subject.update_workspace(workspace.name, base)

            self.assertEqual(marker.read_text(), "preserve me\n")

    def test_force_removal_preserves_directory_replacing_stale_worktree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "central" / "project"
            workspace = root / "workspaces" / "job"
            worktree = workspace / repo.name
            repo.mkdir(parents=True)
            workspace.mkdir(parents=True)
            self.git("init", "--initial-branch=main", cwd=repo)
            self.git("config", "user.name", "Workspace Test", cwd=repo)
            self.git("config", "user.email", "workspace@example.invalid", cwd=repo)
            (repo / "tracked").write_text("content\n")
            self.git("add", "tracked", cwd=repo)
            self.git("commit", "-m", "initial", cwd=repo)
            self.git("worktree", "add", "--detach", worktree, cwd=repo)

            shutil.rmtree(worktree)
            worktree.mkdir()
            self.git("init", "--initial-branch=main", cwd=workspace)
            marker = worktree / "unrelated"
            marker.write_text("preserve me\n")

            with self.assertRaisesRegex(subject.WorkspaceError, "Git top-level"):
                subject.remove_worktrees(workspace, [repo])

            self.assertEqual(marker.read_text(), "preserve me\n")
            self.assertIn(
                worktree.resolve(), subject.registered_worktree_paths(repo)
            )

    def test_existing_aiter_worktree_initializes_recursive_submodules(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            repo = root / "central" / "aiter"
            worktree = workspace / "aiter"
            worktree.mkdir(parents=True)
            repo.mkdir(parents=True)

            with (
                mock.patch.object(
                    subject,
                    "registered_worktree_paths",
                    return_value={worktree.resolve()},
                ),
                mock.patch.object(subject, "validate_linked_worktree"),
                mock.patch.object(subject, "run") as run,
            ):
                self.assertIsNone(subject.add_worktree(workspace, repo))

            run.assert_called_once_with([
                "git", "-C", str(worktree),
                "submodule", "update", "--init", "--recursive",
            ])

    def test_aiter_submodule_failure_remains_pending_and_update_builds_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "workspaces"
            workspace = base / "job"
            worktree = workspace / "aiter"
            repo = root / "central" / "aiter"
            scripts = root / "build-scripts"
            workspace.mkdir(parents=True)
            repo.mkdir(parents=True)
            self.git("init", "--initial-branch=main", cwd=repo)
            scripts.mkdir()
            script = scripts / "01-aiter.sh"
            script.write_text("#!/usr/bin/env bash\n")
            python = workspace / "venv" / "bin" / "python"
            venv.EnvBuilder(with_pip=False).create(python.parents[1])

            def fail_submodule_init(command, **_kwargs):
                if "worktree" in command:
                    worktree.mkdir()
                    return
                raise subprocess.CalledProcessError(1, command)

            with (
                mock.patch.object(
                    subject, "find_default_upstream_ref", return_value="origin/main"
                ),
                mock.patch.object(subject, "run", side_effect=fail_submodule_init),
            ):
                with self.assertRaises(subprocess.CalledProcessError):
                    subject.add_worktree(workspace, repo)

            self.assertEqual(subject.pending_projects(workspace), {"aiter"})

            with (
                mock.patch.object(subject, "BUILD_SCRIPTS_DIR", scripts),
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(subject, "discover_repos", return_value=[repo]),
                mock.patch.object(
                    subject,
                    "registered_worktree_paths",
                    return_value={worktree.resolve()},
                ),
                mock.patch.object(subject, "validate_linked_worktree"),
                mock.patch.object(subject, "activate_venv"),
                mock.patch.object(subject, "run") as run,
            ):
                subject.update_workspace("job", base)

            self.assertEqual(
                [call.args[0] for call in run.call_args_list],
                [
                    [
                        "git", "-C", str(worktree),
                        "submodule", "update", "--init", "--recursive",
                    ],
                    [
                        "bash", str(script), str(worktree),
                        str(workspace / "build" / "aiter"),
                        str(workspace / "install" / "aiter"),
                    ],
                ],
            )
            self.assertEqual(subject.pending_projects(workspace), set())

    def test_failed_project_build_is_retried_by_update(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "workspaces"
            workspace = base / "job"
            source = workspace / "triton"
            repo = root / "central" / "triton"
            scripts = root / "build-scripts"
            source.mkdir(parents=True)
            repo.mkdir(parents=True)
            scripts.mkdir()
            script = scripts / "01-triton.sh"
            script.write_text("#!/usr/bin/env bash\n")
            python = workspace / "venv" / "bin" / "python"
            venv.EnvBuilder(with_pip=False).create(python.parents[1])

            failure = subprocess.CalledProcessError(1, ["bash", str(script)])
            with (
                mock.patch.object(subject, "BUILD_SCRIPTS_DIR", scripts),
                mock.patch.object(subject, "run", side_effect=failure),
            ):
                with self.assertRaises(subprocess.CalledProcessError):
                    subject.post_setup(workspace, only_projects={"triton"})

            self.assertEqual(subject.pending_projects(workspace), {"triton"})

            with (
                mock.patch.object(subject, "BUILD_SCRIPTS_DIR", scripts),
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(subject, "discover_repos", return_value=[repo]),
                mock.patch.object(
                    subject,
                    "registered_worktree_paths",
                    return_value={source.resolve()},
                ),
                mock.patch.object(subject, "validate_linked_worktree"),
                mock.patch.object(subject, "activate_venv"),
                mock.patch.object(subject, "run") as run,
            ):
                subject.update_workspace("job", base)

            run.assert_called_once_with([
                "bash", str(script), str(source),
                str(workspace / "build" / "triton"),
                str(workspace / "install" / "triton"),
            ])
            self.assertEqual(subject.pending_projects(workspace), set())

    def test_update_refuses_build_without_workspace_virtual_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "workspaces"
            workspace = base / "job"
            source = workspace / "triton"
            repo = root / "central" / "triton"
            source.mkdir(parents=True)
            repo.mkdir(parents=True)
            subject.mark_projects_pending(workspace, {"triton"})

            with (
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(subject, "discover_repos", return_value=[repo]),
                mock.patch.object(
                    subject,
                    "registered_worktree_paths",
                    return_value={source.resolve()},
                ),
                mock.patch.object(subject, "validate_linked_worktree"),
                mock.patch.object(subject, "activate_venv") as activate_venv,
                mock.patch.object(subject, "post_setup") as post_setup,
            ):
                with self.assertRaisesRegex(
                    subject.WorkspaceError, "virtual environment.*missing"
                ):
                    subject.update_workspace("job", base)

            activate_venv.assert_not_called()
            post_setup.assert_not_called()
            self.assertEqual(subject.pending_projects(workspace), {"triton"})

    def test_real_workspace_virtual_environment_is_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            venv_path = Path(tmp) / "venv"
            venv.EnvBuilder(with_pip=False).create(venv_path)

            self.assertEqual(
                subject.validate_workspace_venv(venv_path),
                venv_path / "bin" / "python",
            )

    def test_initial_setup_validates_venv_before_activation(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "workspaces"
            failure = subject.WorkspaceError("invalid workspace venv")
            with (
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(subject, "discover_repos", side_effect=[[], []]),
                mock.patch.object(subject, "run"),
                mock.patch.object(
                    subject, "validate_workspace_venv", side_effect=failure
                ),
                mock.patch.object(subject, "activate_venv") as activate_venv,
                mock.patch.object(subject, "post_setup") as post_setup,
            ):
                with self.assertRaisesRegex(subject.WorkspaceError, "invalid"):
                    subject.setup_workspace(
                        "job", base, run_venv_setup=False
                    )

            activate_venv.assert_not_called()
            post_setup.assert_not_called()

    def test_update_rejects_python_that_reports_a_different_prefix(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "workspaces"
            workspace = base / "job"
            source = workspace / "triton"
            repo = root / "central" / "triton"
            source.mkdir(parents=True)
            repo.mkdir(parents=True)
            subject.mark_projects_pending(workspace, {"triton"})

            venv_path = workspace / "venv"
            fake_python = venv_path / "bin" / "python"
            fake_python.parent.mkdir(parents=True)
            (venv_path / "pyvenv.cfg").write_text("home = fake\n")
            fake_python.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                f"print({subject._VENV_PREFIX_MARKER!r} + "
                "json.dumps(os.path.realpath(sys.prefix)))\n"
            )
            fake_python.chmod(0o755)

            with (
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(subject, "discover_repos", return_value=[repo]),
                mock.patch.object(
                    subject,
                    "registered_worktree_paths",
                    return_value={source.resolve()},
                ),
                mock.patch.object(subject, "validate_linked_worktree"),
                mock.patch.object(subject, "activate_venv") as activate_venv,
                mock.patch.object(subject, "post_setup") as post_setup,
            ):
                with self.assertRaisesRegex(
                    subject.WorkspaceError, "resolves to.*refusing"
                ):
                    subject.update_workspace("job", base)

            activate_venv.assert_not_called()
            post_setup.assert_not_called()
            self.assertEqual(subject.pending_projects(workspace), {"triton"})

    def test_force_does_not_remove_workspace_if_any_listing_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "workspaces"
            workspace = base / "job"
            workspace.mkdir(parents=True)
            marker = workspace / "keep"
            marker.write_text("keep")
            repos = [Path(tmp) / "repo-one", Path(tmp) / "repo-two"]
            list_results = [
                subprocess.CompletedProcess(
                    [], 0, stdout=f"worktree {workspace / 'repo-one'}\0", stderr=""
                ),
                subprocess.CompletedProcess([], 128, stdout="", stderr="cannot inspect"),
            ]

            with (
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(
                    subject, "discover_repos", side_effect=[repos, []]
                ),
                mock.patch.object(
                    subject.subprocess, "run", side_effect=list_results
                ) as run,
            ):
                with self.assertRaisesRegex(subject.WorkspaceError, "failed to list"):
                    subject.setup_workspace("job", base, force=True)

            self.assertEqual(marker.read_text(), "keep")
            self.assertEqual(run.call_count, 2)
            self.assertTrue(all("list" in call.args[0] for call in run.call_args_list))

    def test_force_does_not_remove_workspace_after_worktree_remove_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "workspaces"
            workspace = base / "job"
            workspace.mkdir(parents=True)
            marker = workspace / "keep"
            marker.write_text("keep")
            repo = Path(tmp) / "project"
            results = [
                subprocess.CompletedProcess(
                    [], 0, stdout=f"worktree {workspace / repo.name}\0", stderr=""
                ),
                subprocess.CompletedProcess([], 1, stdout="", stderr="remove denied"),
            ]

            with (
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(
                    subject, "discover_repos", side_effect=[[repo], []]
                ),
                mock.patch.object(subject.subprocess, "run", side_effect=results),
            ):
                with self.assertRaisesRegex(subject.WorkspaceError, "failed to remove"):
                    subject.setup_workspace("job", base, force=True)

            self.assertEqual(marker.read_text(), "keep")

    def test_force_does_not_remove_workspace_if_deregistration_did_not_happen(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "workspaces"
            workspace = base / "job"
            workspace.mkdir(parents=True)
            marker = workspace / "keep"
            marker.write_text("keep")
            repo = Path(tmp) / "project"
            registration = f"worktree {workspace / repo.name}\0"
            results = [
                subprocess.CompletedProcess([], 0, stdout=registration, stderr=""),
                subprocess.CompletedProcess([], 0, stdout="", stderr=""),
                subprocess.CompletedProcess([], 0, stdout=registration, stderr=""),
            ]

            with (
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(
                    subject, "discover_repos", side_effect=[[repo], []]
                ),
                mock.patch.object(subject.subprocess, "run", side_effect=results),
            ):
                with self.assertRaisesRegex(subject.WorkspaceError, "still registered"):
                    subject.setup_workspace("job", base, force=True)

            self.assertEqual(marker.read_text(), "keep")

    def test_triton_build_script_pins_uv_to_clean_workspace_venv(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "triton"
            fake_bin = root / "bin"
            log = root / "uv.log"
            workspace_venv = root / "workspace-venv"
            venv_python = workspace_venv / "bin" / "python"
            source.mkdir()
            fake_bin.mkdir()
            venv_python.parent.mkdir(parents=True)
            (workspace_venv / "pyvenv.cfg").write_text("home = test\n")
            venv_python.write_text("#!/usr/bin/env bash\nexit 0\n")
            venv_python.chmod(0o755)
            fake_uv = fake_bin / "uv"
            fake_uv.write_text(
                "#!/usr/bin/env bash\n"
                "dangerous=(\n"
                "  UV_SYSTEM_PYTHON UV_TARGET UV_PREFIX UV_PYTHON\n"
                "  UV_PROJECT_ENVIRONMENT UV_WORKING_DIR UV_PROJECT\n"
                "  PIP_TARGET PIP_PREFIX PIP_ROOT PIP_USER PIP_PYTHON_PATH\n"
                "  PYTHONHOME PYTHONUSERBASE\n"
                ")\n"
                "for name in \"${dangerous[@]}\"; do\n"
                "  if [[ -v $name ]]; then\n"
                "    printf 'leaked environment override: %s\\n' \"$name\" >&2\n"
                "    exit 86\n"
                "  fi\n"
                "done\n"
                "printf '%s\\0' \"$@\" >> \"$UV_LOG\"\n"
                "printf '\\n' >> \"$UV_LOG\"\n"
            )
            fake_uv.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            env["UV_LOG"] = str(log)
            env["VIRTUAL_ENV"] = str(workspace_venv)
            for name in (
                "UV_SYSTEM_PYTHON",
                "UV_TARGET",
                "UV_PREFIX",
                "UV_PYTHON",
                "UV_PROJECT_ENVIRONMENT",
                "UV_WORKING_DIR",
                "UV_PROJECT",
                "PIP_TARGET",
                "PIP_PREFIX",
                "PIP_ROOT",
                "PIP_USER",
                "PIP_PYTHON_PATH",
                "PYTHONHOME",
                "PYTHONUSERBASE",
            ):
                env[name] = str(root / f"override-{name.lower()}")

            subprocess.run(
                [
                    "bash",
                    str(Path(subject.__file__).parent / "build" / "01-triton.sh"),
                    str(source),
                ],
                check=True,
                env=env,
            )

            calls = [
                line.split(b"\0")[:-1]
                for line in log.read_bytes().splitlines()
            ]
            self.assertEqual(
                calls,
                [
                    [
                        b"--no-config",
                        b"pip",
                        b"install",
                        b"--python",
                        os.fsencode(venv_python),
                        b"nanobind==2.10.2",
                    ],
                    [
                        b"--no-config",
                        b"pip",
                        b"install",
                        b"--python",
                        os.fsencode(venv_python),
                        b"-e",
                        b".",
                        b"--no-build-isolation",
                    ],
                ],
            )

    def test_triton_build_script_requires_workspace_venv(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "triton"
            fake_bin = root / "bin"
            marker = root / "uv-was-called"
            source.mkdir()
            fake_bin.mkdir()
            fake_uv = fake_bin / "uv"
            fake_uv.write_text(
                "#!/usr/bin/env bash\n"
                f"touch {str(marker)!r}\n"
            )
            fake_uv.chmod(0o755)
            env = os.environ.copy()
            env.pop("VIRTUAL_ENV", None)
            env["PATH"] = f"{fake_bin}:{env['PATH']}"

            result = subprocess.run(
                [
                    "bash",
                    str(Path(subject.__file__).parent / "build" / "01-triton.sh"),
                    str(source),
                ],
                check=False,
                text=True,
                capture_output=True,
                env=env,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("workspace virtual environment is required", result.stderr)
            self.assertFalse(marker.exists())

    def test_llvm_build_script_yaml_quotes_compilation_database_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "llvm: project # it's"
            fake_bin = root / "bin"
            source.mkdir()
            fake_bin.mkdir()
            fake_cmake = fake_bin / "cmake"
            fake_cmake.write_text("#!/usr/bin/env bash\nexit 0\n")
            fake_cmake.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"

            subprocess.run(
                [
                    "bash",
                    str(
                        Path(subject.__file__).parent
                        / "build"
                        / "01-llvm-project.sh"
                    ),
                    str(source),
                ],
                check=True,
                env=env,
            )

            yaml_path = str(source / "build").replace("'", "''")
            self.assertEqual(
                (source / ".clangd").read_text(),
                "CompileFlags:\n"
                f"  CompilationDatabase: '{yaml_path}'\n",
            )

    def write_two_repo_manifest(self, root):
        repos_list = root / "repos.txt"
        repos_list.write_text(
            "https://example.invalid/org/alpha.git\n"
            "https://example.invalid/org/beta.git\n"
        )
        return repos_list

    @staticmethod
    def make_central_dir(root, *names):
        """Create stand-in central clones that discover_repos recognizes."""
        central = root / "central"
        for name in names:
            (central / name / ".git").mkdir(parents=True)
        return central

    def test_component_option_is_repeatable_and_comma_separated(self):
        for mode_args, target in (([], "setup_workspace"), (["-u"], "update_workspace")):
            argv = [
                "setup_workspace.py", *mode_args,
                "-c", "alpha,beta", "--components", "gamma",
                "--component", "delta", "job",
            ]
            with self.subTest(target=target):
                with (
                    mock.patch.object(sys, "argv", argv),
                    mock.patch.object(subject, target) as entry,
                ):
                    subject.main()

                self.assertEqual(
                    entry.call_args.kwargs["components"],
                    ["alpha", "beta", "gamma", "delta"],
                )

    def test_component_option_rejects_empty_name(self):
        argv = ["setup_workspace.py", "-c", "alpha,", "job"]
        with (
            mock.patch.object(sys, "argv", argv),
            mock.patch.object(subject, "setup_workspace") as setup,
            mock.patch("sys.stderr"),
        ):
            with self.assertRaises(SystemExit):
                subject.main()
        setup.assert_not_called()

    def test_unknown_component_is_rejected_before_repo_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "workspaces"
            base.mkdir()
            repos_list = self.write_two_repo_manifest(root)

            with (
                mock.patch.object(subject, "REPOS_LIST", repos_list),
                mock.patch.object(subject, "ensure_repos") as ensure_repos,
            ):
                for entry in (subject.setup_workspace, subject.update_workspace):
                    with self.subTest(entry=entry.__name__):
                        (base / "job").mkdir(exist_ok=True)
                        with self.assertRaisesRegex(
                            subject.WorkspaceError, "unknown component.*gamma"
                        ):
                            entry("job", base, force=True, components=["gamma"])

            ensure_repos.assert_not_called()

    def test_ensure_repos_only_clones_selected_components(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repos = root / "repos"
            repos_list = self.write_two_repo_manifest(root)

            with (
                mock.patch.object(subject, "REPOS_DIR", repos),
                mock.patch.object(subject, "REPOS_LIST", repos_list),
                mock.patch.object(subject, "clone_detached") as clone,
            ):
                subject.ensure_repos(*subject.load_components(["beta"]))

            clone.assert_called_once_with(
                "https://example.invalid/org/beta.git", repos / "beta"
            )

    def test_setup_with_component_adds_only_selected_worktree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "workspaces"
            repos_list = self.write_two_repo_manifest(root)
            central = self.make_central_dir(root, "alpha", "beta")
            beta = central / "beta"

            with (
                mock.patch.object(subject, "REPOS_LIST", repos_list),
                mock.patch.object(subject, "REPOS_DIR", central),
                mock.patch.object(
                    subject, "read_repo_manifest",
                    wraps=subject.read_repo_manifest,
                ) as read_manifest,
                mock.patch.object(subject, "ensure_repos") as ensure_repos,
                mock.patch.object(subject, "add_worktree") as add_worktree,
                mock.patch.object(subject, "run"),
                mock.patch.object(subject, "validate_workspace_venv"),
                mock.patch.object(subject, "activate_venv"),
                mock.patch.object(subject, "post_setup") as post_setup,
            ):
                subject.setup_workspace(
                    "job", base, run_venv_setup=False, components=["beta"]
                )

            read_manifest.assert_called_once_with()
            self.assertEqual(ensure_repos.call_args.args[1], {"beta"})
            add_worktree.assert_called_once_with(base.resolve() / "job", beta)
            post_setup.assert_called_once_with(
                base.resolve() / "job", only_projects={"beta"}
            )

    def test_update_with_component_leaves_other_pending_builds(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "workspaces"
            workspace = (base / "job")
            scripts = root / "build-scripts"
            scripts.mkdir()
            for name in ("alpha", "beta"):
                (workspace / name).mkdir(parents=True)
                (scripts / f"01-{name}.sh").write_text("#!/usr/bin/env bash\n")
            workspace = workspace.resolve()
            repos_list = self.write_two_repo_manifest(root)
            central = self.make_central_dir(root, "alpha", "beta")
            beta = central / "beta"
            subject.mark_projects_pending(workspace, {"alpha", "beta"})

            output = io.StringIO()
            with (
                mock.patch.object(subject, "REPOS_LIST", repos_list),
                mock.patch.object(subject, "REPOS_DIR", central),
                mock.patch.object(subject, "BUILD_SCRIPTS_DIR", scripts),
                mock.patch.object(subject, "ensure_repos"),
                mock.patch.object(
                    subject, "add_worktree", return_value=None
                ) as add_worktree,
                mock.patch.object(subject, "validate_workspace_venv"),
                mock.patch.object(subject, "activate_venv"),
                mock.patch.object(subject, "run") as run,
                contextlib.redirect_stdout(output),
            ):
                subject.update_workspace("job", base, components=["beta"])

            add_worktree.assert_called_once_with(workspace, beta, force=False)
            run.assert_called_once_with([
                "bash", str(scripts / "01-beta.sh"), str(workspace / "beta"),
                str(workspace / "build" / "beta"),
                str(workspace / "install" / "beta"),
            ])
            self.assertEqual(subject.pending_projects(workspace), {"alpha"})
            self.assertIn("pending outside --components: alpha", output.getvalue())

    def test_empty_component_selection_is_rejected(self):
        with self.assertRaisesRegex(subject.WorkspaceError, "no components"):
            subject.load_components([])

    def test_ensure_repos_verifies_unselected_clones_without_refreshing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repos = root / "repos"
            (repos / "alpha").mkdir(parents=True)
            repos_list = self.write_two_repo_manifest(root)

            with (
                mock.patch.object(subject, "REPOS_DIR", repos),
                mock.patch.object(subject, "REPOS_LIST", repos_list),
                mock.patch.object(
                    subject,
                    "get_origin_url",
                    return_value="https://example.invalid/wrong/alpha.git",
                ),
                mock.patch.object(subject, "refresh_repo") as refresh_repo,
                mock.patch.object(subject, "clone_detached") as clone,
            ):
                with self.assertRaisesRegex(subject.WorkspaceError, "does not match"):
                    subject.ensure_repos(*subject.load_components(["beta"]))

            refresh_repo.assert_not_called()
            clone.assert_not_called()

    def make_workspace_with_two_worktrees(self, root):
        """Return (base, workspace, {name: (repo, worktree)}) with clean worktrees."""
        base = root / "workspaces"
        workspace = base / "job"
        workspace.mkdir(parents=True)
        projects = {}
        for name in ("alpha", "beta"):
            repo = root / "central" / name
            self.make_repo_with_origin_head(repo)
            # Leave only origin/main so local branches don't hide lost commits.
            self.git("checkout", "--detach", cwd=repo)
            self.git("branch", "-D", "main", cwd=repo)
            worktree = workspace / name
            self.git("worktree", "add", "--detach", worktree, "origin/main", cwd=repo)
            projects[name] = (repo, worktree)
        return base, workspace, projects

    def force_setup(self, base, repos):
        with (
            mock.patch.object(subject, "ensure_repos"),
            mock.patch.object(subject, "discover_repos", return_value=repos),
            mock.patch.object(subject, "add_worktree"),
            mock.patch.object(subject, "run"),
            mock.patch.object(subject, "validate_workspace_venv"),
            mock.patch.object(subject, "activate_venv"),
            mock.patch.object(subject, "post_setup"),
        ):
            subject.setup_workspace("job", base, force=True, run_venv_setup=False)

    def test_force_refuses_to_remove_worktrees_with_unsaved_work(self):
        def modify_tracked(worktree):
            (worktree / "tracked").write_text("edited\n")

        def stage_change(worktree):
            modify_tracked(worktree)
            self.git("add", "tracked", cwd=worktree)

        def add_untracked(worktree):
            (worktree / "notes.txt").write_text("draft\n")

        def commit_detached(worktree):
            self.git("config", "user.name", "Workspace Test", cwd=worktree)
            self.git(
                "config", "user.email", "workspace@example.invalid", cwd=worktree
            )
            self.git("commit", "--allow-empty", "-m", "wip", cwd=worktree)

        cases = {
            "modified": (modify_tracked, "uncommitted"),
            "staged": (stage_change, "uncommitted"),
            "untracked": (add_untracked, "uncommitted"),
            "detached commit": (commit_detached, "1 commit"),
        }
        for label, (make_work, message) in cases.items():
            with self.subTest(label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                base, workspace, projects = self.make_workspace_with_two_worktrees(root)
                marker = workspace / "keep"
                marker.write_text("keep")
                beta_repo, beta_worktree = projects["beta"]
                make_work(beta_worktree)

                with self.assertRaisesRegex(
                    subject.WorkspaceError,
                    f"unsaved work:\n  {re.escape(str(beta_worktree))}: {message}",
                ):
                    self.force_setup(base, [repo for repo, _ in projects.values()])

                self.assertEqual(marker.read_text(), "keep")
                for repo, worktree in projects.values():
                    self.assertTrue(worktree.is_dir())
                    self.assertIn(
                        worktree.resolve(), subject.registered_worktree_paths(repo)
                    )

    def test_force_removes_worktree_whose_commits_are_on_a_branch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base, workspace, projects = self.make_workspace_with_two_worktrees(root)
            beta_repo, beta_worktree = projects["beta"]
            self.git("config", "user.name", "Workspace Test", cwd=beta_worktree)
            self.git(
                "config", "user.email", "workspace@example.invalid", cwd=beta_worktree
            )
            self.git("switch", "-c", "feature", cwd=beta_worktree)
            self.git("commit", "--allow-empty", "-m", "saved", cwd=beta_worktree)
            feature = self.git("rev-parse", "HEAD", cwd=beta_worktree).stdout.strip()

            self.force_setup(base, [repo for repo, _ in projects.values()])

            self.assertFalse(beta_worktree.exists())
            self.assertEqual(
                self.git("rev-parse", "feature", cwd=beta_repo).stdout.strip(),
                feature,
            )

    def make_repo_with_origin_head(self, repo):
        """Create a one-commit repo whose origin/HEAD points at origin/main."""
        repo.mkdir(parents=True)
        self.git("init", "--initial-branch=main", cwd=repo)
        self.git("config", "user.name", "Workspace Test", cwd=repo)
        self.git("config", "user.email", "workspace@example.invalid", cwd=repo)
        (repo / "tracked").write_text("content\n")
        self.git("add", "tracked", cwd=repo)
        self.git("commit", "-m", "initial", cwd=repo)
        self.git("update-ref", "refs/remotes/origin/main", "HEAD", cwd=repo)
        self.git(
            "symbolic-ref", "refs/remotes/origin/HEAD",
            "refs/remotes/origin/main", cwd=repo,
        )

    @staticmethod
    def git(*args, cwd=None, check=True):
        return subprocess.run(
            ["git", *(str(arg) for arg in args)],
            cwd=cwd,
            check=check,
            capture_output=True,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
