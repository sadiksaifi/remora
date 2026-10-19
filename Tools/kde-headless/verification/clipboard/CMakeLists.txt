cmake_minimum_required(VERSION 3.16)
project(ClipboardOfflineCheck LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(KRDP_SOURCE_DIR "" CACHE PATH "Patched KRdp source directory")
set(KRDP_BUILD_DIR "" CACHE PATH "Existing patched KRdp build directory")
if(NOT EXISTS "${KRDP_SOURCE_DIR}/src/Clipboard.h" OR NOT EXISTS "${KRDP_BUILD_DIR}/bin/libKRdp.so")
    message(FATAL_ERROR "Set KRDP_SOURCE_DIR and KRDP_BUILD_DIR to the patched source and completed build")
endif()
find_package(Qt6 REQUIRED COMPONENTS Core Gui)
find_package(FreeRDP 3 REQUIRED)
find_package(WinPR 3 REQUIRED)
find_package(KPipeWire REQUIRED)
add_executable(clipboard-check main.cpp)
target_compile_options(clipboard-check PRIVATE -UNDEBUG)
target_include_directories(clipboard-check PRIVATE
    ${KRDP_SOURCE_DIR}/src ${KRDP_BUILD_DIR}/src
    ${FreeRDP_INCLUDE_DIR} ${WinPR_INCLUDE_DIR})
target_link_libraries(clipboard-check PRIVATE
    ${KRDP_BUILD_DIR}/bin/libKRdp.so Qt6::Core Qt6::Gui K::KPipeWireRecord)
