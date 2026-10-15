"""Strict, developer-tool-independent Mach-O inventory for offline admission.

This is structural verification, not proof of API availability or runtime health.
All slices are inspected, even though this workflow only advertises arm64.
"""
from __future__ import annotations
import hashlib
import os
import plistlib
import struct
from pathlib import Path

class ClosureError(ValueError):
    pass

ARCHES = {0x0100000c: "arm64", 0x01000007: "x86_64", 12: "arm", 7: "i386"}
MAGICS = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}

def version_tuple(value):
    parts = str(value).split('.')
    if not 1 <= len(parts) <= 3 or any(not x.isdigit() for x in parts):
        raise ClosureError("Invalid macOS version: " + str(value))
    return tuple(int(x) for x in parts) + (0,) * (3-len(parts))

def packed_version(value):
    return "%d.%d.%d" % (value >> 16, (value >> 8) & 255, value & 255)

def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            digest.update(block)
    return digest.hexdigest()

def is_macho(path):
    with open(path, 'rb') as stream:
        return stream.read(4) in MAGICS

def _thin(data):
    magic = data[:4]
    if magic not in MAGICS or magic in {b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}:
        raise ClosureError("Invalid Mach-O slice")
    endian = '<' if magic[0] in (0xcf, 0xce) else '>'
    header = 32 if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf') else 28
    if len(data) < header:
        raise ClosureError("Truncated Mach-O header")
    cpu, subtype, filetype, count, size, flags = struct.unpack_from(endian+'6I', data, 4)
    if header + size > len(data) or count > size // 8:
        raise ClosureError("Invalid Mach-O load command bounds")
    result = dict(arch=ARCHES.get(cpu, hex(cpu)), cpu_subtype=subtype, filetype=filetype,
                  dylibs=[], rpaths=[], minimum_macos=None, sdk=None, install_name=None, dynamic_linker=None, uuid=None)
    offset = header
    for _ in range(count):
        cmd, length = struct.unpack_from(endian+'II', data, offset)
        if length < 8 or offset+length > header+size:
            raise ClosureError("Invalid Mach-O load command size")
        raw = data[offset:offset+length]
        cmd &= 0x7fffffff
        if cmd == 0x27:
            raise ClosureError('Embedded dynamic-loader environment is not permitted')
        if cmd in (0xc, 0xd, 0x18, 0x1f, 0x20, 0x23, 0x1c, 0xe):
            if length < 12:
                raise ClosureError("Truncated Mach-O string command")
            start = struct.unpack_from(endian+'I', raw, 8)[0]
            if start < 12 or start >= length or b'\0' not in raw[start:]:
                raise ClosureError("Invalid Mach-O string")
            value = raw[start:].split(b'\0', 1)[0].decode('utf-8', errors='strict')
            if cmd == 0xe:
                if value != '/usr/lib/dyld': raise ClosureError('Non-system dynamic linker is not permitted')
                result['dynamic_linker'] = value
            elif cmd == 0xd: result['install_name'] = value
            elif cmd == 0x1c: result['rpaths'].append(value)
            else: result['dylibs'].append(value)
        elif cmd == 0x1b:
            if length != 24: raise ClosureError('Invalid LC_UUID size')
            result['uuid']=raw[8:24].hex()
        elif cmd == 0x32:
            if length < 24: raise ClosureError("Truncated LC_BUILD_VERSION")
            plat, minimum, sdk = struct.unpack_from(endian+'III', raw, 8)
            if plat != 1: raise ClosureError("Non-macOS Mach-O platform")
            result.update(minimum_macos=packed_version(minimum), sdk=packed_version(sdk))
        elif cmd == 0x24:
            if length < 16: raise ClosureError("Truncated LC_VERSION_MIN_MACOSX")
            minimum, sdk = struct.unpack_from(endian+'II', raw, 8)
            result.update(minimum_macos=packed_version(minimum), sdk=packed_version(sdk))
        offset += length
    if offset != header + size:
        raise ClosureError("Unaccounted Mach-O command bytes")
    return result

def parse_macho(path):
    data = Path(path).read_bytes()
    magic = data[:4]
    if magic in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
        endian = '>' if magic[0] == 0xca else '<'
        wide = magic in (b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca')
        if len(data) < 8: raise ClosureError("Truncated fat Mach-O")
        count = struct.unpack_from(endian+'I', data, 4)[0]
        stride = 32 if wide else 20
        if not count or count > 32 or 8+stride*count > len(data):
            raise ClosureError("Invalid fat slice table")
        ranges, slices = [], []
        for i in range(count):
            pos = 8+stride*i
            cpu, sub = struct.unpack_from(endian+'II', data, pos)
            offset, size = struct.unpack_from(endian+('QQ' if wide else 'II'), data, pos+8)
            if offset < 8+stride*count or size < 28 or offset+size > len(data):
                raise ClosureError("Invalid fat slice bounds")
            if any(offset < end and offset+size > start for start,end in ranges):
                raise ClosureError("Overlapping fat slices")
            ranges.append((offset,offset+size))
            item = _thin(data[offset:offset+size])
            if item['arch'] != ARCHES.get(cpu,hex(cpu)) or item['cpu_subtype'] != sub:
                raise ClosureError("Fat table and slice architecture disagree")
            slices.append(item)
        if len({s['arch'] for s in slices}) != len(slices):
            raise ClosureError("Duplicate architecture slices")
        return slices
    return [_thin(data)]

def is_system_load(value):
    import posixpath
    return posixpath.normpath(value)==value and value.startswith(('/System/Library/','/usr/lib/'))

def contained(path, root):
    try: Path(path).resolve().relative_to(Path(root).resolve()); return True
    except ValueError: return False

def inventory(root):
    """No escaping links, case/NFD collisions, special files, writable code or setid."""
    import stat, unicodedata
    root = Path(root).resolve()
    seen, files = set(), []
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root).as_posix()
        key = unicodedata.normalize('NFD', rel).casefold()
        if key in seen: raise ClosureError("Filename collision: " + rel)
        seen.add(key)
        st = path.lstat()
        mode = stat.S_IMODE(st.st_mode)
        if not path.is_symlink() and mode & 0o7022: raise ClosureError("Unsafe file permissions: " + rel)
        entry = dict(path=rel, mode=mode)
        if path.is_symlink():
            target = os.readlink(path)
            if target.startswith('/') or not contained(path,root) or not path.exists():
                raise ClosureError("Escaping, absolute or broken symlink: " + rel)
            entry.update(type='symlink',target=target)
        elif path.is_dir(): entry.update(type='directory')
        elif path.is_file(): entry.update(type='file',sha256=sha256(path),size=st.st_size)
        else: raise ClosureError("Special file is not permitted: " + rel)
        files.append(entry)
    return files

def validate_bundle(app):
    app = Path(app)
    with (app/'Contents/Info.plist').open('rb') as stream: plist = plistlib.load(stream)
    if plist.get('CFBundleIdentifier') != 'com.cilexvision.watchtower':
        raise ClosureError("Watchtower bundle identifier mismatch")
    import re
    for key in ('CFBundleVersion','CFBundleShortVersionString'):
        if not isinstance(plist.get(key),str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}',plist[key]):
            raise ClosureError("Empty or invalid bundle version: " + key)
    exe = plist.get('CFBundleExecutable')
    if not exe or Path(exe).name != exe or not (app/'Contents/MacOS'/exe).is_file():
        raise ClosureError("Invalid bundle executable")
    if not any('cilex' in e.get('CFBundleURLSchemes',[]) for e in plist.get('CFBundleURLTypes',[])):
        raise ClosureError("Missing cilex:// registration")
    return plist

def _expand(value, binary, executable):
    if value == '@loader_path': return binary.parent
    if value == '@executable_path': return executable.parent
    if value.startswith('@loader_path/'):
        return binary.parent/value[len('@loader_path/'):]
    if value.startswith('@executable_path/'):
        return executable.parent/value[len('@executable_path/'):]
    if value.startswith('/'): return Path(value)
    return None

def audit(root, arch='arm64', source_minimum='14.4', executable=None):
    root = Path(root).resolve()
    inventory(root)
    binaries = [p for p in root.rglob('*') if p.is_file() and not p.is_symlink() and is_macho(p)]
    if not binaries: raise ClosureError("No Mach-O runtime found")
    records = []
    floor = version_tuple(source_minimum)
    for binary in binaries:
        slices = parse_macho(binary)
        if arch not in {s['arch'] for s in slices}:
            raise ClosureError("Required architecture missing: " + str(binary.relative_to(root)))
        # Each process has its own executable_path. Python helpers use their own executable.
        main = Path(executable) if executable else binary
        enclosing = next((p for p in binary.parents if p.suffix == '.app'), None)
        if enclosing and (enclosing/'Contents/Info.plist').is_file():
            with (enclosing/'Contents/Info.plist').open('rb') as f: meta=plistlib.load(f)
            main = enclosing/'Contents/MacOS'/meta.get('CFBundleExecutable','')
        for item in slices:
            if not item['minimum_macos']: raise ClosureError("Missing deployment target: " + str(binary))
            if item['install_name'] and not item['install_name'].startswith(('@loader_path/','@rpath/')):
                raise ClosureError('External/absolute Mach-O install ID: '+item['install_name'])
            if item['arch'] == arch: floor=max(floor,version_tuple(item['minimum_macos']))
            for rpath in item['rpaths']:
                expanded = _expand(rpath,binary,main)
                if expanded is None or not contained(expanded,root):
                    raise ClosureError("External/ambiguous runtime search path: " + rpath)
            for dylib in item['dylibs']:
                if is_system_load(dylib): continue
                candidates=[]
                if dylib.startswith('@rpath/'):
                    candidates=[_expand(r,binary,main)/dylib[7:] for r in item['rpaths'] if _expand(r,binary,main)]
                    # dyld inherits the executable's rpaths; do not guess by basename.
                    if main.is_file() and main != binary and is_macho(main):
                        for s in parse_macho(main):
                            if s['arch'] == item['arch']:
                                candidates.extend(_expand(r,main,main)/dylib[7:] for r in s['rpaths'] if _expand(r,main,main))
                else:
                    value=_expand(dylib,binary,main)
                    if value: candidates=[value]
                valid={p.resolve() for p in candidates if p.is_file() and contained(p,root)}
                if len(valid) != 1: raise ClosureError("Unresolved/external/ambiguous dependency: %s -> %s" % (binary.relative_to(root),dylib))
                target=next(iter(valid))
                if not is_macho(target) or item['arch'] not in {s['arch'] for s in parse_macho(target)}:
                    raise ClosureError("Dependency lacks corresponding architecture: " + str(target))
        records.append(dict(path=binary.relative_to(root).as_posix(),sha256=sha256(binary),slices=slices))
    return dict(schema_version=1,arch=arch,minimum_macos='.'.join(map(str,floor)),components=records,
                static_status='passed',api_availability='unverified',clean_machine_runtime='unverified')
