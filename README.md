# phys_reader

Loadable kernel module for reading physical memory regions on MediaTek GKI kernels. Written entirely in AArch64 assembly to satisfy CFI (Control Flow Integrity), PAC (Pointer Authentication), and section layout requirements that prevent normal C-compiled modules from loading.

Built for the **MT6878 (Dimensity 7300)** running **GKI kernel 6.1.141**, but the approach generalizes to any arm64 GKI kernel with `CONFIG_CFI_CLANG` enabled.

## Why Assembly?

GKI kernels on MediaTek devices enforce three things that break conventionally compiled `.ko` files:

1. **CONFIG_CFI_CLANG** — Every function called through a pointer must have a 4-byte KCFI type hash at `[function_address - 4]`. Wrong tag = kernel panic.
2. **PAC (Pointer Authentication)** — All kernel functions use `paciasp`/`autiasp` for return address signing.
3. **Strict section placement** — `init_module` must live in `.init.text`, `cleanup_module` in `.exit.text`, and the module needs `.plt`/`.init.plt` stubs.

A C compiler + kbuild can't produce a module that satisfies all three without the full kernel source tree. A single `.S` file can.

## What It Does

Maps a physical memory region with `memremap()` and exposes it as `/proc/phys_reader` (read-only, mode 0444). Designed for reading AP↔Modem shared memory on MediaTek CCCI devices.

Two pre-built variants:

| Module | Region | Address | Size |
|--------|--------|---------|------|
| `phys_reader_v3.ko` | ap_md_c_smem (cacheable) | `0x8A000000` | 26.4 MB |
| `phys_reader_nc.ko` | ap_md_nc_smem (non-cacheable) | `0x8C000000` | 1.2 MB |

## Build

Requires only `aarch64-linux-gnu-as` and `aarch64-linux-gnu-ld` (from `gcc-aarch64-linux-gnu` or `binutils-aarch64-linux-gnu`). No kernel headers, no Makefile, no kbuild.

```bash
aarch64-linux-gnu-as -o phys_reader_v3.o phys_reader_v3.S
aarch64-linux-gnu-ld -r -o phys_reader_v3.ko phys_reader_v3.o
```

## Usage

Requires root (KernelSU, Magisk, etc).

```bash
# Load
insmod /path/to/phys_reader_v3.ko

# Verify
dmesg | grep phys_reader
# → phys_reader: mapped 8a000000+1a60000 -> /proc/phys_reader

# Read
dd if=/proc/phys_reader of=/sdcard/smem_dump.bin bs=4096

# Unload
rmmod phys_reader
```

## Targeting a Different Address

Edit the `.S` file and change the physical address and size in `init_module`. The address/size must be valid ARM64 MOV immediates (16-bit value shifted by 0, 16, 32, or 48 bits). If the value doesn't fit a single instruction, use a `movz`/`movk` pair — see `phys_reader_nc.S` for an example.

## CFI Type Tags

Extracted and verified across multiple device modules from the same kernel:

| Tag | Function Signature |
|-----|-------------------|
| `0x36b1c5a6` | `int (*)(void)` — module init |
| `0xa540670c` | `void (*)(void)` — module cleanup |
| `0xe866e2f4` | `ssize_t (*)(struct file *, char __user *, size_t, loff_t *)` — read |
| `0x9a660ea0` | `ssize_t (*)(struct file *, const char __user *, size_t, loff_t *)` — write |
| `0x8f07ca55` | `int (*)(struct inode *, struct file *)` — open/release |
| `0x85e5a61e` | `__poll_t (*)(struct file *, struct poll_table_struct *)` — poll |
| `0xe01408cd` | `long (*)(struct file *, unsigned int, unsigned long)` — ioctl |
| `0x63df1691` | `int (*)(struct platform_device *)` — platform probe/remove |
| `0x3f45655f` | `int (*)(struct device *)` — PM suspend/resume |

These tags are kernel-build-specific. If porting to a different kernel build, extract them from an existing `.ko` on the device — look for the 4-byte `.word` immediately before each function entry in the `.text` disassembly.

## Symbol CRCs

Must match the running kernel's exported symbols. These are for `6.1.141-android14-11-gb4b551f657d1`:

| Symbol | CRC |
|--------|-----|
| `_printk` | `0x92997ed8` |
| `memremap` | `0x4d924f20` |
| `memunmap` | `0x9e9fdd9d` |
| `__arch_copy_to_user` | `0x9a85eebb` |
| `proc_create` | `0x0524767b` |
| `remove_proc_entry` | `0xef8b7667` |
| `module_layout` | `0xea759d7f` |

For a different kernel, pull a stock `.ko` from the device and read its `__versions` section with `objdump -s -j __versions module.ko`.

## Module Struct Layout

For this kernel, `struct module` is 0x440 bytes:
- Offset `0x170`: `init` function pointer
- Offset `0x3d8`: `exit` function pointer

Verify on your device by checking any stock `.ko`:
```bash
aarch64-linux-gnu-objdump -s -j '.gnu.linkonce.this_module' /path/to/any.ko
```
Look for the two non-zero quads (the init/exit relocations).

## Target Device

- **Phone**: Moto Edge 2025 (codename oulu, XT2205)
- **SoC**: MediaTek Dimensity 7300 (MT6878)
- **Kernel**: `6.1.141-android14-11-gb4b551f657d1`
- **Root**: KernelSU Next 3.3.0
- **Module signing**: `CONFIG_MODULE_SIG_FORCE=off`, `modules_disabled=0`

## License

GPL (required by kernel module loading).
