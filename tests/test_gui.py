"""GUI tests for dac-rate-gui, run offscreen against tests/fake-dac-rate.

    QT_QPA_PLATFORM=offscreen python3 -m unittest tests/test_gui.py

Set DAC_RATE_SHOTS=<dir> to also save screenshots of each state.
"""
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TMP = tempfile.mkdtemp(prefix="dac-rate-gui-test-")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ["XDG_CONFIG_HOME"] = os.path.join(TMP, "config")  # autostart file, QSettings
os.environ["DAC_RATE_CLI"] = str(HERE / "fake-dac-rate")
os.environ["FAKE_STATE"] = os.path.join(TMP, "state.json")
os.environ["FAKE_LOG"] = os.path.join(TMP, "calls.log")
os.environ["FAKE_DELAY"] = "0.2"

loader = importlib.machinery.SourceFileLoader("gui", str(HERE.parent / "dac-rate-gui"))
spec = importlib.util.spec_from_loader("gui", loader)
gui = importlib.util.module_from_spec(spec)
loader.exec_module(gui)

from PySide6.QtCore import QSettings  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

app = QApplication.instance() or QApplication([])
USB = "alsa_output.usb-Test_DAC-01.analog-stereo"
ONBOARD = "alsa_output.pci-0000_00_1f.3.analog-stereo"
SHOTS = os.environ.get("DAC_RATE_SHOTS")


def wait_until(cond, timeout=10.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        app.processEvents()
        if cond():
            return True
        time.sleep(0.02)
    app.processEvents()
    return cond()


def calls():
    try:
        return [json.loads(line) for line in Path(os.environ["FAKE_LOG"]).read_text().splitlines()]
    except OSError:
        return []


def changes():
    return [c for c in calls() if "set" in c or "reset" in c]


class GuiTest(unittest.TestCase):
    def setUp(self):
        for f in ("FAKE_STATE", "FAKE_LOG"):
            Path(os.environ[f]).unlink(missing_ok=True)
        os.environ.pop("FAKE_FAIL", None)
        os.environ.pop("FAKE_CONFLICT", None)
        self.warnings = []
        gui.QMessageBox.warning = lambda _parent, _title, text: self.warnings.append(text)
        self.w = gui.MainWindow(gui.Cli(os.environ["DAC_RATE_CLI"]), QSettings(os.path.join(TMP, "s.ini"), QSettings.Format.IniFormat))
        self.w.show()
        self.assertTrue(wait_until(lambda: self.w.status is not None and self.w.rate_combo.count() > 0),
                        "window never loaded")

    def tearDown(self):
        # Let queued dac-rate calls finish so they can't leak into the next test.
        wait_until(lambda: not self.w.cli.busy() and not self.w.cli.queue)
        self.w.quitting = True
        self.w.close()
        self.w.deleteLater()
        app.processEvents()

    def shot(self, name):
        if SHOTS:
            os.makedirs(SHOTS, exist_ok=True)
            app.processEvents()
            self.w.grab().save(os.path.join(SHOTS, f"{name}.png"))

    def apply_and_wait(self):
        self.assertTrue(self.w.apply_btn.isEnabled(), "Apply should be enabled")
        self.w.apply_btn.click()
        self.assertTrue(self.w.applying, "should be applying")
        self.assertFalse(self.w.rb_auto.isEnabled(), "controls locked while applying")
        self.assertTrue(wait_until(lambda: not self.w.applying), "apply never finished")
        wait_until(lambda: False, 0.4)  # let the follow-up status refresh land

    def test_initial_state(self):
        self.shot("1-initial")
        self.assertEqual(self.w.node, USB, "USB device is preferred when nothing is remembered")
        self.assertEqual(self.w.device_combo.count(), 2)
        self.assertTrue(self.w.rb_default.isChecked())
        self.assertFalse(self.w.apply_btn.isEnabled(), "nothing to apply yet")
        self.assertFalse(self.w.rate_combo.isEnabled(), "rate list only active for Lock")
        self.assertEqual(self.w.rate_combo.count(), 8)
        self.assertEqual(self.w.rate_combo.currentData(), 192000)
        self.assertEqual(self.w.hw_label.text(), "Idle")
        self.assertTrue(self.w.warn_box.isHidden())

    def test_lock_then_reset(self):
        self.w.rb_lock.click()
        self.w.rate_combo.setCurrentIndex(self.w.rates.index(96000))
        self.assertTrue(self.w.rate_combo.isEnabled())
        self.shot("2-lock-chosen")
        self.apply_and_wait()
        self.assertEqual(changes()[-1], ["--json", "-d", USB, "-m", "card", "-q", "default", "set", "96000"])
        self.assertIn("Locked to 96 kHz", self.w.rule_label.text())
        self.assertFalse(self.w.apply_btn.isEnabled(), "applied state equals the controls")
        self.shot("3-locked")

        self.w.rb_default.click()
        self.apply_and_wait()
        self.assertEqual(changes()[-1], ["--json", "-d", USB, "reset"])
        self.assertIn("No dac-rate rule", self.w.rule_label.text())

    def test_advanced_options(self):
        self.w.adv_toggle.click()
        self.assertTrue(self.w.adv.isVisible())
        self.w.rb_auto.click()
        self.w.match_combo.setCurrentIndex(self.w.match_combo.findData("port"))
        self.w.quality_spin.setValue(10)
        self.shot("4-advanced")
        self.apply_and_wait()
        self.assertEqual(changes()[-1], ["--json", "-d", USB, "-m", "port", "-q", "10", "set", "auto"])
        self.assertIn("Auto", self.w.rule_label.text())
        self.assertIn("this USB port", self.w.rule_label.text())
        # Reopening shows the stored options
        self.w._load_controls_from_rule(self.w.status["rule"])
        self.assertEqual(self.w.match_combo.currentData(), "port")
        self.assertEqual(self.w.quality_spin.value(), 10)

    def test_tray_menu_keeps_options(self):
        self.w.rb_lock.click()
        self.w.adv_toggle.click()
        self.w.quality_spin.setValue(12)
        self.apply_and_wait()
        tray = gui.Tray(self.w)
        self.w.set_tray(tray)
        tray._rebuild_menu()
        texts = [a.text() for a in tray.menu.actions()]
        self.assertEqual(texts[0], "Test USB DAC")
        self.assertIn("Follow the content (Auto)", texts)
        lock_menu = next(a.menu() for a in tray.menu.actions() if a.menu())
        self.assertEqual(lock_menu.title(), "Locked: 192 kHz", "the current lock shows at the top level")
        locked = [a.text() for a in lock_menu.actions() if a.isChecked()]
        self.assertEqual(locked, ["192 kHz"], "current lock is ticked")
        auto = next(a for a in tray.menu.actions() if a.text() == "Follow the content (Auto)")
        auto.trigger()
        self.assertTrue(wait_until(lambda: not self.w.applying and len(changes()) == 2))
        self.assertEqual(changes()[-1], ["--json", "-d", USB, "-m", "card", "-q", "12", "set", "auto"])
        tray.setVisible(False)

    def test_switch_device(self):
        idx = self.w.device_combo.findData(ONBOARD)
        self.w.device_combo.setCurrentIndex(idx)
        self.w.device_combo.activated.emit(idx)
        self.assertTrue(wait_until(lambda: self.w.rate_combo.count() == 4))
        self.assertTrue(wait_until(lambda: ["--json", "use", ONBOARD] in calls()))
        self.assertEqual(self.w.node, ONBOARD)

    def test_error_is_shown(self):
        os.environ["FAKE_FAIL"] = "1"
        self.w.rb_auto.click()
        self.apply_and_wait()
        self.assertEqual(len(self.warnings), 1)
        self.assertTrue(self.warnings[0].startswith("This card already has a rule"), self.warnings[0])
        self.assertTrue(self.w.msg.property("error"))
        self.assertIn("No dac-rate rule", self.w.rule_label.text(), "state unchanged after a failure")
        self.shot("5-error")
        # A new choice by the user clears the error
        self.w.rb_lock.click()
        self.assertFalse(self.w.msg.property("error"))

    def test_conflicts_box(self):
        os.environ["FAKE_CONFLICT"] = "1"
        self.w.refresh_status()
        self.assertTrue(wait_until(lambda: self.w.warn_box.isVisible()))
        self.assertIn("99-other-rate-settings.conf", self.w.warn_box.text())
        wait_until(lambda: False, 0.3)  # the window resizes on the next event loop turn
        self.assert_nothing_clipped()
        self.w.hw_label.setText("352.8 kHz")  # widest live rate text
        self.w.adv_toggle.click()
        wait_until(lambda: False, 0.3)
        self.assert_nothing_clipped()
        self.shot("6-conflict")

    def assert_nothing_clipped(self):
        """Every label gets at least the height its text needs."""
        from PySide6.QtWidgets import QLabel
        for label in self.w.findChildren(QLabel):
            if not label.isVisible():
                continue
            need = label.heightForWidth(label.width()) if label.wordWrap() else label.sizeHint().height()
            self.assertGreaterEqual(label.height(), need - 1,
                                    f"label {label.text()[:40]!r} is clipped ({label.height()} < {need})")

    def test_quit_while_busy(self):
        """Quitting stops queries and lets a change finish instead of cutting it off."""
        self.w.rb_auto.click()
        self.w.apply_btn.click()
        self.assertTrue(self.w.cli.busy())
        self.w.cli.shutdown()
        self.assertFalse(self.w.cli.busy())
        self.assertEqual(json.loads(Path(os.environ["FAKE_STATE"]).read_text())["rules"][USB]["mode"], "auto",
                         "the change ran to the end")
        self.w.cli.run("status|x", ["status"])
        self.w.cli.shutdown()
        wait_until(lambda: False, 0.3)  # no callbacks into deleted objects
        self.w.applying = False

    def test_autostart_toggle(self):
        self.w.cb_autostart.setChecked(True)
        text = gui.AUTOSTART.read_text()
        self.assertIn("--tray", text)
        self.assertTrue(text.startswith("[Desktop Entry]"))
        self.w.cb_autostart.setChecked(False)
        self.assertFalse(gui.AUTOSTART.exists())


if __name__ == "__main__":
    unittest.main()
