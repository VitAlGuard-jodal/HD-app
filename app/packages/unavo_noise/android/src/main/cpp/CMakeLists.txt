cmake_minimum_required(VERSION 3.22.1)
project(unavo_noise C)

set(RNNOISE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../src/rnnoise")

add_library(unavo_noise SHARED
    jni.c
    "${RNNOISE_DIR}/src/denoise.c"
    "${RNNOISE_DIR}/src/rnn.c"
    "${RNNOISE_DIR}/src/pitch.c"
    "${RNNOISE_DIR}/src/kiss_fft.c"
    "${RNNOISE_DIR}/src/celt_lpc.c"
    "${RNNOISE_DIR}/src/nnet.c"
    "${RNNOISE_DIR}/src/nnet_default.c"
    "${RNNOISE_DIR}/src/parse_lpcnet_weights.c"
    "${RNNOISE_DIR}/src/rnnoise_data.c"
    "${RNNOISE_DIR}/src/rnnoise_tables.c"
)

target_include_directories(unavo_noise PRIVATE
    "${RNNOISE_DIR}/include"
    "${RNNOISE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../src/shim"
)
target_compile_definitions(unavo_noise PRIVATE RNNOISE_BUILD DISABLE_DEBUG_FLOAT)
target_compile_options(unavo_noise PRIVATE -O2 -fvisibility=hidden)
target_link_libraries(unavo_noise log)
