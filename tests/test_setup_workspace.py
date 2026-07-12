import os
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
                subject.ensure_repos()

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
                    subject.ensure_repos()
                with self.assertRaisesRegex(subject.WorkspaceError, "does not exist"):
                    subject.discover_repos(only_listed=True)

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
                    subject.ensure_repos()

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
                    subject.ensure_repos()

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
