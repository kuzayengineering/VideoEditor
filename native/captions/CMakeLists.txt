# Auto captions: whisper.cpp (speech to text) behind a tiny C interface
# (vc_captions.cpp) that the app calls through dart:ffi. Built as one shared
# library, libvc_captions.so (Android) / vc_captions.dll (Windows).
cmake_minimum_required(VERSION 3.18)
project(vc_captions C CXX)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
set(GGML_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
# Runs on other people's machines: no tuning for the build machine, and no
# OpenMP runtime to ship (ggml's own thread pool is used).
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)

if(ANDROID AND ANDROID_ABI STREQUAL "arm64-v8a")
  # Phones from about 2019 on (Pixel 4+): dot-product and half-precision
  # instructions make speech recognition several times faster.
  set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "AMD64|x86_64")
  # PCs from about 2013 on.
  set(GGML_AVX ON CACHE BOOL "" FORCE)
  set(GGML_AVX2 ON CACHE BOOL "" FORCE)
  set(GGML_FMA ON CACHE BOOL "" FORCE)
  set(GGML_F16C ON CACHE BOOL "" FORCE)
endif()

add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/../whisper.cpp whisper EXCLUDE_FROM_ALL)

add_library(vc_captions SHARED vc_captions.cpp)
target_link_libraries(vc_captions PRIVATE whisper)
set_target_properties(vc_captions PROPERTIES CXX_STANDARD 17)
if(ANDROID)
  target_link_libraries(vc_captions PRIVATE log)
  # 16 KB pages (Android 15+).
  target_link_options(vc_captions PRIVATE "-Wl,-z,max-page-size=16384")
endif()
