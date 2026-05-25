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
find_package(Qt6 6.4 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2)

# Video is played through QtMultimedia (QML MediaPlayer + VideoOutput), which on
# Linux uses the GStreamer backend with VA-API hardware decode. The QML module
# qml6-module-qtmultimedia provides those types at runtime — no C++ link needed.

qt_standard_project_setup(REQUIRES 6.4)

qt_add_executable(watchtower
    src/main.cpp
)

# Theme.qml is a QML singleton (design tokens). This MUST be set BEFORE
# qt_add_qml_module so the generated qmldir records it as `singleton Theme`.
set_source_files_properties(qml/Theme.qml PROPERTIES
    QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(watchtower
    URI Watchtower
    VERSION 1.0
    # Qt 6.4's default resource prefix is "/<URI>"; pin the 6.5+ convention
    # "/qt/qml" so resource URLs stay stable across Qt versions.
    RESOURCE_PREFIX "/qt/qml"
    QML_FILES
        qml/Main.qml
        qml/Theme.qml
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
        qml/VideoSurface.qml
        qml/VideoTest.qml
    SOURCES
        src/models/CameraStatus.h
        src/models/Types.h
        src/models/MockData.h
        src/models/MockData.cpp
        src/models/ProvisioningImport.h
        src/models/ProvisioningImport.cpp
        src/models/CameraModel.h
        src/models/CameraModel.cpp
        src/models/GroupModel.h
        src/models/GroupModel.cpp
        src/models/EventModel.h
        src/models/EventModel.cpp
        src/models/SavedViewModel.h
        src/models/SavedViewModel.cpp
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

# So the generated qmltyperegistrations.cpp can find the model headers by name.
target_include_directories(watchtower PRIVATE src/models)

target_link_libraries(watchtower PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
)
