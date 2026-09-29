// xnn_sme2.c — runtime control of XNNPACK's Arm SME2 kernels.
//
// MediaPipe Tasks GenAI 0.10.24 statically links an XNNPACK snapshot (June 2025)
// that ships KleidiAI SME2 kernels but gates them behind
// `xnn_enable_arm_sme2_default`, which is 0 and never set. XNNPACK's own setter,
// `xnn_internal_set_arm_sme2`, only takes effect before the first
// `xnn_init_hardware_config()`; after that the default is locked to -1.
// Symbols and struct offsets verified by disassembling hardware-config.o and
// set_arm_sme2.o from the ios-arm64 MediaPipeTasksGenAIC archive.
#include <stdint.h>
#include <sys/sysctl.h>

extern void xnn_internal_set_arm_sme2(int value);
extern const void* xnn_init_hardware_config(void);

// 1 if the CPU reports FEAT_SME2 (A18 / M4 and later), else 0.
int pic2pdf_cpu_has_sme2(void) {
  int v = 0;
  size_t len = sizeof(v);
  if (sysctlbyname("hw.optional.arm.FEAT_SME2", &v, &len, NULL, 0) != 0) return 0;
  return v != 0;
}

// Must be called before any model is loaded. Later calls are ignored by XNNPACK.
void pic2pdf_xnn_set_sme2(int enabled) { xnn_internal_set_arm_sme2(enabled ? 1 : 0); }

// What XNNPACK actually decided: 1 = SME2 kernels selected, 0 = not, -1 = unknown.
// Byte 0x15 of xnn_hardware_config is use_arm_sme2 (verified in disassembly).
// Calling this initializes XNNPACK, so only call it after the gate has been set.
int pic2pdf_xnn_sme2_active(void) {
  const uint8_t* hc = (const uint8_t*)xnn_init_hardware_config();
  if (!hc) return -1;
  return hc[0x15] != 0;
}
