cmake_minimum_required(VERSION 3.21)
project(recording_idle_display LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Qml Quick QuickTest)
add_executable(recording-idle-display main.cpp ../../../src/models/CameraStatus.h)
target_include_directories(recording-idle-display PRIVATE ../../../src/models)
target_compile_definitions(recording-idle-display PRIVATE
    QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
    PRODUCT_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../../qml")
target_link_libraries(recording-idle-display PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::QuickTest)
enable_testing()
add_test(NAME recording-idle-display COMMAND recording-idle-display)
set_tests_properties(recording-idle-display PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software;QML_DISABLE_DISK_CACHE=1;WT_NO_SCHEME_REG=1;WT_RECORDING_TEST_OUTPUT=${CMAKE_CURRENT_BINARY_DIR}")
