"""Small, fixed Finder layout: two icons, no Finder automation/dependencies.

Writes one leaf in Apple's DS_Store buddy/B-tree container. Deliberately not a
general editor. Format reference: https://github.com/dmgbuild/ds_store .
The background alias must be created on the final mounted image, so it resolves
on another Mac rather than pointing back at the build host's staging folder.
"""
import ctypes
import os
from pathlib import Path
import plistlib
import struct

APP_NAME = 'Cilex Watchtower.app'


def finder_alias(path):
    core = ctypes.CDLL('/System/Library/Frameworks/CoreServices.framework/CoreServices')
    ref = ctypes.create_string_buffer(80)  # FSRef
    handle = ctypes.c_void_p()
    core.FSPathMakeRef.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
    core.FSPathMakeRef.restype = ctypes.c_int32
    core.FSNewAliasMinimal.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    core.FSNewAliasMinimal.restype = ctypes.c_int32
    core.GetHandleSize.argtypes = [ctypes.c_void_p]
    core.GetHandleSize.restype = ctypes.c_ssize_t
    core.HLock.argtypes = [ctypes.c_void_p]
    core.DisposeHandle.argtypes = [ctypes.c_void_p]
    if core.FSPathMakeRef(os.fsencode(Path(path).resolve()), ref, None) != 0:
        raise ValueError('Cannot locate the Finder background on the mounted DMG')
    if core.FSNewAliasMinimal(ref, ctypes.byref(handle)) != 0 or not handle.value:
        raise ValueError('Cannot create the Finder background alias')
    try:
        core.HLock(handle)
        size = core.GetHandleSize(handle)
        if not 0 < size <= 16384:
            raise ValueError('Unexpected Finder alias size')
        return ctypes.string_at(ctypes.cast(handle, ctypes.POINTER(ctypes.c_void_p))[0], size)
    finally:
        core.DisposeHandle(handle)


def store_bytes(alias):
    window = {'WindowBounds': '{{200, 160}, {680, 420}}', 'ShowToolbar': False,
              'ShowStatusBar': False, 'ShowSidebar': False, 'ContainerShowSidebar': False,
              'ShowPathbar': False, 'ShowTabView': False, 'PreviewPaneVisibility': False}
    icons = {'viewOptionsVersion': 1, 'backgroundType': 2, 'backgroundImageAlias': alias,
             'iconSize': 112.0, 'textSize': 14.0, 'labelOnBottom': True,
             'arrangeBy': 'none', 'gridSpacing': 100.0, 'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
             'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
             'showIconPreview': False, 'showItemInfo': False}
    records = []
    def record(name, code, kind, value):
        encoded = name.encode('utf-16be')
        records.append(struct.pack('>I', len(encoded)//2) + encoded + code + kind + value)
    def blob(name, code, value):
        record(name, code, b'blob', struct.pack('>I', len(value)) + value)
    blob('.', b'bwsp', plistlib.dumps(window, fmt=plistlib.FMT_BINARY))
    record('.', b'icvl', b'type', b'icnv')
    blob('.', b'icvp', plistlib.dumps(icons, fmt=plistlib.FMT_BINARY))
    record('.', b'vSrn', b'long', struct.pack('>I', 1))
    for name, x in (('Applications', 510), (APP_NAME, 170)):
        blob(name, b'Iloc', struct.pack('>4I', x, 220, 0xffffffff, 0xffff0000))
    leaf = struct.pack('>II', 0, len(records)) + b''.join(records)
    if len(leaf) > 4096:
        raise ValueError('Finder layout exceeds its fixed leaf page')
    data = bytearray(12292)
    struct.pack_into('>I4sIII16s', data, 0, 1, b'Bud1', 4096, 2048, 4096, bytes(16))
    # Block 0: allocator. Block 1: B-tree header. Block 2: single leaf.
    struct.pack_into('>5I', data, 4100, 3, 0, 4096 | 11, 64 | 5, 8192 | 12)
    pos = 4100 + 1032
    toc = struct.pack('>IB4sI', 1, 4, b'DSDB', 1)
    data[pos:pos+len(toc)] = toc
    pos += len(toc)
    free = {5: [32, 96], 7: [128], 8: [256], 9: [512], 10: [1024],
            11: [2048, 6144], 12: [12288]}
    free.update({width: [1 << width] for width in range(14, 31)})
    for width in range(32):
        offsets = free.get(width, [])
        values = struct.pack('>' + 'I' * (len(offsets)+1), len(offsets), *offsets)
        data[pos:pos+len(values)] = values
        pos += len(values)
    struct.pack_into('>5I', data, 68, 2, 0, len(records), 1, 4096)
    data[8196:8196+len(leaf)] = leaf
    return bytes(data)


def configure(volume):
    volume = Path(volume)
    (volume / '.DS_Store').write_bytes(store_bytes(finder_alias(volume / '.background/install.png')))
