"""Run watchtower.exe under a minimal debugger and report WHY it aborts.

1.1.671 dies ~4 s after start on the booth with 0xC0000409 inside ucrtbase!abort
(Windows Application log: fault offset 0x11858), and no fatal line reaches the flight
recorder. This prints, as they happen:
  * every OutputDebugString (Qt's default handler sends qFatal text there),
  * every first-chance C++ exception (0xE06D7363) with its thrown TYPE NAME,
  * the fast-fail / any second-chance exception,
each with a symbolised stack (dbghelp + the build's PDB). Runs from C:\\wt\\pb2 (the
hardlinked runtime), with its own flight recorder, never the guard's install.

  python catch_abort.py [offscreen|window] [seconds]
"""
import ctypes, os, sys, time
from ctypes import wintypes as W

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
dbg = ctypes.WinDLL("dbghelp", use_last_error=True)
EXE = r"C:\wt\pb2\watchtower.exe"
SYMPATH = r"C:\dev\cilex-watchtower\build-windows;C:\wt\pb2"
mode = sys.argv[1] if len(sys.argv) > 1 else "offscreen"
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 25.0

DEBUG_ONLY_THIS_PROCESS = 0x2
CREATE_UNICODE_ENVIRONMENT = 0x400
DBG_CONTINUE, DBG_EXCEPTION_NOT_HANDLED = 0x00010002, 0x80010001
EXCEPTION_DEBUG_EVENT, CREATE_THREAD, CREATE_PROCESS, EXIT_THREAD, EXIT_PROCESS, LOAD_DLL, UNLOAD_DLL, OUTPUT_DEBUG_STRING = 1, 2, 3, 4, 5, 6, 7, 8


class EXCEPTION_RECORD(ctypes.Structure):
    _fields_ = [("ExceptionCode", W.DWORD), ("ExceptionFlags", W.DWORD), ("ExceptionRecord", ctypes.c_void_p),
                ("ExceptionAddress", ctypes.c_void_p), ("NumberParameters", W.DWORD),
                ("ExceptionInformation", ctypes.c_uint64 * 15)]


class EXCEPTION_DEBUG_INFO(ctypes.Structure):
    _fields_ = [("ExceptionRecord", EXCEPTION_RECORD), ("dwFirstChance", W.DWORD)]


class CREATE_PROCESS_DEBUG_INFO(ctypes.Structure):
    _fields_ = [("hFile", W.HANDLE), ("hProcess", W.HANDLE), ("hThread", W.HANDLE), ("lpBaseOfImage", ctypes.c_void_p),
                ("dwDebugInfoFileOffset", W.DWORD), ("nDebugInfoSize", W.DWORD), ("lpThreadLocalBase", ctypes.c_void_p),
                ("lpStartAddress", ctypes.c_void_p), ("lpImageName", ctypes.c_void_p), ("fUnicode", W.WORD)]


class CREATE_THREAD_DEBUG_INFO(ctypes.Structure):
    _fields_ = [("hThread", W.HANDLE), ("lpThreadLocalBase", ctypes.c_void_p), ("lpStartAddress", ctypes.c_void_p)]


class LOAD_DLL_DEBUG_INFO(ctypes.Structure):
    _fields_ = [("hFile", W.HANDLE), ("lpBaseOfDll", ctypes.c_void_p), ("dwDebugInfoFileOffset", W.DWORD),
                ("nDebugInfoSize", W.DWORD), ("lpImageName", ctypes.c_void_p), ("fUnicode", W.WORD)]


class OUTPUT_DEBUG_STRING_INFO(ctypes.Structure):
    _fields_ = [("lpDebugStringData", ctypes.c_void_p), ("fUnicode", W.WORD), ("nDebugStringLength", W.WORD)]


class EXIT_PROCESS_DEBUG_INFO(ctypes.Structure):
    _fields_ = [("dwExitCode", W.DWORD)]


class U(ctypes.Union):
    _fields_ = [("Exception", EXCEPTION_DEBUG_INFO), ("CreateThread", CREATE_THREAD_DEBUG_INFO),
                ("CreateProcessInfo", CREATE_PROCESS_DEBUG_INFO), ("LoadDll", LOAD_DLL_DEBUG_INFO),
                ("DebugString", OUTPUT_DEBUG_STRING_INFO), ("ExitProcess", EXIT_PROCESS_DEBUG_INFO),
                ("pad", ctypes.c_byte * 160)]


class DEBUG_EVENT(ctypes.Structure):
    _fields_ = [("dwDebugEventCode", W.DWORD), ("dwProcessId", W.DWORD), ("dwThreadId", W.DWORD), ("u", U)]


class STARTUPINFOW(ctypes.Structure):
    _fields_ = [("cb", W.DWORD), ("lpReserved", W.LPWSTR), ("lpDesktop", W.LPWSTR), ("lpTitle", W.LPWSTR),
                ("dwX", W.DWORD), ("dwY", W.DWORD), ("dwXSize", W.DWORD), ("dwYSize", W.DWORD),
                ("dwXCountChars", W.DWORD), ("dwYCountChars", W.DWORD), ("dwFillAttribute", W.DWORD),
                ("dwFlags", W.DWORD), ("wShowWindow", W.WORD), ("cbReserved2", W.WORD),
                ("lpReserved2", ctypes.c_void_p), ("hStdInput", W.HANDLE), ("hStdOutput", W.HANDLE),
                ("hStdError", W.HANDLE)]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess", W.HANDLE), ("hThread", W.HANDLE), ("dwProcessId", W.DWORD), ("dwThreadId", W.DWORD)]


# x64 CONTEXT: 1232 bytes, 16-byte aligned. Only the fields StackWalk64 seeds are named.
CONTEXT_ALL = 0x10001F


class CONTEXT(ctypes.Structure):
    _pack_ = 16
    _fields_ = [("P1Home", ctypes.c_uint64 * 6), ("ContextFlags", W.DWORD), ("MxCsr", W.DWORD),
                ("SegCs", W.WORD), ("SegDs", W.WORD), ("SegEs", W.WORD), ("SegFs", W.WORD), ("SegGs", W.WORD),
                ("SegSs", W.WORD), ("EFlags", W.DWORD), ("Dr", ctypes.c_uint64 * 6),
                ("Rax", ctypes.c_uint64), ("Rcx", ctypes.c_uint64), ("Rdx", ctypes.c_uint64), ("Rbx", ctypes.c_uint64),
                ("Rsp", ctypes.c_uint64), ("Rbp", ctypes.c_uint64), ("Rsi", ctypes.c_uint64), ("Rdi", ctypes.c_uint64),
                ("R8_15", ctypes.c_uint64 * 8), ("Rip", ctypes.c_uint64), ("rest", ctypes.c_byte * 976)]


class ADDRESS64(ctypes.Structure):
    _fields_ = [("Offset", ctypes.c_uint64), ("Segment", W.WORD), ("Mode", W.DWORD)]


class STACKFRAME64(ctypes.Structure):
    _fields_ = [("AddrPC", ADDRESS64), ("AddrReturn", ADDRESS64), ("AddrFrame", ADDRESS64), ("AddrStack", ADDRESS64),
                ("AddrBStore", ADDRESS64), ("FuncTableEntry", ctypes.c_void_p), ("Params", ctypes.c_uint64 * 4),
                ("Far", W.BOOL), ("Virtual", W.BOOL), ("Reserved", ctypes.c_uint64 * 3), ("KdHelp", ctypes.c_byte * 256)]


class SYMBOL_INFOW(ctypes.Structure):
    _fields_ = [("SizeOfStruct", W.ULONG), ("TypeIndex", W.ULONG), ("Reserved", ctypes.c_uint64 * 2),
                ("Index", W.ULONG), ("Size", W.ULONG), ("ModBase", ctypes.c_uint64), ("Flags", W.ULONG),
                ("Value", ctypes.c_uint64), ("Address", ctypes.c_uint64), ("Register", W.ULONG),
                ("Scope", W.ULONG), ("Tag", W.ULONG), ("NameLen", W.ULONG), ("MaxNameLen", W.ULONG),
                ("Name", ctypes.c_wchar * 512)]


class IMAGEHLP_LINEW64(ctypes.Structure):
    _fields_ = [("SizeOfStruct", W.DWORD), ("Key", ctypes.c_void_p), ("LineNumber", W.DWORD),
                ("FileName", ctypes.c_wchar_p), ("Address", ctypes.c_uint64)]


k32.WaitForDebugEvent.argtypes = [ctypes.POINTER(DEBUG_EVENT), W.DWORD]
k32.ContinueDebugEvent.argtypes = [W.DWORD, W.DWORD, W.DWORD]
k32.ReadProcessMemory.argtypes = [W.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
k32.GetThreadContext.argtypes = [W.HANDLE, ctypes.POINTER(CONTEXT)]
k32.GetFinalPathNameByHandleW.argtypes = [W.HANDLE, W.LPWSTR, W.DWORD, W.DWORD]
dbg.SymInitializeW.argtypes = [W.HANDLE, W.LPCWSTR, W.BOOL]
dbg.SymFromAddrW.argtypes = [W.HANDLE, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(SYMBOL_INFOW)]
dbg.SymGetLineFromAddrW64.argtypes = [W.HANDLE, ctypes.c_uint64, ctypes.POINTER(W.DWORD), ctypes.POINTER(IMAGEHLP_LINEW64)]
dbg.SymGetModuleBase64.restype = ctypes.c_uint64
dbg.SymGetModuleBase64.argtypes = [W.HANDLE, ctypes.c_uint64]
dbg.SymFunctionTableAccess64.restype = ctypes.c_void_p
dbg.SymFunctionTableAccess64.argtypes = [W.HANDLE, ctypes.c_uint64]
dbg.StackWalk64.argtypes = [W.DWORD, W.HANDLE, W.HANDLE, ctypes.POINTER(STACKFRAME64), ctypes.c_void_p,
                            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
dbg.SymSetOptions(0x2 | 0x10 | 0x4)   # UNDNAME | LOAD_LINES | DEFERRED_LOADS


def rpm(h, addr, n):
    buf = ctypes.create_string_buffer(n)
    got = ctypes.c_size_t()
    if not k32.ReadProcessMemory(h, ctypes.c_void_p(addr), buf, n, ctypes.byref(got)):
        return None
    return buf.raw[:got.value]


modules = {}      # base -> path
threads = {}      # tid -> handle
hproc = None
sym_ready = False


def modname(addr):
    best = None
    for b, p in modules.items():
        if b <= addr and (best is None or b > best):
            best = b
    return (os.path.basename(modules[best]) + f"+0x{addr - best:x}") if best is not None else f"0x{addr:x}"


def symbolise(addr):
    si = SYMBOL_INFOW()
    si.SizeOfStruct = ctypes.sizeof(SYMBOL_INFOW) - ctypes.sizeof(ctypes.c_wchar) * 512 + 2
    si.SizeOfStruct = 88
    si.MaxNameLen = 511
    disp = ctypes.c_uint64()
    name = None
    if dbg.SymFromAddrW(hproc, addr, ctypes.byref(disp), ctypes.byref(si)):
        name = f"{si.Name}+0x{disp.value:x}"
    ln = IMAGEHLP_LINEW64()
    ln.SizeOfStruct = ctypes.sizeof(IMAGEHLP_LINEW64)
    d32 = W.DWORD()
    where = ""
    if dbg.SymGetLineFromAddrW64(hproc, addr, ctypes.byref(d32), ctypes.byref(ln)) and ln.FileName:
        where = f"  [{os.path.basename(ln.FileName)}:{ln.LineNumber}]"
    return f"{modname(addr):<34} {name or '?'}{where}"


def stack(tid, maxf=28):
    global sym_ready
    if not sym_ready:
        dbg.SymInitializeW(hproc, SYMPATH, True)
        sym_ready = True
    else:
        dbg.SymRefreshModuleList(hproc)
    th = threads.get(tid)
    if not th:
        return ["  (no thread handle)"]
    ctx_buf = ctypes.create_string_buffer(ctypes.sizeof(CONTEXT) + 16)
    off = (16 - ctypes.addressof(ctx_buf) % 16) % 16
    ctx = CONTEXT.from_buffer(ctx_buf, off)
    ctx.ContextFlags = CONTEXT_ALL
    if not k32.GetThreadContext(th, ctypes.byref(ctx)):
        return [f"  (GetThreadContext failed {ctypes.get_last_error()})"]
    sf = STACKFRAME64()
    sf.AddrPC.Offset, sf.AddrPC.Mode = ctx.Rip, 3
    sf.AddrFrame.Offset, sf.AddrFrame.Mode = ctx.Rbp, 3
    sf.AddrStack.Offset, sf.AddrStack.Mode = ctx.Rsp, 3
    out = []
    fta = ctypes.cast(dbg.SymFunctionTableAccess64, ctypes.c_void_p)
    gmb = ctypes.cast(dbg.SymGetModuleBase64, ctypes.c_void_p)
    for _ in range(maxf):
        if not dbg.StackWalk64(0x8664, hproc, th, ctypes.byref(sf), ctypes.byref(ctx), None, fta, gmb, None):
            break
        if not sf.AddrPC.Offset:
            break
        out.append("    " + symbolise(sf.AddrPC.Offset))
    return out


def cxx_type(rec):
    """The thrown C++ type's decorated name, from the x64 ThrowInfo (RVA-based)."""
    try:
        if rec.NumberParameters < 4:
            return "?"
        throw_info, base = rec.ExceptionInformation[2], rec.ExceptionInformation[3]
        ti = rpm(hproc, throw_info, 16)
        cta_rva = int.from_bytes(ti[12:16], "little", signed=True)
        cta = rpm(hproc, base + cta_rva, 8)
        ct_rva = int.from_bytes(cta[4:8], "little", signed=True)
        ct = rpm(hproc, base + ct_rva, 8)
        td_rva = int.from_bytes(ct[4:8], "little", signed=True)
        name = rpm(hproc, base + td_rva + 16, 128).split(b"\0")[0].decode(errors="replace")
        return name
    except Exception as e:
        return f"? ({e})"


env = dict(os.environ)
env["WT_FLIGHTREC_DIR"] = r"C:\wt\pb2-flightrec"
if mode == "offscreen":
    env["QT_QPA_PLATFORM"] = "offscreen"
block = "".join(f"{k}={v}\0" for k, v in env.items()) + "\0"
si, pi = STARTUPINFOW(), PROCESS_INFORMATION()
si.cb = ctypes.sizeof(si)
if not k32.CreateProcessW(EXE, None, None, None, False, DEBUG_ONLY_THIS_PROCESS | CREATE_UNICODE_ENVIRONMENT,
                          ctypes.create_unicode_buffer(block), os.path.dirname(EXE), ctypes.byref(si), ctypes.byref(pi)):
    sys.exit(f"CreateProcess failed {ctypes.get_last_error()}")
hproc = pi.hProcess
print(f"started pid {pi.dwProcessId} mode={mode}, watching {secs:.0f} s", flush=True)
t_end = time.monotonic() + secs
ev = DEBUG_EVENT()
seen_cxx = 0
done = False
while not done:
    if time.monotonic() > t_end:
        print("TIMEOUT: still alive -- terminating the probe", flush=True)
        k32.TerminateProcess(hproc, 1)
    if not k32.WaitForDebugEvent(ctypes.byref(ev), 500):
        continue
    cont = DBG_CONTINUE
    code = ev.dwDebugEventCode
    if code == CREATE_PROCESS:
        cp = ev.u.CreateProcessInfo
        threads[ev.dwThreadId] = cp.hThread
        modules[cp.lpBaseOfImage] = EXE
    elif code == CREATE_THREAD:
        threads[ev.dwThreadId] = ev.u.CreateThread.hThread
    elif code == LOAD_DLL:
        ld = ev.u.LoadDll
        buf = ctypes.create_unicode_buffer(1024)
        if ld.hFile and k32.GetFinalPathNameByHandleW(ld.hFile, buf, 1024, 0):
            modules[ld.lpBaseOfDll] = buf.value.replace("\\\\?\\", "")
    elif code == OUTPUT_DEBUG_STRING:
        ds = ev.u.DebugString
        raw = rpm(hproc, ds.lpDebugStringData, ds.nDebugStringLength * (2 if ds.fUnicode else 1)) or b""
        txt = raw.decode("utf-16-le" if ds.fUnicode else "mbcs", errors="replace").rstrip("\0\r\n")
        if txt:
            print(f"[ODS t={ev.dwThreadId}] {txt[:400]}", flush=True)
    elif code == EXCEPTION_DEBUG_EVENT:
        rec = ev.u.Exception.ExceptionRecord
        first = ev.u.Exception.dwFirstChance
        ex = rec.ExceptionCode
        if ex == 0x80000003 and not first:
            pass
        elif ex == 0x80000003:
            cont = DBG_CONTINUE          # the loader's initial breakpoint
        elif ex == 0xE06D7363:
            seen_cxx += 1
            print(f"\n== C++ exception #{seen_cxx} ({'first' if first else 'SECOND'} chance) thread {ev.dwThreadId}: "
                  f"type {cxx_type(rec)} at {modname(rec.ExceptionAddress or 0)}", flush=True)
            if seen_cxx <= 6 or not first:
                print("\n".join(stack(ev.dwThreadId)), flush=True)
            cont = DBG_EXCEPTION_NOT_HANDLED
        elif ex in (0xC0000409, 0xC0000005, 0xC00000FD, 0xC0000374) or not first:
            print(f"\n== EXCEPTION 0x{ex:08X} ({'first' if first else 'SECOND'} chance) thread {ev.dwThreadId} at "
                  f"{modname(rec.ExceptionAddress or 0)}; params "
                  f"{[hex(rec.ExceptionInformation[i]) for i in range(min(rec.NumberParameters, 3))]}", flush=True)
            print("\n".join(stack(ev.dwThreadId)), flush=True)
            cont = DBG_EXCEPTION_NOT_HANDLED
        else:
            cont = DBG_EXCEPTION_NOT_HANDLED
    elif code == EXIT_PROCESS:
        print(f"\nprocess exited, code 0x{ev.u.ExitProcess.dwExitCode:08X}", flush=True)
        done = True
    k32.ContinueDebugEvent(ev.dwProcessId, ev.dwThreadId, cont)
