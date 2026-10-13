#!/usr/bin/env python3
"""Observe only an owned x64 Windows child with private application settings.

The caller must build trusted pinned source containing the WT_SETTINGS_DIR hook.
Hook literals are checked before launch; the hook's fresh PID/path marker is then
required. This is startup verification, not a sandbox for untrusted executables.
No registry reads, injection, process attachment, or application output logging.
"""
from __future__ import annotations

import argparse
import ctypes as C
from ctypes import wintypes as W
import datetime as DT
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
import time


class Refused(Exception):
    pass


class FILETIME(C.Structure):
    _fields_ = [("low", W.DWORD), ("high", W.DWORD)]


class SECURITY_ATTRIBUTES(C.Structure):
    _fields_ = [("length", W.DWORD), ("descriptor", C.c_void_p), ("inherit", W.BOOL)]


class STARTUPINFOW(C.Structure):
    _fields_ = [
        ("cb", W.DWORD), ("reserved", W.LPWSTR), ("desktop", W.LPWSTR),
        ("title", W.LPWSTR), ("x", W.DWORD), ("y", W.DWORD),
        ("xsize", W.DWORD), ("ysize", W.DWORD), ("xchars", W.DWORD),
        ("ychars", W.DWORD), ("fill", W.DWORD), ("flags", W.DWORD),
        ("show", W.WORD), ("reserved_size", W.WORD),
        ("reserved_bytes", C.c_void_p), ("stdin", W.HANDLE),
        ("stdout", W.HANDLE), ("stderr", W.HANDLE),
    ]


class STARTUPINFOEXW(C.Structure):
    _fields_ = [("startup", STARTUPINFOW), ("attributes", C.c_void_p)]


class PROCESS_INFORMATION(C.Structure):
    _fields_ = [("process", W.HANDLE), ("thread", W.HANDLE),
                ("pid", W.DWORD), ("tid", W.DWORD)]


class EXCEPTION_RECORD(C.Structure):
    _fields_ = [("code", W.DWORD), ("flags", W.DWORD),
                ("record", C.c_void_p), ("address", C.c_void_p),
                ("parameter_count", W.DWORD), ("information", C.c_size_t * 15)]


class EXCEPTION_DEBUG_INFO(C.Structure):
    _fields_ = [("record", EXCEPTION_RECORD), ("first_chance", W.DWORD)]


class CREATE_PROCESS_DEBUG_INFO(C.Structure):
    _fields_ = [("file", W.HANDLE), ("process", W.HANDLE),
                ("thread", W.HANDLE), ("image_base", C.c_void_p),
                ("debug_offset", W.DWORD), ("debug_size", W.DWORD),
                ("thread_local_base", C.c_void_p), ("start_address", C.c_void_p),
                ("image_name", C.c_void_p), ("unicode", W.WORD)]


class LOAD_DLL_DEBUG_INFO(C.Structure):
    _fields_ = [("file", W.HANDLE), ("base", C.c_void_p),
                ("debug_offset", W.DWORD), ("debug_size", W.DWORD),
                ("image_name", C.c_void_p), ("unicode", W.WORD)]


class EXIT_PROCESS_DEBUG_INFO(C.Structure):
    _fields_ = [("code", W.DWORD)]


class DEBUG_UNION(C.Union):
    _fields_ = [("exception", EXCEPTION_DEBUG_INFO),
                ("create_process", CREATE_PROCESS_DEBUG_INFO),
                ("load_dll", LOAD_DLL_DEBUG_INFO),
                ("exit_process", EXIT_PROCESS_DEBUG_INFO)]


class DEBUG_EVENT(C.Structure):
    _fields_ = [("code", W.DWORD), ("pid", W.DWORD),
                ("tid", W.DWORD), ("data", DEBUG_UNION)]


def canonical(path: str | Path) -> str:
    return os.path.normcase(os.path.realpath(os.fspath(path)))


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest().upper()


def validate_binary(path: Path) -> None:
    # Fail before launching old binaries: a missing marker observed afterwards
    # would be too late to prevent their native settings reads.
    data = path.read_bytes()
    if len(data) < 64 or data[:2] != b"MZ":
        raise Refused("TARGET_NOT_WINDOWS_EXECUTABLE")
    offset = struct.unpack_from("<I", data, 0x3C)[0]
    if offset + 6 > len(data) or data[offset:offset + 4] != b"PE\0\0":
        raise Refused("TARGET_PE_HEADER_INVALID")
    if struct.unpack_from("<H", data, offset + 4)[0] != 0x8664:
        raise Refused("TARGET_MUST_BE_X64")
    for literal in ("WT_SETTINGS_DIR", ".startup-settings.json"):
        if literal.encode("ascii") not in data and literal.encode("utf-16le") not in data:
            raise Refused("TARGET_SETTINGS_HOOK_NOT_PRESENT")
    normalized = str(path).replace("/", "\\")
    if re.search(r"(?i)\\AppData\\Local\\Programs\\Cilex Watchtower(?:\.[^\\]+)?\\watchtower\.exe$", normalized):
        raise Refused("INSTALLED_CAMERA_WALL_REFUSED")


def make_private_directory(path: Path) -> None:
    if not path.is_absolute():
        raise Refused("PRIVATE_DIRECTORY_MUST_BE_ABSOLUTE")
    if path.exists() and (not path.is_dir() or any(path.iterdir())):
        raise Refused("PRIVATE_DIRECTORY_MUST_BE_FRESH_AND_EMPTY")
    path.mkdir(parents=True, exist_ok=True)


def isolated_environment(home: Path, flightrec: Path) -> dict[str, str]:
    private = {}
    sensitive = re.compile(r"(?i)(PASS|SECRET|CREDENTIAL|TOKEN|API_KEY|JWT|AUTH|PROXY)")
    for name, value in os.environ.items():
        if name.upper().startswith(("WT_", "QT_", "QML_")) or sensitive.search(name):
            continue
        private[name] = value
    local, roaming, temporary = home / "AppData" / "Local", home / "AppData" / "Roaming", home / "tmp"
    for path in (local, roaming, temporary):
        path.mkdir(parents=True, exist_ok=True)
    private.update({
        "USERPROFILE": str(home), "HOME": str(home),
        "LOCALAPPDATA": str(local), "APPDATA": str(roaming),
        "TEMP": str(temporary), "TMP": str(temporary),
        "WT_SETTINGS_DIR": str(home / "settings"),
        "WT_FLIGHTREC_DIR": str(flightrec), "WT_RESTORE_OFF": "1",
        "WT_NO_STATION_ENROL": "1", "WT_NO_SCHEME_REG": "1",
        "WT_CV_URL": "http://127.0.0.1:1", "QT_QPA_PLATFORM": "offscreen",
        "QT_QUICK_BACKEND": "software", "QT_QUICK_CONTROLS_STYLE": "Fusion",
        "PYTHONIOENCODING": "utf-8", "PYTHONUTF8": "1",
    })
    return private


class OwnedDebugChild:
    def __init__(self, executable: Path, environment: dict[str, str]):
        self.executable = executable
        self.environment = environment
        self.info = PROCESS_INFORMATION()
        self.creation = None
        self.pending = None
        self.started = False
        self.exited = False
        self.initial_breakpoint = False
        self.k = C.WinDLL("kernel32", use_last_error=True)
        specs = {
            "CreateFileW": (W.HANDLE, [W.LPCWSTR, W.DWORD, W.DWORD, C.POINTER(SECURITY_ATTRIBUTES), W.DWORD, W.DWORD, W.HANDLE]),
            "CloseHandle": (W.BOOL, [W.HANDLE]),
            "InitializeProcThreadAttributeList": (W.BOOL, [C.c_void_p, W.DWORD, W.DWORD, C.POINTER(C.c_size_t)]),
            "UpdateProcThreadAttribute": (W.BOOL, [C.c_void_p, W.DWORD, C.c_size_t, C.c_void_p, C.c_size_t, C.c_void_p, C.c_void_p]),
            "DeleteProcThreadAttributeList": (None, [C.c_void_p]),
            "CreateProcessW": (W.BOOL, [W.LPCWSTR, W.LPWSTR, C.c_void_p, C.c_void_p, W.BOOL, W.DWORD, C.c_void_p, W.LPCWSTR, C.c_void_p, C.POINTER(PROCESS_INFORMATION)]),
            "WaitForDebugEvent": (W.BOOL, [C.POINTER(DEBUG_EVENT), W.DWORD]),
            "ContinueDebugEvent": (W.BOOL, [W.DWORD, W.DWORD, W.DWORD]),
            "GetProcessTimes": (W.BOOL, [W.HANDLE, C.POINTER(FILETIME), C.POINTER(FILETIME), C.POINTER(FILETIME), C.POINTER(FILETIME)]),
            "GetProcessId": (W.DWORD, [W.HANDLE]),
            "QueryFullProcessImageNameW": (W.BOOL, [W.HANDLE, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD)]),
            "GetExitCodeProcess": (W.BOOL, [W.HANDLE, C.POINTER(W.DWORD)]),
            "TerminateProcess": (W.BOOL, [W.HANDLE, W.UINT]),
            "WaitForSingleObject": (W.DWORD, [W.HANDLE, W.DWORD]),
            "DebugSetProcessKillOnExit": (W.BOOL, [W.BOOL]),
        }
        for name, (result, arguments) in specs.items():
            function = getattr(self.k, name)
            function.restype, function.argtypes = result, arguments

    def _creation(self) -> int:
        values = [FILETIME() for _ in range(4)]
        if not self.k.GetProcessTimes(self.info.process, *(C.byref(value) for value in values)):
            raise Refused("OWNED_PROCESS_TIME_UNAVAILABLE")
        return (int(values[0].high) << 32) | int(values[0].low)

    def _image(self) -> str:
        buffer = C.create_unicode_buffer(32768)
        length = W.DWORD(len(buffer))
        if not self.k.QueryFullProcessImageNameW(self.info.process, 0, buffer, C.byref(length)):
            raise Refused("OWNED_PROCESS_IMAGE_UNAVAILABLE")
        return canonical(buffer.value)

    def assert_identity(self, image: bool = True) -> None:
        if not self.started or self.k.GetProcessId(self.info.process) != self.info.pid or self._creation() != self.creation:
            raise Refused("OWNED_PROCESS_IDENTITY_CHANGED")
        if image and self._image() != canonical(self.executable):
            raise Refused("OWNED_PROCESS_PATH_CHANGED")

    def start(self) -> None:
        attributes = SECURITY_ATTRIBUTES(C.sizeof(SECURITY_ATTRIBUTES), None, True)
        nul = self.k.CreateFileW("NUL", 0xC0000000, 3, C.byref(attributes), 3, 0x80, None)
        if nul in (None, C.c_void_p(-1).value):
            raise Refused("PRIVATE_STDIO_UNAVAILABLE")
        attribute_buffer, initialized = None, False
        try:
            size = C.c_size_t()
            self.k.InitializeProcThreadAttributeList(None, 1, 0, C.byref(size))
            if not size.value:
                raise Refused("HANDLE_LIST_SIZE_UNAVAILABLE")
            attribute_buffer = C.create_string_buffer(size.value)
            if not self.k.InitializeProcThreadAttributeList(attribute_buffer, 1, 0, C.byref(size)):
                raise Refused("HANDLE_LIST_INITIALIZATION_FAILED")
            initialized = True
            handles = (W.HANDLE * 1)(nul)
            if not self.k.UpdateProcThreadAttribute(attribute_buffer, 0, 0x20002, handles, C.sizeof(handles), None, None):
                raise Refused("PRIVATE_HANDLE_LIST_FAILED")
            startup = STARTUPINFOEXW()
            startup.startup.cb = C.sizeof(startup)
            startup.startup.flags = 0x101  # hidden + explicitly private NUL stdio
            startup.startup.stdin = startup.startup.stdout = startup.startup.stderr = nul
            startup.attributes = C.cast(attribute_buffer, C.c_void_p)
            command = C.create_unicode_buffer('"' + str(self.executable) + '"')
            block = C.create_unicode_buffer("\0".join(name + "=" + value for name, value in sorted(self.environment.items(), key=lambda item: item[0].upper())) + "\0\0")
            flags = 2 | 0x400 | 0x80000 | 0x08000000
            if not self.k.CreateProcessW(str(self.executable), command, None, None, True, flags, block, str(self.executable.parent), C.byref(startup), C.byref(self.info)):
                raise OSError(C.get_last_error(), "PROCESS_START_FAILED")
            self.started = True
            self.creation = self._creation()
            self.assert_identity()
            if not self.k.DebugSetProcessKillOnExit(True):
                raise Refused("OWNED_DEBUG_EXIT_PROTECTION_FAILED")
        finally:
            if initialized:
                self.k.DeleteProcThreadAttributeList(attribute_buffer)
            self.k.CloseHandle(nul)

    def exit_code(self) -> int:
        value = W.DWORD()
        if not self.k.GetExitCodeProcess(self.info.process, C.byref(value)):
            raise Refused("OWNED_PROCESS_STATE_UNAVAILABLE")
        return int(value.value)

    def event(self, milliseconds: int = 200) -> DEBUG_EVENT | None:
        event = DEBUG_EVENT()
        if not self.k.WaitForDebugEvent(C.byref(event), milliseconds):
            error = C.get_last_error()
            if error == 121:
                return None
            raise Refused("OWNED_DEBUG_WAIT_FAILED")
        self.pending = (int(event.pid), int(event.tid))
        if event.pid != self.info.pid:
            raise Refused("UNEXPECTED_DEBUG_PROCESS")
        if event.code == 3 and event.data.create_process.file:
            self.k.CloseHandle(event.data.create_process.file)
        elif event.code == 6 and event.data.load_dll.file:
            self.k.CloseHandle(event.data.load_dll.file)
        return event

    def continue_event(self, disposition: int = 0x00010002) -> None:
        if self.pending:
            pid, tid = self.pending
            if not self.k.ContinueDebugEvent(pid, tid, disposition):
                raise Refused("OWNED_DEBUG_CONTINUE_FAILED")
            self.pending = None

    def terminate(self) -> bool:
        if not self.started:
            return False
        active = not self.exited and self.exit_code() == 259
        if self.creation is None:
            # CreateProcess returned this retained handle directly to us. If
            # identity capture itself failed, never reopen by PID: terminate
            # only that still-owned handle so the unverified child cannot run.
            if self.k.GetProcessId(self.info.process) != self.info.pid:
                raise Refused("OWNED_STARTUP_HANDLE_IDENTITY_CHANGED")
        else:
            self.assert_identity(image=active)
        terminated = False
        if active:
            if not self.k.TerminateProcess(self.info.process, 0xD0000001):
                raise Refused("OWNED_CHILD_TERMINATION_FAILED")
            terminated = True
        # Termination happens before continuing a pending event. No unrelated
        # process is attached, reopened by PID, or stopped by executable name.
        self.continue_event()
        deadline = time.monotonic() + 5
        while self.k.WaitForSingleObject(self.info.process, 0) != 0:
            if time.monotonic() >= deadline:
                raise Refused("OWNED_CHILD_EXIT_TIMEOUT")
            event = self.event(100)
            if event is not None:
                if event.code == 5:
                    self.exited = True
                self.continue_event()
        return terminated

    def close(self) -> None:
        for handle in (self.info.thread, self.info.process):
            if handle:
                self.k.CloseHandle(handle)


def settings_marker(home: Path, pid: int, earliest: float) -> bool:
    settings = home / "settings"
    marker = settings / ".startup-settings.json"
    if not marker.is_file() or marker.stat().st_mtime < earliest - 2:
        return False
    try:
        value = json.loads(marker.read_text(encoding="utf-8-sig"))
        return (
            type(value.get("pid")) is int and value["pid"] == pid
            and value.get("format") == "ini"
            and canonical(value.get("userPath", "")) == canonical(settings / "user")
            and canonical(value.get("systemPath", "")) == canonical(settings / "system")
            and (settings / "user").is_dir() and (settings / "system").is_dir()
        )
    except (OSError, ValueError, TypeError):
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True)
    parser.add_argument("--home", required=True)
    parser.add_argument("--flightrec", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--seconds", type=int, default=40)
    parser.add_argument("--symbols", help="Optional local symbols directory; no network symbol lookup.")
    args = parser.parse_args()
    result = {
        "Passed": False, "NativeSettingsIsolated": False, "Alive": False,
        "SecondChanceFaults": 0, "FaultCodes": [], "ProcessStartError": None,
        "SHA256": None, "PID": None, "CreatedUTC": None, "MonitoredSeconds": 0,
        "ExitCode": None, "TerminatedOwnChild": False, "Error": None,
    }
    child = None
    result_path = Path(args.result)
    may_write = False
    try:
        if sys.platform != "win32" or C.sizeof(C.c_void_p) != 8:
            raise Refused("X64_WINDOWS_PYTHON_REQUIRED")
        if not 1 <= args.seconds <= 300:
            raise Refused("MONITOR_DURATION_INVALID")
        for value in (args.exe, args.home, args.flightrec, args.result):
            if not re.match(r"^[A-Za-z]:[\\/]", value):
                raise Refused("LOCAL_ABSOLUTE_PATH_REQUIRED")
        executable, home, flightrec = (Path(value).resolve(strict=False) for value in (args.exe, args.home, args.flightrec))
        result_path = result_path.resolve(strict=False)
        if result_path.exists() or canonical(result_path) == canonical(executable):
            raise Refused("FRESH_RESULT_PATH_REQUIRED")
        result_path.parent.mkdir(parents=True, exist_ok=True)
        may_write = True
        if not executable.is_file():
            raise Refused("TARGET_EXECUTABLE_MISSING")
        result["SHA256"] = digest(executable)
        validate_binary(executable)
        if canonical(home) in {canonical(os.environ.get("USERPROFILE", "")), canonical(os.environ.get("APPDATA", "")), canonical(os.environ.get("LOCALAPPDATA", ""))}:
            raise Refused("REAL_PROFILE_DIRECTORY_REFUSED")
        if canonical(home) == canonical(flightrec) or canonical(home) == canonical(executable.parent):
            raise Refused("PRIVATE_DIRECTORY_COLLISION")
        make_private_directory(home)
        make_private_directory(flightrec)
        environment = isolated_environment(home, flightrec)
        child = OwnedDebugChild(executable, environment)
        launch_wallclock = time.time()
        child.start()
        result["PID"] = int(child.info.pid)
        result["CreatedUTC"] = DT.datetime.fromtimestamp((child.creation - 116444736000000000) / 10000000, DT.timezone.utc).isoformat()
        marker_deadline = time.monotonic() + 10
        observed_from = None
        while True:
            event = child.event()
            if event is not None:
                disposition = 0x00010002
                if event.code == 1:
                    exception = event.data.exception
                    code = int(exception.record.code)
                    if code == 0x80000003 and exception.first_chance and not child.initial_breakpoint:
                        child.initial_breakpoint = True
                    else:
                        disposition = 0x80010001
                        if not exception.first_chance:
                            result["SecondChanceFaults"] += 1
                            result["FaultCodes"].append("0x%08X" % code)
                elif event.code == 5:
                    child.exited = True
                    result["ExitCode"] = int(event.data.exit_process.code)
                child.continue_event(disposition)
            if child.exited:
                raise Refused("OWNED_CHILD_EXITED_EARLY")
            if result["SecondChanceFaults"]:
                raise Refused("OWNED_CHILD_SECOND_CHANCE_FAULT")
            if not result["NativeSettingsIsolated"]:
                if settings_marker(home, int(child.info.pid), launch_wallclock):
                    child.assert_identity()
                    result["NativeSettingsIsolated"] = True
                    observed_from = time.monotonic()
                elif time.monotonic() >= marker_deadline:
                    raise Refused("PRIVATE_SETTINGS_MARKER_MISSING_OR_INVALID")
            if observed_from is not None:
                result["MonitoredSeconds"] = round(time.monotonic() - observed_from, 3)
                if result["MonitoredSeconds"] >= args.seconds:
                    child.assert_identity()
                    result["Alive"] = child.exit_code() == 259
                    if digest(executable) != result["SHA256"]:
                        raise Refused("TARGET_FILE_CHANGED_DURING_MONITOR")
                    result["Passed"] = result["Alive"] and result["NativeSettingsIsolated"]
                    break
    except Refused as error:
        result["Error"] = str(error)
    except OSError as error:
        if child is not None and not child.started:
            result["ProcessStartError"] = int(getattr(error, "winerror", None) or error.errno or 1)
        result["Error"] = "OPERATING_SYSTEM_OPERATION_FAILED"
    except Exception:
        result["Error"] = "MONITOR_OPERATION_FAILED"
    finally:
        if child is not None:
            try:
                result["TerminatedOwnChild"] = child.terminate()
            except Exception:
                result["Passed"] = False
                result["Error"] = "OWNED_CHILD_CLEANUP_FAILED"
            finally:
                child.close()
        if may_write:
            try:
                # Only the requested fresh metadata result is written; private
                # test directories are retained and no recursive cleanup occurs.
                with result_path.open("x", encoding="utf-8") as stream:
                    json.dump(result, stream, ensure_ascii=True, indent=2)
            except Exception:
                result["Passed"] = False
                result["Error"] = "RESULT_WRITE_FAILED"
        print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return 0 if result["Passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
