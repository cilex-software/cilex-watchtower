cmake_minimum_required(VERSION 3.21)

project(watchtower
    VERSION 0.1.0
    DESCRIPTION "Watchtower — lightweight native VMS operator client"
    LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Qt 6.4 ships with Ubuntu 24.04. We pin >= 6.4 and use the modern
# qt_add_qml_module flow. GStreamer / Multimedia / Sql get linked in later
# phases (video pipeline, persistence) — kept out of the first build to keep
# the dependency surface minimal until those features land.
find_package(Qt6 6.4 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 Sql Network Multimedia)

# Video is played through QtMultimedia (QML MediaPlayer + VideoOutput), which on
# Linux uses the GStreamer backend with VA-API hardware decode. The opt-in
# low-latency path (RtspVideoSource, behind WT_LOWLATENCY) drives a small custom
# GStreamer pipeline directly to control rtspsrc latency, so we link GStreamer +
# Qt6::Multimedia (QVideoSink/QVideoFrame) for it.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED IMPORTED_TARGET
    gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0)

qt_standard_project_setup(REQUIRES 6.4)

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
target_compile_definitions(watchtower PRIVATE WT_GIT_SHA="${WT_GIT_SHA}")

# Theme.qml and LayoutSpec.qml are QML singletons (design tokens / layout brain).
# This MUST be set BEFORE qt_add_qml_module so the generated qmldir records them
# as `singleton`.
set_source_files_properties(qml/Theme.qml qml/LayoutSpec.qml qml/EventStyle.qml qml/EventsStore.qml PROPERTIES
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
        qml/Theme.qml
        qml/LayoutSpec.qml
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
        qml/TopBar.qml
        qml/OpsSidebar.qml
        qml/LiveMonitor.qml
        qml/CameraGroups.qml
        qml/SingleCameraDetail.qml
        qml/PlaybackScreen.qml
        qml/PlaybackCalendar.qml
        qml/WallPlayback.qml
        qml/ExportDrawer.qml
        qml/HealthScreen.qml
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
        src/models/HlsProxy.cpp
        src/models/PlaybackClient.h
        src/models/PlaybackClient.cpp
        src/models/SnapshotModel.h
        src/models/SnapshotModel.cpp
        src/models/StorageHealth.h
        src/models/StorageHealth.cpp
        src/models/RtspVideoSource.h
        src/models/RtspVideoSource.cpp
        src/models/CvImageProvider.h
        src/models/CvImageProvider.cpp
        src/models/SiteMapModel.h
        src/models/SiteMapModel.cpp
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
