"""Acquire one immutable source revision without modifying an existing checkout."""
from __future__ import annotations

import getpass
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import urllib.parse

from common import DeployError, command, clean_env, secret, sha256, atomic_json, utc

DEFAULT_REPOSITORY = "https://github.com/romayankin/cilex-watchtower.git"


def source_tree_hash(root, exclude_git=False):
    """Hash every source entry, including links and permissions; never follow escapes."""
    from common import digest
    root = Path(root).resolve()
    rows = []
    for entry in sorted(root.rglob('*')):
        relative = entry.relative_to(root)
        if exclude_git and relative.parts[0] == '.git':
            continue
        mode = stat.S_IMODE(entry.lstat().st_mode)
        if entry.is_symlink():
            try:
                entry.resolve(strict=True).relative_to(root)
            except (OSError, ValueError, RuntimeError):
                raise DeployError('source.link', 'Source contains an escaping or broken link; do not build this workspace.', 'integrity')
            rows.append([relative.as_posix(), 'link', os.readlink(entry), mode])
        elif entry.is_file():
            rows.append([relative.as_posix(), 'file', sha256(entry), mode])
        elif entry.is_dir():
            rows.append([relative.as_posix(), 'directory', mode])
        else:
            raise DeployError('source.type', 'Source contains a special filesystem object; do not build this workspace.', 'integrity')
    return digest(rows)


def validate_repository(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise DeployError("source.repository", "Use an HTTPS repository URL without credentials, query parameters or fragments.", "usage")
    return url


def token_input(options):
    sources = sum(bool(options.get(k)) for k in ("gh_token_fd", "gh_keychain_service", "gh_token_prompt"))
    if sources > 1:
        raise DeployError("authentication.ambiguous", "Select one GitHub credential channel.", "usage")
    if options.get("gh_token_fd") is not None:
        try:
            fd = int(options["gh_token_fd"])
            if fd < 3:
                raise ValueError()
            if not select.select([fd], [], [], 10)[0]:
                raise ValueError()
            # One bounded read also handles pipes whose writer remains open.
            value = os.read(fd, 4097).decode("utf-8").strip()
        except (OSError, ValueError, UnicodeError):
            raise DeployError("authentication.fd", "Cannot read the protected GitHub-token descriptor; supply an open descriptor numbered 3 or higher.", "authentication")
    elif options.get("gh_keychain_service"):
        args = ["/usr/bin/security", "find-generic-password", "-s", options["gh_keychain_service"]]
        if options.get("gh_keychain_account"):
            args += ["-a", options["gh_keychain_account"]]
        args += ["-w"]
        # The user explicitly selects this service. Its secret output never enters a log.
        proc = command(args, timeout=20, check=False)
        if proc.returncode:
            raise DeployError("authentication.keychain", "The selected Keychain credential is unavailable; unlock/access it explicitly or use a protected descriptor.", "authentication")
        value = proc.stdout.strip()
    elif options.get("gh_token_prompt"):
        if options.get("noninteractive") or not os.isatty(0):
            raise DeployError("authentication.input", "A masked prompt requires a terminal; provide --gh-token-fd or an explicitly selected Keychain service.", "authentication")
        value = getpass.getpass("GitHub token / Токен GitHub: ")
    else:
        return None
    if not value or len(value.encode()) > 4096 or "\n" in value or "\r" in value:
        raise DeployError("authentication.token", "The selected credential channel did not contain one valid token line.", "authentication")
    return secret(value)


def authenticated_git(git, args, cwd, token, log, offline=False):
    """Token is inherited only by this authentication operation, never argv/env."""
    if offline:
        raise DeployError("source.offline_fetch", "A fresh fetch is impossible offline; supply a trusted source archive and its commit/hash.", "source")
    read_fd = write_fd = None
    extra = {"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"}
    try:
        if token:
            read_fd, write_fd = os.pipe()
            os.write(write_fd, (token + "\n").encode())
            os.close(write_fd)
            write_fd = None
            askpass = Path(__file__).with_name("git-askpass.sh")
            extra.update({"GIT_ASKPASS": str(askpass), "CILEX_GH_TOKEN_FD": str(read_fd)})
        proc = command([git, "-c", "credential.helper=", "-c", "http.sslVerify=true", *args],
                       cwd=cwd, env=extra, timeout=300, log=log, network=True,
                       check=False, pass_fds=(() if read_fd is None else (read_fd,)))
    finally:
        for fd in (read_fd, write_fd):
            if fd is not None:
                os.close(fd)
    if proc.returncode:
        err = proc.stderr.lower()
        if any(word in err for word in ("authentication", "403", "401", "could not read username", "repository not found")):
            kind = "authentication"
            remedy = "Repository authentication failed; provide authorized GitHub access through a masked prompt, Keychain or protected descriptor."
        elif any(word in err for word in ("certificate", "ssl", "tls")):
            kind, remedy = "security", "TLS verification failed; correct the certificate/proxy configuration without disabling verification."
        elif "couldn't find remote ref" in err:
            kind, remedy = "source", "The requested exact reference does not exist; supply an existing tag. No fallback source was used."
        else:
            kind, remedy = "source", "The fresh source fetch failed; inspect connectivity/proxy and retry, or supply a trusted offline source archive."
        raise DeployError("source.fetch_" + kind, remedy, kind)
    return proc


def obtain(options, run_dir, git="/usr/bin/git", log=None):
    root = Path(run_dir) / "source"
    provenance_file = Path(run_dir) / "source-provenance.json"
    repository = validate_repository(options.get("repository", DEFAULT_REPOSITORY))
    # A resumed run keeps its original pinned commit. It never relabels it fresh.
    if provenance_file.exists():
        import json
        provenance = json.loads(provenance_file.read_text())
        if not root.is_dir() or provenance.get("repository") != repository:
            raise DeployError("source.resume", "The pinned source workspace is missing or its provenance changed; inspect the interrupted run.", "integrity")
        if provenance.get('acquisition') == 'fresh-fetch':
            if not (root / '.git').is_dir():
                raise DeployError('source.modified', 'The pinned Git checkout metadata is missing; do not reuse this workspace.', 'integrity')
            actual = command([git, "rev-parse", "HEAD"], cwd=root).stdout.strip()
            dirty = command([git, "status", "--porcelain"], cwd=root).stdout
            if actual != provenance["commit"] or dirty or source_tree_hash(root, exclude_git=True) != provenance.get('tree_sha256'):
                raise DeployError("source.modified", "The pinned source checkout changed after acquisition; it cannot be reused.", "integrity")
        else:
            if source_tree_hash(root) != provenance.get("tree_sha256"):
                raise DeployError("source.modified", "The extracted source changed after acquisition; it cannot be reused.", "integrity")
        return root, provenance
    if options.get("source_archive"):
        if options.get('tag'):
            raise DeployError('source.offline_tag', 'Offline archive tag validation is not implemented; use an authenticated exact-tag fetch or supply the trusted archive commit without --tag.', 'source',
                              ru='Проверка тега офлайн-архива не реализована; получите точный тег из репозитория либо укажите доверенный коммит архива без --tag.')
        archive = Path(options["source_archive"])
        expected, commit = options.get("source_sha256", ""), options.get("source_commit", "")
        if not re.fullmatch(r"[0-9a-fA-F]{64}", expected) or not re.fullmatch(r"[0-9a-fA-F]{40,64}", commit):
            raise DeployError("source.archive_provenance", "Supply --source-sha256 and --source-commit from a trusted source, separately from the archive.", "integrity")
        if sha256(archive) != expected.lower():
            raise DeployError("source.archive_hash", "The source archive hash does not match; do not extract or build it.", "integrity")
        from install import safe_extract
        root.mkdir(mode=0o700)
        safe_extract(archive, root, expected_sha256=expected.lower())
        if not (root / "CMakeLists.txt").is_file():
            raise DeployError("source.archive_layout", "The source archive must have CMakeLists.txt at its root; supply the documented source bundle.", "source")
        provenance = {"repository": repository, "commit": commit, "tag": options.get("tag"),
                      "acquisition": "trusted-offline-archive", "archive_sha256": expected.lower(), "at": utc()}
        if options.get("source_dirty_tree"):
            if not options.get("development"):
                raise DeployError("source.dirty_production", "A development source snapshot cannot produce a production artifact.", "source")
            provenance.update(commit_role="base-commit-only", uncommitted_changes=True)
        provenance["tree_sha256"] = source_tree_hash(root)
    else:
        if options.get("dependencies") == "offline":
            raise DeployError("source.offline_missing", "Offline build requires --source-archive, --source-sha256 and --source-commit; no network request was made.", "source")
        if root.exists():
            raise DeployError("source.interrupted", "An incomplete source workspace exists without trusted provenance; preserve it and start a new run.", "source")
        root.mkdir(mode=0o700)
        command([git, "init", "--quiet"], cwd=root)
        command([git, "remote", "add", "origin", repository], cwd=root)
        tag = options.get("tag")
        ref = "refs/tags/" + tag if tag else "refs/heads/main"
        command([git, "check-ref-format", ref], cwd=root)
        token = token_input(options)
        args = ["fetch", "--no-tags", "--depth=1", "origin", "+" + ref + ":refs/cilex/source"]
        try:
            authenticated_git(git, args, root, token, log)
        except DeployError as exc:
            if exc.finding != "source.fetch_authentication" or token or options.get("noninteractive") or not os.isatty(0):
                raise
            token = token_input(dict(options, gh_token_prompt=True))
            authenticated_git(git, args, root, token, log)
        commit = command([git, "rev-parse", "refs/cilex/source^{commit}"], cwd=root).stdout.strip()
        command([git, "checkout", "--detach", "--quiet", commit], cwd=root)
        provenance = {"repository": repository, "commit": commit, "tag": tag,
                      "acquisition": "fresh-fetch", "requested_ref": ref, "at": utc()}
        provenance['tree_sha256'] = source_tree_hash(root, exclude_git=True)
    atomic_json(provenance_file, provenance)
    return root, provenance
