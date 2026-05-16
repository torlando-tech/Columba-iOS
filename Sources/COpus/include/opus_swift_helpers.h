/* Swift-callable wrappers for variadic opus_encoder/decoder_ctl functions */
#ifndef OPUS_SWIFT_HELPERS_H
#define OPUS_SWIFT_HELPERS_H

#include "opus.h"

#ifdef __cplusplus
extern "C" {
#endif

static inline int opus_encoder_set_bitrate(OpusEncoder *st, opus_int32 bitrate) {
    return opus_encoder_ctl(st, OPUS_SET_BITRATE(bitrate));
}

static inline int opus_encoder_set_complexity(OpusEncoder *st, opus_int32 complexity) {
    return opus_encoder_ctl(st, OPUS_SET_COMPLEXITY(complexity));
}

static inline int opus_encoder_set_signal(OpusEncoder *st, opus_int32 signal) {
    return opus_encoder_ctl(st, OPUS_SET_SIGNAL(signal));
}

static inline int opus_encoder_set_bandwidth(OpusEncoder *st, opus_int32 bandwidth) {
    return opus_encoder_ctl(st, OPUS_SET_BANDWIDTH(bandwidth));
}

static inline int opus_encoder_reset(OpusEncoder *st) {
    return opus_encoder_ctl(st, OPUS_RESET_STATE);
}

static inline int opus_decoder_reset(OpusDecoder *st) {
    return opus_decoder_ctl(st, OPUS_RESET_STATE);
}

/* Force a specific encoder mode: 1000=SILK, 1001=Hybrid, 1002=CELT.
   This uses the private OPUS_SET_FORCE_MODE CTL (11002) for testing only. */
#define OPUS_SET_FORCE_MODE_REQUEST 11002
static inline int opus_encoder_set_force_mode(OpusEncoder *st, opus_int32 mode) {
    return opus_encoder_ctl(st, OPUS_SET_FORCE_MODE_REQUEST, mode);
}

#define OPUS_MODE_SILK_ONLY   1000
#define OPUS_MODE_HYBRID      1001
#define OPUS_MODE_CELT_ONLY   1002

#ifdef __cplusplus
}
#endif

#endif /* OPUS_SWIFT_HELPERS_H */
