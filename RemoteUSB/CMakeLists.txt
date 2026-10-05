cmake_minimum_required(VERSION 3.24)
project(moonlight-usbd VERSION 1.0.0 LANGUAGES C CXX)

# usbipdcpp's C++23 std::format path uses libc++ floating-point to_chars,
# introduced by the Apple SDK at macOS 13.3. The main application remains
# deployable to macOS 12; the optional USB exporter is gated at 13.3.
if(APPLE)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.3" CACHE STRING "" FORCE)
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(LIBUSB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libusb/libusb")
set(LIBUSB_BUILD_DIR "${CMAKE_BINARY_DIR}/libusb")
file(MAKE_DIRECTORY "${LIBUSB_BUILD_DIR}/include/libusb-1.0")
file(WRITE "${LIBUSB_BUILD_DIR}/config.h" [=[
#include <AvailabilityMacros.h>
#define DEFAULT_VISIBILITY __attribute__((visibility("default")))
#define ENABLE_LOGGING 1
#define HAVE_PTHREAD_THREADID_NP 1
#define HAVE_NFDS_T 1
#define HAVE_SYS_TIME_H 1
#define PLATFORM_POSIX 1
#define PRINTF_FORMAT(a,b) __attribute__((__format__(__printf__,a,b)))
#define _GNU_SOURCE 1
]=])
file(WRITE "${LIBUSB_BUILD_DIR}/include/libusb-1.0/libusb.h"
     "#pragma once\n#include \"${LIBUSB_DIR}/libusb.h\"\n")

add_library(usb-1.0 STATIC
    "${LIBUSB_DIR}/core.c"
    "${LIBUSB_DIR}/descriptor.c"
    "${LIBUSB_DIR}/hotplug.c"
    "${LIBUSB_DIR}/io.c"
    "${LIBUSB_DIR}/strerror.c"
    "${LIBUSB_DIR}/sync.c"
    "${LIBUSB_DIR}/os/events_posix.c"
    "${LIBUSB_DIR}/os/threads_posix.c"
    "${LIBUSB_DIR}/os/darwin_usb.c")
set_target_properties(usb-1.0 PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
target_include_directories(usb-1.0 PUBLIC "${LIBUSB_BUILD_DIR}/include"
                           "${LIBUSB_DIR}")
target_include_directories(usb-1.0 PRIVATE "${LIBUSB_BUILD_DIR}")
target_link_libraries(usb-1.0 PRIVATE objc)
target_link_options(usb-1.0 INTERFACE "-framework" "IOKit"
                    "-framework" "CoreFoundation" "-framework" "Security")

file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/cmake/asio" "${CMAKE_BINARY_DIR}/cmake/spdlog")
file(WRITE "${CMAKE_BINARY_DIR}/cmake/asio/asioConfig.cmake"
     "add_library(asio::asio INTERFACE IMPORTED)\n"
     "set_target_properties(asio::asio PROPERTIES INTERFACE_INCLUDE_DIRECTORIES \"${CMAKE_CURRENT_SOURCE_DIR}/third_party/asio/asio/include\")\n")
file(WRITE "${CMAKE_BINARY_DIR}/cmake/spdlog/spdlogConfig.cmake"
     "add_library(spdlog::spdlog INTERFACE IMPORTED)\n"
     "set_target_properties(spdlog::spdlog PROPERTIES INTERFACE_INCLUDE_DIRECTORIES \"${CMAKE_CURRENT_SOURCE_DIR}/third_party/spdlog/include\")\n")
list(APPEND CMAKE_PREFIX_PATH "${CMAKE_BINARY_DIR}/cmake/asio" "${CMAKE_BINARY_DIR}/cmake/spdlog")

file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/pkgconfig")
file(WRITE "${CMAKE_BINARY_DIR}/pkgconfig/libusb-1.0.pc"
     "Name: libusb-1.0\nDescription: vendored libusb for Remote USB\nVersion: 1.0.29\n"
     "Libs: ${CMAKE_BINARY_DIR}/lib/libusb-1.0.a -lobjc -framework IOKit -framework CoreFoundation -framework Security\n"
     "Cflags: -I${LIBUSB_BUILD_DIR}/include -I${LIBUSB_DIR}\n")
set(ENV{PKG_CONFIG_LIBDIR} "${CMAKE_BINARY_DIR}/pkgconfig")
set(ENV{PKG_CONFIG_PATH} "${CMAKE_BINARY_DIR}/pkgconfig")
set(USBIPDCPP_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_VIRTUAL_DEVICE OFF CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_LIBUSB_COMPONENTS ON CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/usbipdcpp EXCLUDE_FROM_ALL)

add_executable(moonlight-usbd main.cpp)
target_compile_definitions(moonlight-usbd PRIVATE MOONLIGHT_USB_HELPER_VERSION="${PROJECT_VERSION}")
target_link_libraries(moonlight-usbd PRIVATE usbipdcpp_libusb)
