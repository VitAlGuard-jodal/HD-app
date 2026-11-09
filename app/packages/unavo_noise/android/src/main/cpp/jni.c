#include <jni.h>
#include <stdint.h>

#include "rnnoise.h"

JNIEXPORT jlong JNICALL
Java_kr_modumoa_unavonoise_RnnoiseBridge_create(JNIEnv *env, jobject thiz) {
    (void)env;
    (void)thiz;
    return (jlong)(intptr_t)rnnoise_create(NULL);
}

JNIEXPORT jfloat JNICALL
Java_kr_modumoa_unavonoise_RnnoiseBridge_process(
        JNIEnv *env, jobject thiz, jlong state, jobject buffer, jint frames) {
    (void)thiz;
    if (state == 0 || buffer == NULL || frames != rnnoise_get_frame_size()) {
        return -1.0f;
    }

    const jlong required_bytes = (jlong)frames * (jlong)sizeof(float);
    if ((*env)->GetDirectBufferCapacity(env, buffer) < required_bytes) {
        return -1.0f;
    }
    float *samples = (*env)->GetDirectBufferAddress(env, buffer);
    if (samples == NULL) {
        return -1.0f;
    }

    DenoiseState *denoiser = (DenoiseState *)(intptr_t)state;
    return rnnoise_process_frame(denoiser, samples, samples);
}

JNIEXPORT void JNICALL
Java_kr_modumoa_unavonoise_RnnoiseBridge_destroy(
        JNIEnv *env, jobject thiz, jlong state) {
    (void)env;
    (void)thiz;
    if (state != 0) {
        rnnoise_destroy((DenoiseState *)(intptr_t)state);
    }
}
