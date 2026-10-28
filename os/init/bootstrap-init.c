/*
 * 定制系统 bring-up init (arm64, freestanding, no libc)
 * Direct Linux syscalls: print banner, mount /proc /sys, tiny shell.
 */
typedef unsigned long u64;
typedef long s64;

static inline s64 sys6(long n, long a, long b, long c, long d, long e, long f)
{
    register long x8 asm("x8") = n;
    register long x0 asm("x0") = a;
    register long x1 asm("x1") = b;
    register long x2 asm("x2") = c;
    register long x3 asm("x3") = d;
    register long x4 asm("x4") = e;
    register long x5 asm("x5") = f;
    asm volatile("svc #0"
                 : "+r"(x0)
                 : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
                 : "memory");
    return x0;
}

#define SYS_read 63
#define SYS_write 64
#define SYS_openat 56
#define SYS_close 57
#define SYS_mount 40
#define SYS_reboot 142
#define SYS_uname 160
#define SYS_exit 93

static long sys_read(int fd, void *buf, u64 len) { return sys6(SYS_read, fd, (long)buf, len, 0, 0, 0); }
static long sys_write(int fd, const void *buf, u64 len) { return sys6(SYS_write, fd, (long)buf, len, 0, 0, 0); }
static long sys_mount(const char *src, const char *tgt, const char *type, u64 flags, const char *data)
{
    return sys6(SYS_mount, (long)src, (long)tgt, (long)type, flags, (long)data, 0);
}
static long sys_reboot(int cmd)
{
    return sys6(SYS_reboot, 0xfee1dead, 672274793, cmd, 0, 0, 0);
}
#define RB_RESTART 0x01234567
#define RB_POWER_OFF 0x4321fedc

static u64 slen(const char *s) { u64 n = 0; while (s[n]) n++; return n; }
static void puts(const char *s) { sys_write(1, s, slen(s)); }
static void putc(char c) { sys_write(1, &c, 1); }
static void puthex(u64 v)
{
    char b[19]; int i; b[0] = '0'; b[1] = 'x';
    for (i = 0; i < 16; i++) {
        int d = (v >> (60 - i * 4)) & 0xf;
        b[2 + i] = d < 10 ? '0' + d : 'a' + d - 10;
    }
    b[18] = '\n';
    sys_write(1, b, 19);
}
static void putdec(u64 v)
{
    char b[21]; int i = 20; b[20] = '\n';
    if (!v) { b[19] = '0'; sys_write(1, b + 19, 2); return; }
    while (v) { b[--i] = '0' + (v % 10); v /= 10; }
    sys_write(1, b + i, 21 - i);
}
static int scmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}
static int sncmp(const char *a, const char *b, u64 n)
{
    while (n && *a && *a == *b) { a++; b++; n--; }
    if (!n) return 0;
    return (unsigned char)*a - (unsigned char)*b;
}

static char line[256];
static int readline(void)
{
    int n = 0;
    for (;;) {
        char c;
        long r = sys_read(0, &c, 1);
        if (r <= 0) continue;
        if (c == '\r') continue;
        if (c == '\n') { putc('\n'); line[n] = 0; return n; }
        if ((c == 0x7f || c == 8) && n > 0) { n--; puts("\b \b"); continue; }
        if (n < 255) { line[n++] = c; putc(c); }
    }
}

struct utsname_buf { char sys[65], node[65], rel[65], ver[65], mach[65], dom[65]; };

void _start(void)
{
    puts("\n");
    puts("=====================================\n");
    puts("  arm64 bring-up  -  custom kernel\n");
    puts("  kernel: 7.3.0 (custom build)\n");
    puts("=====================================\n");

    long r = sys_mount("devtmpfs", "/dev", "devtmpfs", 0, "");
    puts("[init] mount /dev  -> "); putdec((u64)(r < 0 ? -r : 0));
    r = sys_mount("proc", "/proc", "proc", 0, "");
    puts("[init] mount /proc -> "); putdec((u64)(r < 0 ? -r : 0));
    r = sys_mount("sysfs", "/sys", "sysfs", 0, "");
    puts("[init] mount /sys  -> "); putdec((u64)(r < 0 ? -r : 0));

    for (;;) {
        puts("os> ");
        readline();
        if (!line[0]) continue;
        if (!scmp(line, "help")) {
            puts("commands: help, uname, echo <text>, reboot, poweroff, clear\n");
        } else if (!scmp(line, "uname")) {
            struct utsname_buf u;
            if (sys6(SYS_uname, (long)&u, 0, 0, 0, 0, 0) == 0) {
                puts(u.sys); putc(' '); puts(u.rel); putc(' '); puts(u.mach); putc('\n');
            } else {
                puts("uname failed\n");
            }
        } else if (!sncmp(line, "echo ", 5)) {
            puts(line + 5); putc('\n');
        } else if (!scmp(line, "reboot")) {
            puts("rebooting...\n");
            sys_reboot(RB_RESTART);
            while (1) {}
        } else if (!scmp(line, "poweroff")) {
            puts("powering off...\n");
            sys_reboot(RB_POWER_OFF);
            while (1) {}
        } else if (!scmp(line, "clear")) {
            puts("\x1b[2J\x1b[H");
        } else {
            puts("unknown: "); puts(line); puts(" (type help)\n");
        }
    }
}
