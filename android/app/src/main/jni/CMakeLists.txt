cmake_minimum_required(VERSION 3.22.1)
project(pty C)

add_library(pty SHARED
    pty_bridge.c
)

find_library(log-lib log)

target_link_libraries(pty
    ${log-lib}
)

# openpty()/forkpty() live in bionic libc on Android — no -lutil needed.
# Do NOT use -Wl,--no-undefined here: it can fail the build if any optional
# symbol (e.g. termios extensions) is weakly resolved by the NDK stub.

target_compile_options(pty PRIVATE
    -Wall
    -Wextra
    -O2
    -fPIC
    -D_GNU_SOURCE
)

# Ensure the output is named libpty.so (matches System.loadLibrary("pty"))
set_target_properties(pty PROPERTIES OUTPUT_NAME "pty")
