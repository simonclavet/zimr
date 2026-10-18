cmake_minimum_required(VERSION 3.21)

# MSVC runtime configuration (before project())
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL" CACHE STRING "" FORCE)
endif()

set(CMAKE_CONFIGURATION_TYPES "Debug;RelWithDebInfo" CACHE STRING "" FORCE)

project(Gogus LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# =============================================================================
# Fetch raylib
# =============================================================================
include(FetchContent)

set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_GAMES OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    raylib
    GIT_REPOSITORY https://github.com/raysan5/raylib.git
    GIT_TAG 5.5
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(raylib)

# =============================================================================
# Fetch imgui and rlImGui
# =============================================================================
FetchContent_Declare(
    imgui
    GIT_REPOSITORY https://github.com/ocornut/imgui.git
    GIT_TAG master
    GIT_SHALLOW TRUE
)

FetchContent_Declare(
    rlimgui
    GIT_REPOSITORY https://github.com/raylib-extras/rlImGui.git
    GIT_TAG main
    GIT_SHALLOW TRUE
)

cmake_policy(SET CMP0169 OLD)
FetchContent_Populate(imgui)
FetchContent_Populate(rlimgui)

set(IMGUI_SOURCES
    ${imgui_SOURCE_DIR}/imgui.cpp
    ${imgui_SOURCE_DIR}/imgui_demo.cpp
    ${imgui_SOURCE_DIR}/imgui_draw.cpp
    ${imgui_SOURCE_DIR}/imgui_tables.cpp
    ${imgui_SOURCE_DIR}/imgui_widgets.cpp
    ${rlimgui_SOURCE_DIR}/rlImGui.cpp
)

# =============================================================================
# Main executable
# =============================================================================
add_executable(Gogus
    src/main.cpp
    src/utils.h
    src/math_utils.h
    ${IMGUI_SOURCES}
)

target_include_directories(Gogus PRIVATE
    ${CMAKE_SOURCE_DIR}/src
    ${imgui_SOURCE_DIR}
    ${rlimgui_SOURCE_DIR}
    ${raylib_SOURCE_DIR}/src/external/glfw/include
)

target_link_libraries(Gogus PRIVATE raylib)

if(WIN32)
    target_link_libraries(Gogus PRIVATE opengl32 gdi32 winmm)
endif()

target_compile_definitions(Gogus PRIVATE
    NOMINMAX
    _CRT_SECURE_NO_WARNINGS
)

if(MSVC)
    target_compile_options(Gogus PRIVATE /W4 /WX /wd4100 /wd4267 /wd4018 /wd4505)
    set_source_files_properties(${IMGUI_SOURCES} PROPERTIES COMPILE_FLAGS "/W0")
endif()

# Set as startup project in Visual Studio
set_property(DIRECTORY ${CMAKE_SOURCE_DIR} PROPERTY VS_STARTUP_PROJECT Gogus)
