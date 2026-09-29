phys_reader — Physical Memory Reader Kernel Module for MT6878 (Moto Edge 2025)
================================================================================

Kernel: 6.1.141-android14-11-gb4b551f657d1 (GKI)
SoC:    MediaTek Dimensity 7300 (MT6878)
Root:   KernelSU Next 3.3.0

WHAT IT DOES
------------
Loads a kernel module that maps a physical memory region via memremap()
and exposes it as /proc/phys_reader for userspace reads. Designed to
read AP-MD (Application Processor ↔ Modem) shared memory regions.

Two variants included:

  phys_reader_v3.ko  — Maps ap_md_c_smem  (0x8A000000, 26.4MB cacheable shared mem)
  phys_reader_nc.ko  — Maps ap_md_nc_smem (0x8C000000, 1.2MB non-cacheable shared mem)


FILES
-----
  phys_reader_v3.S   — Full assembly source for the cacheable variant
  phys_reader_v3.ko  — Pre-built module (5912 bytes)
  phys_reader_nc.S   — Full assembly source for the non-cacheable variant
  phys_reader_nc.ko  — Pre-built module (5928 bytes)


WHY ASSEMBLY?
-------------
This kernel (GKI 6.1 on MT6878) has three features that prevent normal
C-compiled modules from loading:

1. CONFIG_CFI_CLANG — Control Flow Integrity. Every function called via
   indirect call (function pointer) needs a 4-byte CFI type hash at
   [function_address - 4]. The kernel checks this tag before every
   indirect call and panics if it's wrong.

2. PAC (Pointer Authentication) — All kernel functions use paciasp/autiasp
   instructions for return address signing.

3. Section requirements — init_module MUST be in .init.text, cleanup_module
   MUST be in .exit.text, and the module needs .plt / .init.plt sections.

Writing in assembly lets us place CFI tags, PAC instructions, and sections
exactly where the kernel expects them.


CFI TAGS (verified from 4 device modules)
------------------------------------------
  0x36b1c5a6  int (*)(void)                    — init_module, cleanup helpers
  0xa540670c  void (*)(void)                   — cleanup_module
  0xe866e2f4  ssize_t (*)(file*, char __user*, size_t, loff_t*)  — read handler
  0x8f07ca55  int (*)(struct inode*, struct file*)               — open/release
  0x9a660ea0  ssize_t (*)(file*, const char __user*, size_t, loff_t*)  — write
  0x63df1691  int (*)(struct platform_device*) — platform probe/remove
  0x3f45655f  int (*)(struct device*)          — PM suspend/resume


CRC VERSIONS (from device modules — must match running kernel)
--------------------------------------------------------------
  _printk              0x92997ed8
  memremap             0x4d924f20
  memunmap             0x9e9fdd9d
  __arch_copy_to_user  0x9a85eebb
  proc_create          0x0524767b
  remove_proc_entry    0xef8b7667
  module_layout        0xea759d7f


STRUCT LAYOUT
-------------
  struct module:  0x440 bytes total
    offset 0x170: init function pointer
    offset 0x3d8: exit function pointer

  proc_ops:
    offset 0x00:  proc_flags (u32, padded to 8)
    offset 0x08:  proc_open
    offset 0x10:  proc_read    <-- we set this
    offset 0x18:  proc_read_iter
    ...total 0x60 bytes


HOW TO BUILD (cross-compile from Linux x86_64)
-----------------------------------------------
Requires: aarch64-linux-gnu-as, aarch64-linux-gnu-ld (from gcc-aarch64-linux-gnu)

  # Assemble
  aarch64-linux-gnu-as -o phys_reader_v3.o phys_reader_v3.S

  # Link as relocatable object (.ko)
  aarch64-linux-gnu-ld -r -o phys_reader_v3.ko phys_reader_v3.o

That's it. No kernel headers, no Makefile, no kbuild. The .S file contains
everything: code, metadata, version CRCs, modinfo, and the module struct.


HOW TO BUILD FOR A DIFFERENT MEMORY REGION
------------------------------------------
Edit the .S file and change:

  1. The physical address in init_module (mov x0, #0x8NNNNNNN)
  2. The region size in init_module (mov x1, #0xNNNNNNN) and in
     phys_read (mov x19, #...) and in the printk format args
  3. If the size isn't a valid single MOV immediate (must be a 16-bit
     value shifted by 0/16/32/48), use movz + movk pair instead.

Valid single-instruction examples:
  0x1A60000  = 0x1A6 << 16  ✓
  0x100000   = 0x10  << 16  ✓
  0x8A000000 = 0x8A00 << 16 ✓

Needs two instructions:
  0x12C000 → movz xN, #0xC000 / movk xN, #0x12, lsl #16


HOW TO USE
----------
All commands require root (su or KernelSU shell).

  # Load the module
  insmod /sdcard/phys_reader/phys_reader_v3.ko

  # Verify it loaded
  dmesg | grep phys_reader
  # Should show: "phys_reader: mapped 8a000000+1a60000 -> /proc/phys_reader"

  # Test with a small read
  head -c 16 /proc/phys_reader | xxd

  # Full dump to file
  dd if=/proc/phys_reader of=/sdcard/smem_dump.bin bs=4096

  # Unload when done
  rmmod phys_reader

  # For the nc_smem variant:
  insmod /sdcard/phys_reader/phys_reader_nc.ko
  dd if=/proc/phys_reader of=/sdcard/nc_smem_dump.bin bs=4096
  rmmod phys_reader


WHAT'S IN THE SHARED MEMORY
----------------------------
ap_md_c_smem (0x8A000000, 26.4MB):
  - CCCI (Cross Core Communication Interface) headers (magic: FICMFICM)
  - Modem firmware debug log buffer (~20MB of text log messages)
  - NVRAM filesystem metadata (LDT file table entries)
  - SML (SIM Lock) verification trace logs
  - Carrier configuration data (T-Mobile/MetroPCS APNs, SIP addresses)
  - SEJ AES encryption operation logs

ap_md_nc_smem (0x8C000000, 1.2MB):
  - CCCI debug structures (magic: iFiW)
  - GPS/GNSS calibration data ($PMTK sentences)


SAFETY NOTES
-------------
- This module only READS memory. It does not write to any physical address.
- memremap creates a virtual mapping; it does not modify the physical memory.
- The module creates /proc/phys_reader with mode 0444 (read-only).
- Always rmmod after use to clean up the mapping.
- Do NOT attempt to map modem-private DRAM (0xD0000000+) — it is protected
  by the EMI MPU and will cause undefined behavior.
- Do NOT insmod while another phys_reader is already loaded — rmmod first.


KNOWN ISSUES
------------
- If you use the wrong CFI tag, insmod succeeds but reading /proc/phys_reader
  causes a kernel panic. The tags in these modules are verified correct.
- On reboot, the module is automatically unloaded (not persistent).
- The module name in lsmod is "phys_reader" for both variants. Only load one
  at a time.