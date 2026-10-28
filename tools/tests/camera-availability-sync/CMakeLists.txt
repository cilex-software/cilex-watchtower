cmake_minimum_required(VERSION 3.21)
project(camera_availability_sync_contract LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Network Sql Test)
set(MODELS "${CMAKE_CURRENT_LIST_DIR}/../../../src/models")
add_executable(camera-availability-sync-test main.cpp
    "${MODELS}/CameraAvailabilityWorker.cpp" "${MODELS}/CameraAvailabilityWorker.h"
    "${MODELS}/CameraAvailabilityJournal.cpp" "${MODELS}/CameraAvailabilityJournal.h")
target_include_directories(camera-availability-sync-test PRIVATE "${MODELS}")
target_compile_definitions(camera-availability-sync-test PRIVATE
    AVAILABILITY_FIXTURES="${CMAKE_CURRENT_LIST_DIR}/../../../docs/reference/camera-availability-v1")
target_link_libraries(camera-availability-sync-test PRIVATE Qt6::Core Qt6::Network Qt6::Sql Qt6::Test)
enable_testing()
add_test(NAME camera-availability-sync-contract COMMAND camera-availability-sync-test)
