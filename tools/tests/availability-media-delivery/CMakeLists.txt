cmake_minimum_required(VERSION 3.21)
project(availability_media_delivery LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Multimedia Network Test)
set(MODELS "${CMAKE_CURRENT_LIST_DIR}/../../../src/models")
add_executable(availability-media-delivery main.cpp
    "${MODELS}/MediaDeliveryObserver.cpp" "${MODELS}/MediaDeliveryObserver.h"
    "${MODELS}/AvailabilityObservationBus.cpp" "${MODELS}/AvailabilityObservationBus.h")
target_include_directories(availability-media-delivery PRIVATE "${MODELS}")
target_link_libraries(availability-media-delivery PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Multimedia Qt6::Network Qt6::Test)
