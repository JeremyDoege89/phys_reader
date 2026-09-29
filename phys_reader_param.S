/*
 * phys_reader_param.S — Parameterized physical memory reader for MT6878 / GKI 6.1.141
 *
 * Same GKI constraints as phys_reader_v3.S (CFI tags, PAC, section layout),
 * but the mapped window is configurable at runtime via a proc write:
 *
 *   echo "0x40000000 0x10000000" > /proc/phys_reader_param   # remap window
 *   dd if=/proc/phys_reader_param of=/sdcard/ram.bin bs=1M
 *
 * Default window: 0x40000000 + 0x10000000 (256MB at the usual DRAM base —
 * verify against /proc/iomem on your device).
 *
 * The write handler parses the user string with LDTR (unprivileged loads),
 * so no extra kernel imports are needed beyond what v3 already uses.
 * Read chunk size raised from 4K to 1MB for sane dump speeds.
 *
 * CFI tags (from phys_reader README, kernel 6.1.141-android14-11):
 *   int (*)(void):                                             0x36b1c5a6
 *   void (*)(void):                                            0xa540670c
 *   ssize_t (*)(file*, char __user*, size_t, loff_t*):         0xe866e2f4
 *   ssize_t (*)(file*, const char __user*, size_t, loff_t*):   0x9a660ea0
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
	.asciz "phys_reader_param"
	.balign 8
fmt_ok:
	.asciz "phys_reader_param: mapped %llx+%llx -> /proc/phys_reader_param\n"
	.balign 8
fmt_remap:
	.asciz "phys_reader_param: remapped %llx+%llx\n"
	.balign 8
fmt_fail:
	.asciz "phys_reader_param: memremap failed for %llx+%llx\n"
	.balign 8
fmt_unload:
	.asciz "phys_reader_param: unloaded\n"
	.balign 8
fmt_bad:
	.asciz "phys_reader_param: bad input (want \"<hex_addr> <hex_size>\")\n"

/* ====================== BSS ====================== */
.section .bss,"aw",@nobits
.balign 8
phys_addr:
	.zero 8
phys_size:
	.zero 8
total_size:
	.zero 8
map_ptr:
	.zero 8

/* ====================== Data (.data) ====================== */
/*
 * proc_ops struct (0x60 bytes): proc_read at +0x10, proc_write at +0x20.
 * Both are set by init_module at runtime.
 */
.section .data,"aw"
.balign 8
phys_pops:
	.zero 0x60

/* ====================== .text ====================== */
.section .text,"ax"
.balign 4

/*
 * Parse one hex number from user memory.
 *   in:  x19 = cursor (user ptr), x20 = end
 *   out: x21 = value, x19 = new cursor, w22 = digits parsed (0 = none)
 *   clobbers: w3, w4
 * Local function, called via direct bl — no CFI tag needed.
 */
.Lparse_hex:
	mov	x21, #0
	mov	w22, #0
.Lph_ws:
	cmp	x19, x20
	b.hs	.Lph_done
	ldtrb	w3, [x19]
	cmp	w3, #0x20
	b.eq	.Lph_ws_next
	cmp	w3, #0x9
	b.eq	.Lph_ws_next
	cmp	w3, #0xa
	b.eq	.Lph_ws_next
	cmp	w3, #0xd
	b.eq	.Lph_ws_next
	b	.Lph_0x
.Lph_ws_next:
	add	x19, x19, #1
	b	.Lph_ws
.Lph_0x:
	cmp	w3, #0x30			/* '0' */
	b.ne	.Lph_digits
	add	x4, x19, #1
	cmp	x4, x20
	b.hs	.Lph_digits
	ldtrb	w4, [x4]
	cmp	w4, #0x78			/* 'x' */
	b.eq	.Lph_skip0x
	cmp	w4, #0x58			/* 'X' */
	b.eq	.Lph_skip0x
	b	.Lph_digits
.Lph_skip0x:
	add	x19, x19, #2
.Lph_digits:
	cmp	x19, x20
	b.hs	.Lph_done
	ldtrb	w3, [x19]
	sub	w4, w3, #0x30
	cmp	w4, #9
	b.ls	.Lph_acc			/* '0'-'9' */
	orr	w4, w3, #0x20		/* tolower */
	sub	w4, w4, #0x61		/* 'a' */
	cmp	w4, #5
	b.hi	.Lph_done		/* not a hex digit */
	add	w4, w4, #10
.Lph_acc:
	lsl	x21, x21, #4
	add	x21, x21, x4
	add	w22, w22, #1
	add	x19, x19, #1
	b	.Lph_digits
.Lph_done:
	ret

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

	/* Cap at 1MB per read */
	movz	x19, #0x10, lsl #16
	cmp	x2, x19
	csel	x19, x2, x19, ls	/* x19 = min(count, 1MB) */

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
	mov	x0, #-14			/* -EFAULT */

.Lread_ret:
	ldr	x21, [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #48
	autiasp
	ret
.size phys_read, .-phys_read


/* CFI tag for write handler: ssize_t (*)(file*, const char __user*, size_t, loff_t*) */
.long 0x9a660ea0

.globl phys_write
.type phys_write, %function
phys_write:
	/* x0=file, x1=ubuf, x2=count, x3=ppos */
	paciasp
	stp	x29, x30, [sp, #-80]!
	mov	x29, sp
	stp	x19, x20, [sp, #16]
	stp	x21, x22, [sp, #32]
	stp	x23, x24, [sp, #48]
	stp	x25, x26, [sp, #64]

	mov	x25, x2			/* x25 = original count */
	mov	x26, #63
	cmp	x2, x26
	csel	x2, x2, x26, ls		/* x2 = min(count, 63) */
	mov	x19, x1			/* x19 = cursor */
	add	x20, x1, x2		/* x20 = end */

	bl	.Lparse_hex
	mov	x23, x21			/* x23 = phys addr */
	cbz	w22, .Lw_bad

	bl	.Lparse_hex
	mov	x24, x21			/* x24 = size */
	cbz	w22, .Lw_bad

	/* validate: nonzero addr/size, size <= 1GB */
	cbz	x23, .Lw_bad
	cbz	x24, .Lw_bad
	movz	x4, #0x4000, lsl #16	/* 0x40000000 */
	cmp	x24, x4
	b.hi	.Lw_bad

	/* unmap old window */
	adrp	x0, map_ptr
	ldr	x0, [x0, :lo12:map_ptr]
	cbz	x0, .Lw_nomap
	bl	memunmap
.Lw_nomap:
	/* memremap(addr, size, MEMREMAP_WB) */
	mov	x0, x23
	mov	x1, x24
	mov	x2, #1
	bl	memremap
	cbz	x0, .Lw_fail

	adrp	x1, map_ptr
	str	x0, [x1, :lo12:map_ptr]
	adrp	x1, phys_addr
	str	x23, [x1, :lo12:phys_addr]
	adrp	x1, phys_size
	str	x24, [x1, :lo12:phys_size]
	adrp	x1, total_size
	str	x24, [x1, :lo12:total_size]

	adrp	x0, fmt_remap
	add	x0, x0, :lo12:fmt_remap
	mov	x1, x23
	mov	x2, x24
	bl	_printk

	mov	x0, x25			/* return original count */
	b	.Lw_ret

.Lw_fail:
	adrp	x1, map_ptr
	str	xzr, [x1, :lo12:map_ptr]
	adrp	x1, total_size
	str	xzr, [x1, :lo12:total_size]
	adrp	x1, phys_size
	str	xzr, [x1, :lo12:phys_size]
	adrp	x0, fmt_fail
	add	x0, x0, :lo12:fmt_fail
	mov	x1, x23
	mov	x2, x24
	bl	_printk
	mov	x0, #-12			/* -ENOMEM */
	b	.Lw_ret

.Lw_bad:
	adrp	x0, fmt_bad
	add	x0, x0, :lo12:fmt_bad
	bl	_printk
	mov	x0, #-22			/* -EINVAL */
.Lw_ret:
	ldp	x25, x26, [sp, #64]
	ldp	x23, x24, [sp, #48]
	ldp	x21, x22, [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #80
	autiasp
	ret
.size phys_write, .-phys_write


/* ====================== .init.text: init_module ====================== */
.section .init.text,"ax"
.balign 4

/* CFI tag for int (*)(void) */
.long 0x36b1c5a6

.globl init_module
.type init_module, %function
init_module:
	paciasp
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp

	/* No default mapping — user writes the desired range via proc.
	 * total_size/map_ptr stay 0 (BSS), so reads return EOF until set. */

	/* phys_pops.proc_read = phys_read; proc_write = phys_write */
	adrp	x1, phys_pops
	add	x1, x1, :lo12:phys_pops
	adrp	x2, phys_read
	add	x2, x2, :lo12:phys_read
	str	x2, [x1, #16]
	adrp	x2, phys_write
	add	x2, x2, :lo12:phys_write
	str	x2, [x1, #32]		/* proc_write at offset 0x20 */

	/* proc_create("phys_reader_param", 0644, NULL, &phys_pops) */
	adrp	x3, phys_pops
	add	x3, x3, :lo12:phys_pops
	adrp	x0, proc_name
	add	x0, x0, :lo12:proc_name
	mov	w1, #0x1a4		/* 0644 octal */
	mov	x2, #0			/* parent = NULL */
	bl	proc_create

	/* _printk — announce ready, no mapping yet */
	adrp	x0, fmt_ok
	add	x0, x0, :lo12:fmt_ok
	mov	x1, #0
	mov	x2, #0
	bl	_printk

	/* return 0 */
	mov	w0, #0
	ldp	x29, x30, [sp], #16
	autiasp
	ret
.size init_module, .-init_module


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

	/* remove_proc_entry("phys_reader_param", NULL) */
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

	/* _printk("phys_reader_param: unloaded") */
	adrp	x0, fmt_unload
	add	x0, x0, :lo12:fmt_unload
	bl	_printk

	ldp	x29, x30, [sp], #16
	autiasp
	ret
.size cleanup_module, .-cleanup_module


/* ====================== .modinfo ====================== */
.section .modinfo,"a"
	.asciz "description=Parameterized physical memory reader via /proc"
	.asciz "license=GPL"
	.asciz "vermagic=6.1.141-android14-11-gb4b551f657d1 SMP preempt mod_unload modversions aarch64"
	.asciz "name=phys_reader_param"
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
	.ascii "phys_reader_param"
	.zero 56 - 17
	.zero 0x170 - 0x18 - 56
	.quad init_module
	.zero 0x3d8 - 0x170 - 8
	.quad cleanup_module
	.zero 0x440 - 0x3d8 - 8
