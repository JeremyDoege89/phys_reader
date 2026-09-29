/*
 * phys_reader_v3.S — Complete kernel module in assembly for MT6878
 *
 * Maps ap_md_c_smem (0x8A000000, 26.4MB) and exposes via /proc/phys_reader.
 * Includes CFI tags + PAC instructions matching GKI kernel expectations.
 *
 * CFI tags (verified from 4 device modules):
 *   int (*)(void):      0x36b1c5a6  (init_module)
 *   void (*)(void):     0xa540670c  (cleanup_module)
 *   read handler:       0xe866e2f4  (ssize_t (*)(file*, char __user*, size_t, loff_t*))
 */

/* ====================== PLT stubs ====================== */
.section .plt,"ax",%progbits
.balign 16
	.byte 0

.section .init.plt,"ax",%progbits
	.byte 0

/* ====================== Constants (.rodata) ====================== */
.section .rodata,"a"
.balign 8
proc_name:
	.asciz "phys_reader"
	.balign 8
fmt_ok:
	.asciz "phys_reader: mapped %llx+%llx -> /proc/phys_reader\n"
	.balign 8
fmt_fail:
	.asciz "phys_reader: memremap failed for %llx+%llx\n"
	.balign 8
fmt_unload:
	.asciz "phys_reader: unloaded\n"

/* ====================== BSS ====================== */
.section .bss,"aw",@nobits
.balign 8
total_size:
	.zero 8
map_ptr:
	.zero 8

/* ====================== Data (.data) ====================== */
/*
 * proc_ops struct (0x60 bytes, all NULL except proc_read at +0x10).
 * proc_read is set by init_module at runtime.
 */
.section .data,"aw"
.balign 8
phys_pops:
	.zero 0x60

/* ====================== .text: phys_read ====================== */
.section .text,"ax"
.balign 4

/* CFI tag for read handler: ssize_t (*)(file*, char __user*, size_t, loff_t*) */
.long 0xe866e2f4

.globl phys_read
.type phys_read, %function
phys_read:
	/* x0=file, x1=ubuf, x2=count, x3=ppos */
	paciasp
	stp	x29, x30, [sp, #-48]!
	mov	x29, sp
	stp	x19, x20, [sp, #16]
	str	x21, [sp, #32]

	mov	x21, x3			/* x21 = ppos ptr */
	ldr	x20, [x21]		/* x20 = *ppos (offset) */

	/* Load total_size */
	adrp	x4, total_size
	ldr	x4, [x4, :lo12:total_size]

	/* if (off >= total_size) return 0 */
	cmp	x4, x20
	b.ls	.Lread_eof

	/* Clamp count to remaining */
	sub	x5, x4, x20		/* x5 = remaining */
	cmp	x2, x5
	csel	x2, x5, x2, hi		/* count = min(count, remaining) */

	/* Cap at PAGE_SIZE */
	mov	x19, #4096
	cmp	x2, x19
	csel	x19, x2, x19, ls	/* x19 = min(count, 4096) */

	/* Load map pointer */
	adrp	x4, map_ptr
	ldr	x4, [x4, :lo12:map_ptr]

	/* __arch_copy_to_user(ubuf, map+offset, chunk) */
	mov	x0, x1			/* dst = ubuf */
	add	x1, x4, x20		/* src = map + offset */
	mov	x2, x19			/* len = chunk */
	bl	__arch_copy_to_user

	/* Check return (0 = success) */
	cbnz	x0, .Lread_fault

	/* Success: update *ppos, return chunk */
	add	x20, x19, x20
	str	x20, [x21]
	mov	x0, x19
	b	.Lread_ret

.Lread_eof:
	mov	x0, #0
	b	.Lread_ret

.Lread_fault:
	mov	x0, #-14		/* -EFAULT */

.Lread_ret:
	ldr	x21, [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #48
	autiasp
	ret
.size phys_read, . - phys_read


/* ====================== .init.text: init_module ====================== */
.section .init.text,"ax"
.balign 4

/* CFI tag for int (*)(void) */
.long 0x36b1c5a6

.globl init_module
.type init_module, %function
init_module:
	paciasp
	stp	x29, x30, [sp, #-32]!
	mov	x29, sp
	str	x19, [sp, #16]

	/* memremap(0x8A000000, 0x1A60000, 7) */
	mov	x0, #0x8c000000
	movz	x1, #0xC000
	movk	x1, #0x12, lsl #16
	mov	x2, #7			/* WB|WT|WC */
	bl	memremap

	/* Store map pointer */
	adrp	x1, map_ptr
	str	x0, [x1, :lo12:map_ptr]

	/* if (!map) goto fail */
	cbz	x0, .Linit_fail

	/* Store total_size */
	movz	x19, #0xC000
	movk	x19, #0x12, lsl #16
	adrp	x1, total_size
	str	x19, [x1, :lo12:total_size]

	/* Set phys_pops.proc_read = phys_read */
	adrp	x1, phys_pops
	add	x1, x1, :lo12:phys_pops
	adrp	x2, phys_read
	add	x2, x2, :lo12:phys_read
	str	x2, [x1, #16]		/* proc_read at offset 0x10 */

	/* proc_create("phys_reader", 0444, NULL, &phys_pops) */
	adrp	x3, phys_pops
	add	x3, x3, :lo12:phys_pops
	adrp	x0, proc_name
	add	x0, x0, :lo12:proc_name
	mov	w1, #0x124		/* 0444 octal */
	mov	x2, #0			/* parent = NULL */
	bl	proc_create

	/* _printk("phys_reader: mapped ...") */
	adrp	x0, fmt_ok
	add	x0, x0, :lo12:fmt_ok
	mov	x1, #0x8c000000
	movz	x2, #0xC000
	movk	x2, #0x12, lsl #16
	bl	_printk

	/* return 0 */
	mov	w0, #0
	b	.Linit_ret

.Linit_fail:
	/* _printk("phys_reader: memremap failed ...") */
	adrp	x0, fmt_fail
	add	x0, x0, :lo12:fmt_fail
	mov	x1, #0x8c000000
	movz	x2, #0xC000
	movk	x2, #0x12, lsl #16
	bl	_printk
	mov	w0, #-12		/* -ENOMEM */

.Linit_ret:
	ldr	x19, [sp, #16]
	ldp	x29, x30, [sp], #32
	autiasp
	ret
.size init_module, . - init_module


/* ====================== .exit.text: cleanup_module ====================== */
.section .exit.text,"ax"
.balign 4

/* CFI tag for void (*)(void) */
.long 0xa540670c

.globl cleanup_module
.type cleanup_module, %function
cleanup_module:
	paciasp
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp

	/* remove_proc_entry("phys_reader", NULL) */
	adrp	x0, proc_name
	add	x0, x0, :lo12:proc_name
	mov	x1, #0
	bl	remove_proc_entry

	/* if (map) memunmap(map) */
	adrp	x0, map_ptr
	ldr	x0, [x0, :lo12:map_ptr]
	cbz	x0, .Lclean_skip
	bl	memunmap
.Lclean_skip:

	/* _printk("phys_reader: unloaded") */
	adrp	x0, fmt_unload
	add	x0, x0, :lo12:fmt_unload
	bl	_printk

	ldp	x29, x30, [sp], #16
	autiasp
	ret
.size cleanup_module, . - cleanup_module


/* ====================== .modinfo ====================== */
.section .modinfo,"a"
	.asciz "description=Physical memory reader via /proc"
	.asciz "license=GPL"
	.asciz "vermagic=6.1.141-android14-11-gb4b551f657d1 SMP preempt mod_unload modversions aarch64"
	.asciz "name=phys_reader"
	.asciz "depends="

/* ====================== __versions ====================== */
.section __versions,"a"
.balign 8

/* 1. _printk */
	.long 0x92997ed8
	.long 0
	.ascii "_printk"
	.zero 56 - 7

/* 2. memremap */
	.long 0x4d924f20
	.long 0
	.ascii "memremap"
	.zero 56 - 8

/* 3. memunmap */
	.long 0x9e9fdd9d
	.long 0
	.ascii "memunmap"
	.zero 56 - 8

/* 4. __arch_copy_to_user */
	.long 0x9a85eebb
	.long 0
	.ascii "__arch_copy_to_user"
	.zero 56 - 19

/* 5. proc_create */
	.long 0x0524767b
	.long 0
	.ascii "proc_create"
	.zero 56 - 11

/* 6. remove_proc_entry */
	.long 0xef8b7667
	.long 0
	.ascii "remove_proc_entry"
	.zero 56 - 17

/* 7. module_layout */
	.long 0xea759d7f
	.long 0
	.ascii "module_layout"
	.zero 56 - 13


/* ====================== .gnu.linkonce.this_module ====================== */
.section ".gnu.linkonce.this_module","aw"
.balign 64
.globl __this_module
__this_module:
	.zero 0x18
	.ascii "phys_reader"
	.zero 56 - 11
	.zero 0x170 - 0x18 - 56
	.quad init_module
	.zero 0x3d8 - 0x170 - 8
	.quad cleanup_module
	.zero 0x440 - 0x3d8 - 8
