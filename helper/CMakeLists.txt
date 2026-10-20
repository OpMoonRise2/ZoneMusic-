# ZMHelper — ZoneMusic engine-music sentinel (Ashita v4 plugin)
#
# BUILD (32-bit; the FFXI client is a 32-bit process):
#
#   cmake -B build -A Win32 -DASHITA_SDK_DIR="<Ashita>/plugins/sdk"
#   cmake --build build --config Release
#
# Output: build/Release/ZMHelper.dll  ->  copy to <Ashita>/plugins/
# Load in game:  /load zmhelper   (or add to your boot script)

cmake_minimum_required(VERSION 3.15)
project(ZMHelper CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 4)
    message(FATAL_ERROR "ZMHelper must be built 32-bit (FFXI is a 32-bit client). Configure with: cmake -B build -A Win32")
endif()

# The Ashita v4 SDK headers ship with every Ashita install in <Ashita>/plugins/sdk.
set(ASHITA_SDK_DIR "" CACHE PATH "Path to the Ashita v4 SDK headers (<Ashita>/plugins/sdk)")
if(NOT EXISTS "${ASHITA_SDK_DIR}/Ashita.h")
    message(FATAL_ERROR "Ashita SDK not found. Configure with -DASHITA_SDK_DIR=\"<Ashita>/plugins/sdk\"")
endif()

add_library(ZMHelper SHARED
    src/ZMHelper.cpp
    src/exports.def
    deps/detours/detours.cpp
    deps/detours/disasm.cpp
    deps/detours/modules.cpp
    deps/detours/creatwth.cpp
    deps/detours/image.cpp
    deps/detours/uimports.cpp
)

# uimports.cpp is meant to be #included by creatwth.cpp in Detours' build;
# excluding it from standalone compilation mirrors the official build.
set_source_files_properties(deps/detours/uimports.cpp PROPERTIES HEADER_FILE_ONLY ON)

target_include_directories(ZMHelper PRIVATE
    "${ASHITA_SDK_DIR}"
    deps/detours
)

target_compile_definitions(ZMHelper PRIVATE
    WIN32 _WINDOWS _USRDLL NOMINMAX WIN32_LEAN_AND_MEAN
)

set_target_properties(ZMHelper PROPERTIES
    OUTPUT_NAME "ZMHelper"
    PREFIX ""
)
