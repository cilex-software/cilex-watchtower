cmake_minimum_required(VERSION 3.21)
project(live_view_persistence LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Qml)
set(MODELS "${CMAKE_CURRENT_LIST_DIR}/../../../src/models")
add_executable(live-view-persistence main.cpp
    "${MODELS}/Settings.cpp" "${MODELS}/Settings.h"
    "${MODELS}/SavedViewModel.cpp" "${MODELS}/SavedViewModel.h"
    "${MODELS}/MockData.cpp")
target_include_directories(live-view-persistence PRIVATE "${MODELS}")
target_link_libraries(live-view-persistence PRIVATE Qt6::Core Qt6::Qml)
enable_testing()
add_test(NAME live-view-persistence COMMAND live-view-persistence)
