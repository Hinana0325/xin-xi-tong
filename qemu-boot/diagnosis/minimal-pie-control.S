/* Syscall-only control group: no libc, no dynamic linker.
 * _start issues write(1, marker) then exit_group(42) via raw syscalls.
 * If this runs, kernel exec + console output work; if it fails, the
 * fault is below libc entirely. */
    .text
    .globl _start
_start:
    mov x8, #64          /* __NR_write */
    mov x0, #1           /* fd 1 */
    adr x1, msg
    mov x2, #15          /* strlen("CONTROL-MARKER\n") */
    svc #0
    mov x8, #94          /* __NR_exit_group */
    mov x0, #42
    svc #0
msg:
    .ascii "CONTROL-MARKER\n"
