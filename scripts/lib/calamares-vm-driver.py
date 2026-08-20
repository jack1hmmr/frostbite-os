#!/usr/bin/env python3
"""Stateful QMP/OCR driver for Frostbite's disposable installer VM.

The driver deliberately does not use fixed click coordinates or blind sleeps.
Every destructive transition is preceded by OCR assertions from a fresh QEMU
screendump.  Input is sent through QMP to a USB tablet and keyboard.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


SCREENSHOT_INTERVAL = 1.5
TEXT_KEY_DELAY = 0.04
POINTER_EVENT_DELAY = 0.1
ABS_MAX = 0x7FFF


class DriverError(RuntimeError):
    pass


@dataclass(frozen=True)
class OcrWord:
    text: str
    left: int
    top: int
    width: int
    height: int
    block: int
    paragraph: int
    line: int


@dataclass(frozen=True)
class ScreenState:
    text: str
    words: tuple[OcrWord, ...]
    width: int
    height: int
    crop_x: int
    crop_y: int
    scale: int
    full_png: Path
    central_png: Path


class Qmp:
    def __init__(self, path: Path, timeout: float = 30.0) -> None:
        self.path = path
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        deadline = time.monotonic() + timeout
        while True:
            try:
                self.socket.connect(str(path))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.monotonic() >= deadline:
                    raise DriverError(f"QMP socket did not become ready: {path}")
                time.sleep(0.2)
        self.reader = self.socket.makefile("rb")
        greeting = self._read_message(deadline)
        if "QMP" not in greeting:
            raise DriverError(f"invalid QMP greeting: {greeting!r}")
        self._next_id = 1
        self.execute("qmp_capabilities")

    def close(self) -> None:
        self.reader.close()
        self.socket.close()

    def _read_message(self, deadline: float) -> dict:
        while time.monotonic() < deadline:
            remaining = max(0.1, deadline - time.monotonic())
            self.socket.settimeout(remaining)
            try:
                line = self.reader.readline()
            except socket.timeout as exc:
                raise DriverError("timed out waiting for QMP response") from exc
            if not line:
                raise DriverError("QMP connection closed")
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
        raise DriverError("timed out waiting for QMP message")

    def execute(self, command: str, arguments: dict | None = None, timeout: float = 30.0):
        command_id = self._next_id
        self._next_id += 1
        message: dict = {"execute": command, "id": command_id}
        if arguments:
            message["arguments"] = arguments
        self.socket.sendall(json.dumps(message, separators=(",", ":")).encode() + b"\r\n")
        deadline = time.monotonic() + timeout
        while True:
            reply = self._read_message(deadline)
            if reply.get("id") != command_id:
                continue
            if "error" in reply:
                raise DriverError(f"QMP {command} failed: {reply['error']}")
            return reply.get("return")


def run_checked(command: Sequence[str], *, timeout: float = 60.0, text: bool = True) -> str:
    completed = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
        timeout=timeout,
    )
    if completed.returncode != 0:
        stderr = completed.stderr if text else completed.stderr.decode(errors="replace")
        raise DriverError(f"command failed ({completed.returncode}): {' '.join(command)}\n{stderr}")
    return completed.stdout if text else completed.stdout.decode(errors="replace")


def normalized(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.lower()).strip()


def safe_name(value: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9_.-]+", "-", value).strip("-.")
    return cleaned or "state"


class Driver:
    def __init__(self, qmp_path: Path, evidence_dir: Path) -> None:
        self.qmp = Qmp(qmp_path)
        self.evidence_dir = evidence_dir.resolve()
        self.evidence_dir.mkdir(parents=True, exist_ok=True)
        self.poll_dir = self.evidence_dir / ".poll"
        self.poll_dir.mkdir(exist_ok=True)
        self.counter = 0

    def close(self) -> None:
        self.qmp.close()

    def _capture_raw(self) -> Path:
        raw = self.poll_dir / "screen.ppm"
        raw.unlink(missing_ok=True)
        self.qmp.execute("screendump", {"filename": str(raw)})
        if not raw.is_file() or raw.stat().st_size == 0:
            raise DriverError("QMP screendump did not create an image")
        return raw

    def capture(self, label: str, *, persist: bool = False, central: bool = True) -> ScreenState:
        raw = self._capture_raw()
        dimensions = run_checked(["magick", "identify", "-format", "%w %h", str(raw)]).split()
        if len(dimensions) != 2:
            raise DriverError(f"could not determine screendump dimensions: {dimensions}")
        width, height = (int(part) for part in dimensions)
        if width < 640 or height < 480:
            raise DriverError(f"unexpected screendump size: {width}x{height}")

        crop_x = int(width * 0.22) if central else 0
        crop_y = int(height * 0.035) if central else 0
        crop_width = width - crop_x - int(width * 0.015) if central else width
        crop_height = int(height * 0.86) if central else height
        scale = 2

        stem = safe_name(label)
        if persist:
            self.counter += 1
            prefix = self.evidence_dir / f"{self.counter:02d}-{stem}"
        else:
            prefix = self.poll_dir / stem
        full_png = Path(f"{prefix}.png")
        central_png = Path(f"{prefix}.central.png")
        inverted_png = Path(f"{prefix}.central-inverted.png")
        ocr_txt = Path(f"{prefix}.ocr.txt")

        run_checked(["magick", str(raw), str(full_png)])
        run_checked(
            [
                "magick",
                str(raw),
                "-crop",
                f"{crop_width}x{crop_height}+{crop_x}+{crop_y}",
                "+repage",
                "-colorspace",
                "Gray",
                "-resize",
                f"{scale * 100}%",
                "-contrast-stretch",
                "1%x1%",
                str(central_png),
            ]
        )
        run_checked(["magick", str(central_png), "-negate", str(inverted_png)])
        normal_text = run_checked(
            ["tesseract", str(central_png), "stdout", "--psm", "11", "-l", "eng"], timeout=90
        )
        inverted_text = run_checked(
            ["tesseract", str(inverted_png), "stdout", "--psm", "11", "-l", "eng"], timeout=90
        )
        normal_tsv = run_checked(
            ["tesseract", str(central_png), "stdout", "--psm", "11", "-l", "eng", "tsv"], timeout=90
        )
        inverted_tsv = run_checked(
            ["tesseract", str(inverted_png), "stdout", "--psm", "11", "-l", "eng", "tsv"], timeout=90
        )
        text_output = f"--- normal OCR ---\n{normal_text}\n--- inverted OCR ---\n{inverted_text}"
        ocr_txt.write_text(text_output, encoding="utf-8")

        words: list[OcrWord] = []
        for variant, tsv_output in enumerate((normal_tsv, inverted_tsv)):
            for row in csv.DictReader(io.StringIO(tsv_output), delimiter="\t"):
                token = (row.get("text") or "").strip()
                if not token:
                    continue
                try:
                    words.append(
                        OcrWord(
                            text=token,
                            left=int(row["left"]),
                            top=int(row["top"]),
                            width=int(row["width"]),
                            height=int(row["height"]),
                            block=int(row["block_num"]) + variant * 1_000_000,
                            paragraph=int(row["par_num"]),
                            line=int(row["line_num"]),
                        )
                    )
                except (KeyError, TypeError, ValueError):
                    continue
        return ScreenState(
            text=text_output,
            words=tuple(words),
            width=width,
            height=height,
            crop_x=crop_x,
            crop_y=crop_y,
            scale=scale,
            full_png=full_png,
            central_png=central_png,
        )

    @staticmethod
    def _matches(state: ScreenState, patterns: Iterable[str]) -> bool:
        text = normalized(state.text)
        return all(re.search(pattern, text, flags=re.IGNORECASE) for pattern in patterns)

    def wait_text(
        self,
        label: str,
        patterns: Sequence[str],
        *,
        timeout: float = 180.0,
        central: bool = True,
        reject: Sequence[str] = ("installation failed", "failed to install"),
    ) -> ScreenState:
        deadline = time.monotonic() + timeout
        last: ScreenState | None = None
        while time.monotonic() < deadline:
            last = self.capture(label, central=central)
            screen_text = normalized(last.text)
            if any(re.search(pattern, screen_text, flags=re.IGNORECASE) for pattern in reject):
                failed = self.capture(f"{label}-rejected", persist=True, central=central)
                raise DriverError(f"failure text appeared while waiting for {label}: {normalized(failed.text)!r}")
            if self._matches(last, patterns):
                return self.capture(label, persist=True, central=central)
            time.sleep(SCREENSHOT_INTERVAL)
        final = self.capture(f"{label}-timeout", persist=True, central=central)
        raise DriverError(
            f"timed out waiting for {label}; required={patterns!r}; OCR={normalized(final.text)!r}"
        )

    def wait_text_with_action(
        self,
        label: str,
        patterns: Sequence[str],
        action,
        *,
        timeout: float = 240.0,
        action_interval: float = 5.0,
        central: bool = False,
    ) -> ScreenState:
        deadline = time.monotonic() + timeout
        next_action = 0.0
        while time.monotonic() < deadline:
            state = self.capture(label, central=central)
            if self._matches(state, patterns):
                return self.capture(label, persist=True, central=central)
            now = time.monotonic()
            if now >= next_action:
                action()
                next_action = now + action_interval
            time.sleep(SCREENSHOT_INTERVAL)
        final = self.capture(f"{label}-timeout", persist=True, central=central)
        raise DriverError(f"timed out waiting for {label}; OCR={normalized(final.text)!r}")

    def _key_events(self, qcode: str, modifiers: Sequence[str] = ()) -> list[dict]:
        events: list[dict] = []
        for modifier in modifiers:
            events.append({"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": modifier}}})
        events.append({"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": qcode}}})
        events.append({"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": qcode}}})
        for modifier in reversed(modifiers):
            events.append({"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": modifier}}})
        return events

    def key(self, qcode: str, *modifiers: str) -> None:
        self.qmp.execute("input-send-event", {"events": self._key_events(qcode, modifiers)})

    def shortcut(self, modifier: str, qcode: str) -> None:
        self.key(qcode, modifier)

    def type_text(self, value: str) -> None:
        punctuation: dict[str, tuple[str, tuple[str, ...]]] = {
            " ": ("spc", ()),
            "-": ("minus", ()),
            "_": ("minus", ("shift",)),
            ".": ("dot", ()),
            "/": ("slash", ()),
            "&": ("7", ("shift",)),
        }
        for character in value:
            if "a" <= character <= "z" or "0" <= character <= "9":
                qcode, modifiers = character, ()
            elif "A" <= character <= "Z":
                qcode, modifiers = character.lower(), ("shift",)
            elif character in punctuation:
                qcode, modifiers = punctuation[character]
            else:
                raise DriverError(f"unsupported keyboard character: {character!r}")
            self.key(qcode, *modifiers)
            # QMP acknowledges event injection before the guest necessarily
            # consumes it. A small pace prevents characters from disappearing
            # in firmware, TTY, and Qt input fields on loaded CI runners.
            time.sleep(TEXT_KEY_DELAY)

    def line(self, value: str) -> None:
        self.type_text(value)
        self.key("ret")
        time.sleep(TEXT_KEY_DELAY)

    def click_phrase(self, state: ScreenState, phrase: str) -> None:
        wanted = [normalized(token) for token in phrase.split()]
        line_groups: dict[tuple[int, int, int], list[OcrWord]] = {}
        for word in state.words:
            line_groups.setdefault((word.block, word.paragraph, word.line), []).append(word)
        for words in line_groups.values():
            words.sort(key=lambda word: word.left)
            tokens = [normalized(word.text) for word in words]
            for offset in range(0, len(tokens) - len(wanted) + 1):
                if tokens[offset : offset + len(wanted)] != wanted:
                    continue
                selected = words[offset : offset + len(wanted)]
                left = min(word.left for word in selected)
                right = max(word.left + word.width for word in selected)
                top = min(word.top for word in selected)
                bottom = max(word.top + word.height for word in selected)
                x = state.crop_x + ((left + right) / 2) / state.scale
                y = state.crop_y + ((top + bottom) / 2) / state.scale
                abs_x = max(0, min(ABS_MAX, round(x * ABS_MAX / (state.width - 1))))
                abs_y = max(0, min(ABS_MAX, round(y * ABS_MAX / (state.height - 1))))
                # QMP acknowledges injected events before Sway and Qt have
                # necessarily consumed them. Deliver pointer motion, press,
                # and release as distinct commands so the guest observes a
                # real click instead of a collapsed same-batch transition.
                self.qmp.execute(
                    "input-send-event",
                    {
                        "events": [
                            {"type": "abs", "data": {"axis": "x", "value": abs_x}},
                            {"type": "abs", "data": {"axis": "y", "value": abs_y}},
                        ]
                    },
                )
                time.sleep(POINTER_EVENT_DELAY)
                self.qmp.execute(
                    "input-send-event",
                    {"events": [{"type": "btn", "data": {"down": True, "button": "left"}}]},
                )
                time.sleep(POINTER_EVENT_DELAY)
                self.qmp.execute(
                    "input-send-event",
                    {"events": [{"type": "btn", "data": {"down": False, "button": "left"}}]},
                )
                time.sleep(POINTER_EVENT_DELAY)
                return
        raise DriverError(f"could not locate clickable OCR phrase {phrase!r}; OCR={normalized(state.text)!r}")

    def system_powerdown(self) -> None:
        self.qmp.execute("system_powerdown")


def env_password() -> str:
    password = os.environ.get("FROSTBITE_VM_PASSWORD", "")
    if not password:
        raise DriverError("FROSTBITE_VM_PASSWORD is required")
    if not re.fullmatch(r"[A-Za-z0-9]{12,64}", password):
        raise DriverError("FROSTBITE_VM_PASSWORD must be 12-64 ASCII letters/digits")
    return password


def boot_installer(driver: Driver, serial_log: Path) -> None:
    # GRUB's menu is intentionally short-lived.  One OCR poll runs four
    # Tesseract passes and can outlast the whole countdown on a fast KVM host,
    # while the same menu is emitted immediately to GRUB's serial console.
    wait_file_text(
        serial_log,
        r"Start Frostbite OS[\s\S]*Install Frostbite OS \(erase one disk\)",
        60,
    )
    driver.key("down")
    driver.key("ret")


def install(driver: Driver, serial_log: Path) -> None:
    password = env_password()
    boot_installer(driver, serial_log)

    driver.wait_text("welcome", (r"welcome", r"frostbite"), timeout=300)
    driver.shortcut("alt", "n")
    # The central OCR crop intentionally excludes the left navigation rail and
    # clips the Region label at 1280x800. Match the configured location fields
    # that remain fully visible instead of waiting on cropped page chrome.
    driver.wait_text("location", (r"zone", r"chicago", r"american english"))
    driver.shortcut("alt", "n")
    driver.wait_text("keyboard", (r"generic 105 key pc", r"english colemak", r"english dvorak"))
    driver.shortcut("alt", "n")

    partition = driver.wait_text(
        "partition-choice",
        (r"erase disk", r"delete all data", r"selected storage device"),
        timeout=300,
    )
    driver.click_phrase(partition, "Erase disk")
    # With a single forced no-swap choice Calamares intentionally hides the
    # swap combobox, so the page cannot display a "No swap" label. The white
    # "After" label is also left of the normal center crop, while the preview's
    # dim filesystem labels are not reliable OCR targets. At this reversible
    # stage, prove the erase preview appeared; the destructive Summary gate and
    # installed-disk audit enforce the exact target, layout, and no-swap policy
    # before and after any disk write.
    driver.wait_text(
        "partition-erase-selected",
        (r"erase disk", r"after"),
        timeout=120,
        central=False,
    )
    driver.shortcut("alt", "n")

    # Users-page fields start at the left edge of Calamares' content area, so
    # the normal center crop can cut off both the labels and typed values.
    driver.wait_text(
        "users",
        (
            r"what is your name",
            r"use to log in",
            r"name of this computer",
            r"choose a password",
        ),
        central=False,
    )
    # Calamares focuses the full-name field whenever this page is activated.
    # Rely on that source-level contract instead of OCR-clicking its dim
    # placeholder, which disappears under the high-contrast OCR transform.
    driver.type_text("Frostbite CI")
    driver.key("tab")
    driver.shortcut("ctrl", "a")
    driver.type_text("frosttest")
    driver.key("tab")
    driver.shortcut("ctrl", "a")
    driver.type_text("frostbite-ci")
    driver.key("tab")
    driver.type_text(password)
    driver.key("tab")
    driver.type_text(password)
    # Preserve a screenshot of the filled form. The transition to Summary and
    # the two-boot installed audit are the authoritative value checks; the
    # low-contrast QLineEdit contents are intentionally not an OCR gate.
    driver.capture("users-filled", persist=True, central=False)
    driver.shortcut("alt", "n")

    # The normal OCR crop excludes the left navigation rail and can clip the
    # erase-mode text at the content edge. Require the confirmation-page
    # heading plus the exact destructive disk and layout details before Alt+I.
    driver.wait_text(
        "destructive-summary",
        (
            r"install procedure",
            r"erase",
            r"vda",
            r"gpt",
            r"512\s*mib",
            r"efi",
            r"ext4",
        ),
        timeout=300,
        central=False,
    )
    # Alt+I is allowed only after all destructive target/layout assertions pass.
    driver.shortcut("alt", "i")
    driver.wait_text(
        "installation-complete",
        (r"all done", r"has been installed"),
        timeout=2400,
        reject=(r"installation failed", r"failed to install", r"failed"),
    )
    driver.system_powerdown()


def enter_tty2(driver: Driver, label: str) -> None:
    def advance_boot_and_select_tty2() -> None:
        # Enter starts the default installed GRUB entry when its short menu is
        # visible. Ctrl-Alt-F2 is harmless in firmware/GRUB and selects tty2 as
        # soon as the installed kernel and getty are ready. This avoids making
        # fallback-boot proof depend on OCR catching a brief GRUB countdown.
        driver.key("ret")
        driver.key("f2", "ctrl", "alt")

    driver.wait_text_with_action(
        f"{label}-tty2-login",
        (r"frostbite ci login",),
        advance_boot_and_select_tty2,
        timeout=480,
        central=False,
    )


def login_installed(driver: Driver, label: str, password: str) -> None:
    driver.line("frosttest")
    driver.wait_text(f"{label}-password", (r"password",), timeout=90, central=False, reject=())
    driver.line(password)
    driver.wait_text(
        f"{label}-shell",
        (r"frosttest frostbite ci",),
        timeout=120,
        central=False,
        reject=(r"login incorrect",),
    )
    driver.shortcut("ctrl", "l")
    driver.line("echo FROSTBITE_VM_LOGIN_PASS")
    driver.wait_text(
        f"{label}-login-ready",
        (r"frostbite vm login pass",),
        timeout=90,
        central=False,
        reject=(r"login incorrect",),
    )


def first_boot(driver: Driver) -> None:
    password = env_password()
    enter_tty2(driver, "first-boot")
    login_installed(driver, "first-boot", password)
    firstboot_probe = "/usr/bin/test -e /var/lib/frostbite/firstboot.done && echo FROSTBITE_VM_FIRSTBOOT_PASS"
    driver.wait_text_with_action(
        "first-boot-complete",
        (r"frostbite vm firstboot pass",),
        lambda: driver.line(firstboot_probe),
        timeout=600,
        central=False,
    )
    driver.system_powerdown()


def wait_file_text(path: Path, pattern: str, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    regex = re.compile(pattern)
    while time.monotonic() < deadline:
        if path.is_file():
            content = path.read_text(encoding="utf-8", errors="replace")
            if regex.search(content):
                return
            if "FROSTBITE_VM_AUDIT_FAIL" in content:
                raise DriverError("installed-system audit reported failure")
        time.sleep(1.0)
    raise DriverError(f"timed out waiting for {pattern!r} in {path}")


def audit_boot(driver: Driver, serial_log: Path) -> None:
    password = env_password()
    enter_tty2(driver, "audit-boot")
    login_installed(driver, "audit-boot", password)

    driver.line("sudo -v && echo FROSTBITE_VM_SUDO_PASS")
    driver.wait_text("audit-sudo-password", (r"password",), timeout=90, central=False, reject=())
    driver.line(password)
    driver.wait_text(
        "audit-sudo-ready", (r"frostbite vm sudo pass",), timeout=120, central=False, reject=()
    )

    commands = (
        ("sudo mkdir -p /mnt/ci && echo FROSTBITE_VM_MKDIR_PASS", r"frostbite vm mkdir pass"),
        (
            "sudo mount -o ro /dev/sr0 /mnt/ci && echo FROSTBITE_VM_MOUNT_PASS",
            r"frostbite vm mount pass",
        ),
    )
    for index, (command, marker) in enumerate(commands, start=1):
        driver.line(command)
        driver.wait_text(
            f"audit-command-{index}", (marker,), timeout=120, central=False, reject=()
        )

    driver.line("sudo bash /mnt/ci/audit-installed-vm.sh")
    wait_file_text(serial_log, r"FROSTBITE_VM_AUDIT_PASSWORD_READY", 180)
    # The audit reads this from /dev/tty2 with echo disabled; it is never put
    # in a command line, screenshot, shell history, or retained evidence file.
    driver.line(password)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("install", "first-boot", "audit-boot"))
    parser.add_argument("--qmp", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--serial-log", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.mode in ("install", "audit-boot") and args.serial_log is None:
        raise DriverError(f"--serial-log is required for {args.mode}")
    driver = Driver(args.qmp, args.evidence)
    try:
        if args.mode == "install":
            install(driver, args.serial_log)
        elif args.mode == "first-boot":
            first_boot(driver)
        else:
            audit_boot(driver, args.serial_log)
    finally:
        driver.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (DriverError, OSError, subprocess.SubprocessError) as error:
        print(f"VM driver error: {error}", file=sys.stderr)
        raise SystemExit(1)
