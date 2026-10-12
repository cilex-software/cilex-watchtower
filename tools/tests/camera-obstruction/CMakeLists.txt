cmake_minimum_required(VERSION 3.21)
project(camera_obstruction_contract LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Network Test)
set(MODELS "${CMAKE_CURRENT_LIST_DIR}/../../../src/models")
add_executable(camera-obstruction-test main.cpp
    "${MODELS}/CameraObstructionController.cpp" "${MODELS}/CameraObstructionController.h"
    "${MODELS}/AuthController.cpp" "${MODELS}/AuthController.h")
target_include_directories(camera-obstruction-test PRIVATE "${MODELS}")
target_link_libraries(camera-obstruction-test PRIVATE Qt6::Core Qt6::Network Qt6::Test)
enable_testing()
add_test(NAME camera-obstruction-contract COMMAND camera-obstruction-test)
