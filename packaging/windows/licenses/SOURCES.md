# Third-party sources — LGPL written offer (Windows distribution)

The LGPL requires that the source for each dynamically-linked/bundled LGPL component
remain available. Watchtower does not modify these components; it ships the upstream
binaries unchanged. Below are the **exact pinned versions** and where their source lives.
These URLs are the standing written offer — the sources stay available there.

| Component | Version | Binary source (what we ship) | Source code |
|---|---|---|---|
| **Qt** | 6.12.0 (msvc2022_64) | aqtinstall / download.qt.io | https://download.qt.io/archive/qt/6.12/6.12.0/single/ · https://code.qt.io/cgit/ |
| **GStreamer** | 1.26.11 (msvc x86_64) | gstreamer.freedesktop.org MSVC MSI | https://gstreamer.freedesktop.org/src/ · https://gitlab.freedesktop.org/gstreamer/gstreamer (tag 1.26.11) |
| **FFmpeg** | BtbN `win64-lgpl-shared` (latest master build) | https://github.com/BtbN/FFmpeg-Builds/releases | https://github.com/BtbN/FFmpeg-Builds (build config) · https://git.ffmpeg.org/ffmpeg.git (the built tag) |

Pinning notes:
- Qt and GStreamer versions are pinned in `.github/workflows/windows.yml`
  (`QT_VERSION`, `GST_VERSION`) — update this table when those bump.
- The FFmpeg build is BtbN's rolling `latest` LGPL-shared asset (fetched by `deploy.ps1`).
  For a reproducible release, pin a dated BtbN release tag instead of `latest` and record
  the exact FFmpeg source tag its build metadata reports, then note it here.
- Watchtower's own source (separately licensed): https://github.com/romayankin/cilex-watchtower

To obtain a component's source: follow its "Source code" link and select the version in
the first column. No component is modified by Watchtower.
