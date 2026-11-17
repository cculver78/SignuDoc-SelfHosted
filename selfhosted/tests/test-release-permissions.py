#!/usr/bin/env python3
"""Check traversal permissions for an unrelated build account."""
import os
from pathlib import Path
import stat
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleasePermissions(unittest.TestCase):
    def test_installer_and_deployer_allow_build_traversal(self):
        installer = (ROOT / "selfhosted/scripts/install-prerequisites.sh").read_text()
        deploy = (ROOT / "selfhosted/scripts/deploy.sh").read_text()
        self.assertRegex(installer, r'install -d -o root -g signudoc -m 0751 /opt/signudoc /opt/signudoc/releases')
        self.assertRegex(deploy, r'install -d -o root -g signudoc -m 0751 "\$APP_ROOT" "\$RELEASES_DIR"')
        self.assertLess(deploy.index('install -d -o root -g signudoc -m 0751'), deploy.index('mktemp -d "$RELEASES_DIR/'))
        self.assertIn('chown signudoc-build:signudoc-build "$build_dir"', deploy)
        self.assertIn('chown -R root:signudoc "$build_dir"', deploy)
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "signudoc"
            releases = app / "releases"
            build = releases / ".build.test"
            build.mkdir(parents=True)
            for path in (app, releases):
                os.chmod(path, 0o751)
                mode = stat.S_IMODE(path.stat().st_mode)
                self.assertTrue(mode & stat.S_IXOTH)  # unrelated build account can traverse
                self.assertFalse(mode & (stat.S_IROTH | stat.S_IWOTH))
            os.chmod(build, 0o700)
            self.assertEqual(stat.S_IMODE(build.stat().st_mode), 0o700)
            self.assertTrue(build.is_dir())


if __name__ == "__main__":
    unittest.main()
