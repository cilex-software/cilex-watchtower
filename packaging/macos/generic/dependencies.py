"""Pinned dependency assessment/provisioning; assessment never writes or downloads.

Official installers that need authorization or license workflow are deliberately
not executed. An explicit reviewed local receipt enables experimental host tools,
without waiving any pinned download hash or production security requirement.
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import tempfile
import time
from urllib.parse import urlparse
import zipfile

from common import DeployError, atomic_json, clean_env, command, digest, private_dir, read_json, sha256, utc
from install import safe_extract, safe_name, collision_key

MANIFEST = Path(__file__).parent / "manifests/dependencies.json"
LOCAL_FINDING = "build.local-dependency-receipt"
TOOL_PACKAGES = {"cmake": "CMake", "ninja": "Ninja", "python": "Python", "qt_root": "Qt", "gstreamer_root": "GStreamerRuntime", "ffmpeg": "FFmpeg"}
REQUIRED = ("cmake", "ninja", "pkg_config", "qt_root", "gstreamer_root", "python", "ffmpeg", "licenses_dir")
OFFICIAL_HOSTS = {"github.com", "download.qt.io", "gstreamer.freedesktop.org", "www.python.org", "ffmpeg.org", "files.pythonhosted.org"}


def fail(finding, message, code="dependency", details=None):
    raise DeployError(finding, message, code,
        ru="Подготовка зависимостей не завершена (" + finding + "); сборка остановлена. Проверьте план, точные версии и перечисленные локальные файлы; затем повторите попытку или подготовьте их вручную.",
        details=details)


def accepted(options):
    value = options.get("accept_findings") or []
    return set(x.strip() for x in value.split(",") if x.strip()) if isinstance(value, str) else set(value)


def catalog():
    data = read_json(MANIFEST)
    if data.get("schema_version") != 1 or not isinstance(data.get("packages"), list):
        fail("dependencies.manifest", "Unsupported dependency manifest schema.", "integrity")
    seen = set()
    for package in data["packages"]:
        if package.get("id") in seen or not package.get("version"):
            fail("dependencies.manifest", "Dependency IDs and exact versions must be unique and nonempty.", "integrity")
        seen.add(package["id"])
        url = urlparse(package.get("url", ""))
        if url.scheme != "https" or url.hostname not in OFFICIAL_HOSTS or url.username or url.password or url.query or url.fragment or not re.fullmatch(r"[0-9a-f]{64}", package.get("sha256", "")):
            fail("dependencies.manifest", "Dependency source URL or SHA-256 is not an approved pinned official source.", "integrity")
    return data


def cache_file(package, options):
    root = Path(options.get("cache_dir") or Path.home() / "Library/Caches/CilexWatchtower/Deploy").expanduser().absolute()
    name = Path(urlparse(package["url"]).path).name
    if not re.fullmatch(r"[A-Za-z0-9._+\-]+", name):
        fail("dependencies.filename", "Dependency archive filename is invalid.", "integrity")
    return root / "dependencies/downloads" / package["sha256"] / name


def selected_tools(options):
    tools, provenance = {}, {}
    if options.get("tools_json"):
        path = Path(options["tools_json"]).expanduser().absolute()
        if path.is_symlink() or not path.is_file():
            fail("dependencies.tools_file", "--tools-json must name an existing regular JSON file.", "usage")
        data = read_json(path)
        if not isinstance(data, dict):
            fail("dependencies.tools_file", "Tool configuration must be a JSON object.", "usage")
        tools = dict(data.get("tools", data))
        provenance = data.get("provenance", {})
        for key in ("schema_version", "provenance", "profile", "receipts"):
            tools.pop(key, None)
    if options.get("python") and "python" not in tools:
        tools["python"] = options["python"]
    if options.get("developer_dir"):
        tools["developer_dir"] = options["developer_dir"]
    for key in (*REQUIRED, "developer_dir", "macdeployqt", "git"):
        if tools.get(key):
            path = Path(tools[key]).expanduser()
            if not path.is_absolute():
                fail("dependencies.absolute_path", "Every selected tool path must be absolute: " + key, "usage")
            # Resolve normal toolchain/framework symlinks before recording inputs.
            resolved = path.resolve()
            # Resolving venv/bin/python to the base interpreter would destroy the
            # isolation being assessed and silently select the global packages.
            tools[key] = str(path.absolute() if key == "python" else resolved)
            if any(part.lower() == "watchtower.app" for part in (*path.parts, *resolved.parts)):
                fail("dependencies.installed_runtime", "Build inputs cannot come from an installed Watchtower bundle.", "integrity")
    return tools, provenance


def inspect_toolchain(tools):
    developer = tools.get("developer_dir")
    if not developer:
        selected = command(["/usr/bin/xcode-select", "-p"], check=False, timeout=10)
        if selected.returncode == 0:
            developer = selected.stdout.strip()
    if not developer or not Path(developer).is_absolute() or not Path(developer).is_dir():
        return {"state": "missing", "next_action": "Install an authorized Apple toolchain from https://developer.apple.com/download/all/; select its absolute developer_dir. No installation dialog was requested."}
    root = Path(developer)
    clang = next((path for path in (root / "usr/bin/clang", root / "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang") if path.is_file()), None)
    git = next((path for path in (root / "usr/bin/git",) if path.is_file()), None)
    sdk = next((path for path in (root / "SDKs/MacOSX.sdk", root / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk") if path.is_dir()), None)
    result = {"state": "present" if clang and git and sdk else "incomplete", "developer_dir": str(root.resolve()),
              "clang": str(clang.resolve()) if clang else None, "git": str(git.resolve()) if git else None,
              "sdk": str(sdk.resolve()) if sdk else None, "apple_license": "Must already be accepted through Apple's authorized workflow"}
    if clang:
        probe = command([str(clang), "--version"], check=False, timeout=15, env={"DEVELOPER_DIR": str(root)})
        result["clang_version"] = probe.stdout.splitlines()[0] if probe.stdout else "unknown"
        if probe.returncode:
            result["state"] = "unavailable"
    return result


def version_probe(key, path, tools):
    if key in ("cmake", "ninja", "pkg_config", "python"):
        args = [path, "--version"]
    elif key == "qt_root":
        qmake = Path(path) / "bin/qmake"
        if not qmake.is_file():
            return None
        args = [str(qmake), "-query", "QT_VERSION"]
    elif key == "gstreamer_root":
        pkgconf = tools.get("pkg_config")
        if not pkgconf or not Path(pkgconf).is_file():
            return None
        args = [pkgconf, "--modversion", "gstreamer-1.0"]
    elif key == "ffmpeg":
        args = [path, "-hide_banner", "-version"]
    else:
        return None
    env = {"PKG_CONFIG_LIBDIR": str(Path(tools.get("gstreamer_root", "/nonexistent")) / "lib/pkgconfig"), "PKG_CONFIG_PATH": ""}
    reply = command(args, env=env, timeout=20, check=False)
    if reply.returncode:
        return None
    found = re.search(r"(?<!\d)(\d+\.\d+(?:\.\d+)?)(?!\d)", reply.stdout + reply.stderr)
    return found.group(1) if found else None


def inspect_python(path):
    code = "import importlib.metadata,json,sys; names=['pyinstaller','pyinstaller-hooks-contrib','altgraph','packaging','setuptools','macholib']; versions={};\nfor n in names:\n try: versions[n]=importlib.metadata.version(n)\n except importlib.metadata.PackageNotFoundError: pass\nprint(json.dumps({'isolated':sys.prefix!=sys.base_prefix,'versions':versions,'version':'.'.join(map(str,sys.version_info[:3]))}))"
    reply = command([path, "-I", "-B", "-c", code], check=False, timeout=20)
    if reply.returncode:
        return {"isolated": False, "versions": {}, "version": None}
    try:
        return json.loads(reply.stdout)
    except ValueError:
        return {"isolated": False, "versions": {}, "version": None}


def assess(options):
    """Return a single concrete read-only plan; do not create even cache dirs."""
    data = catalog()
    tools, provenance = selected_tools(options)
    toolchain = inspect_toolchain(tools)
    if toolchain.get("developer_dir"):
        tools["developer_dir"] = toolchain["developer_dir"]
    if toolchain.get("git"):
        tools["git"] = toolchain["git"]
    findings, missing, plan, observations = [], [], [], {}
    local_accepted = LOCAL_FINDING in accepted(options)
    if options.get("tools_json") or options.get("python"):
        findings.append({"id": LOCAL_FINDING, "severity": "advisory", "accepted": local_accepted,
                         "message": "Explicit local tools require a reviewed local dependency receipt; captured versions/hashes describe this host and do not establish vendor provenance or clean-machine support."})
    if toolchain["state"] != "present":
        missing.append({"id": "AppleToolchain", "path": tools.get("developer_dir"), "url": "https://developer.apple.com/download/all/", "action": "Install/select an authorized Apple toolchain and SDK; the deployment never triggers installation dialogs."})
    for key in REQUIRED:
        path = tools.get(key)
        if path and Path(path).exists():
            version = version_probe(key, path, tools) if key != "licenses_dir" else None
            observations[key] = {"path": path, "version": version}
            if Path(path).is_file():
                observations[key]["sha256"] = sha256(path)
        else:
            missing.append({"id": key, "path": path, "action": "Supply this absolute tool path in tools.json."})
    packages = {package["id"]: package for package in data["packages"]}
    for package in data["packages"]:
        path = cache_file(package, options)
        cache = "missing"
        if path.exists():
            cache = "verified" if path.is_file() and not path.is_symlink() and sha256(path) == package["sha256"] else "invalid"
            if cache == "invalid":
                findings.append({"id": "dependencies.cache_integrity", "severity": "fatal", "overridable": False, "path": str(path)})
        key = next((name for name, package_id in TOOL_PACKAGES.items() if package_id == package["id"]), None)
        observed = observations.get(key, {}) if key else {}
        action = "use-reviewed-local" if observed else "provision-isolated" if package["id"] in ("CMake", "Ninja") or package["kind"] == "wheel" else "manual-authorized-provision"
        plan.append({"id": package["id"], "version": package["version"], "license": package["license"],
                     "source": package["url"], "sha256": package["sha256"], "cache_path": str(path),
                     "cache_state": cache, "action": action, "observed": observed,
                     "instructions": package["manual"], "security_status": package.get("security_status")})
        if observed.get("version") and observed["version"] != package["version"]:
            findings.append({"id": "build.local-version." + key, "severity": "advisory", "accepted": local_accepted,
                             "required": package["version"], "observed": observed["version"]})
    python_state = inspect_python(tools["python"]) if tools.get("python") and Path(tools["python"]).is_file() else None
    wheels = {p["id"][6:]: p["version"] for p in data["packages"] if p["kind"] == "wheel"}
    prepared = bool(python_state and python_state.get("isolated") and all(python_state.get("versions", {}).get(name) == version for name, version in wheels.items()))
    if python_state and not prepared:
        missing.append({"id": "IsolatedPyInstallerEnvironment", "action": "Use auto mode to create an isolated environment from pinned wheels, or provide a prepared reviewed venv."})
    return {"schema_version": 1, "profile": data["profile"], "read_only": True, "tools": tools,
            "toolchain": toolchain, "plan": plan, "missing": missing, "findings": findings,
            "licenses": sorted({item["license"] for item in plan} | {"Apple Xcode and SDK Agreement"}),
            "observations": observations, "python": python_state, "python_prepared": prepared,
            "provenance": provenance, "production_security_blocked": bool(python_state and python_state.get("version") == "3.13.0")}


def download_failure(exit_code, status):
    if status in (401, 403): return "authorization"
    if status == 407 or exit_code == 5: return "proxy"
    if status in (404, 410): return "unavailable_version"
    if exit_code in (35, 51, 53, 54, 58, 59, 60, 64, 66, 77, 80, 82, 83, 90, 91): return "tls"
    if exit_code in (6, 7, 18, 28, 52, 55, 56) or status in (408, 429) or status >= 500: return "connectivity"
    return "http_failure"


def fetch(package, options):
    destination = cache_file(package, options)
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not destination.is_file() or destination.stat().st_mode & 0o022 or sha256(destination) != package["sha256"]:
            fail("dependencies.cache_integrity", "Cached dependency failed SHA-256 verification; preserve it for inspection and manually replace the exact file.", "integrity", {"path": str(destination), "url": package["url"]})
        return destination
    if options.get("dependencies") == "offline":
        fail("dependencies.offline_missing", "Offline mode cannot download missing dependencies; supply these exact files.", details={"missing_files": [str(destination)], "url": package["url"], "sha256": package["sha256"]})
    if options.get("dependencies", "manual") != "auto":
        fail("dependencies.manual_missing", "Manual dependency mode does not download files; provision the listed version and SHA-256 into the cache.", details={"missing_files": [str(destination)], "url": package["url"], "sha256": package["sha256"]})
    private_dir(destination.parent)
    fd, temporary = tempfile.mkstemp(prefix=".partial-", dir=destination.parent)
    os.close(fd)
    part = Path(temporary)
    if shutil.disk_usage(destination.parent).free < int(package.get("download_bytes", 512 * 1024**2)) + 128 * 1024**2:
        fail("dependencies.space", "Insufficient space to download safely; free space and retry.")
    for attempt in range(3):
        args = ["/usr/bin/curl", "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2", "--location", "--max-redirs", "5",
                "--connect-timeout", "10", "--max-time", "600", "--fail", "--silent", "--show-error",
                "--output", str(part), "--write-out", "%{http_code}", package["url"]]
        reply = command(args, timeout=620, network=True, check=False)
        status = int(reply.stdout[-3:]) if reply.stdout[-3:].isdigit() else 0
        if reply.returncode == 0 and status == 200:
            if sha256(part) != package["sha256"]:
                fail("dependencies.download_integrity", "Official download SHA-256 does not match the pinned manifest; do not override or use this file.", "integrity", {"path": str(part), "url": package["url"]})
            os.replace(part, destination)
            destination.chmod(0o600)
            return destination
        category = download_failure(reply.returncode, status)
        if category != "connectivity" or attempt == 2:
            fail("dependencies.download_" + category, "Dependency download failed (" + category + "); retry after correcting the connection or manually obtain the exact file from the manifest URL.", details={"id": package["id"], "http_status": status, "curl_exit": reply.returncode, "url": package["url"], "cache_path": str(destination), "partial": str(part), "attempts": attempt + 1})
        time.sleep(attempt + 1)
    raise AssertionError("bounded download loop")


def extract_ninja(archive, root):
    root = Path(root)
    seen, entries = set(), []
    with zipfile.ZipFile(archive) as source:
        total = 0
        for item in source.infolist():
            name = str(safe_name(item.filename.rstrip("/") if item.is_dir() else item.filename))
            key = collision_key(name)
            mode = item.external_attr >> 16
            if key in seen or stat.S_ISLNK(mode) or (mode and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode))):
                fail("dependencies.zip_entry", "Ninja archive has a duplicate, link or special entry.", "integrity")
            if mode & 0o7022:
                fail("dependencies.zip_permissions", "Ninja archive contains unsafe permissions.", "integrity")
            seen.add(key); total += item.file_size; entries.append((name, item, mode))
        if total > 512 * 1024**2 or shutil.disk_usage(root).free < total + 128 * 1024**2:
            fail("dependencies.zip_space", "Ninja extraction cannot fit safely in the selected filesystem.")
        for name, item, mode in entries:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if item.is_dir():
                target.mkdir(exist_ok=True)
            else:
                with source.open(item) as incoming, target.open("xb") as output:
                    shutil.copyfileobj(incoming, output)
                target.chmod(0o755 if mode & 0o111 else 0o644)


def provision_tool(package, options, run_dir):
    archive = fetch(package, options)
    tools_root = Path(run_dir) / "dependency-tools"
    private_dir(tools_root)
    root = Path(tempfile.mkdtemp(prefix=package["id"].lower() + "-", dir=tools_root))
    if package["id"] == "CMake":
        safe_extract(archive, root, package["sha256"])
        candidates = list(root.rglob("CMake.app/Contents/bin/cmake"))
    else:
        extract_ninja(archive, root)
        candidates = [p for p in root.rglob("ninja") if p.is_file()]
    if len(candidates) != 1 or not os.access(candidates[0], os.X_OK):
        fail("dependencies.executable", "Pinned tool archive does not contain exactly one executable expected tool.", "integrity")
    key = "cmake" if package["id"] == "CMake" else "ninja"
    if version_probe(key, str(candidates[0]), {}) != package["version"]:
        fail("dependencies.tool_version", "Pinned tool executable reports a different version; do not use this artifact.", "integrity")
    return str(candidates[0]), {"id": package["id"], "version": package["version"], "archive": str(archive), "sha256": package["sha256"], "executable_sha256": sha256(candidates[0]), "provenance": "pinned-official-download"}


def provision_python(python, packages, options, run_dir):
    wheel_packages = [package for package in packages if package["kind"] == "wheel"]
    missing = [str(cache_file(p, options)) for p in wheel_packages if not cache_file(p, options).is_file()]
    if options.get("dependencies") == "offline" and missing:
        fail("dependencies.offline_missing", "Offline Python packaging dependencies are missing; provide every exact wheel before retrying.", details={"missing_files": missing})
    wheels = [fetch(package, options) for package in wheel_packages]
    root = Path(run_dir) / "dependency-python"
    if root.exists():
        fail("dependencies.venv_exists", "An interrupted Python environment already exists; inspect it or choose a new build workspace before provisioning.")
    command([python, "-I", "-B", "-m", "venv", str(root)], timeout=120)
    selected = root / "bin/python3"
    requirements = Path(run_dir) / "pinned-python-requirements.txt"
    requirements.write_text("\n".join(str(path) + " --hash=sha256:" + package["sha256"] for path, package in zip(wheels, wheel_packages)) + "\n")
    requirements.chmod(0o600)
    env = {"PIP_NO_INDEX": "1", "PIP_DISABLE_PIP_VERSION_CHECK": "1", "PIP_CONFIG_FILE": "/dev/null"}
    command([str(selected), "-I", "-B", "-m", "pip", "install", "--no-index", "--no-deps", "--require-hashes", "--no-compile", "-r", str(requirements)], env=env, timeout=300)
    observed = inspect_python(str(selected))
    if not observed.get("isolated") or any(observed.get("versions", {}).get(p["id"][6:]) != p["version"] for p in wheel_packages):
        fail("dependencies.python_environment", "Isolated Python dependency versions do not match the pinned wheel manifest.", "integrity")
    return str(selected), {"id": "IsolatedPyInstallerEnvironment", "python": observed["version"], "versions": observed["versions"],
                           "wheels": [{"id": p["id"], "sha256": p["sha256"], "path": str(path)} for p, path in zip(wheel_packages, wheels)], "provenance": "pinned-official-wheels"}


def resolve(options, run_dir):
    assessment = assess(options)
    if options.get("dry_run") or options.get("mode") in ("check", "verify"):
        return {"tools": assessment["tools"], "receipts": [], "plan": assessment, "read_only": True}
    if os.geteuid() == 0:
        fail("dependencies.root", "Dependency provisioning as root is forbidden; use an ordinary build account.", "authorization")
    if (options.get("tools_json") or options.get("python")) and LOCAL_FINDING not in accepted(options):
        fail(LOCAL_FINDING, "Explicit local dependency inputs require --accept-findings build.local-dependency-receipt after reviewing the concrete plan.", details={"plan": assessment})
    if any(finding.get("severity") == "fatal" for finding in assessment["findings"]):
        fail("dependencies.cache_integrity", "A cached dependency failed integrity verification; manually replace the listed file before building.", "integrity", {"findings": assessment["findings"]})
    if assessment["toolchain"]["state"] != "present":
        fail("dependencies.apple_toolchain", "Apple tools or SDK are missing; install and license them through Apple's authorized workflow, then retry. No installer or dialog was invoked.", details={"toolchain": assessment["toolchain"]})
    if assessment["production_security_blocked"] and not (options.get("development") or options.get("allow_development")):
        fail("dependencies.python_security", "Python 3.13.0 is a historical test runtime; production artifacts are blocked until a reviewed security-maintained version is pinned and tested.", "security")
    tools = dict(assessment["tools"])
    manual_missing = [key for key in ("pkg_config", "qt_root", "gstreamer_root", "python", "ffmpeg", "licenses_dir") if not tools.get(key) or not Path(tools[key]).exists()]
    if manual_missing:
        fail("dependencies.manual_required", "Automatic provisioning is unavailable for these reviewed SDK/runtime/license inputs; provide them through tools.json using the version-specific manifest instructions.", details={"missing": manual_missing, "plan": assessment["plan"]})
    unversioned = [key for key, value in assessment["observations"].items() if key != "licenses_dir" and not value.get("version")]
    if unversioned:
        fail("dependencies.tool_version", "Selected local tools did not report an identifiable version; repair their explicit paths before building.", details={"tools": unversioned})
    if not options.get("accept_licenses"):
        fail("dependencies.licenses", "Review the concrete dependency licenses and provide --accept-licenses; Apple agreements must already be accepted through Apple's own workflow.", "authorization", {"licenses": assessment["licenses"]})
    run_dir = private_dir(run_dir)
    packages = catalog()["packages"]
    by_id = {package["id"]: package for package in packages}
    receipts = [{"id": "ReviewedLocalInputs", "finding": LOCAL_FINDING, "observations": assessment["observations"],
                 "provenance": assessment["provenance"], "toolchain": assessment["toolchain"], "recorded_at": utc()}]
    for key, identifier in (("cmake", "CMake"), ("ninja", "Ninja")):
        if not tools.get(key) or not Path(tools[key]).exists():
            tools[key], receipt = provision_tool(by_id[identifier], options, run_dir)
            receipts.append(receipt)
    if not assessment["python_prepared"]:
        if options.get("dependencies", "manual") == "manual":
            fail("dependencies.manual_python_environment", "The selected Python environment is not isolated with all pinned packaging wheels; prepare it manually or choose auto/offline provisioning.")
        tools["python"], receipt = provision_python(tools["python"], packages, options, run_dir)
        receipts.append(receipt)
    else:
        receipts.append({"id": "ReviewedLocalPythonEnvironment", **assessment["python"], "finding": LOCAL_FINDING})
    result = {"schema_version": 1, "tools": tools, "receipts": receipts, "plan": assessment,
              "accepted_findings": sorted(accepted(options)), "production_security_blocked": assessment["production_security_blocked"]}
    evidence = run_dir / "dependency-receipts.json"
    atomic_json(evidence, result)
    result["evidence"] = str(evidence)
    return result
