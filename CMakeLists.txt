cmake_minimum_required(VERSION 3.21)

project(watchtower
    VERSION 1.1.777
    DESCRIPTION "Watchtower — lightweight native VMS operator client"
    LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Qt >= 6.8 REQUIRED. Ubuntu 24.04's system Qt 6.4.2 is BANNED: its QtMultimedia
# GStreamer backend SIGSEGVs in libsoup during playback seeks (the P0) and its
# VideoOutput leaks a frame-buffer per frame → OOM. The floor makes 6.4.2 fail to
# configure (hard error) instead of silently building a crash-prone binary. Primary
# toolchain is Qt 6.12 (build against ~/Qt/6.12.0 — see CMakePresets.json / run.sh);
# Qt 6.8.3 LTS is a supported fallback (the 8.8 h-validated runtime). Both use Qt's
# mature FFmpeg media backend.
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 Sql Network Multimedia LinguistTools)

# Video is played through QtMultimedia (QML MediaPlayer + VideoOutput), which on
# Linux uses the GStreamer backend with VA-API hardware decode. The opt-in
# low-latency path (RtspVideoSource, behind WT_LOWLATENCY) drives a small custom
# GStreamer pipeline directly to control rtspsrc latency, so we link GStreamer +
# Qt6::Multimedia (QVideoSink/QVideoFrame) for it.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED IMPORTED_TARGET
    gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0)

# macOS: Homebrew's glib->libffi .pc chain bakes an include path INTO THE CLT
# SDK (…/MacOSX<ver>.sdk/usr/include/ffi) which does not exist on current
# Tahoe SDKs — and CMake hard-errors on any non-existent dir in an imported
# target's INTERFACE_INCLUDE_DIRECTORIES (M0 defect, operator's M1 Pro,
# 2026-08-17). Our code never includes ffi headers (that is a
# gobject-introspection build-time need), so a missing dir contributes nothing
# but the error: filter every non-existent path out rather than chasing
# Apple SDK drift per machine.
if(APPLE)
    get_target_property(_wt_gst_inc PkgConfig::GST INTERFACE_INCLUDE_DIRECTORIES)
    if(_wt_gst_inc)
        set(_wt_gst_inc_ok "")
        foreach(_d IN LISTS _wt_gst_inc)
            if(EXISTS "${_d}")
                list(APPEND _wt_gst_inc_ok "${_d}")
            else()
                message(STATUS "watchtower: dropping non-existent GST include dir: ${_d}")
            endif()
        endforeach()
        set_target_properties(PkgConfig::GST PROPERTIES
            INTERFACE_INCLUDE_DIRECTORIES "${_wt_gst_inc_ok}")
    endif()
endif()

qt_standard_project_setup(REQUIRES 6.8)

# Qt 6.12's qmlcachegen SIGSEGVs when invoked with --dump-aot-stats (a build-time
# AOT-compilation *diagnostic*, on by default). It does not affect the produced
# binary or the AOT-compiled QML — only the stats side-file — so we turn it off.
# Harmless no-op on Qt < 6.12 (the variable/feature doesn't exist there).
set(QT_QML_GENERATE_AOTSTATS OFF)

qt_add_executable(watchtower
    src/main.cpp
)

# Build identifier (short git SHA, captured at CMake configure time). Exposed
# to QML as `wtBuild` and shown on the login screen so a relaunch confirms the
# expected binary is running. Refreshes on any (re)configure.
execute_process(
    COMMAND git rev-parse --short=8 HEAD
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    OUTPUT_VARIABLE WT_GIT_SHA
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
if(NOT WT_GIT_SHA)
    set(WT_GIT_SHA "dev")
endif()

# A SHA from a DIRTY tree is worse than no SHA: it looks exact while naming a commit that
# does not contain the code you are running. Advice given to cilex-pro-mobile 2026-09-22 and
# owed to ourselves — a screenshot of a build id is only a git ref when the tree was clean,
# and nothing here enforced that. Two lines.
execute_process(
    COMMAND git status --porcelain
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    OUTPUT_VARIABLE WT_GIT_DIRTY
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
if(WT_GIT_DIRTY)
    set(WT_GIT_SHA "${WT_GIT_SHA}-dirty")
endif()

# THE BOUND ON THAT, stated because the marker would otherwise imply more than it can:
# both values are captured at CONFIGURE time, not at every compile. In practice CMakeLists
# is rewritten by the per-commit version bump, so a commit always forces a reconfigure and
# the SHA is fresh after one. An edit that touches no CMake input and is then built WITHOUT
# reconfiguring keeps the previous stamp — so `-dirty` proves the tree was dirty at
# configure, and its ABSENCE does not prove the binary is clean. Re-run cmake to be sure.
target_compile_definitions(watchtower PRIVATE WT_GIT_SHA="${WT_GIT_SHA}")
target_compile_definitions(watchtower PRIVATE WT_VERSION="${PROJECT_VERSION}")

# Qt 6.12.0's qmlcachegen SIGSEGVs in the AOT C++ codegen pass on qml/Main.qml (the QML is valid — 6.8.3
# compiled it fine; this is a 6.12 tool regression). `--only-bytecode` skips the AOT pass — the QML *bytecode*
# cache is still built, so startup stays fast — and Qt's CMake then also omits the separately-crashing
# `--dump-aot-stats`. Auto-on for Qt >= 6.12 (our pinned toolchain); `-DWT_ENABLE_AOT=ON` re-enables AOT once a
# fixed Qt ships. AOT is a JS-binding *speed* optimisation, not a correctness feature — the app is identical.
option(WT_ENABLE_AOT "QML AOT C++ codegen (SIGSEGVs on Qt 6.12.0 — leave OFF there)" OFF)
if(NOT WT_ENABLE_AOT AND Qt6_VERSION VERSION_GREATER_EQUAL 6.12)
    set_target_properties(watchtower PROPERTIES QT_QMLCACHEGEN_ARGUMENTS "--only-bytecode")
endif()

# Theme.qml and LayoutSpec.qml are QML singletons (design tokens / layout brain).
# This MUST be set BEFORE qt_add_qml_module so the generated qmldir records them
# as `singleton`.
set_source_files_properties(qml/Theme.qml qml/LayoutSpec.qml qml/EventStyle.qml qml/EventsStore.qml qml/ReconnectCoordinator.qml qml/PbFmt.qml qml/LabsNames.qml PROPERTIES
    QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(watchtower
    URI Watchtower
    VERSION 1.0
    # Qt 6.4's default resource prefix is "/<URI>"; pin the 6.5+ convention
    # "/qt/qml" so resource URLs stay stable across Qt versions.
    RESOURCE_PREFIX "/qt/qml"
    QML_FILES
        qml/Main.qml
        qml/LoginScreen.qml
        qml/AlertsDropdown.qml
        qml/CameraObstructionAlert.qml
        qml/CameraObstructionButton.qml
        qml/CameraObstructionReview.qml
        qml/Theme.qml
        qml/LayoutSpec.qml
        qml/ReconnectCoordinator.qml
        qml/EventStyle.qml
        qml/EventsStore.qml
        qml/EvIcon.qml
        qml/Sev.qml
        qml/TypePill.qml
        qml/StateTag.qml
        qml/EvButton.qml
        qml/EvPersonGlyph.qml
        qml/EvVehicleGlyph.qml
        qml/EvSnapshot.qml
        qml/EvPlayer.qml
        qml/EvHeroPlayer.qml
        qml/EvTriage.qml
        qml/EvWall.qml
        qml/EvSessions.qml
        qml/EvVerify.qml
        qml/EvTimeline.qml
        qml/EvMap.qml
        qml/EventsArea.qml
        qml/NetIcon.qml
        qml/Icon.qml
        qml/StatusBadge.qml
        qml/LiveStatusBadge.qml
        qml/RecordingStatusBadge.qml
        qml/IconButton.qml
        qml/PlaceholderVid.qml
        qml/CameraTile.qml
        qml/FilterPill.qml
        qml/PaginationControl.qml
        qml/StatusSummaryChip.qml
        qml/EmptyState.qml
        qml/LoadingState.qml
        qml/NavRail.qml
        qml/TitleBar.qml
        qml/TabStrip.qml
        qml/TopBar.qml
        qml/OpsSidebar.qml
        qml/LiveMonitor.qml
        qml/GroupSwitcher.qml
        qml/CameraGroups.qml
        qml/SingleCameraDetail.qml
        qml/PtzPanel.qml
        qml/LiveThumb.qml
        qml/GroupSuggestions.qml
        qml/PlaybackScreen.qml
        qml/PbFmt.qml
        qml/ExportProgress.qml
        qml/PbRibbon.qml
        qml/PbNavHeader.qml
        qml/PbLanes.qml
        qml/LabsNames.qml
        qml/LabsCard.qml
        qml/PbTransport.qml
        qml/PbEventsPanel.qml
        qml/PbBanner.qml
        qml/FrameStepper.qml
        qml/FrameStrip.qml
        qml/FrameHarvester.qml
        qml/PlaybackCalendar.qml
        qml/WallPlayback.qml
        qml/WpCell.qml
        qml/ExportDrawer.qml
        qml/HealthScreen.qml
        qml/LabsScreen.qml
        qml/LabsStats.qml
        qml/LabsSeg.qml
        qml/LabsFindings.qml
        qml/EventsScreen.qml
        qml/SavedViewsScreen.qml
        qml/SaveViewModal.qml
        qml/CommandPalette.qml
        qml/ClipsScreen.qml
        qml/PreferencesScreen.qml
        qml/VideoSurface.qml
        qml/VideoTest.qml
        qml/HdCapTest.qml
        qml/Toast.qml
        qml/WatchChip.qml
        qml/WatchNames.js
        qml/GroupsStatus.js
        qml/ToastHost.qml
    SOURCES
        src/models/CameraStatus.h
        src/models/Types.h
        src/models/AuthController.h
        src/models/AuthController.cpp
        src/models/MockData.h
        src/models/MockData.cpp
        src/models/CameraModel.h
        src/models/CameraModel.cpp
        src/models/Artifacts.h
        src/models/Artifacts.cpp
        src/models/CameraStore.h
        src/models/CameraStore.cpp
        src/models/Settings.h
        src/models/Settings.cpp
        src/models/GroupModel.h
        src/models/GroupModel.cpp
        src/models/EventModel.h
        src/models/EventModel.cpp
        src/models/SavedViewModel.h
        src/models/SavedViewModel.cpp
        src/models/HlsProxy.h
        src/models/LiveProxy.h
        src/models/HlsProxy.cpp
        src/models/LiveProxy.cpp
        src/models/PlaybackClient.h
        src/models/PlaybackClient.cpp
        src/models/PtzClient.h
        src/models/PtzClient.cpp
        src/models/WatchClient.h
        src/models/WatchClient.cpp
        src/models/CameraObstructionController.h
        src/models/CameraObstructionController.cpp
        src/models/ClipTranscoder.h
        src/models/ClipTranscoder.cpp
        src/models/SnapshotModel.h
        src/models/SnapshotModel.cpp
        src/models/StorageHealth.h
        src/models/StorageHealth.cpp
        src/models/LabsStation.h
        src/models/LabsStatsData.h
        src/models/LabsFindingsData.h
        src/models/LabsFindingsModel.h
        src/models/LabsFindingsModel.cpp
        src/models/LabsModel.h
        src/models/LabsModel.cpp
        src/models/LabsTimelineData.h
        src/models/LabsTimeline.h
        src/models/LabsTimeline.cpp
        src/models/LabsLanesItem.h
        src/models/LabsLanesItem.cpp
        src/models/RtspVideoSource.h
        src/models/RtspVideoSource.cpp
        src/models/CvImageProvider.h
        src/models/CvImageProvider.cpp
        src/models/SiteMapModel.h
        src/models/SiteMapModel.cpp
        src/models/MemTelemetry.h
        src/models/MemTelemetry.cpp
        src/models/LanguageController.h
        src/models/LanguageController.cpp
        src/models/FrameClock.h
        src/models/FrameClock.cpp
        src/models/MotionScan.h
        src/models/MotionScan.cpp
        src/models/FrameCache.h
        src/models/FrameCache.cpp
        src/models/FlightRecorder.h
        src/models/FlightRecorder.cpp
        src/models/MetalCacheProbe.h
        src/models/MetalCacheProbe.cpp
        src/models/DeepLink.h
        src/models/DeepLink.cpp
)

# UI translations (EN/RU). Builds .qm from the committed .ts at build time and embeds
# them at :/i18n/ in the binary — so it works identically on Linux and Windows with no
# external files. Regenerate the .ts after adding/changing qsTr() strings with:
#   cmake --build <dir> --target update_translations   (runs lupdate)
qt_add_translations(watchtower
    TS_FILES
        i18n/watchtower_en.ts
        i18n/watchtower_ru.ts
    RESOURCE_PREFIX "/i18n"
)

# Self-hosted fonts (Space Grotesk + JetBrains Mono, OFL) embedded at :/fonts/.
qt_add_resources(watchtower "fonts"
    PREFIX "/fonts"
    BASE "assets/fonts"
    FILES
        assets/fonts/SpaceGrotesk-Variable.ttf
        assets/fonts/JetBrainsMono-Regular.ttf
        assets/fonts/JetBrainsMono-Medium.ttf
        assets/fonts/JetBrainsMono-SemiBold.ttf
)

# Brand imagery embedded at :/images/ (Cilex hexagon logo, RGBA w/ transparency).
qt_add_resources(watchtower "images"
    PREFIX "/images"
    BASE "assets/images"
    FILES
        assets/images/cilex-logo.png
)

# So the generated qmltyperegistrations.cpp can find the model headers by name.
target_include_directories(watchtower PRIVATE src/models)

target_link_libraries(watchtower PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Sql
    Qt6::Network
    Qt6::Multimedia
    PkgConfig::GST
)

if(APPLE)
    # LSRegisterURL (DeepLink::ensureSchemeRegistered — the cilex:// self-claim on boot)
    target_link_libraries(watchtower PRIVATE "-framework CoreServices")
endif()

# ---------------------------------------------------------------------------
# Windows packaging (scaffold). Inert on Linux/macOS — only configures when WIN32,
# so the current Linux build is unaffected. See packaging/windows/README.md.
# The shared C++/QML above is cross-platform; this is the only platform-specific
# build logic (decode platform differences are handled at runtime by decodebin +
# #ifdef Q_OS_WIN in the C++, not here).
# ---------------------------------------------------------------------------
if(WIN32)
    enable_language(RC)

    # GUI subsystem (no console window) + the app icon + version info via the resource script.
    # The Windows manifest is Qt's (qt_add_executable auto-generates one on 6.12 with
    # PerMonitorV2 DPI + Win10/11 compat + asInvoker). We do NOT embed our own — doing so
    # AND Qt's produced a link-time duplicate RT_MANIFEST (CVT1100). Custom manifest extras
    # (long-path, UTF-8 code page) are a W4 follow-up. See packaging/windows/watchtower.rc.
    set_target_properties(watchtower PROPERTIES WIN32_EXECUTABLE TRUE)
    target_sources(watchtower PRIVATE packaging/windows/watchtower.rc)

    # PSAPI: GetProcessMemoryInfo — the Windows RSS reader in main.cpp / MemTelemetry.cpp
    # (the /proc/self/statm equivalent). SetUnhandledExceptionFilter is in kernel32 (auto-linked).
    # DBGHELP: MiniDumpWriteDump — the crash-time minidump (FlightRecorder, Warden CW-04).
    target_link_libraries(watchtower PRIVATE psapi dbghelp winmm)   # winmm: timeBeginPeriod (main.cpp)

    # Bundle the runtime: windeployqt (Qt DLLs/QML/plugins) + the GStreamer LGPL subset.
    # Explicit target:  cmake --build <dir> --target deploy-windows
    # (Requires a Windows build against Qt 6.12 msvc2022_64 — see packaging/windows/README.md.)
    add_custom_target(deploy-windows
        COMMAND powershell -ExecutionPolicy Bypass -File
                "${CMAKE_SOURCE_DIR}/packaging/windows/deploy.ps1"
                -ExePath "$<TARGET_FILE:watchtower>"
                -QmlDir  "${CMAKE_SOURCE_DIR}/qml"
        DEPENDS watchtower
        VERBATIM
        COMMENT "windeployqt + GStreamer bundling (packaging/windows/deploy.ps1)")
endif()

# macOS packaging (scaffold, 2026-08-16). Inert off-APPLE. NEVER CONFIGURED ON A
# MAC YET — M0 of docs/plans/mac-port/ is the first run. Version flows from
# PROJECT_VERSION into the bundle, so Info.plist.in never joins the bump-hook
# file set. Bundle id is provisional until the operator confirms at M4.
if(APPLE)
    set_target_properties(watchtower PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/packaging/macos/Info.plist.in"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.cilexvision.watchtower"
        MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}")
endif()

