// bench_xnn.c — experimental instrumentation for the Arm SME2 A/B investigation.
//
// XNNPACK (statically linked via MediaPipeTasksGenAIC) gates its SME2 kernels
// behind `xnn_enable_arm_sme2_default` (default 0) AND the cpuinfo FEAT_SME2
// probe. Nothing in the shipped runtime ever flips the default, so the SME2
// kernels in the binary are unreachable. `xnn_internal_set_arm_sme2()` is the
// upstream XNNPACK setter; it only takes effect if called before the first
// xnn_init_hardware_config() (the init locks the value to -1 afterwards).
//
// Symbols verified by disassembling hardware-config.o / set_arm_sme2.o in
// MediaPipeTasksGenAIC 0.10.24 (ios-arm64).
#include <stdint.h>
#include <string.h>
#include <sys/sysctl.h>

extern void xnn_internal_set_arm_sme2(int value);
extern int xnn_enable_arm_sme2_default;
extern const void* xnn_init_hardware_config(void);

void bench_xnn_set_sme2(int value) { xnn_internal_set_arm_sme2(value); }

int bench_xnn_sme2_default(void) { return xnn_enable_arm_sme2_default; }

// Read back what XNNPACK *decided* after init. Offsets verified in the
// disassembly of _init_hardware_config (hardware-config.o):
//   [0x00] u64 arch_flags
//   [0x10] use_arm_neon_dot   (cpuinfo_isa.dot)
//   [0x11] use_arm_neon_i8mm  (cpuinfo_isa.i8mm)
//   [0x14] use_arm_sme        (cpuinfo_isa.sme)
//   [0x15] use_arm_sme2       (cpuinfo_isa.sme2 && enable_default)
// This triggers XNNPACK init if not already done, so callers must only use it
// AFTER the gate has been set for the experimental configuration.
int bench_xnn_hw_flags(uint64_t* arch_flags, int* dot, int* i8mm, int* sme, int* sme2) {
  const uint8_t* hc = (const uint8_t*)xnn_init_hardware_config();
  if (!hc) return 0;
  memcpy(arch_flags, hc, sizeof(uint64_t));
  *dot = hc[0x10]; *i8mm = hc[0x11]; *sme = hc[0x14]; *sme2 = hc[0x15];
  return 1;
}

// Safe ISA probe via the same sysctls cpuinfo uses. Returns -1 if key missing.
int bench_sysctl_int(const char* name) {
  int v = 0; size_t len = sizeof(v);
  if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return -1;
  return v;
}
int bench_sysctl_str(const char* name, char* out, size_t cap) {
  size_t len = cap;
  if (sysctlbyname(name, out, &len, NULL, 0) != 0) { out[0] = 0; return -1; }
  return 0;
}

// ---- Probe: call MediaPipe's own Skia CGImage->pixels routine directly. ----
#include <CoreGraphics/CoreGraphics.h>
#include <stdlib.h>
// bool SkCopyPixelsFromCGImage(const SkImageInfo&, size_t rowBytes, void* dst, CGImageRef)
extern _Bool sk_copy_pixels(const void* info, size_t rowBytes, void* dst, CGImageRef img)
    __asm__("__Z23SkCopyPixelsFromCGImageRK11SkImageInfomPvP7CGImage");

// SkImageInfo layout (verified from the disassembly: width/height read at +0x10):
// { SkColorSpace* cs; int colorType; int alphaType; int width; int height; }
typedef struct { void* cs; int colorType; int alphaType; int width; int height; } ProbeSkImageInfo;

// Returns ok flag; writes mean R,G,B of the destination buffer (assumes 4 bytes/pixel).
int probe_sk_copy(CGImageRef img, int colorType, int alphaType, double* r, double* g, double* b, double* a) {
  int w = (int)CGImageGetWidth(img), h = (int)CGImageGetHeight(img);
  ProbeSkImageInfo info = { NULL, colorType, alphaType, w, h };
  size_t rb = (size_t)w * 4;
  unsigned char* buf = calloc(rb * h, 1);
  int ok = sk_copy_pixels(&info, rb, buf, img);
  double s[4] = {0};
  for (size_t i = 0; i < rb * h; i += 4) for (int c = 0; c < 4; c++) s[c] += buf[i + c];
  double n = (double)w * h; *r = s[0]/n; *g = s[1]/n; *b = s[2]/n; *a = s[3]/n;
  free(buf);
  return ok;
}

// Same draw done with plain CoreGraphics (sRGB, BGRA premultiplied-first little endian = 0x2002).
int probe_cg_copy(CGImageRef img, double* r, double* g, double* b, double* a) {
  int w = (int)CGImageGetWidth(img), h = (int)CGImageGetHeight(img);
  size_t rb = (size_t)w * 4;
  unsigned char* buf = calloc(rb * h, 1);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, rb, cs, 0x2002);
  int ok = ctx != NULL;
  if (ctx) { CGContextSetBlendMode(ctx, kCGBlendModeCopy); CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img); CGContextRelease(ctx); }
  CGColorSpaceRelease(cs);
  double s[4] = {0};
  for (size_t i = 0; i < rb * h; i += 4) for (int c = 0; c < 4; c++) s[c] += buf[i + c];
  double n = (double)w * h; *r = s[0]/n; *g = s[1]/n; *b = s[2]/n; *a = s[3]/n;
  free(buf);
  return ok;
}

// ---- Probe: MediaPipe C API with an explicit preferred_backend. ----
#include <MediaPipeTasksGenAIC/llm_inference_engine.h>
#include <MediaPipeTasksGenAIC/llm_inference_engine_ios.h>
#include <string.h>
#include <stdio.h>

// Returns 0 on success; writes the model's reply (or an error) into out.
int probe_c_api(const char* model, const char* enc, const char* adp, const char* cache_dir,
                int backend, CGImageRef img, const char* prompt, char* out, size_t out_cap) {
  LlmModelSettings ms; memset(&ms, 0, sizeof ms);
  ms.model_path = model; ms.vision_encoder_path = enc; ms.vision_adapter_path = adp;
  ms.cache_dir = cache_dir; ms.max_num_tokens = 512; ms.max_num_images = 1; ms.max_top_k = 1;
  ms.preferred_backend = (LlmPreferredBackend)backend;
  char* err = NULL; LlmInferenceEngine_Engine* engine = NULL;
  if (LlmInferenceEngine_CreateEngine(&ms, &engine, &err) != 0) { snprintf(out, out_cap, "CreateEngine error: %s", err ? err : "?"); return 1; }
  LlmSessionConfig sc; memset(&sc, 0, sizeof sc);
  sc.topk = 1; sc.topp = 1.0f; sc.temperature = 0.0f; sc.random_seed = 0; sc.enable_vision_modality = true;
  LlmInferenceEngine_Session* s = NULL;
  if (LlmInferenceEngine_CreateSession(engine, &sc, &s, &err) != 0) { snprintf(out, out_cap, "CreateSession error: %s", err ? err : "?"); return 2; }
  if (img && LlmInferenceEngine_Session_AddCgImage(s, img, &err) != 0) { snprintf(out, out_cap, "AddImage error: %s", err ? err : "?"); return 3; }
  if (LlmInferenceEngine_Session_AddQueryChunk(s, prompt, &err) != 0) { snprintf(out, out_cap, "AddQuery error: %s", err ? err : "?"); return 4; }
  LlmResponseContext rc; memset(&rc, 0, sizeof rc);
  if (LlmInferenceEngine_Session_PredictSync(s, &rc, &err) != 0) { snprintf(out, out_cap, "Predict error: %s", err ? err : "?"); return 5; }
  out[0] = 0;
  for (int i = 0; i < rc.response_count; i++) strncat(out, rc.response_array[i], out_cap - strlen(out) - 1);
  LlmInferenceEngine_CloseResponseContext(&rc);
  LlmInferenceEngine_Session_Delete(s);
  LlmInferenceEngine_Engine_Delete(engine);
  return 0;
}
