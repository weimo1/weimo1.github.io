---
title: gdb
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "基础知识", "调试与工具"]
publish: true
---

# gdb

使用c++编程的同学，经常会遇到诸如内存越界、重复释放等内存问题，大家比较习惯的追查这类问题的方式是，打开core文件的limit，生成core文件，用[gdb](https://zhida.zhihu.com/search?content_id=180705491&content_type=Article&match_order=1&q=gdb&zhida_source=entity)进行分析； 但是，在实际的生产环境中。由于程序本省占用内存非常大，比如搜索的索引服务，进行core的dump不太现实，所以一般采用，在程序中捕获信号，之后打印进程的堆栈信息，再进行追查。 下面本文，就按照这种方式进行追查，首先，分析没有so的程序如何使用objdump与汇编进行分析程序的问题所在；接着分析有so的程序，如何使用objdump进行分析，希望对大家能有所帮助。

[程序员的自我修养：如何用好 GDB](https://zhuanlan.zhihu.com/p/1998703496158016253)

## **使用objdump分析**

## **core在so里面的objdump分析**

### gdb技巧

#### **1.巧用tab补全**

gdb技巧挺多的，比如说**直接回车**是继续执行上一次的代码

比如输入b连续按下两次tab，可以查看gdb的所有b开头的gdb指令

b main 但由于记不清main的函数全称，在b ma之后连续按下两次tab，可以查看ma开头的所有函数名称

**TUI 模式：**GDB 的界面会分为几个窗格，包括源代码窗格、汇编窗格、寄存器窗格等。

按下**ctrl x a**会显示下图的窗口(可以上下滑动查看原代码)，其中箭头表示【当前准备执行但还未执行的开始位置】。再次按下**ctrl x a**会退出该窗口模式

#### 2. 打印输出指定地址的值

比如说结构体**TreeNode**，地址为**0x555555559300**。

打印每次都需要p root->xxxx...,如果树的深度太深则每次都需要从根节点root开始寻址太麻烦。

p \*((TreeNode\*)0x555555559300)

#### 3. 查看当前执行到哪行代码+代码内容

##### 方式一：info line 结合 list 。

##### 方式二：f

`f` 命令的功能是帮助了解当前执行的代码所在的位置，特别是在调试过程中出现错误时，可以帮助确认错误发生的地点。

#### 服务器 CPU 占用率高，如何排查？

这是一个经典的性能排查问题，标准流程如下：

1. **找到高 CPU 进程**：使用 `top` 或 `htop` 命令，按 `P`（按 CPU 使用率排序）。
2. **找到该进程中消耗 CPU 的线程**：

```
top -H -p <pid>  # 查看某个进程下的所有线程
或
ps -T -p <pid> -o pid,tid,pcpu,comm  # 查看线程信息
```

3. **将高 CPU 线程 ID 转为十六进制**（为 gdb 做准备）：

```
printf "%x\n" <tid>
```

4. **使用 gdb 附加到进程**：

```
gdb -p <pid>
```

5. **在 gdb 中查看该线程的调用栈**，分析它在执行什么：

```
(gdb) thread <tid>  # 切换到高 CPU 线程
(gdb) bt            # 查看该线程的调用栈
```

**调用栈分析**：如果 `bt` 显示线程反复出现在同一个或几个函数中，这些函数就是热点函数，需要优化。

#### 多线程调试

**查看和操作线程**：

```
(gdb) info threads          # 查看所有线程
(gdb) thread [线程号]      # 切换到指定线程
(gdb) thread apply all bt  # 查看所有线程的调用栈
```

**调试技巧**：

* 使用 `set scheduler-locking on` 锁定其他线程，专注调试当前线程
* 使用 `break [位置] thread [线程号]` 设置线程特定断点

#### 内存调试技巧

**处理未命名内存引用**：

1. 使用 `watch` 命令设置观察点，监控内存变化

```
(gdb) watch *(int*)0x12345678  # 监控特定地址
```

2. 使用 `x` 命令检查内存内容

```
(gdb) x/8xw 0x12345678  # 以16进制显示8个字
(gdb) x/s 0x12345678    # 以字符串形式显示
```

3. 使用 Valgrind 等工具辅助检测内存问题

## GDB原理

![](../../资源/图片/yuque_851f59a53ac0.png)

![](../../资源/图片/yuque_ca62ae579088.png)

![](../../资源/图片/yuque_c78fe6af6bbe.png)

![](../../资源/图片/yuque_22a97a628107.png)

### 源码 -> 可执行文件 -> 进程

正常来说，我应该开始介绍 DWARF 的技术细节，以及 DWARF 是如何发挥作用的了，但是我想在这之前，还是掰扯一些可能大家已经耳熟能详的东西，考虑到 AI 输出的会比我说的又详细又好，那我就快速直奔重点：

刚才已经提到了，GDB 或者说调试器的作用，都是将进程某一刻的运行状态映射回源码世界。更进一步的说，调试器的诸多能力，比如说符号查找，变量查看以及调用栈回溯，都是仰仗 DWARF 来完成的。所以，我们需要了解这里面源码到可执行文件再到进程运行时的转换细节，才能更好的理解 DWARF 是如何保留这些信息的，以及保留了哪些信息。

***源码 -> 可执行文件***

想必大家都听过 C 语言编译的过程：预处理、编译、汇编和链接，也都听过 JAVA 是一次编译，到处运行。而这里，我想展示一张来自 《Crafting Interpreters》中的图片，基本上每个语言都可以在这张图片里面找到对应的路径，而我每次遇到各种编译相关的问题时，自己脑海中首先会浮现出这张图。

![](../../资源/图片/yuque_47fb4ab97861.png)

结合着 -g 编译选项可以生成调试信息，并且 ELF 格式中包含着 DWARF 相关的 section，所以 **DWARF 是编译器在编译过程中生成的**。并且我们可以进一步理解，不管是什么样的编译型编程语言，最终在这个过程中，`source code` 都会被转换为 `machine code`。这意味着源码中大量的信息会被剥离优化掉，所以 DWARF 是怎么帮助 GDB 把机器码映射回源码的答案在这里变得会稍微清晰一些：这些被剥离的信息以 DWARF 的形式被编译器记录了下来。

另外，可能大家还会有疑问的是，**GDB 还能支持 C/C++ 以外编译型编程语言的调试吗，更蛋疼的一点的问题，GDB 还能支持 Lua 或者 Python 这种脚本型语言的调试吗**，这些问题，都会在后面进行讨论

DWARF 做了什么，一句话概括的话就是：记录了每个指令被执行时，所有变量和参数所处的内存位置信息。我们都知道，这里需要被记录的信息量多的吓人，老老实实的一一记录肯定是不行的，那么 DWARF 的解法是什么呢。DWARF 的选择很酷，直接设计了一个基于栈的微型虚拟机语言，用这个虚拟机语言来描述某个变量在特定的指令范围内对应的具体地址位置，极大的节约了空间。当然这也增加了调试器的解析负担，不过我觉得是值得的，毕竟 DWARF 解析并不是一个高频操作，调试的时候需要看的信息其实是有限的。

![](../../资源/图片/yuque_ced130089bb8.png)

![](../../资源/图片/yuque_e42ea1da64fc.png)

![](../../资源/图片/yuque_d2c92bed7d08.png)

## 一、核心概念

- **定义**：GDB（GNU Debugger）是 Linux 平台最强大的源码级调试器，通过 ptrace 系统调用控制被调试进程，依赖 DWARF 调试信息将机器码映射回源码
- **关键词**：ptrace、DWARF、int3 断点、core dump、watchpoint、TUI 模式、反向调试（record）
- **适用场景/边界**：程序崩溃（segfault）现场分析、逻辑错误断点调试、多线程死锁排查、性能热点调用栈取样；边界：优化后变量可能不可见（`<optimized out>`）、容器中需 `SYS_PTRACE` 权限

## 二、详细解析（≥200字）

- **原理拆解（三层递进）**：
  - **第一层——断点机制**：GDB 在目标地址写入 `int3` 指令（0xCC），CPU 执行到此处触发 SIGTRAP 信号，操作系统暂停进程并将控制权交给 GDB。恢复执行时 GDB 将原指令放回并单步执行
  - **第二层——DWARF 调试信息**：编译时 `-g` 选项让编译器生成 DWARF 段（`.debug_info`/`.debug_line`/`.debug_frame`）。DWARF 使用基于栈的微型虚拟机语言描述"每个指令地址对应的变量位置和源码行号"，极大压缩信息量
  - **第三层——watchpoint 实现**：优先使用 x86 硬件断点寄存器（DR0-DR3，最多 4 个），监视指定内存地址的读/写。当硬件寄存器不够时回退到软件单步模拟（每执行一条指令检查一次——极慢，仅适合短时间监视）
- **关键数据结构/接口**：`ptrace(PTRACE_PEEKDATA/POKEDATA, ...)` 读写进程内存；`/proc/<pid>/mem` 可替代 ptrace
- **关键公式**：`bt full` 显示完整调用栈+局部变量；`thread apply all bt` 打印所有线程调用栈

## 三、动手实践（代码案例）

```bash
# 1. 基础调试流程
g++ -g -O0 crash.cpp -o crash
gdb ./crash
(gdb) run                    # 运行程序
# Program received signal SIGSEGV, Segmentation fault.
(gdb) bt                     # 查看崩溃调用栈
(gdb) frame 2                # 切到栈帧 2
(gdb) info locals            # 查看局部变量
(gdb) print ptr              # 打印变量值
(gdb) x/8xw 0x12345678      # 查看内存内容

# 2. 条件断点
(gdb) break process.cpp:100 if ptr == nullptr

# 3. 多线程调试
(gdb) info threads           # 列出所有线程
(gdb) thread 3               # 切换到线程 3
(gdb) thread apply all bt    # 所有线程调用栈
(gdb) set scheduler-locking on  # 只运行当前线程

# 4. 附加到运行中的进程
gdb -p <pid>

# 5. core dump 分析
ulimit -c unlimited
gdb ./crash core
(gdb) bt full                # 崩溃时刻完整现场
(gdb) info registers         # 寄存器值

# 6. 反向调试
(gdb) record                 # 开始记录
(gdb) continue               # 运行到崩溃
(gdb) reverse-next           # 反向单步（回到崩溃前一条指令）
```

- **预期**：掌握断点调试、调用栈分析、core dump 排查、多线程调试四大核心能力
- **补充**：TUI 模式（Ctrl+X+A）提供源代码窗口，`layout split` 同时显示源码和汇编

## 四、进阶应用（≥500字）

- **与其他主题的关联**：与编译原理（DWARF 调试信息格式）、操作系统（ptrace/信号机制）、性能分析（perf 采样与 gdb 互补）、逆向工程（objdump/readelf 配合）强相关
- **工程中的真实用法**：
  - **release 版本调试**：用 `-O2 -g` 编译——保留优化性能同时生成符号。注意：优化后变量可能被寄存器分配或消除（`info locals` 显示 `<optimized out>`），指令重排导致行号错位
  - **CPU 高占用排查**：`top -H -p <pid>` 找到高 CPU 线程 → `printf "%x\n" <tid>` 转十六进制 → `gdb -p <pid>` → `thread <tid>; bt` 看该线程在做什么
  - **多线程死锁**：`thread apply all bt` 整体分析——若多个线程各自停在 `pthread_mutex_lock` 或 `futex_wait`，检查锁的获取顺序是否构成环
  - **GDB Python 扩展**：GDB 内置 Python 解释器，可编写自定义命令（如 `define` 宏、Python script 自动打印复杂数据结构）
- **常见优化策略**：
  - **算法层面**：条件断点（`break N if cond`）只在满足条件时中断，避免不必要的暂停
  - **工具链**：`catch throw` 在 C++ 异常抛出点自动中断；`catch syscall write` 在指定系统调用时中断
  - **具体技巧**：tab 键双击补全命令和函数名（`b ma<TAB><TAB>` 列出所有 ma 开头的函数）；`set var x=42` 在调试中修改变量值跳过异常路径；`jump <addr>` 跳转到指定地址（慎用，可能破坏程序状态）；用 `-tui` 启动 GDB 图形模式；`info line *0x地址` 将地址翻译为文件名+行号

## 五、源码解析和实践感悟

### 1. GDB 的调试信息机制

```c++
// -g 生成 DWARF 调试信息: 映射 指令地址→源码行号、变量位置
// break main: GDB 在 main 函数地址处插入 int3 (0xCC) 断点指令
// 断点命中后: SIGTRAP → 操作系统暂停进程 → GDB 接管控制

// watch var: 利用硬件断点寄存器(DR0-DR3)，监视变量地址写入
// 硬件断点仅 4 个，超出用软件单步模拟（极慢）
```

### 2. 核心转储分析

```c++
// ulimit -c unlimited; 程序 crash 后生成 core dump
// gdb ./program core 可事后分析崩溃时的:
// - 所有寄存器值 (info registers)
// - 完整调用栈 (bt full)
// - 各栈帧的局部变量 (frame N; info locals)
```

### 实践经验
1. **release 调试加 -g**：`-O2 -g` 在优化后仍保留调试符号
2. **条件断点**：`break file.cpp:100 if x>10` 只在条件满足时中断
3. **反向调试**：`record` 记录执行历史，`reverse-next` 反向单步
4. **attach 到运行进程**：`gdb -p <pid>` 无需重启
5. **Python 脚本**：GDB 支持 Python 扩展自定义命令

## 六、面试准备

### Q&A（10题）

**Q1: GDB 断点的底层原理？**
A: 在目标地址写入 int3 指令（0xCC），CPU 执行到此时触发 SIGTRAP，OS 暂停进程交由 GDB

**Q2: watchpoint 如何实现？**
A: 优先使用硬件断点寄存器（DR0-DR3，最多 4 个），超出用软件单步模拟

**Q3: release 版本能否调试？**
A: 加 `-O2 -g` 编译即可，但变量可能被优化消失、指令重排导致行号错位

**Q4: core dump 是什么？**
A: 进程异常终止时的内存快照，包含调用栈、寄存器、堆栈数据

**Q5: bt full 和 bt 的区别？**
A: bt 只显示函数名，bt full 还显示每个栈帧的局部变量值

**Q6: 如何在 GDB 中修改程序状态？**
A: `set var x=42` 修改变量，`jump` 跳转到指定地址继续执行

**Q7: 条件断点的用法？**
A: `break 100 if ptr != nullptr` 只在条件满足时中断

**Q8: 多线程调试怎么切换到不同线程？**
A: `info threads` 查看所有线程，`thread N` 切换到线程 N

**Q9: 如何调试已运行的进程？**
A: `gdb -p <pid>` 或 `gdb ./prog <pid>` 附加到运行中的进程

**Q10: catch throw 有什么用？**
A: 在 C++ 异常抛出点自动中断，方便定位异常来源

### 陷阱与反问（5个）
1. **陷阱**：优化后变量可能被寄存器分配或消除→ `info locals` 显示 `<optimized out>`
2. **反问**：GDB vs IDE 调试器选哪个？→ GDB 适合远程/无界面环境，IDE 调试器更适合日常开发
3. **陷阱**：段错误后程序被 kill，需要设置 `ulimit -c unlimited` 才能生成 core
4. **反问**：GDB 能调试模板代码吗？→ 能，但模板实例化后的函数名非常长，需要 tab 补全
5. **陷阱**：多线程环境下的断点会导致所有线程暂停

### 一句话答案（8个）
1. **int3**：GDB 断点的底层指令
2. **DWARF**：Linux 调试信息格式
3. **bt**：打印调用栈
4. **core dump**：崩溃内存快照
5. **watch**：监视变量变化
6. **frame N**：切换到栈帧 N
7. **record**：启用反向调试
8. **catch throw**：异常抛出断点
