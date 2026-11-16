// Audio decoders compiled as one translation unit: stb_vorbis (Ogg Vorbis, public domain /
// MIT, https://github.com/nothings/stb) and dr_mp3 (MP3, public domain / MIT-0,
// https://github.com/mackron/dr_libs). Only the decode-from-memory paths are built in.
#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>

#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PUSHDATA_API
#include "stb_vorbis.c"

#define DR_MP3_IMPLEMENTATION
#define DR_MP3_NO_STDIO
#include "dr_mp3.h"

void *vass_mp3_open(const void *data, size_t len) {
    drmp3 *m = (drmp3 *)malloc(sizeof(drmp3));
    if (!m) return NULL;
    if (!drmp3_init_memory(m, data, len, NULL)) {
        free(m);
        return NULL;
    }
    return m;
}

void vass_mp3_info(void *m, unsigned *channels, unsigned *rate) {
    *channels = ((drmp3 *)m)->channels;
    *rate = ((drmp3 *)m)->sampleRate;
}

uint64_t vass_mp3_read(void *m, uint64_t frames, float *out) {
    return drmp3_read_pcm_frames_f32((drmp3 *)m, frames, out);
}

void vass_mp3_close(void *m) {
    drmp3_uninit((drmp3 *)m);
    free(m);
}
