"""Tests for install.sh: install, upgrade, downgrade, build marking, restart.

    python3 -m unittest tests/test_install.py

Each test copies the scripts into a fresh git repo tagged like a release and
installs into a temporary HOME. Dependencies and systemctl are stubs on PATH.
The restart tests run the real app (offscreen) against tests/fake-dac-rate.
"""
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
FILES = ["install.sh", "dac-rate", "dac-rate-gui", "dac-rate.desktop"]
VERSION = re.search(r"^VERSION=(\S+)", (REPO / "dac-rate").read_text(), re.M).group(1)
UNIT = r"app-dac\x2drate\x2dgui@autostart.service"

STUBS = {
    "wireplumber": 'echo "Compiled with libwireplumber 0.5.10"; echo "Linked with libwireplumber 0.5.10"',
    "pw-dump": "exit 0", "pw-cat": "exit 0", "pw-metadata": "exit 0", "update-desktop-database": "exit 0",
    # Logs its arguments; the unit counts as active while $FAKE_UNIT_ACTIVE exists.
    "systemctl": 'echo "$*" >>"$SYSTEMCTL_LOG"\n'
                 'case "$*" in *is-active*) [ -e "$FAKE_UNIT_ACTIVE" ] ;; *) exit 0 ;; esac',
}


def gui_pids(gui):
    """PIDs whose command line is python3 <gui> ..."""
    pids = []
    for f in Path("/proc").glob("[0-9]*/cmdline"):
        try:
            argv = f.read_bytes().split(b"\0")
        except OSError:
            continue
        if len(argv) >= 2 and argv[1] == str(gui).encode():
            pids.append(int(f.parent.name))
    return pids


def wait_for(cond, timeout=15.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.05)
    return cond()


class InstallTest(unittest.TestCase):
    def setUp(self):
        # Short path: the app's single-instance socket lives in TMPDIR (108-byte limit).
        self.tmp = Path(tempfile.mkdtemp(prefix="dri-", dir="/tmp" if os.access("/tmp", os.W_OK) else None))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.src = self.tmp / "src"
        self.src.mkdir()
        for f in FILES:
            shutil.copy2(REPO / f, self.src / f)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.bin = self.home / ".local/bin/dac-rate"
        self.gui = self.home / ".local/bin/dac-rate-gui"
        self.login_item = self.home / ".config/autostart/dac-rate-gui.desktop"
        stubs = self.tmp / "stubs"
        stubs.mkdir()
        for name, body in STUBS.items():
            (stubs / name).write_text(f"#!/bin/sh\n{body}\n")
            (stubs / name).chmod(0o755)
        if not shutil.which("jq"):
            (stubs / "jq").write_text("#!/bin/sh\nexit 0\n")
            (stubs / "jq").chmod(0o755)
        (self.tmp / "run").mkdir()
        (self.tmp / "xdg").mkdir()
        self.env = {
            "HOME": str(self.home), "PATH": f"{stubs}:{os.environ['PATH']}", "LANG": "C.UTF-8",
            "TMPDIR": str(self.tmp / "run"), "XDG_RUNTIME_DIR": str(self.tmp / "xdg"), "QT_QPA_PLATFORM": "offscreen",
            "SYSTEMCTL_LOG": str(self.tmp / "systemctl.log"), "FAKE_UNIT_ACTIVE": str(self.tmp / "unit-active"),
            "DAC_RATE_CLI": str(HERE / "fake-dac-rate"),
            "FAKE_STATE": str(self.tmp / "state.json"), "FAKE_LOG": str(self.tmp / "calls.log"),
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        }
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "release")
        self.git("tag", "-a", f"v{VERSION}", "-m", f"dac-rate {VERSION}")
        self.addCleanup(self.kill_apps)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.src, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def install(self, *args, ok=True, **env):
        r = subprocess.run(["bash", str(self.src / "install.sh"), *args], env={**self.env, **env},
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        out = r.stdout + r.stderr
        if ok is not None:
            self.assertEqual(r.returncode == 0, ok, out)
        return out

    def version(self, path):
        cmd = [str(path), "--version"] if path == self.gui else [str(path), "version"]
        return subprocess.run(cmd, env=self.env, capture_output=True, text=True).stdout.strip()

    def set_installed_version(self, v):
        text = self.bin.read_text()
        self.bin.write_text(re.sub(r"^VERSION=\S+", f"VERSION={v}", text, flags=re.M))

    def start_app(self, *args):
        p = subprocess.Popen([str(self.gui), *args], env=self.env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: p.poll() is None and p.kill())
        # Ready once the single-instance server is listening.
        self.assertTrue(wait_for(lambda: any(f.name.startswith("dac-rate-gui-") for f in self.tmp.joinpath("run").iterdir())),
                        "app never started")
        return p

    def kill_apps(self):
        for pid in gui_pids(self.gui):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    # --- install / upgrade / downgrade ----------------------------------------------

    def test_fresh_install(self):
        out = self.install()
        self.assertIn(f"Installing {VERSION}", out)
        self.assertIn(f"Source: v{VERSION}", out)
        self.assertNotIn("Warning", out)
        self.assertEqual(self.bin.read_bytes(), (REPO / "dac-rate").read_bytes(), "a release installs unchanged")
        self.assertEqual(self.gui.read_bytes(), (REPO / "dac-rate-gui").read_bytes())
        self.assertEqual(self.version(self.bin), f"dac-rate {VERSION}")
        self.assertEqual(self.version(self.gui), f"dac-rate-gui {VERSION}")
        launcher = (self.home / ".local/share/applications/dac-rate.desktop").read_text()
        self.assertIn(f"\nExec={self.gui}\n", launcher)
        self.assertEqual(list(self.gui.parent.glob("*.??????")), [], "no temp files left behind")

    def test_reinstall(self):
        self.install()
        self.assertIn(f"Reinstalling {VERSION}", self.install())

    def test_upgrade(self):
        self.install()
        self.set_installed_version("1.0.0")
        out = self.install()
        self.assertIn(f"Upgrading 1.0.0 → {VERSION}", out)
        self.assertEqual(self.version(self.bin), f"dac-rate {VERSION}")

    def test_downgrade_needs_force(self):
        self.install()
        self.set_installed_version("99.0.0")
        out = self.install(ok=False)
        self.assertIn(f"Downgrading 99.0.0 → {VERSION}", out)
        self.assertIn("Not downgrading without --force", out)
        self.assertEqual(self.version(self.bin), "dac-rate 99.0.0", "nothing changed")
        self.install("--force")
        self.assertEqual(self.version(self.bin), f"dac-rate {VERSION}")

    def test_dry_run_changes_nothing(self):
        out = self.install("--dry-run")
        self.assertIn("Dry run", out)
        self.assertIn(f"Installing {VERSION}", out)
        self.assertFalse(self.bin.exists())
        self.assertFalse(self.gui.exists())

    def test_unknown_option(self):
        self.assertIn("Unknown option", self.install("--frobnicate", ok=False))

    # --- source and build ---------------------------------------------------------------

    def test_dirty_checkout_is_marked(self):
        with open(self.src / "dac-rate-gui", "a") as f:
            f.write("# local edit\n")
        out = self.install()
        self.assertIn("uncommitted changes", out)
        self.assertEqual(self.version(self.bin), f"dac-rate {VERSION} ({VERSION}-dirty)")
        self.assertEqual(self.version(self.gui), f"dac-rate-gui {VERSION} ({VERSION}-dirty)")
        # Installing the clean release afterwards says what it replaces
        self.git("checkout", "-q", "dac-rate-gui")
        self.assertIn(f"Reinstalling {VERSION} (the installed one was {VERSION}-dirty)", self.install())
        self.assertEqual(self.version(self.bin), f"dac-rate {VERSION}")

    def test_commits_after_tag(self):
        (self.src / "notes").write_text("x")
        self.git("add", "notes")
        self.git("commit", "-qm", "dev")
        out = self.install()
        build = f"{VERSION}-1-g{self.git('rev-parse', '--short', 'HEAD')}"
        self.assertIn(f"Source: v{build}", out)
        self.assertIn("commits after the tag", out)
        self.assertEqual(self.version(self.gui), f"dac-rate-gui {VERSION} ({build})")

    def test_tag_and_version_disagree(self):
        self.git("tag", "-d", f"v{VERSION}")
        self.git("tag", "-a", "v99.0.0", "-m", "x")
        out = self.install(ok=False)
        self.assertIn(f"at v99.0.0 but the files say VERSION {VERSION}", out)
        self.assertFalse(self.bin.exists())
        self.install("--force")
        self.assertEqual(self.version(self.bin), f"dac-rate {VERSION} (99.0.0)")

    def test_unreleased_version(self):
        self.git("tag", "-d", f"v{VERSION}")
        self.git("tag", "-a", "v0.1.0", "-m", "x")
        out = self.install()
        self.assertIn(f"{VERSION} is not released yet (latest tag here is v0.1.0)", out)

    def test_versions_must_match(self):
        p = self.src / "dac-rate-gui"
        p.write_text(p.read_text().replace(f'VERSION = "{VERSION}"', 'VERSION = "0.0.1"'))
        out = self.install(ok=False)
        self.assertIn("VERSION differs", out)
        self.assertFalse(self.bin.exists())

    def test_not_a_git_checkout(self):
        shutil.rmtree(self.src / ".git")
        out = self.install()
        self.assertIn("not a git checkout", out)
        self.assertEqual(self.version(self.bin), f"dac-rate {VERSION}")

    # --- login item and restart ---------------------------------------------------------

    def test_login_item_is_repointed(self):
        self.login_item.parent.mkdir(parents=True)
        self.login_item.write_text("[Desktop Entry]\nType=Application\nName=x\nExec=/old/place/dac-rate-gui --tray\n")
        out = self.install()
        self.assertIn("Pointed the login item at", out)
        self.assertIn(f"\nExec={self.gui} --tray\n", self.login_item.read_text())
        self.assertNotIn("Pointed the login item", self.install(), "left alone once correct")

    def systemctl_calls(self):
        log = Path(self.env["SYSTEMCTL_LOG"])
        return log.read_text().splitlines() if log.exists() else []

    def test_restarts_systemd_unit(self):
        self.install()
        self.set_installed_version("1.0.0")
        Path(self.env["FAKE_UNIT_ACTIVE"]).touch()
        out = self.install()
        self.assertIn(f"Restarted the running app (1.0.0 → {VERSION})", out)
        calls = self.systemctl_calls()
        self.assertIn(f"--user start {UNIT}", calls)
        self.assertNotIn(f"--user restart {UNIT}", calls, "restart would SIGKILL after the unit's 5 s stop timeout")

    def test_unit_app_is_stopped_cleanly_before_start(self):
        self.install()
        app = self.start_app("--tray")
        Path(self.env["FAKE_UNIT_ACTIVE"]).touch()
        out = self.install()
        self.assertEqual(app.wait(5), 0, "stopped by SIGTERM through the app's own quit, not killed")
        self.assertNotIn("did not quit", out)
        self.assertIn(f"--user start {UNIT}", self.systemctl_calls())

    def test_unit_reloaded_after_login_item_fix(self):
        self.install()
        self.login_item.parent.mkdir(parents=True)
        self.login_item.write_text("[Desktop Entry]\nType=Application\nName=x\nExec=/old/dac-rate-gui --tray\n")
        Path(self.env["FAKE_UNIT_ACTIVE"]).touch()
        self.install()
        calls = self.systemctl_calls()
        self.assertIn("--user daemon-reload", calls)
        self.assertLess(calls.index("--user daemon-reload"), calls.index(f"--user start {UNIT}"))

    def test_restarts_running_app_in_same_mode(self):
        self.install()
        old = self.start_app("--tray")
        start = time.monotonic()
        out = self.install()
        self.assertLess(time.monotonic() - start, 20, "did not wait for the stop timeout")
        self.assertNotIn("did not quit", out)
        self.assertIn(f"Restarted the running app ({VERSION})", out)
        self.assertEqual(old.wait(5), 0, "SIGTERM quits cleanly, not killed")
        self.assertTrue(wait_for(lambda: gui_pids(self.gui)), "new copy never started")
        pid = gui_pids(self.gui)[0]
        self.assertNotEqual(pid, old.pid)
        argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        self.assertIn(b"--tray", argv, "relaunched in the tray, as it was")
        # The relaunched app must not keep the installer's lock (an inherited fd)
        self.assertNotIn("Another ./install.sh is running", self.install(ok=None))

    def test_failed_relaunch_is_reported(self):
        self.install()
        old = self.start_app("--tray")
        out = self.install(QT_QPA_PLATFORM="no-such-platform")
        self.assertEqual(old.wait(5), 0)
        self.assertIn("The app did not start again", out)
        self.assertIn("no-such-platform", out, "shows the app's own error")
        self.assertNotIn("Restarted", out)

    def test_concurrent_install_refused(self):
        import fcntl
        with open(self.tmp / "xdg" / f"dac-rate-install.{os.getuid()}.lock", "w") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            self.assertIn("Another ./install.sh is running", self.install(ok=False))
        self.install()

    def test_no_restart_when_not_running(self):
        out = self.install()
        self.assertNotIn("Restarted", out)
        self.assertNotIn("restart", Path(self.env["SYSTEMCTL_LOG"]).read_text() if Path(self.env["SYSTEMCTL_LOG"]).exists() else "")

    def test_uninstall_quits_app_cleanly(self):
        self.install()
        app = self.start_app()
        out = self.install("--force", "--uninstall")
        self.assertIn("Removed", out)
        self.assertNotIn("did not quit", out)
        self.assertEqual(app.wait(5), 0, "quit through SIGTERM, cleanly")
        self.assertFalse(self.bin.exists() or self.gui.exists())


if __name__ == "__main__":
    unittest.main()
