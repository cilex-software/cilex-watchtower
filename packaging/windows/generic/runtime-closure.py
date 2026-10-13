"""Build-time PE import closure; never searches PATH or an installed Watchtower.

The small system allowlist represents DLLs supplied by supported Windows, not
whatever happens to be installed in System32 on the developer's computer.
Dynamic Qt/QML/GStreamer plugins are explicitly staged by Build.psm1 before
this pass. This is a necessary static check, not proof of video/GPU behavior.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys


SYSTEM_DLLS = set("""
advapi32.dll authz.dll avicap32.dll avrt.dll bcrypt.dll bcryptprimitives.dll cabinet.dll
cfgmgr32.dll clbcatq.dll comctl32.dll comdlg32.dll concrt140-invalid.dll crypt32.dll
cryptbase.dll cryptnet.dll cryptsp.dll d2d1.dll d3d9.dll d3d10.dll d3d10_1.dll
d3d11.dll d3d12.dll d3dcompiler_47.dll dcomp.dll dbghelp.dll dhcpcsvc.dll
dhcpcsvc6.dll dnsapi.dll dsound.dll dwmapi.dll dwrite.dll dxgi.dll dxva2.dll
evr.dll faultrep.dll fwpuclnt.dll gdi32.dll gdi32full.dll glu32.dll hid.dll
icuuc.dll icuin.dll imagehlp.dll imm32.dll iphlpapi.dll kernel32.dll kernelbase.dll ksuser.dll mapi32.dll
mf.dll mfplat.dll mfreadwrite.dll mfuuid.dll mmdevapi.dll mpr.dll msacm32.dll mscms.dll
msasn1.dll msdmo.dll msvcrt.dll mswsock.dll ncrypt.dll netapi32.dll ntdll.dll
ntmarta.dll odbc32.dll ole32.dll oleacc.dll oleaut32.dll opengl32.dll pdh.dll powrprof.dll
profapi.dll propsys.dll psapi.dll rasapi32.dll rpcrt4.dll secur32.dll
sechost.dll setupapi.dll shcore.dll shell32.dll shlwapi.dll srpapi.dll sspicli.dll
strmiids.dll ucrtbase.dll uiautomationcore.dll urlmon.dll user32.dll userenv.dll usp10.dll uxtheme.dll
version.dll virtdisk.dll win32u.dll windowscodecs.dll winhttp.dll wininet.dll
winmm.dll winspool.drv wintrust.dll winusb.dll wldap32.dll ws2_32.dll wsock32.dll wtsapi32.dll
normaliz.dll msimg32.dll sensapi.dll winrnr.dll winnsi.dll nsi.dll
""".split())
SYSTEM_DLLS.discard("concrt140-invalid.dll")
# Windows 10 1703 includes icuuc/icuin; do not add icu.dll (introduced in
# 1903) to a 1809 baseline. https://learn.microsoft.com/windows/win32/intl/international-components-for-unicode--icu-


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest().upper()


def is_system(name):
    name = name.lower()
    return name in SYSTEM_DLLS or name.startswith(("api-ms-win-", "ext-ms-win-"))


def pe_imports(path):
    import pefile
    with pefile.PE(str(path), fast_load=True) as pe:
        if pe.FILE_HEADER.Machine != 0x8664:
            raise ValueError("non-x64 runtime file: " + path.name)
        pe.parse_data_directories(directories=[1, 13])
        result = set()
        for table in ("DIRECTORY_ENTRY_IMPORT", "DIRECTORY_ENTRY_DELAY_IMPORT"):
            for item in getattr(pe, table, []):
                name = item.dll.decode("ascii").lower()
                if Path(name).name != name or ":" in name or "\\" in name:
                    raise ValueError("invalid PE import name")
                result.add(name)
        return sorted(result)


def inventory(root):
    """Reject junctions and symlinks rather than copying an external tree."""
    root = Path(root).resolve(strict=True)
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
            raise ValueError("linked runtime path is not allowed")
        if path.is_file():
            path.resolve(strict=True).relative_to(root)
            yield path


def complete_closure(payload, roots, inspect=pe_imports):
    payload = Path(payload).resolve(strict=True)
    candidates = {}
    for root in roots:
        for file in inventory(root):
            if file.suffix.lower() == ".dll":
                candidates.setdefault(file.name.lower(), []).append(file)
    pending = [p for p in inventory(payload)
               if p.suffix.lower() in (".exe", ".dll")
               and "prerequisites" not in p.relative_to(payload).parts]
    checked = set()
    copied = []
    imports = {}
    while pending:
        binary = pending.pop()
        relative = binary.relative_to(payload).as_posix()
        if relative in checked:
            continue
        checked.add(relative)
        dependencies = inspect(binary)
        imports[relative] = dependencies
        for name in dependencies:
            if is_system(name):
                continue
            # Windows executable/plugin directory, then application root.
            local = next((p for folder in (binary.parent, payload)
                          for p in folder.iterdir()
                          if p.is_file() and p.name.lower() == name), None)
            if local:
                pending.append(local)
                continue
            found = candidates.get(name, [])
            if not found:
                raise ValueError("missing runtime dependency: %s requires %s" % (relative, name))
            hashes = {digest(p) for p in found}
            if len(hashes) != 1:
                raise ValueError("ambiguous runtime dependency: " + name)
            destination = payload / found[0].name
            if destination.exists():
                raise ValueError("runtime dependency destination changed")
            shutil.copyfile(found[0], destination)
            copied.append({"path": destination.name, "sha256": digest(destination)})
            pending.append(destination)
    return {"passed": True, "checkedFiles": len(checked), "copied": copied,
            "imports": imports, "limitation": "Static imports only; dynamic paths need runtime tests."}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload", required=True)
    parser.add_argument("--root", action="append", default=[])
    parser.add_argument("--result", required=True)
    args = parser.parse_args()
    try:
        result = complete_closure(args.payload, args.root)
    except Exception as error:
        result = {"passed": False, "error": str(error)}
    destination = Path(args.result)
    with destination.open("x", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=True, indent=2)
    print(json.dumps({"passed": result["passed"], "result": str(destination)}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
