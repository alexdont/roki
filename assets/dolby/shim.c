// A Dolby (AC-3 / E-AC-3) and DTS audio decoder for the browser: FFmpeg's decoders, built to
// WebAssembly with nothing else of FFmpeg, behind a tiny interface. Audio in as the packets a
// Matroska or MP4 file holds, audio out as interleaved 32-bit float, already mixed down to
// stereo by the decoder itself (what a browser plays anyway).
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <emscripten/emscripten.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
#include <libavutil/opt.h>

typedef struct {
  AVCodecContext *ctx;
  AVPacket *pkt;
  AVFrame *frame;
  float *out;
  int out_cap;      // floats
  int out_frames;   // frames in out
  int channels;
  int rate;
} Dec;

EMSCRIPTEN_KEEPALIVE
Dec *dolby_open(const char *name, const uint8_t *extradata, int extradata_len, int downmix_stereo) {
  const AVCodec *codec = avcodec_find_decoder_by_name(name);
  if (!codec) return NULL;
  Dec *d = calloc(1, sizeof(Dec));
  d->ctx = avcodec_alloc_context3(codec);
  d->pkt = av_packet_alloc();
  d->frame = av_frame_alloc();
  if (!d->ctx || !d->pkt || !d->frame) return NULL;
  if (extradata && extradata_len > 0) {
    d->ctx->extradata = av_mallocz(extradata_len + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(d->ctx->extradata, extradata, extradata_len);
    d->ctx->extradata_size = extradata_len;
  }
  d->ctx->request_sample_fmt = AV_SAMPLE_FMT_FLTP;
  // The decoders mix down themselves when asked (their "downmix" option; dcadec and ac3dec both have it).
  if (downmix_stereo) av_opt_set(d->ctx->priv_data, "downmix", "stereo", 0);
  if (avcodec_open2(d->ctx, codec, NULL) < 0) return NULL;
  return d;
}

// One sample of one channel as a float, whatever the decoder's format.
static inline float sample_at(const AVFrame *f, int ch, int i) {
  enum AVSampleFormat fmt = f->format;
  int planar = av_sample_fmt_is_planar(fmt);
  int nb = f->ch_layout.nb_channels;
  const uint8_t *base = planar ? f->extended_data[ch] : f->extended_data[0];
  int idx = planar ? i : i * nb + ch;
  switch (av_get_packed_sample_fmt(fmt)) {
    case AV_SAMPLE_FMT_FLT: return ((const float *)base)[idx];
    case AV_SAMPLE_FMT_DBL: return (float)((const double *)base)[idx];
    case AV_SAMPLE_FMT_S32: return ((const int32_t *)base)[idx] / 2147483648.0f;
    case AV_SAMPLE_FMT_S16: return ((const int16_t *)base)[idx] / 32768.0f;
    case AV_SAMPLE_FMT_U8:  return (((const uint8_t *)base)[idx] - 128) / 128.0f;
    default: return 0.0f;
  }
}

// Append a decoded frame to `out` as stereo (or mono as it is), interleaved. More than two
// channels (the decoder could not mix them down) are folded the usual way: centre and the
// surrounds at -3 dB into each side, LFE left out.
static int append_frame(Dec *d) {
  AVFrame *f = d->frame;
  int nb = f->ch_layout.nb_channels;
  int n = f->nb_samples;
  int outch = nb >= 2 ? 2 : 1;
  int need = (d->out_frames + n) * outch;
  if (need > d->out_cap) {
    int cap = need * 2;
    float *o = realloc(d->out, cap * sizeof(float));
    if (!o) return -1;
    d->out = o;
    d->out_cap = cap;
  }
  float *o = d->out + d->out_frames * outch;
  if (nb <= 2) {
    for (int i = 0; i < n; i++)
      for (int c = 0; c < outch; c++) o[i * outch + c] = sample_at(f, c, i);
  } else {
    // FFmpeg's native order: FL FR FC LFE BL BR [SL SR ...]
    for (int i = 0; i < n; i++) {
      float l = sample_at(f, 0, i), r = sample_at(f, 1, i);
      float c = nb > 2 ? sample_at(f, 2, i) * 0.7071f : 0;
      float bl = nb > 4 ? sample_at(f, 4, i) * 0.7071f : 0;
      float br = nb > 5 ? sample_at(f, 5, i) * 0.7071f : 0;
      float sl = nb > 6 ? sample_at(f, 6, i) * 0.7071f : 0;
      float sr = nb > 7 ? sample_at(f, 7, i) * 0.7071f : 0;
      o[i * 2] = l + c + bl + sl;
      o[i * 2 + 1] = r + c + br + sr;
    }
  }
  d->out_frames += n;
  d->channels = outch;
  d->rate = f->sample_rate;
  return 0;
}

static int drain(Dec *d) {
  for (;;) {
    int r = avcodec_receive_frame(d->ctx, d->frame);
    if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return 0;
    if (r < 0) return r;
    if (append_frame(d) < 0) return -1;
    av_frame_unref(d->frame);
  }
}

// Decode one packet. Returns the number of frames now in `out` (read them with dolby_out
// before the next call), or a negative error.
EMSCRIPTEN_KEEPALIVE
int dolby_decode(Dec *d, const uint8_t *data, int len) {
  d->out_frames = 0;
  if (av_new_packet(d->pkt, len) < 0) return -1;
  memcpy(d->pkt->data, data, len);
  int r = avcodec_send_packet(d->ctx, d->pkt);
  av_packet_unref(d->pkt);
  if (r < 0 && r != AVERROR(EAGAIN)) return r;
  if (drain(d) < 0) return -2;
  return d->out_frames;
}

EMSCRIPTEN_KEEPALIVE
int dolby_flush(Dec *d) {
  d->out_frames = 0;
  avcodec_send_packet(d->ctx, NULL);
  if (drain(d) < 0) return -2;
  return d->out_frames;
}

EMSCRIPTEN_KEEPALIVE float *dolby_out(Dec *d) { return d->out; }
EMSCRIPTEN_KEEPALIVE int dolby_channels(Dec *d) { return d->channels; }
EMSCRIPTEN_KEEPALIVE int dolby_rate(Dec *d) { return d->rate; }

EMSCRIPTEN_KEEPALIVE
void dolby_close(Dec *d) {
  if (!d) return;
  avcodec_free_context(&d->ctx);
  av_packet_free(&d->pkt);
  av_frame_free(&d->frame);
  free(d->out);
  free(d);
}
