cmake_minimum_required(VERSION 3.22.1)
project(pty C)

add_library(pty SHARED
    pty_bridge.c
)

find_library(log-lib log)

target_link_libraries(pty
    ${log-lib}
)

# Required for openpty()
target_link_options(pty PRIVATE -Wl,--no-undefined)

# Compiler flags
target_compile_options(pty PRIVATE
    -Wall
    -Wextra
    -O2
    -fPIC
    -D_GNU_SOURCE
)
