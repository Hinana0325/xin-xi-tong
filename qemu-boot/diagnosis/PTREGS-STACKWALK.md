# pt_regs 用户态栈 walk：GSI init 主动 SIGABRT 调用者定位

日期：2026-10-29（Asia/Shanghai）。QEMU virt only，无真机，无推送，未修改任何原始目录。
本目录内全部为诊断脚本与副本输出；Android 未启动，init 未修复。

## 结论（已定位）

**崩溃点：GSI `/system/bin/init` 的 `main()`（文件偏移 `0x76e74`，`.gnu_debugdata` 符号 `main`）内的一条
`LOG(FATAL)`，消息为：**

```
Second-stage init requires an argument to main()
```

**调用链（栈底 → 栈顶）：**

```
_start → _start_main → __libc_init（libc）→ main（init）
  → android::base::LogMessage 构造/析构（libbase，两个未命名库帧）
  → abort → raise → rt_tgsigqueueinfo（syscall 240，SIGABRT，si_code=-1）
```

**根因**：这个 `init` 二进制是**纯 second-stage** 的 init。`main()` 按 `argv` 分发：
`basename(argv[0])=="ueventd"` → ueventd；`argv[1]` 为 `subcontext` / `selinux_setup` /
`second_stage` → 各自入口；其余一切情况（含内核直接以 `argc=1` 执行 `/init`）都落入
`LOG(FATAL)`。ramdisk 的 `/init` 是指向 `/system/bin/init` 的符号链接（与 GSI 内文件同一
SHA-256），内核以 `argc=1` 直接执行它，必然触发该 FATAL——在打印任何 init 日志之前就
`abort()`。这与此前观察到的“无任何 init 日志、立即 SIGABRT”完全一致。

**此前被排除的假说均不再是候选**：`ld.config.txt` 缺失（linker 已自行解析完整闭包）、
sepolicy CIL 形态、空 `/proc/bootconfig`、libc 启动环境（minimal-PIE 实验证明 libc 环境正常）。
崩溃发生在 `main()` 入口分发处，这些子系统根本还没走到。

**不需要“调试版 init 重建”来定位**：调用者已用栈证据精确定位，见下文。下一步应是
**第一阶段（first-stage）方案**，见文末“下一步”。

---

## 1. 实验条件与复核

- QEMU：`qemu-system-aarch64` 8.2.2，`virt` / cortex-a57，TCG，`nokaslr`，gdb stub；
  内核为 `~/workspace/kernel-android17-6.18/out/dist-qemu-virt/Image`（4K 页，
  `CONFIG_ARM64_VA_BITS=39`，三级页表）。
- ramdisk：`~/workspace/bootable-ramdisk/ramdisk.cpio.gz` 原件（只读使用，未修改）。
- 断点：`__arm64_sys_rt_tgsigqueueinfo`，地址经 `System.map`/`vmlinux` 在 `nokaslr` 下核对为
  `0xffffffc0804da3d4`，硬件断点（`hbreak`），命中 1 次即禁用并继续，复现崩溃。
- 调试器：`gdb-multiarch` 15.1。符号：`~/workspace/gdb-init/symbols/init-symbols.txt`
 （init 的 `.gnu_debugdata` 解压，3,228 个函数符号；`main` 文件偏移 `0x76e74`，
  `_start` `0x70000`，init ELF 入口点 `0x70000`，第一 LOAD 段 vaddr 0）。
- 本任务只写 `~/workspace/gdb-ptregs/`；`gdb-init/`、`bootable-ramdisk/`、`init-debug/`、
  `minimal-pie/`、内核树、GSI zip、`system-apps`、`xin-xi-tong`、`PocketVM` 均只读。

哈希复核（任务开始与结束均验证，未变）：

```
GSI zip      a359a50b6eb8e9f63168e928bd14167603225e92cd8605ec86a4bda6591fc13b
ramdisk.cpio a50640cfbb0522dd1a014cf891a7413b45858feffdc2a83745ab8e0aa21b716c
```

## 2. pt_regs 原文（断点命中时，`$x0` = pt_regs* = `0xffffffc082b0bec0`）

取自 `gdb-transcript.txt`（附录全文），按 arm64 `struct pt_regs` 布局
（`regs[31]` @ +0…+248，`sp` +248，`pc` +256，`pstate` +264，`orig_x0` +272，
`syscallno` +280）：

```
syscallno(pt_regs+280)=240
args: a0(tgid)=1 a1(tid)=1 a2(sig)=6 a3(uinfo)=7ff9bffeb0
pt_regs LR(+240)=7f8455c0f8 SP(+248)=7ff9bffeb0 ELR(+256)=7f8455c11c PSTATE(+264)=0 ORIG_X0(+272)=1
```

regs[0..30] 全量转储（`x/31gx pt_regs`，即 `regs[0]` 在 `0xffffffc082b0bec0`）：

```
0xffffffc082b0bec0:  0x0000000000000001  0x0000000000000001   <- regs[0..1]  = tgid/tid
0xffffffc082b0bed0:  0x0000000000000006  0x0000007ff9bffeb0   <- regs[2..3]  = sig/uinfo
0xffffffc082b0bee0:  0x71601f6d601f7264  0x71601f6d601f7264   <- regs[4..5]  （siginfo 数据）
0xffffffc082b0bef0:  0x71601f6d601f7264  0x7f7f7f7f7f7f7f7f   <- regs[6..7]
0xffffffc082b0bf00:  0x00000000000000f0  0x531f4c6bb0537bc2   <- regs[8..9]
0xffffffc082b0bf10:  0x000000ff00000020  0x000000003b9ac9ff   <- regs[10..11]
0xffffffc082b0bf20:  0x0000007f8bf2d000  0x000000007fffffff   <- regs[12..13]
0xffffffc082b0bf30:  0x0000000000000506  0x0000000000000000   <- regs[14..15]
0xffffffc082b0bf40:  0x0000007f845d6e98  0x0000007f845bc7c0   <- regs[16..17]
0xffffffc082b0bf50:  0x0000007f8bb88000  0x0000000000000001   <- regs[18..19]
0xffffffc082b0bf60:  0x0000000000000001  0x00000000ffffffff   <- regs[20..21]
0xffffffc082b0bf70:  0xb400007e54413370  0x0000007f8be47e80   <- regs[22..23]
0xffffffc082b0bf80:  0x0000000000000000  0x0000000000000000   <- regs[24..25]
0xffffffc082b0bf90:  0x0000000000000000  0x0000000000000000   <- regs[26..27]
0xffffffc082b0bfa0:  0x0000000000000000  0x0000007ff9bfff30   <- regs[28], regs[29]=x29/FP
0xffffffc082b0bfb0:  0x0000007f8455c0f8                          <- regs[30]=LR
```

合理性核对（命中后先核对，通过才继续解栈）：

- ELR `0x7f8455c11c`：落在 libc 映射内（与 LR `0x7f8455c0f8` 同一库，相邻地址，符合
  raise → syscall wrapper 的返回关系）；此前 gdb 会话已在 vmlinux 反汇编中确认该地址
  处于 `__arm64_sys_rt_tgsigqueueinfo` 返回路径上的 libc `raise/tgkill` 代码。
- SP `0x7ff9bffeb0`：典型用户态栈顶附近地址，与 `uinfo` 参数值相同（siginfo 结构体
  就放在栈顶，符合 bionic `raise()` 的传参方式）。
- syscall 号 240 = `rt_tgsigqueueinfo`，sig=6，`si_code=-1`（SI_QUEUE），tgid=tid=1：
  与上一轮 gdb 会话的结论一致——init 自己主动 raise。

已知限制（本轮不再重复尝试）：QEMU gdb stub 在停于 EL1 时**无法直接读 EL0 用户态内存**
（`x/` 读用户态地址报 `Cannot access memory`；stub 上报的 TTBR0_EL1 `0x42500000`
经核查不是 PID 1 的页表，不可信）。用户态栈的读取改走下节的页表路径。

## 3. 用户态栈转储方法（mm->pgd + monitor `xp`）

- DWARF 偏移（`vmlinux`）：`task_struct.mm` = 1688，`mm_struct.pgd` = 104，
  `task_struct.comm` = 2328。命中时 `SP_EL0` = `0xffffff8003142500`；
  由此定位的 task 的 `comm` = `'init'`（路径正确性校验通过），
  `task->mm` = `0xffffff8006ac5280`，`mm->pgd`（VA）= `0xffffff8006bcc000`。
- Walk：L1 表项经 gdb 在 pgd VA 处读；L2/L3 表项经 QEMU monitor `xp` 按物理地址读，
  绕过 stub 的地址翻译问题。3 级页表（4K 页，VA_BITS=39：L1 bits[38:30]，
  L2 [29:21]，L3 [20:12]）。
- 结果：栈转储 2 页、1,024 个 word，见 `stackwalk-out/stackdump.txt`；
  第 2 页后未映射（已到栈顶）。
  - 页 0：VA `0x7ff9bff000` → PA `0xbca81000`
  - 页 1：VA `0x7ff9c00000` → PA `0xbca80000`
- 注：ELR−4 处的 SVC 指令字节检查因脚本偏移 bug 未实际取到（输出为空），**未声称**；
  该检查对结论非必需（ELR 的库归属已由 LR/相邻地址关系确立）。

## 4. 栈上 auxv 与 init 加载基址推算

在栈转储中找到 auxv，关键项：

```
AT_ENTRY      = 0x5568628000
AT_PHDR       = 0x55685b8040
AT_BASE       = 0x7f8bf33000   （linker64 基址）
AT_PAGESZ     = 0x1000
AT_PHNUM      = 12
AT_SYSINFO_EHDR = 0x7f8bf31000
```

init 加载基址（PIE，ASLR 随机化后）：

```
base = AT_ENTRY − entry偏移(0x70000) = 0x5568628000 − 0x70000 = 0x55685b8000
     = AT_PHDR − 0x40             = 0x55685b8040 − 0x40    = 0x55685b8000   ✓ 一致
```

符号解析：运行时地址 − `0x55685b8000` = 文件偏移，再对照 `.gnu_debugdata` 符号表
（`symbols/init-symbols.txt`）。栈上高于当前 SP 的 word 含初始栈的陈旧内容，不一定
是 live 调用链——live 帧以 SP 附近及 FP 链为准。

## 5. 帧指针（x29）walk 与调用链

x29 = `0x7ff9bfff30`（pt_regs regs[29]）。按 AAPCS64 `[FP]`=上一 FP、`[FP+8]`=保存的 LR
逐帧跟随，链完整闭合（末帧 prev FP = 0、LR = 0）：

| 深度 | FP | prev FP | 保存的 LR | 解析 |
|---|---|---|---|---|
| 0 | `0x7ff9bfff30` | `0x7ff9bfff60` | `0x7f8ac2ac9c` | 库帧（libbase LogMessage/abort 路径，.so 未命名，见注） |
| 1 | `0x7ff9bfff60` | `0x7ff9bfffc0` | `0x7f8a9dbb7c` | 库帧（同上） |
| 2 | `0x7ff9bfffc0` | `0x7ff9c00070` | `0x556862f0cc` | **init `main`+600**（文件偏移 `0x770cc`） |
| 3 | `0x7ff9c00070` | `0x7ff9c000a0` | `0x7f84553674` | libc（`__libc_init` 调用 `main` 的返回点） |
| 4 | `0x7ff9c000a0` | `0x7ff9c00110` | `0x5568628068` | init `_start_main`+83（文件偏移 `0x70068`） |
| 5 | `0x7ff9c00110` | `0x0` | `0x0` | 链尾（`_start` 帧） |

深度 0/1 的两个库帧未解析到命名的 `.so`（本次未捕获各库的加载基址，且无需为结论
命名它们）：深度 0 帧内含有 panic/日志字符串指针（下节），与 libbase `LogMessage`
析构 → `abort` 的路径一致；命名这两个中间帧不影响调用者定位，因为深度 2 的
`main`+600 返回地址已由反汇编逐指令锚定（第 6 节）。

SP 起的 live 帧区原文（`stackdump.txt` 摘录，SP=`0x7ff9bffeb0`，siginfo 位于栈顶）：

```
0x7ff9bffeb0: 0x0000000000000000   0x00000000ffffffff   <- siginfo（si_signo/si_errno/si_code=-1）
0x7ff9bffec0: 0x0000000000000001   0x0000000000000000
0x7ff9bffed0: 0x0000000000000000   0x0000000000000000
0x7ff9bffee0: 0x0000000000000000   0x0000000000000000
0x7ff9bffef0: 0x0000000000000000   0x0000000000000000
0x7ff9bfff00: 0x0000000000000000   0x0000000000000000
0x7ff9bfff10: 0x0000000000000000   0x0000000000000000
0x7ff9bfff20: 0x0000000000000000   0x0000000000000000
0x7ff9bfff30: 0x0000007ff9bfff60   0x0000007f8ac2ac9c   <- FP 链：深度 0 帧
0x7ff9bfff40: 0x0000007ff9bfff70   0x0000000000000020
0x7ff9bfff50: 0x00000055685d93ad   0x0000007ff9c00030   <- 0x213ad 字符串指针（见第 7 节）
0x7ff9bfff60: 0x0000007ff9bfffc0   0x0000007f8a9dbb7c   <- FP 链：深度 1 帧
0x7ff9bfff70: 0x0000000000000039   0x0000000000000030
0x7ff9bfff80: 0xb400007ec440f9c0   0x0000000000000030
0x7ff9bfff90: 0x000000077fffffff   0xb400007d7440d371
0x7ff9bfffa0: 0x00000055685d93be   0x0000000000000055   <- 0x213be 字符串指针（同上）
0x7ff9bfffb0: 0xb400007ec440f9c0   0x531f4c6bb0537bc2
0x7ff9bfffc0: 0x0000007ff9c00070   0x000000556862f0cc   <- FP 链：深度 2 帧，LR = main+600
0x7ff9bfffd0: 0x0000007ff9c00130   0x0000007ff9c00130
0x7ff9bfffe0: 0x0000007f8be47e80   0x0000000000000001
0x7ff9bffff0: 0x0000000000000002   0x0000007f8c124350
0x7ff9c00000: 0x0000007ff9c00000   0x0000007ff9c00000
0x7ff9c00010: 0x0000007ff9c00040   0x0000007f8455cba8
0x7ff9c00020: 0x0000000000000008   0x0000005568830000
```

## 6. 决定性证据：`main()` 尾部的反汇编

离线反汇编（gdb-multiarch，`~/workspace/init-debug/extract/system/bin/init`，只读）：

```
0x770a8: bl  LogMessage::LogMessage@plt        ; 构造 LOG(FATAL) 消息对象
0x770ac: add  x0, sp, #0x30
0x770b0: bl  LogMessage::stream@plt             ; 取消息流
0x770b4: adrp x1, 0x28000
0x770b8: add  x1, x1, #0xffd                    ; x1 = 0x28ffd，消息文本地址
0x770bc: mov  w2, #0x30                         ; 长度 48
0x770c0: bl  0x770dc                            ; 本地辅助函数（写入 string_view）
0x770c4: add  x0, sp, #0x30
0x770c8: bl  LogMessage::~LogMessage@plt        ; 析构 -> FATAL -> abort
0x770cc: mov  w0, wzr                            ; <-- FP 链深度 2 的 LR（main+600）恰落于此
```

文件偏移 `0x28ffd` 处的 48 字节原文：

```
Second-stage init requires an argument to main()
```

`main()` 的分发逻辑（`0x76e74` 起，`argc`=`w20`，`argv`=`x19`）：

```
setpriority(0, 0, -20)
if (strcmp(__gnu_basename(argv[0]), "ueventd") == 0)  -> 尾调用 0x117a34（ueventd 入口）
if (argc < 2)                                          -> 落入 FATAL 块（0x76f0c）
if (strcmp(argv[1], "subcontext")    == 0)             -> 0x76f50（InitLogging + subcontext）
if (strcmp(argv[1], "selinux_setup") == 0)             -> 0x76fb8（尾调用）
if (strcmp(argv[1], "second_stage")  == 0)             -> 0x76fe0，尾调用 0xc99a4（SecondStageMain）
else                                                   -> FATAL 块（0x76f0c）
FATAL 块：LogMessage 构造（file 实参见第 7 节）-> stream << 上述 48 字节消息
           -> LogMessage 析构 -> abort() -> raise(SIGABRT) -> syscall 240
```

比较字符串的文件偏移（实测）：`ueventd` @ `0x28154`；`subcontext` @ `0x1fb46`；
`selinux_setup` @ `0x1d549`；`second_stage` @ `0x1347a`。本二进制中**没有 first-stage
分支**：它只认上述四种调用方式。

## 7. 栈上 `0x55685d93ad` / `0x55685d93be` 两个指针的澄清（不是调用者）

这两个值曾被误认为可能的返回地址。核查后确定：

- 换算：`0x55685d93ad − 0x55685b8000 = 0x213ad`，`0x55685d93be − base = 0x213be`。
  文件偏移 `0x21390` 附近的反汇编解出的是 ASCII 数据（字符串片段），不是指令；
  `0x213ad` 位于 `.rodata` 字符串区内，**是数据指针，不是代码地址，不得报为调用者**。
- `0x213ad` 处字符串内容（含相邻字节）：
  `"\x19aborting due to panic at \xc0\x02:\n\xc0\x01\n"` 后紧跟
  `"system/core/init/main.cpp"`。该指针是 FATAL 块中 `LogMessage` 构造函数的
  `file` 实参——反汇编 `0x7708c`：`adrp x1, 0x21000` / `add x1, x1, #0x3ad`
  （x1 = `0x213ad`，长度实参 `0x55` = 85）。它出现在 aborting 帧的栈上正是因为
  `LogMessage` 对象持有它。`0x213be` 是同一字符串区内 +17 字节处的另一指针
  （同一日志/格式化调用的另一实参）。
- 因此：这两个指针佐证了“正在执行一条带源码位置的 FATAL 日志”，但调用链的
  锚点是第 5–6 节的 FP 链 + `main`+600 + 消息文本。

## 8. ramdisk 的 `/init` 与 GSI init 为同一文件

cpio 解析（只读，`ramdisk.cpio.gz`）：

```
init               symlink 16  -> /system/bin/init
system/bin/init    file 2653128  sha256 = bb702f17e6660ef8f2a1fd9158c2de876fa0c8f9679a7a49f4a2d02e1119451f
```

与 `~/workspace/init-debug/extract/system/bin/init` 的 SHA-256 完全相同。
内核执行 ramdisk 根目录的 `/init`（argv[0]=`/init`，basename `init` ≠ `ueventd`，
argc=1），直接命中第 6 节的 FATAL 分支。**这是本次启动路径的必然结果，不是偶发。**

## 9. serial.log 佐证

`serial.log`（306 行，本目录内；QEMU 串口输出）：

```
libc: Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 1 (init), pid 1 (<unknown>)
[    3.254622][    T1] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00
```

init 死后内核 panic，QEMU 退出——与 gdb 会话末尾 `[Inferior 1 (process 1) exited normally]`
一致。Android 从未启动，无 adb。

## 10. 下一步（供父 agent 决策，非本任务执行范围）

定位已完成，**不要再走“调试版 init 重建”来定位**。真正的缺口是 first-stage：

1. **ramdisk 需要一个 first-stage init**：挂载 system 镜像（virtio-blk 上的
   `system.img`）到 `/system`，做 first-stage 准备（`/dev`、`/proc`、`/sys`、
   sepolicy 载入、property 区域等），然后以 `argv = {"init", "second_stage", …}`
   执行 `/system/bin/init`。直接以 `argc=1` 执行它必然再次 FATAL。
2. 可选路径（需另立任务验证）：(a) 从 AOSP 构建真正的 `init_first_stage`；
   (b) 在 ramdisk 中写一个最小 first-stage shim（静态 shell 或 C 程序），挂载后
   exec second-stage——但 second-stage 对 first-stage 已完成工作的期望
   （fstab、sepolicy、ueventd、property 服务区）可能使最小 shim 在 FATAL 之后
   遇到下一处失败，需逐个迭代；(c) 核查 GSI 内是否另有 first-stage 资源
   （本次核查：`system.img` 内除 `/system/bin/init` 外无其他 init 二进制；
   `first_stage_ramdisk/` 仅含 fstab 文件）。
3. 在 first-stage 方案落地前，**不要声称 Android 已启动或 init 已修复**；
   本目录的 ramdisk/gdb 副本不是启动镜像。

## 附录 A：gdb transcript 全文（`gdb-transcript.txt`）

```
=== connecting to QEMU gdb stub ===
warning: No executable has been specified and target does not support
determining executable automatically.  Try using the "file" command.
0x0000000040000000 in ?? ()
=== hbreak at __arm64_sys_rt_tgsigqueueinfo (System.map 0xffffffc0804da3d4, nokaslr) ===
Hardware assisted breakpoint 1 at 0xffffffc0804da3d4
Num     Type           Disp Enb Address            What
1       hw breakpoint  keep y   0xffffffc0804da3d4
        silent
        set $hitcount = $hitcount + 1
        printf "=== HIT %d pc=%lx x0(pt_regs)=%lx ===\n", $hitcount, $pc, $x0
        set $pregs = $x0
        printf "syscallno(pt_regs+280)=%d\n", *(int*)($pregs + 280)
        printf "args: a0(tgid)=%ld a1(tid)=%ld a2(sig)=%ld a3(uinfo)=%lx\n", *(long*)($pregs), *(long*)($pregs + 8), *(long*)($pregs + 16), *(long*)($pregs + 24)
        printf "pt_regs LR(+240)=%lx SP(+248)=%lx ELR(+256)=%lx PSTATE(+264)=%lx ORIG_X0(+272)=%lx\n", *(long*)($pregs + 240), *(long*)($pregs + 248), *(long*)($pregs + 256), *(long*)($pregs + 264), *(long*)($pregs + 272)
        echo --- regs[0..30] (x/31gx pt_regs) ---\n
        x/31gx $pregs
        if $hitcount == 1
          python exec(open("/home/hatch/workspace/gdb-ptregs/stackwalk2.py").read())
        end
        echo --- disabling breakpoint 1, continuing guest ---\n
        disable 1
        continue
=== continuing guest to panic ===
[Switching to Thread 1.2]
=== HIT 1 pc=ffffffc0804da3d4 x0(pt_regs)=ffffffc082b0bec0 ===
syscallno(pt_regs+280)=240
args: a0(tgid)=1 a1(tid)=1 a2(sig)=6 a3(uinfo)=7ff9bffeb0
pt_regs LR(+240)=7f8455c0f8 SP(+248)=7ff9bffeb0 ELR(+256)=7f8455c11c PSTATE(+264)=0 ORIG_X0(+272)=1
--- regs[0..30] (x/31gx pt_regs) ---
0xffffffc082b0bec0:  0x0000000000000001  0x0000000000000001
0xffffffc082b0bed0:  0x0000000000000006  0x0000007ff9bffeb0
0xffffffc082b0bee0:  0x71601f6d601f7264  0x71601f6d601f7264
0xffffffc082b0bef0:  0x71601f6d601f7264  0x7f7f7f7f7f7f7f7f
0xffffffc082b0bf00:  0x00000000000000f0  0x531f4c6bb0537bc2
0xffffffc082b0bf10:  0x000000ff00000020  0x000000003b9ac9ff
0xffffffc082b0bf20:  0x0000007f8bf2d000  0x000000007fffffff
0xffffffc082b0bf30:  0x0000000000000506  0x0000000000000000
0xffffffc082b0bf40:  0x0000007f845d6e98  0x0000007f845bc7c0
0xffffffc082b0bf50:  0x0000007f8bb88000  0x0000000000000001
0xffffffc082b0bf60:  0x0000000000000001  0x00000000ffffffff
0xffffffc082b0bf70:  0xb400007e54413370  0x0000007f8be47e80
0xffffffc082b0bf80:  0x0000000000000000  0x0000000000000000
0xffffffc082b0bf90:  0x0000000000000000  0x0000000000000000
0xffffffc082b0bfa0:  0x0000000000000000  0x0000007ff9bfff30
0xffffffc082b0bfb0:  0x0000007f8455c0f8
STACKWALK2-DONE sp=0x7ff9bffeb0 elr=0x7f8455c11c pages=2 pgd=0xffffff8006bcc000
--- disabling breakpoint 1, continuing guest ---
[Inferior 1 (process 1) exited normally]

=== END OF SCRIPT (gdb continue returned) ===
```

## 附录 B：本目录文件清单

```
PTREGS-STACKWALK.md            本报告
gdb-transcript.txt             断点命中时的 gdb 全量输出（含 pt_regs，附录 A 已全文引用）
serial.log                     QEMU 串口输出 306 行（含 Fatal signal 6 / Attempted to kill init）
gdb-script.txt / run-gdb-session.sh / gdb-stdout.log / qemu-gdb.log
                               会话脚本与日志
stackwalk.py / stackwalk2.py   页表 walk 脚本（第 2、3、4 轮调试的演进记录）
stackwalk-out/
  stackdump.txt                用户态栈 2 页、1,024 word 原始转储
  stackwalk-summary.txt        walk 摘要（pgd、页映射）
  info-registers.txt / monitor-registers.txt
                               寄存器与 monitor 输出
analyze-stack.py               栈/auxv 离线分析脚本
session1/ … session4/         前 4 轮失败尝试的记录（stub 读 EL0 内存失败、
                               TTBR0 不可信、SP_EL0 解析问题；均已记录在案，
                               不再重复尝试）
work/                          过程文件
```

## 附录 C：方法陷阱（已验证，后续勿踩）

- QEMU gdb stub 停于 EL1 时读不到 EL0 用户态内存；用户态读取必须走
  `task->mm->pgd` + monitor `xp` 物理读。
- stub 上报的 `TTBR0_EL1`（`0x42500000`）不是 PID 1 的页表，走它页表 walk
  会在 L1 读到全零描述符。
- `SP_EL0` 不能用 `parse_and_eval("$sp_el0")`（转 long 失败），须从
  `info registers` 文本解析。
- gdb.Value 的 `$x0` 为有符号值，作地址运算前须 `& 0xFFFFFFFFFFFFFFFF` 掩码，
  否则 Python 报 `OverflowError`。
- `LD_DEBUG=1` 是无效值（linker 打印用法后 exit 1）；早期 diag1/diag2 因此无效。
- 栈上指向 `.rodata` 的指针（如 `0x213ad`）不是返回地址；报告调用者前必须
  区分代码地址与数据指针。
