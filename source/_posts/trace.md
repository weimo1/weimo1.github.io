---
title: trace
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "基础知识", "调试与工具"]
publish: true
---

# trace

<https://zhuanlan.zhihu.com/p/2002142593505566878>

# **核心定位与层级**

|  |  |  |  |
| --- | --- | --- | --- |
| **工具** | **作用层级** | **核心目标** | **权限要求** |
| `strace` | 用户空间 | 追踪进程的**系统调用** | 普通用户/调试权限 |
| `ptrace` | 用户-内核桥梁 | 提供**进程调试**的底层接口 | 需调试权限 |
| `ftrace` | 内核空间 | 追踪**内核函数**执行路径 | Root 权限 |

## Ftrace（Function Tracer）

**定位**：Linux 内核内置的**轻量级调试工具**  
**核心功能**：

* **函数调用追踪**：记录内核函数执行路径
* **事件追踪**：捕获调度/中断/系统调用等事件
* **性能分析**：测量函数执行时间
* **动态探测**：通过 kprobe 追踪任意内核地址

**关键特性**：

* **零开销闲置**：未启用时几乎无性能损耗
* **生产环境友好**：设计目标之一是可在线使用
* **无需编译**：通过 debugfs 实时配置（`/sys/kernel/debug/tracing`）

**核心接口**：

```
# 启用函数追踪
echo function > current_tracer

# 追踪特定函数
echo __x64_sys_write > set_ftrace_filter

# 启用函数图追踪器
echo function_graph > current_tracer
```

**适用场景**：

* 内核死锁/卡顿诊断
* 系统调用链路分析
* 中断延迟测量
* 调度器行为观察

---

#### **2. trace-cmd**

**定位**：Ftrace 的**命令行前端工具**  
**核心价值**：

* 简化 Ftrace 复杂操作
* 提供类 perf 的用户体验
* 支持数据录制/报告/转换

**核心功能**：

```
# 录制函数图追踪
trace-cmd record -p function_graph -g vfs_read

# 追踪系统调用
trace-cmd record -e syscalls

# 生成可读报告
trace-cmd report > trace.log

# 转换数据格式
trace-cmd report -t > trace.dat
```

**关键优势**：

* **一键操作**：封装复杂的 Ftrace 配置
* **跨版本兼容**：自动处理内核差异
* **插件体系**：支持自定义分析模块
* **可视化集成**：无缝对接 kernelshark

## ptrace 系统调用深度解析

ptrace（process trace）是 Linux 系统中最强大的进程调试工具之一，它提供了对进程执行的**细粒度控制**能力。作为调试器（如 GDB）和系统调用跟踪器（如 strace）的底层基础，ptrace 允许一个进程（tracer）观察和控制另一个进程（tracee）的执行。

![](../../资源/图片/yuque_23d6951302ef.png)

## strace 终极指南：深入系统调用追踪

strace 是 Linux 系统中最强大的**系统调用追踪工具**，它通过内核的 ptrace 机制实现，能够实时监控应用程序与内核的交互过程。作为系统管理员和开发者的必备工具，strace 提供了对程序行为的深度洞察能力。

## **核心功能全景图**

|  |  |  |
| --- | --- | --- |
| **功能类别** | **具体能力** | **应用场景** |
| **系统调用追踪** | 捕获所有系统调用 | 程序行为分析 |
| **参数解析** | 显示调用参数值 | 调试数据流 |
| **错误诊断** | 显示错误码和描述 | 故障排查 |
| **性能分析** | 统计调用耗时 | 性能优化 |
| **信号监控** | 捕获进程信号 | 异常行为分析 |
| **文件访问** | 跟踪文件操作 | 权限问题诊断 |
| **网络交互** | 监控套接字操作 | 网络调试 |

## **基础用法与输出解析**

### **基本命令**

### 基本用法

```
strace [options] command [args]
```

### 常用选项

* **-c**：统计系统调用的次数、时间和错误。
* **-f**：跟踪由 fork 创建的子进程。
* **-ff**：与 -f 一起使用，将每个子进程的跟踪输出写入单独的文件。
* **-e trace=syscall\_list**：只跟踪指定的系统调用（用逗号分隔）。
* **-e trace=file**：只跟踪与文件操作相关的系统调用。
* **-e trace=process**：只跟踪进程管理相关的系统调用。
* **-e trace=network**：只跟踪网络相关的系统调用。
* **-e trace=signal**：只跟踪信号相关的系统调用。
* **-e trace=ipc**：只跟踪进程间通信相关的系统调用。
* **-e trace=desc**：只跟踪文件描述符相关的系统调用。
* **-e trace=memory**：只跟踪内存映射相关的系统调用。
* **-p pid**：附加到正在运行的进程（通过进程ID）。
* **-o file**：将输出写入文件而不是标准错误输出。
* **-s size**：指定打印字符串的最大长度（默认为32）。
* **-v**：显示系统调用中的环境、状态等详细信息（冗余模式）。
* **-t**：在输出中的每一行前加上时间（小时:分钟:秒）。
* **-tt**：在输出中的每一行前加上时间（包括微秒）。
* **-T**：显示每个系统调用所花费的时间。
* **-y**：打印与文件描述符相关的路径。
* **-yy**：打印与套接字、字符设备等相关的详细信息

## 一、核心概念

- **定义**：Trace（追踪）是通过记录系统调用、内核函数调用或函数调用路径来分析程序行为的技术，主要工具包括 strace（系统调用追踪）、ptrace（进程控制接口）和 ftrace（内核函数追踪）
- **关键词**：strace、ptrace、ftrace、function_graph、trace-cmd、系统调用追踪、内核函数追踪
- **适用场景/边界**：strace 适合排查"程序为什么卡住/报错"（文件找不到、权限拒绝、网络超时）；ftrace 适合排查内核路径延迟和调用链；边界：生产环境慎用 strace（每次 syscall 两次上下文切换，性能降低 10-50%）

## 二、详细解析（≥200字）

- **原理拆解（三层递进）**：
  - **第一层——ptrace 内核机制**：ptrace 是 Linux 内核提供的进程控制系统调用。tracer 通过 `PTRACE_SYSCALL` 让 tracee 每遇到系统调用入口和出口各暂停一次——每次暂停触发一次上下文切换和 waitpid。这是 strace 的性能开销根源
  - **第二层——strace vs ltrace 区别**：strace 追踪系统调用（用户态→内核的边界），无法看到库函数内部（如 `malloc` 的具体分配算法）；ltrace 追踪动态库函数调用（PLT 拦截），能看到库函数参数和返回值
  - **第三层——ftrace 的零开销设计**：ftrace 在内核编译时将 mcount/nop 调用插入每个函数入口。未启用时这是一条 nop（零开销）；启用后 nop 被热替换为跳转到追踪缓冲区记录函数地址，实现近乎无感的内核函数追踪
- **关键数据结构/接口**：strace `-e trace=file,network,process` 按类别过滤；ftrace 通过 `/sys/kernel/debug/tracing/` 的 debugfs 接口控制
- **关键公式**：`strace -c` 统计模式（只计数不计输出）比全量输出快得多；`trace-cmd record -p function_graph -g <func>` 捕获指定函数的完整调用树

## 三、动手实践（代码案例）

```bash
# 1. strace 基本用法
strace ls /tmp                     # 追踪 ls 的所有系统调用
strace -c ls /tmp                  # 统计模式：只显示系统调用汇总表
strace -e trace=file ls /tmp       # 只追踪文件操作相关调用
strace -e trace=network curl google.com  # 只追踪网络相关调用
strace -p 1234                     # 附加到运行中的进程 PID=1234
strace -f -o trace.log ./server    # 追踪子进程，输出到文件
strace -T -tt ./slow_program       # 显示每次调用的耗时(-T)和精确时间戳(-tt)

# 2. ftrace 内核函数追踪（需 root）
cd /sys/kernel/debug/tracing
echo function_graph > current_tracer       # 启用函数图追踪器
echo __x64_sys_write > set_ftrace_filter  # 只追踪 write 系统调用
echo 1 > tracing_on                        # 开始追踪
cat trace                                  # 查看结果

# 3. trace-cmd 简化 ftrace
trace-cmd record -p function_graph -g vfs_read   # 追踪 vfs_read 调用树
trace-cmd report > trace.log              # 生成可读报告

# 4. strace -c 快速诊断
strace -c -p $(pgrep myserver)           # 统计服务器进程的系统调用分布
# 输出：% time / seconds / usecs/call / calls / errors / syscall
# 看 time 列定位耗时大户，errors 列看失败调用
```

- **预期**：掌握 strace 过滤和统计、ftrace 内核追踪、trace-cmd 简化操作
- **补充**：容器内 strace 需 `--cap-add=SYS_PTRACE` 或 `--security-opt seccomp=unconfined`

## 四、进阶应用（≥500字）

- **与其他主题的关联**：与性能分析（strace -c 统计 → perf 采样 → ftrace 内核路径 三步递进）、调试（gdb 底层也是 ptrace）、内核开发（ftrace + kprobe 动态探针）强相关
- **工程中的真实用法**：
  - **程序启动失败排查**：`strace -e trace=file ./program` 看最后几个 `open`/`stat` 调用，通常能在返回 `ENOENT` (No such file) 处找到缺失的文件或库
  - **网络超时诊断**：`strace -e trace=network -T curl https://api.example.com` 观察 `connect` 和 `recvfrom` 的耗时，超时的调用一目了然
  - **内核延迟分析**：`trace-cmd record -p function_graph -g tcp_sendmsg` 捕获 TCP 发送的完整内核调用路径，每个函数的微秒级耗时暴露瓶颈函数
  - **高频系统调用优化**：`strace -c` 发现 `write(1, "x", 1)` 被调用百万次——优化为缓冲区批量写入，系统调用次数从百万降到个位数
- **常见优化策略**：
  - **算法层面**：`strace -c` 统计模式开销远小于全量输出（只记录计数器），适合快速定位高频系统调用
  - **工具链对比**：perf 采样看 CPU 热点（谁消耗 CPU），ftrace 追踪看内核调用路径（谁调了谁，每步耗时），两者互补
  - **具体技巧**：`strace -k` 显示系统调用的调用栈（需内核 CONFIG_STACKTRACE）；`strace -y` 显示文件描述符对应的路径；`strace -yy` 显示 socket/设备等详细信息；生产环境用 `perf trace` 替代 strace（开销更低）；多线程追踪用 `strace -f -ff -o trace` 为每个线程生成单独文件

## 五、源码解析和实践感悟

### 1. ptrace 的内核实现路径

```c++
// 用户态 strace 本质是对 ptrace 系统调用的封装
long ptrace(enum __ptrace_request request, pid_t pid,
            void *addr, void *data);

// strace 内部简化逻辑
void trace_syscall(pid_t child) {
    int status;
    while (1) {
        ptrace(PTRACE_SYSCALL, child, 0, 0);  // 让子进程执行到下一个系统调用
        waitpid(child, &status, 0);
        
        struct user_regs_struct regs;
        ptrace(PTRACE_GETREGS, child, 0, &regs);  // 读取寄存器
        long syscall_num = regs.orig_rax;          // x86_64 系统调用号在 rax
        
        // 再等一次 syscall 获取返回值
        ptrace(PTRACE_SYSCALL, child, 0, 0);
        waitpid(child, &status, 0);
        ptrace(PTRACE_GETREGS, child, 0, &regs);
        long retval = regs.rax;
    }
}
```

ptrace 在每个 syscall 入口和出口各停一次（两次 PTRACE_SYSCALL），因此 strace 会产生双重上下文切换开销，这是其性能开销的主要来源。

### 2. ftrace 的 function_graph 输出

```bash
# trace-cmd record -p function_graph -g __x64_sys_write
# trace-cmd report 输出示例：
 0)  ksys_write() {
 0)    __fdget_pos() {
 0)      __fget_light() {
 0)   0.120 us |        }  /* __fget_light */
 0)   0.340 us |      }  /* __fdget_pos */
 0)    vfs_write() {
 0)      rw_verify_area();
 0)      __vfs_write() {
 0)        new_sync_write() {
 0)          call_write_iter() {
 0)            ext4_file_write_iter() {
 0)               ...
```

function_graph 追踪器不只能看调用路径，每个函数的耗时（括号右侧的 `us` 值）是关键性能数据——耗时尖锐跳变的地方就是瓶颈。

### 3. trace-cmd vs perf 的选择

```bash
# ftrace: 追踪内核函数调用路径（谁调了谁，耗时多少）
trace-cmd record -p function_graph -g tcp_sendmsg

# perf: 采样性能热点（CPU 在哪花了最多时间）
perf record -g -p <pid> -- sleep 10
perf report

# 经验法则：查调用路径用 ftrace；查 CPU 热点用 perf
```

### 实践经验

1. **strace 性能开销**：每次系统调用两次 ptrace 上下文切换，可能增加 10-50% 开销，生产环境慎用 `-f` 追踪子进程
2. **`strace -c` 统计模式**：比全量输出快得多，适合快速定位高频/慢系统调用
3. **ftrace 零开销**：`nop` 模式无性能损耗，生产环境可保持启用
4. **perf vs ftrace**：perf 采样看热点，ftrace 追踪看调用路径，两者互补
5. **gdb 底层也是 ptrace**：所有 Linux 调试器（gdb/strace/ltrace）共享 ptrace 接口
6. **容器限制**：docker 默认禁止 ptrace，需 `--cap-add=SYS_PTRACE`

## 六、面试准备

### Q&A（8题）

**Q1: strace、ptrace、ftrace 的区别？**
A: strace 是用户态工具追踪系统调用；ptrace 是内核接口（调试器底层）；ftrace 追踪内核函数执行

**Q2: strace 为什么有性能开销？**
A: 每个系统调用两次 ptrace 触发（入口+出口），每次需上下文切换和 waitpid，高 QPS 场景可降低 50% 吞吐

**Q3: `strace -c` 的作用？**
A: 统计模式，只记录每个系统调用的次数/时间/错误，几乎无运行时打印开销

**Q4: ftrace 的 function_graph 追踪器能看到什么？**
A: 函数调用树 + 每个函数的执行时间（微秒级），用于定位内核路径中的慢函数

**Q5: 如何追踪一个已经在运行的进程？**
A: `strace -p <pid>`、`trace-cmd record -p function_graph -P <pid>`

**Q6: ptrace 能同时被多个 tracer 附加吗？**
A: 不能，一个 tracee 同时只能被一个 tracer 附加。这是 Linux 内核的限制

**Q7: perf 和 ftrace 分别适合什么场景？**
A: perf 采样看 CPU 热点（谁耗 CPU），ftrace 追踪看调用路径（谁调了谁），互补使用

**Q8: 为什么容器里 strace 可能失败？**
A: Docker 默认 seccomp 配置禁用 ptrace 系统调用，需 `--cap-add=SYS_PTRACE` 或 `--security-opt seccomp=unconfined`

### 陷阱与反问（5个）

1. **陷阱**：生产环境 `strace -f` 追踪高频服务 — 性能暴跌甚至服务不可用
2. **反问**：strace 能看到库函数调用吗？→ 不能，只看到系统调用。库函数用 ltrace
3. **陷阱**：strace 输出直接存文件，缓冲区满时可能丢数据 — 应重定向到文件
4. **反问**：为什么 perf top 看到的是汇编地址而非函数名？→ 缺少符号表，需 `-g` 编译或安装 debuginfo
5. **陷阱**：ftrace 在 ARM 设备上可能缺少某些 tracer — 不同架构内核编译选项不同

### 一句话答案（5个）

1. **strace 本质**：ptrace 封装，捕获进程的每一个系统调用
2. **系统调用 vs 库函数**：strace 看前者，ltrace 看后者
3. **ftrace 核心**：内核函数调用追踪，function_graph 看调用路径+耗时
4. **ptrace 限制**：一个进程同时只能被一个 tracer 附加
5. **性能排查顺序**：先 `strace -c` 统计 → 再 ftrace/perf 深入
