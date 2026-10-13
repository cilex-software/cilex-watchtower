#!/usr/bin/env python3
"""Compare a frozen Warden module with source without executing either.

Run on the Windows build host using its existing Python/PyInstaller installation.
The source hash includes its original bytes. Only code filenames are normalized.
"""

import sys
sys.dont_write_bytecode = True

import argparse
import dis
import hashlib
import json
import marshal
from pathlib import Path
import re
import types


def normalize(code):
    return code.replace(
        co_filename="<warden>",
        co_consts=tuple(normalize(item) if isinstance(item, types.CodeType) else item
                        for item in code.co_consts),
    )


def version_of(code):
    instructions = list(dis.get_instructions(code))
    found = [instructions[index - 1].argval
             for index, instruction in enumerate(instructions)
             if index and instruction.opname == "STORE_NAME"
             and instruction.argval == "WARDEN_VERSION"
             and instructions[index - 1].opname == "LOAD_CONST"]
    if len(found) != 1 or not isinstance(found[0], str):
        raise ValueError("warden_version_unavailable")
    return found[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    args = parser.parse_args()
    result = dict(matches=False, warden_version=None, exe_sha256=None,
                  source_sha256=None)
    failure = "input_read_failed"
    try:
        executable = args.exe.read_bytes()
        source = args.source.read_bytes()
        result["exe_sha256"] = hashlib.sha256(executable).hexdigest()
        result["source_sha256"] = hashlib.sha256(source).hexdigest()
        failure = "pyinstaller_unavailable"
        from PyInstaller.archive.readers import CArchiveReader

        failure = "archive_read_failed"
        archive = CArchiveReader(str(args.exe))
        # Marshal is version-specific. Refuse a different bundled Windows Python
        # before reading its code objects rather than returning a false match.
        python_dlls = [Path(name).name for name in archive.toc
                       if re.fullmatch(r"python\d+\.dll", Path(name).name,
                                       re.IGNORECASE)]
        if len(python_dlls) != 1:
            failure = "archive_python_version_unavailable"
            raise ValueError(failure)
        digits = re.search(r"python(\d+)\.dll", python_dlls[0], re.IGNORECASE).group(1)
        if digits != f"{sys.version_info.major}{sys.version_info.minor}":
            failure = "archive_python_version_mismatch"
            raise ValueError(failure)
        failure = "embedded_warden_code_unavailable"
        embedded = marshal.loads(archive.extract("warden"))
        if not isinstance(embedded, types.CodeType):
            raise ValueError(failure)
        failure = "warden_version_unavailable"
        result["warden_version"] = version_of(embedded)
        failure = "source_compile_failed"
        compiled = compile(source.decode("utf-8-sig"), "<warden>", "exec", optimize=0)
        source_version = version_of(compiled)
        failure = "files_changed_during_inspection"
        if args.exe.read_bytes() != executable or args.source.read_bytes() != source:
            raise ValueError(failure)
        result["matches"] = (result["warden_version"] == source_version
                             and normalize(embedded) == normalize(compiled))
        print(json.dumps(result, ensure_ascii=True))
        return 0 if result["matches"] else 1
    except Exception:
        # Never print arbitrary exception text, source, archive constants, or
        # command output. The caller gets a bounded, credential-free failure.
        result["error"] = failure
        print(json.dumps(result, ensure_ascii=True))
        return 2


if __name__ == "__main__":
    sys.exit(main())
