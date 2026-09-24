#ifndef TRANSPORT_CORE_H
#define TRANSPORT_CORE_H
#include <stdint.h>
#include <stdbool.h>
#include <AudioToolbox/AudioToolbox.h>
typedef struct AJRenderer AJRenderer;
typedef struct { uint8_t byte; uint8_t messageEnd; uint64_t hostTime; } AJByte;
AJRenderer *aj_create(uint32_t sampleRate, double ticksPerSecond);
void aj_destroy(AJRenderer *r);
// One serialized producer, one audio consumer. Whole batch accepted or rejected.
bool aj_enqueue(AJRenderer *r, const AJByte *bytes, uint32_t count);
void aj_configure(AJRenderer *r, float amplitude, bool reversed, uint32_t idleBits);
void aj_render(AJRenderer *r, float *left, float *right, uint32_t frames, uint64_t hostTime);
void aj_panic(AJRenderer *r);
uint32_t aj_pending(AJRenderer *r);
uint64_t aj_dropped(AJRenderer *r);
uint64_t aj_transmitted(AJRenderer *r);
AURenderCallback aj_callback(void);
OSStatus aj_audio_callback(void *ref, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data);
#endif
