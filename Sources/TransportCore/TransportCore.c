#include "TransportCore.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#define CAPACITY 65536u
#define BAUD 31250u
struct AJRenderer {
    AJByte queue[CAPACITY];
    _Atomic uint32_t writeIndex, readIndex;
    _Atomic uint64_t dropped, transmitted;
    _Atomic uint32_t amplitudeBits, reversed, idleBits;
    uint32_t rate, fraction, remaining, bit, gap;
    bool active;
    AJByte current;
    _Atomic uint64_t panicThrough;
    uint32_t panicPosition;
    bool panicking;
    double ticksPerSample;
};
AJRenderer *aj_create(uint32_t rate, double ticksPerSecond) {
    if (rate < BAUD || ticksPerSecond <= 0) return NULL;
    AJRenderer *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->rate = rate; r->ticksPerSample = ticksPerSecond / rate;
    r->fraction = BAUD / 2;
    aj_configure(r, .90f, true, 0);
    return r;
}
void aj_panic(AJRenderer *r) {
    atomic_store(&r->panicThrough, (uint64_t)atomic_load(&r->writeIndex) + 1);
}
void aj_destroy(AJRenderer *r) { free(r); }
bool aj_enqueue(AJRenderer *r, const AJByte *bytes, uint32_t count) {
    uint32_t w = atomic_load_explicit(&r->writeIndex, memory_order_relaxed);
    uint32_t rd = atomic_load_explicit(&r->readIndex, memory_order_acquire);
    if (count > CAPACITY - (w - rd)) { atomic_fetch_add(&r->dropped, count); return false; }
    for (uint32_t i = 0; i < count; i++) r->queue[(w + i) % CAPACITY] = bytes[i];
    atomic_store_explicit(&r->writeIndex, w + count, memory_order_release);
    return true;
}
void aj_configure(AJRenderer *r, float amplitude, bool reversed, uint32_t idleBits) {
    if (amplitude < .50f) amplitude = .50f;
    if (amplitude > .99f) amplitude = .99f;
    uint32_t bits; memcpy(&bits, &amplitude, sizeof(bits));
    atomic_store(&r->amplitudeBits, bits);
    atomic_store(&r->reversed, reversed);
    atomic_store(&r->idleBits, idleBits > 4 ? 4 : idleBits);
}
static uint32_t bit_samples(AJRenderer *r) {
    r->fraction += r->rate;
    uint32_t n = r->fraction / BAUD;
    r->fraction %= BAUD;
    return n;
}
// At 96 kHz each byte starts a fresh fixed-width active-bit clock.
// Only STOP consumes the fractional byte-duration remainder. Additional idle
// bits may use the same reservoir, but START/data never read or update it.
static uint32_t uart_bit_samples(AJRenderer *r) {
    if (r->rate != 96000) return bit_samples(r);
    if (r->bit < 9) return 3;
    r->fraction += 10 * r->rate;
    uint32_t byteSamples = r->fraction / BAUD;
    r->fraction %= BAUD;
    return byteSamples - 9 * 3; // STOP is 3 or 4 samples; mean 3.72.
}
void aj_render(AJRenderer *r, float *left, float *right, uint32_t frames, uint64_t hostTime) {
    uint32_t raw = atomic_load(&r->amplitudeBits);
    float amp; memcpy(&amp, &raw, sizeof(amp));
    float on = atomic_load(&r->reversed) ? -amp : amp;
    for (uint32_t i = 0; i < frames; i++) {
        if (r->active && r->remaining == 0) {
            r->bit++;
            if (r->bit == 10) {
                r->active = false;
                atomic_fetch_add_explicit(&r->transmitted, 1, memory_order_relaxed);
                r->gap = r->current.messageEnd ? atomic_load(&r->idleBits) : 0;
            } else r->remaining = uart_bit_samples(r);
        }
        if (!r->active && r->remaining == 0 && r->gap) {
            r->remaining = bit_samples(r); r->gap--;
        }
        if (!r->active && r->remaining == 0) {
            uint64_t panic = atomic_exchange(&r->panicThrough, 0);
            if (panic) {
                uint32_t currentRead = atomic_load(&r->readIndex);
                uint32_t target = (uint32_t)(panic - 1);
                if (target - currentRead <= CAPACITY)
                    atomic_store_explicit(&r->readIndex, target, memory_order_release);
                r->panicking = true; r->panicPosition = 0;
            }
            uint32_t rd = atomic_load_explicit(&r->readIndex, memory_order_relaxed);
            uint32_t w = atomic_load_explicit(&r->writeIndex, memory_order_acquire);
            uint64_t now = hostTime + (uint64_t)(i * r->ticksPerSample);
            if (r->panicking) {
                uint32_t p = r->panicPosition++, channel = p / 9, part = p % 9;
                uint8_t sequence[9] = {0xB0 | channel, 123, 0, 0xB0 | channel, 120, 0, 0xE0 | channel, 0, 64};
                r->current = (AJByte){sequence[part], part % 3 == 2, 0};
                r->active = true; r->bit = 0; r->remaining = uart_bit_samples(r);
                if (r->panicPosition == 144) r->panicking = false;
            } else if (rd != w && r->queue[rd % CAPACITY].hostTime <= now) {
                r->current = r->queue[rd % CAPACITY];
                atomic_store_explicit(&r->readIndex, rd + 1, memory_order_release);
                r->active = true; r->bit = 0; r->remaining = uart_bit_samples(r);
            } else {
                // Reset the idle/STOP reservoir at a new burst. At 96 kHz no
                // active-bit phase exists; other rates retain their original timing.
                r->fraction = BAUD / 2;
            }
        }
        bool zero = r->active && (r->bit == 0 || (r->bit < 9 && !(r->current.byte & (1u << (r->bit - 1)))));
        left[i] = zero ? on : 0; right[i] = zero ? -on : 0;
        if (r->remaining) r->remaining--;
    }
}
uint32_t aj_pending(AJRenderer *r) {
    uint32_t rd = atomic_load(&r->readIndex);
    return atomic_load(&r->writeIndex) - rd;
}
uint64_t aj_dropped(AJRenderer *r) { return atomic_load(&r->dropped); }
uint64_t aj_transmitted(AJRenderer *r) { return atomic_load(&r->transmitted); }
AURenderCallback aj_callback(void) { return aj_audio_callback; }
OSStatus aj_audio_callback(void *ref, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    if (!data) return kAudio_ParamError;
    if (data->mNumberBuffers != 2 || !data->mBuffers[0].mData || !data->mBuffers[1].mData) {
        for (UInt32 b = 0; b < data->mNumberBuffers; b++)
            if (data->mBuffers[b].mData) memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
        return kAudio_ParamError;
    }
    uint64_t host = (time->mFlags & kAudioTimeStampHostTimeValid) ? time->mHostTime : mach_absolute_time();
    aj_render(ref, data->mBuffers[0].mData, data->mBuffers[1].mData, frames, host);
    return noErr;
}
