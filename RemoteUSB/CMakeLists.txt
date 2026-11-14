cmake_minimum_required(VERSION 3.24)
project(moonlight-usbd VERSION 2.0.0 LANGUAGES C CXX OBJCXX)
include(CTest)

if(APPLE)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.3" CACHE STRING "" FORCE)
endif()

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../core" "${CMAKE_CURRENT_BINARY_DIR}/core")

add_executable(moonlight-usbd main.mm RootTransferValidation.cpp USBIPHostWire.cpp)
target_compile_definitions(moonlight-usbd PRIVATE MOONLIGHT_USB_HELPER_VERSION="${PROJECT_VERSION}")
target_include_directories(moonlight-usbd PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../core/network/usbip-core/include")
target_link_libraries(moonlight-usbd PRIVATE usbip_core "-framework IOKit" "-framework CoreFoundation")
set_source_files_properties(main.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")

if(BUILD_TESTING)
    add_executable(remote_usb_bounds_test RootTransferValidationTest.cpp RootTransferValidation.cpp)
    add_test(NAME remote_usb_bounds_test COMMAND remote_usb_bounds_test)
    add_executable(usbip_host_wire_test USBIPHostWireTest.cpp USBIPHostWire.cpp)
    add_test(NAME usbip_host_wire_test COMMAND usbip_host_wire_test)
endif()
