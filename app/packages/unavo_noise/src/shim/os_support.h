/* rnnoise 0.2 릴리스의 src/vec_neon.h 가 존재하지 않는 "os_support.h" 를 include 한다(상류 main 은
 * common.h 포함 + RNN_CLEAR 로 고쳤다). 원본(src/rnnoise/)을 손대지 않고 같은 효과를 내는 shim. */
#ifndef UNAVO_OS_SUPPORT_SHIM_H
#define UNAVO_OS_SUPPORT_SHIM_H
#include "common.h"
#ifndef OPUS_CLEAR
#define OPUS_CLEAR(dst, n) RNN_CLEAR(dst, n)
#endif
#endif
