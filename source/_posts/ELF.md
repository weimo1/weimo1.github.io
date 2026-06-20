---
title: ELF
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "基础知识", "运行时与链接"]
publish: true
---

# ELF

> 参考：https://zhuanlan.zhihu.com/p/1979190567213757017

## 一、核心概念

- **定义**：ELF（Executable and Linkable Format）是 Linux/Unix 系统的标准二进制文件格式，涵盖可执行文件、共享库（.so）、目标文件（.o）和 core dump
- **关键词**：ELF Header、Section Header Table、Program Header Table、.text/.data/.bss、symbol table、DWARF
- **适用场景/边界**：编译器输出格式、链接器输入/输出、动态加载（ld.so）、调试信息载体（DWARF 嵌入 ELF）

## 二、详细解析（≥200字）

- **原理拆解（三层递进）**：
  - **第一层——两种视图**：① 链接视图（Linking View）：以 Section 为单位组织——`.text`（代码）、`.data`（已初始化数据）、`.bss`（零初始化数据）、`.rodata`（只读数据）、`.symtab`（符号表）；② 执行视图（Execution View）：以 Segment 为单位组织——内核加载时按 Segment 映射内存，一个 Segment 可包含多个 Section
  - **第二层——ELF Header 结构**：文件头 64 字节（64位）包含：魔数 `\x7fELF`、类别（32/64位）、字节序、ABI、入口地址、Section/Program Header 表偏移量和表项数
  - **第三层——动态链接机制**：`.dynamic` 段包含动态链接信息。`.plt`（Procedure Linkage Table）和 `.got`（Global Offset Table）实现延迟绑定——首次调用外部函数时通过 `_dl_runtime_resolve` 解析符号地址并回填 GOT，后续调用直接跳转
- **关键数据结构/接口**：`readelf -h/-S/-l/-s` 查看 ELF 各层结构；`objdump -d/-t` 反汇编/查符号
- **关键公式**：`.bss` 段在文件中不占空间（只记录大小），加载时由内核清零

## 三、动手实践（代码案例）

```bash
# 1. 查看 ELF Header
readelf -h /bin/ls
# 输出：Magic、Class（ELF64）、Entry point address、Section header offset 等

# 2. 列出所有 Section
readelf -S /bin/ls
# .text(代码) .rodata(只读数据) .data .bss .symtab(符号表) .strtab(字符串表)

# 3. 查看 Segment（执行视图）
readelf -l /bin/ls
# LOAD 段：加载到内存的代码+数据；DYNAMIC 段：动态链接信息

# 4. 动态库依赖
readelf -d /bin/ls | grep NEEDED
# libcap.so.2, libc.so.6 ...

# 5. 符号表
readelf -s /bin/ls | grep FUNC  # 所有函数符号

# 6. 编译各阶段产物对比
# 目标文件 .o：只有 Section 视图（未链接）
g++ -c main.cpp -o main.o
readelf -S main.o

# 可执行文件：Section + Segment 视图（已链接）
g++ main.o -o main
readelf -l main  # 有 LOAD 段
```

- **预期**：掌握 ELF 双视图结构、Section/Segment 概念、动态链接机制
- **补充**：`.interp` 段指定动态链接器路径（如 `/lib64/ld-linux-x86-64.so.2`）

## 四、进阶应用（≥500字）

- **与其他主题的关联**：与编译原理（编译器输出 .o 即为 ELF）、链接原理（ld 合并 .o 的 Section 到可执行文件 Segment）、动态加载（ld.so 解析 ELF）、调试（DWARF 嵌入 ELF）、逆向工程（readelf/objdump 分析 ELF）强相关
- **工程中的真实用法**：
  - **符号可见性控制**：`__attribute__((visibility("hidden")))` 或 `-fvisibility=hidden` 限制 .so 导出符号，减小符号表、加速加载、避免符号冲突
  - **strip 瘦身**：`strip --strip-all` 移除调试信息和符号表（`.symtab`/`.debug_*`），可减少 50-90% 二进制体积。保留 `.dynsym`（动态符号）不影响运行时
  - **PIE/PIC 与安全**：`-fPIE -pie` 生成位置无关可执行文件，启用 ASLR（地址空间布局随机化）；`-fPIC` 生成位置无关代码用于共享库
  - **`LD_PRELOAD` 注入**：利用 ELF 动态链接的符号解析顺序，`LD_PRELOAD=./hook.so ./program` 可拦截系统调用
- **常见分析命令链**：
  - **符号未定义排查**：`ldd program` 看所有依赖 → `readelf -d` 确认 NEEDED → `nm -D` 查动态符号
  - **段错误定位**：`dmesg | tail` 看崩溃地址 → `addr2line -e program -f <addr>` 翻译地址到源码行
  - **二进制分类**：`file program` 快速判断（静态链接/动态链接/PIE/stripped）

## 五、源码解析和实践感悟

### 1. ELF Header 结构（C 定义）

```c++
// /usr/include/elf.h
typedef struct {
    unsigned char e_ident[EI_NIDENT];  // 魔数 + 类别 + 字节序 + ABI
    uint16_t      e_type;              // ET_EXEC(可执行) ET_DYN(共享库) ET_REL(.o)
    uint16_t      e_machine;           // EM_X86_64 / EM_AARCH64
    uint32_t      e_version;
    Elf64_Addr    e_entry;             // ★ 程序入口虚拟地址
    Elf64_Off     e_phoff;             // Program Header Table 偏移
    Elf64_Off     e_shoff;             // Section Header Table 偏移
    uint32_t      e_flags;
    uint16_t      e_ehsize;            // ELF Header 自身大小
    uint16_t      e_phentsize;         // Program Header 表项大小
    uint16_t      e_phnum;             // Program Header 表项数量
    uint16_t      e_shentsize;         // Section Header 表项大小
    uint16_t      e_shnum;             // Section Header 表项数量
    uint16_t      e_shstrndx;          // Section 名称字符串表索引
} Elf64_Ehdr;
```

### 2. 动态链接延迟绑定的 PLT/GOT 机制

```c++
// PLT stub 简化逻辑（首次调用外部函数 printf）
// 1. call printf@plt → jmp *GOT[n]（GOT 初始指向 PLT 下一条指令）
// 2. push link_map_index; jmp _dl_runtime_resolve
// 3. ld.so 查找符号 printf → 将真实地址写入 GOT[n]
// 4. 后续调用：jmp *GOT[n] 直接跳到真实 printf
```

### 实践经验

1. **`-Wl,--gc-sections`**：链接时移除未引用的 Section，配合 `-ffunction-sections -fdata-sections` 可显著减小二进制
2. **`_start` vs `main`**：ELF 入口是 `_start`（来自 crt1.o），它会调用 `__libc_start_main` → `main`，然后 `exit`
3. **`.init_array` / `.fini_array`**：构造函数（`__attribute__((constructor))`）和析构函数存放在此
4. **`LD_SHOW_AUXV=1`**：显示内核传递给进程的辅助向量（auxv），包含 AT_ENTRY（入口地址）、AT_PHDR（程序头地址）
5. **`patchelf` 工具**：修改 ELF 的 RPATH 和动态链接器，避免重新编译

## 六、面试准备

### Q&A（8题）

**Q1: ELF 文件的 Section 和 Segment 区别？**
A: Section 是链接视图（供 ld 使用），Segment 是执行视图（供 kernel 加载）。一个 Segment 包含多个 Section

**Q2: `.bss` 段为什么在文件中不占空间？**
A: .bss 存未初始化或零初始化的全局变量，内核加载时直接分配零页，无需存储实际数据

**Q3: 动态链接的 GOT 和 PLT 分别做什么？**
A: PLT（Procedure Linkage Table）是跳板代码，GOT（Global Offset Table）存函数真实地址。延迟绑定中 GOT 初始指向 PLT 下一条指令

**Q4: `-fPIC` 和 `-fPIE` 的区别？**
A: PIC 用于共享库（通过 GOT 间接访问全局变量），PIE 用于可执行文件（开启 ASLR），PIE 的性能略优于 PIC

**Q5: 如何查看一个 ELF 的依赖库？**
A: `ldd program`（小心代码注入风险）或 `readelf -d program | grep NEEDED`

**Q6: strip 命令做了什么？**
A: 移除 `.symtab`、`.strtab`（静态符号表）和 `.debug_*` 调试段，保留 `.dynsym`（动态符号）确保运行时正常

**Q7: ELF 入口地址在哪里？**
A: `e_entry` 字段。对可执行文件通常是 `_start`（crt1.o），对共享库可能是 0

**Q8: 什么是 `LD_PRELOAD`？**
A: 强制优先加载指定 .so，可拦截系统调用。用于调试、注入、性能分析

### 陷阱与反问（5个）

1. **陷阱**：`ldd` 执行目标程序来获取依赖——不可信程序用 `readelf -d` 代替
2. **反问**：静态链接 vs 动态链接？→ 静态独立但体积大、安全更新需重编译；动态节省空间、库可热更新
3. **陷阱**：不同 libc 版本 ABI 不兼容——`GLIBC_2.34 not found` 意味着需要匹配的 libc 版本
4. **反问**：为什么 .o 文件也是 ELF？→ ELF 格式统一了目标文件、可执行文件和共享库，只通过 e_type 区分
5. **陷阱**：strip 后 `addr2line` 无法翻译地址——需要保留未 strip 的版本或使用 debuginfo 包

### 一句话答案（5个）

1. **ELF 本质**：Linux 标准二进制格式
2. **Section vs Segment**：链接视角 vs 执行视角
3. **PLT/GOT**：动态链接的延迟绑定机制
4. **`.bss`**：零初始化数据段，文件中不占空间
5. **`readelf -d`**：查看动态链接信息的首选命令

## 附录

![](../../资源/图片/yuque_320c8160c2cd.png)
