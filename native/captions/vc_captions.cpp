// Auto captions: turns 16 kHz mono speech into words with their times,
// using whisper.cpp. A deliberately small C interface for dart:ffi.

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "whisper.h"

#if defined(_WIN32)
#define VC_API extern "C" __declspec(dllexport)
#else
#define VC_API extern "C" __attribute__((visibility("default")))
#endif

namespace {

std::atomic<int> g_cancel{0};

typedef void (*vc_progress_fn)(int32_t percent);

void quiet_log(enum ggml_log_level, const char *, void *) {}

void json_string(std::string &out, const char *s) {
  out += '"';
  for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
    switch (*p) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (*p < 0x20) {
          char buf[8];
          snprintf(buf, sizeof buf, "\\u%04x", *p);
          out += buf;
        } else {
          out += (char)*p;
        }
    }
  }
  out += '"';
}

char *dup(const std::string &s) {
  char *p = (char *)malloc(s.size() + 1);
  memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

// The alignment heads for word timing (DTW) that match the model file.
whisper_alignment_heads_preset heads_for(const char *model) {
  const std::string m = model;
  auto has = [&](const char *x) { return m.find(x) != std::string::npos; };
  if (has("tiny.en")) return WHISPER_AHEADS_TINY_EN;
  if (has("base.en")) return WHISPER_AHEADS_BASE_EN;
  if (has("small.en")) return WHISPER_AHEADS_SMALL_EN;
  if (has("tiny")) return WHISPER_AHEADS_TINY;
  if (has("base")) return WHISPER_AHEADS_BASE;
  if (has("small")) return WHISPER_AHEADS_SMALL;
  return WHISPER_AHEADS_NONE;
}

char *error(const char *what) {
  std::string out = "{\"error\":";
  json_string(out, what);
  out += "}";
  return dup(out);
}

}  // namespace

/// Stops a transcription in progress (from any thread).
VC_API void vc_cancel(void) { g_cancel = 1; }

/// Frees a result of vc_transcribe.
VC_API void vc_free(char *p) { free(p); }

/// Recognises the speech in [samples] (16 kHz mono, -1..1) with the model
/// file [model]. [language] is "en", "auto" and so on. [progress] (may be
/// null) is called with 0-100 from the working thread.
///
/// Returns JSON (free with vc_free):
///   {"language":"en","words":[{"s":120,"e":480,"w":"Hello"}, ...]}
/// with times in milliseconds, or {"error":"..."} / {"cancelled":true}.
VC_API char *vc_transcribe(const char *model, const float *samples,
                           int32_t n_samples, const char *language,
                           int32_t threads, vc_progress_fn progress) {
  g_cancel = 0;
  whisper_log_set(quiet_log, nullptr);

  whisper_context_params cp = whisper_context_default_params();
  cp.use_gpu = false;
  // Word times lined up with the sound itself (much closer than the
  // model's own timestamps, especially after silence).
  cp.dtw_aheads_preset = heads_for(model);
  cp.dtw_token_timestamps = cp.dtw_aheads_preset != WHISPER_AHEADS_NONE;
  // (Not available together with flash attention.)
  if (cp.dtw_token_timestamps) cp.flash_attn = false;
  whisper_context *ctx = whisper_init_from_file_with_params(model, cp);
  if (ctx == nullptr) return error("The speech model could not be loaded.");

  whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  p.n_threads = threads > 0 ? threads : 4;
  p.print_progress = false;
  p.print_realtime = false;
  p.print_timestamps = false;
  p.print_special = false;
  p.translate = false;
  p.language = language != nullptr && *language ? language : "auto";
  p.detect_language = false;
  // One segment per word, with its own times.
  p.token_timestamps = true;
  p.max_len = 1;
  p.split_on_word = true;
  // No "[music]" or "(laughs)" style tags.
  p.suppress_nst = true;
  p.progress_callback = [](whisper_context *, whisper_state *, int pct,
                           void *user) {
    if (user != nullptr) ((vc_progress_fn)user)(pct);
  };
  p.progress_callback_user_data = (void *)progress;
  p.abort_callback = [](void *) { return g_cancel.load() != 0; };
  p.abort_callback_user_data = nullptr;

  const int r = whisper_full(ctx, p, samples, n_samples);
  if (g_cancel.load() != 0) {
    whisper_free(ctx);
    return dup("{\"cancelled\":true}");
  }
  if (r != 0) {
    whisper_free(ctx);
    return error("Speech recognition failed.");
  }

  std::string out = "{\"language\":";
  json_string(out, whisper_lang_str(whisper_full_lang_id(ctx)));
  out += ",\"words\":[";
  // Each segment is one word. Its start: the aligned (DTW) time of its
  // first real token when there is one; its end: the next word's start,
  // or its own end time when a pause follows.
  struct Word {
    std::string text;
    long long start, end;
  };
  std::vector<Word> words;
  const whisper_token eot = whisper_token_eot(ctx);
  const int n = whisper_full_n_segments(ctx);
  for (int i = 0; i < n; ++i) {
    std::string text = whisper_full_get_segment_text(ctx, i);
    // Trim the leading space and line breaks.
    size_t a = text.find_first_not_of(" \t\r\n");
    size_t b = text.find_last_not_of(" \t\r\n");
    if (a == std::string::npos) continue;
    text = text.substr(a, b - a + 1);
    // Times are in hundredths of a second.
    long long t0 = whisper_full_get_segment_t0(ctx, i) * 10;
    long long t1 = whisper_full_get_segment_t1(ctx, i) * 10;
    if (cp.dtw_token_timestamps) {
      const int nt = whisper_full_n_tokens(ctx, i);
      for (int j = 0; j < nt; ++j) {
        const whisper_token_data d = whisper_full_get_token_data(ctx, i, j);
        if (d.id >= eot || d.t_dtw < 0) continue;
        t0 = d.t_dtw * 10;
        break;
      }
    }
    words.push_back({text, t0, t1});
  }
  for (size_t i = 0; i < words.size(); ++i) {
    Word &w = words[i];
    if (i + 1 < words.size()) {
      const long long next = words[i + 1].start;
      if (w.end > next || w.end < w.start) w.end = next;
    }
    if (w.end < w.start + 80) w.end = w.start + 80;
  }
  bool first = true;
  for (const Word &w : words) {
    const std::string &text = w.text;
    const long long t0 = w.start, t1 = w.end;
    if (!first) out += ',';
    first = false;
    char buf[64];
    snprintf(buf, sizeof buf, "{\"s\":%lld,\"e\":%lld,\"w\":", t0, t1);
    out += buf;
    json_string(out, text.c_str());
    out += '}';
  }
  out += "]}";
  whisper_free(ctx);
  return dup(out);
}
