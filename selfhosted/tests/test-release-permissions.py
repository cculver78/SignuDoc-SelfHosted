#!/usr/bin/env python3
"""Regression checks for deployment directory access and ownership."""
import os
from pathlib import Path
import pwd
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleasePermissions(unittest.TestCase):
    def test_scripts_repair_only_the_two_parent_directories(self):
        installer = (ROOT / "selfhosted/scripts/install-prerequisites.sh").read_text()
        deploy = (ROOT / "selfhosted/scripts/deploy.sh").read_text()
        self.assertIn('install -d -o signudoc-deploy -g signudoc-deploy -m 0755 /opt/signudoc\n', installer)
        self.assertIn('install -d -o root -g signudoc -m 0755 /opt/signudoc/releases\n', installer)
        app = 'install -d -o signudoc-deploy -g signudoc-deploy -m 0755 "$APP_ROOT"'
        releases = 'install -d -o root -g signudoc -m 0755 "$RELEASES_DIR"'
        self.assertIn(app, deploy)
        self.assertIn(releases, deploy)
        self.assertLess(deploy.index(app), deploy.index(releases))
        self.assertLess(deploy.index(releases), deploy.index('mktemp -d "$RELEASES_DIR/'))
        self.assertIn('chown signudoc-build:signudoc-build "$build_dir"', deploy)
        self.assertIn('chown -R root:signudoc "$build_dir"', deploy)
        self.assertIn('find "$build_dir" -type d -exec chmod 0750 {} +', deploy)

    def test_setup_is_idempotent_and_does_not_change_release_contents(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "signudoc"
            releases = app / "releases"
            completed = releases / "completed"
            completed.mkdir(parents=True)
            completed.chmod(0o750)
            app.chmod(0o750)
            releases.chmod(0o751)
            # Execute the same install operations with the test user's IDs.
            for _ in range(2):
                for directory in (app, releases):
                    subprocess.run(["install", "-d", "-m", "0755", str(directory)], check=True)
                self.assertEqual(stat.S_IMODE(app.stat().st_mode), 0o755)
                self.assertEqual(stat.S_IMODE(releases.stat().st_mode), 0o755)
                self.assertEqual(stat.S_IMODE(completed.stat().st_mode), 0o750)
                self.assertFalse(releases.stat().st_mode & stat.S_IWOTH)

    @unittest.skipUnless(os.geteuid() == 0, "requires root to switch to an unrelated account")
    def test_unrelated_account_can_list_and_traverse_but_not_write(self):
        nobody = pwd.getpwnam("nobody")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            root.chmod(0o755)
            app = root / "signudoc"
            releases = app / "releases"
            build = releases / ".build-test"
            build.mkdir(parents=True)
            app.chmod(0o755)
            releases.chmod(0o755)
            os.chown(build, nobody.pw_uid, nobody.pw_gid)
            build.chmod(0o700)
            def drop_privileges():
                os.setgroups([])
                os.setgid(nobody.pw_gid)
                os.setuid(nobody.pw_uid)
            result = subprocess.run(
                ["sh", "-c", 'ls "$1" >/dev/null && ls "$2" >/dev/null && cd "$3" && test ! -w "$2"', "sh", str(app), str(releases), str(build)],
                preexec_fn=drop_privileges, check=False,
            )
            self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
