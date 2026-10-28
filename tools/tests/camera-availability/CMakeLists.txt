cmake_minimum_required(VERSION 3.21)
project(camera_availability_journal_contract LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Sql)
set(MODELS "${CMAKE_CURRENT_LIST_DIR}/../../../src/models")
add_executable(camera-availability-journal-test main.cpp
    "${MODELS}/CameraAvailabilityJournal.cpp"
    "${MODELS}/CameraAvailabilityJournal.h")
target_include_directories(camera-availability-journal-test PRIVATE "${MODELS}")
target_link_libraries(camera-availability-journal-test PRIVATE Qt6::Core Qt6::Sql)
enable_testing()
add_test(NAME camera-availability-journal-contract COMMAND camera-availability-journal-test)
