---
title: ptmalloc
date: 2026-06-20
categories:
  - ["项目学习", "性能优化与架构"]
publish: true
---

# ptmalloc

> ptmalloc 是 glibc 的默认内存分配器，基于 Doug Lea 的 dlmalloc 改进，增加了多线程支持。其核心是以 malloc_chunk 为基本单元、通过 fastbins/smallbins/largebins/unsorted bin 等多级空闲链表管理内存。

## 一、核心概念

- 定义：ptmalloc 是 glibc 中的用户态内存分配器，通过 brk() 或 mmap() 从内核申请大块内存，以 chunk 为单位管理分配和释放。引入主分配区（main_arena）和非主分配区（non_main_arena）机制支持多线程并发。
- 关键词：malloc_state、malloc_chunk、arena、fastbin、unsorted bin、small bin、large bin、top chunk、brk、mmap
- 适用场景/边界：
  - Linux 用户态 C/C++ 程序默认 malloc/free 实现
  - 适合通用场景，极端多线程高并发场景考虑 tcmalloc/jemalloc
  - 小内存分配频繁场景下可能产生较多内存碎片
  - 分配区数量只增不减

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：基本工作原理**

ptmalloc 通过 brk（堆内存）或者 mmap（内存映射）系统调用从内核申请一大块连续内存，申请的内存由 top chunk 管理。用户程序调用 malloc 从内存池申请内存（chunk），如果内存池有空闲 chunk，则从空闲 chunk 返回；如果没有空闲 chunk，则从 top chunk 裁剪可用 chunk 返回。用户程序调用 free 将释放 chunk 归入空闲链表或 top chunk。

**核心流程：** 获取分配区(arena)并加锁 → fast bin → unsorted bin → small bin → large bin → top chunk → 扩展堆

![](https://cdn.nlark.com/yuque/0/2025/webp/50402827/1755763785334-02ced744-ee69-497d-b4b5-ee28d410de83.webp)

**第二层：关键数据结构**

ptmalloc 围绕两个核心结构体：`malloc_state` 和 `malloc_chunk`。

**1) malloc_state**

```c++
struct malloc_state
{
    __libc_lock_define (, mutex);    // 互斥锁
    int flags;                        // 标志
    mfastbinptr fastbinsY[NFASTBINS]; // fastbins
    mchunkptr top;                    // top chunk
    mchunkptr bins[NBINS * 2 - 2];   // unsortedbins, smallbins, largebins
    unsigned int binmap[BINMAPSIZE];  // bin 位图
    struct malloc_state *next;        // 链表指针
    // ......
};
```

重要成员说明：
- **fastbinsY 数组**：fastbins，存储 16-160 字节 chunk 的空闲链表。
- **bins 数组**：分为三部分：
  1. unsortedbins：chunk 缓存区，存储从 fastbins 合并的空闲 chunk。
  2. smallbins：空闲链表，存储 32-1024 字节的 chunk。
  3. largebins：空闲链表，存储大于 1024 字节的 chunk。
- **top chunk**：超级 chunk，ptmalloc 内存池。
- **binmap**：可用 bins 位图，快速查找可用 bin。
- **next**：单向链表指针，连接不同 malloc_state。

**2) malloc_chunk**

```c++
struct malloc_chunk {
    INTERNAL_SIZE_T mchunk_prev_size;   // 前一个 chunk 大小
    INTERNAL_SIZE_T mchunk_size;        // 当前 chunk 大小，后三位为 A,M,P
    struct malloc_chunk* fd;            // 链表后驱指针
    struct malloc_chunk* bk;            // 链表前驱指针
    struct malloc_chunk* fd_nextsize;   // largebins 后驱指针
    struct malloc_chunk* bk_nextsize;   // largebins 前驱指针
};
```

chunk 是 ptmalloc 最难理解的概念，只有理解了 chunk 才能真正理解 ptmalloc。

**第三层：chunk 的结构与空间复用**

chunk 可分为使用中和空闲两种状态：

**a) 使用中的 chunk**

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1756699604157-aa0df83a-d270-471b-baee-dbaf6b296262.png)

说明：
1. chunk 指针指向 chunk 开始地址，mem 指针指向用户内存块开始地址
2. P=0 时前一个 chunk 空闲，prev_size 有效；P=1 时前一个 chunk 使用中，prev_size 无效
3. M=1 为 mmap 映射区域分配，M=0 为 heap 区域分配
4. A=0 为主分配区分配，A=1 为非主分配区分配

**b) 空闲的 chunk**

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1756699604152-7b8e84e9-0229-4d96-a8c5-d49f718e41e1.png)

说明：
1. 空闲 chunk 的 M 状态不存在，只有 AP 状态（mmap 分配的内存 free 时直接 unmmap，不放入空闲链表）
2. 用户数据区存储了四个指针：fd 指向后一个空闲 chunk，bk 指向前一个空闲 chunk
3. large bin 中还有 fd_nextsize 和 bk_nextsize，用于加速查找

**c) chunk 中的空间复用**

为最小化 chunk 占用，ptmalloc 使用空间复用。空闲时至少需要 4 个 size_t 存储 prev_size、size、fd、bk（16 bytes）。使用中时，下一个 chunk 的 prev_size 域无效，可被当前 chunk 使用。

实际分配大小公式：
```
in_use_size = (用户请求大小 + 8 - 4) align to 8 bytes
chunk_size = max(in_use_size, 16)
```

### 关键数据结构/接口

**fastbins 数组**

![](https://cdn.nlark.com/yuque/0/2025/webp/50402827/1755763936431-4a70de4a-7b21-4c5e-bda3-2fec5f4436de.webp)

fastbins 数组长度 10，每个元素为 chunk 链表头。10 个链表分别存储 16-160 字节的 chunk，步长 16 字节。malloc 申请小于 160 字节时，从 fastbins 空闲链表查找匹配。

**bins 数组**

![](https://cdn.nlark.com/yuque/0/2025/webp/50402827/1755763936376-66bfae68-cf7a-4cec-bbf6-77930e633b2e.webp)

bins 数组长度 128，分为三部分：
- unsortedbins（0号元素）：chunk 缓存区，**目的是回收小块内存，解决内存碎片问题**
- smallbins：32-1024 字节
- largebins：>1024 字节

![](https://cdn.nlark.com/yuque/0/2025/webp/50402827/1755763846875-da805218-44c1-4641-818d-567aae68d25c.webp)

## 三、动手实践（代码案例）

```c++
#include <stdlib.h>
#include <stdio.h>
#include <malloc.h>

int main() {
    // 小内存分配 → fastbin
    void* p1 = malloc(32);
    void* p2 = malloc(64);
    void* p3 = malloc(128);
    
    // 中等内存 → smallbin 或 unsorted bin
    void* p4 = malloc(512);
    void* p5 = malloc(1024);
    
    // 大内存 → mmap（超过 128KB 阈值）
    void* p6 = malloc(256 * 1024);
    
    printf("p1=%p p2=%p p3=%p\n", p1, p2, p3);
    printf("p4=%p p5=%p p6=%p\n", p4, p5, p6);
    
    // 查看分配器统计信息
    struct mallinfo info = mallinfo();
    printf("arena=%d ordblks=%d smblks=%d hblks=%d\n",
           info.arena, info.ordblks, info.smblks, info.hblks);
    
    free(p1); free(p2); free(p3);
    free(p4); free(p5); free(p6);
    
    // 收缩 top chunk
    malloc_trim(0);
    
    return 0;
}
```

编译运行：
```bash
gcc -o ptmalloc_test ptmalloc_test.c
./ptmalloc_test
```

## 四、进阶应用（≥500字）

### 与其他主题的关联

ptmalloc 与以下主题深度关联：
- **tcmalloc/jemalloc**：同为用户态内存分配器。tcmalloc 通过线程局部缓存（TLS）减少锁竞争，jemalloc 以大小类（size class）和线程缓存优化碎片。两者在多线程场景性能通常优于 ptmalloc。
- **操作系统内存管理**：ptmalloc 依赖 brk() 和 mmap() 系统调用，与内核页管理、缺页异常、TLB 机制密切相关。
- **内存池设计**：ptmalloc 的多级 bin 架构是通用内存池的经典参考设计。

### 工程中的真实用法

- **MySQL** 使用 jemalloc 替代 glibc ptmalloc 以减少内存碎片
- **Redis** 使用 jemalloc 作为默认分配器（可通过编译选项切换）
- **Chrome/Firefox** 各自实现了定制分配器（PartitionAlloc/mozjemalloc）

### 常见优化策略

- **减少分配区锁竞争**：在高并发场景，考虑使用 tcmalloc（per-thread cache）或 jemalloc（per-CPU cache）
- **避免内存碎片**：预分配大块内存并自行管理（如内存池）；合理控制分配大小以减少外部碎片
- **降低 mmap 阈值**：调整 `M_MMAP_THRESHOLD` 使得大内存直接 mmap 分配（避免污染 top chunk）
- **定期 trim**：调用 `malloc_trim()` 归还空闲内存给操作系统

**注意：内存池内存不够，并不一定表示内存都被用完，也有可能是存在内存碎片。**

## 五、源码解析和实践感悟（≥1000字）

### 关键实现路径

### malloc 函数流程分析

![](https://cdn.nlark.com/yuque/0/2025/webp/50402827/1755763951647-daa4d89e-7c4f-47ed-9ed2-b02ca6c14f3c.webp)

详细步骤：

1. 获取分配区的锁，防止多线程冲突
2. 计算实际需要分配的内存的 chunk 实际大小
3. 判断 chunk 大小，如果小于 `max_fast`（64B），尝试去 fast bins 上取适合的 chunk，有则分配结束
4. 判断 chunk 大小是否小于 512B，如果是，从 small bins 查找 chunk，有合适的则分配结束
5. ptmalloc 首先遍历 fast bins 中的 chunk，将相邻 chunk 合并并链接到 unsorted bin，然后遍历 unsorted bin：
   - 若 unsorted bin 只有一个 chunk 且大于待分配大小 → 切割，剩余扔回 unsorted bin
   - 若大小相等 → 返回并从 unsorted bin 删除
   - 若属于 small bins 范围 → 放入 small bins 头部
   - 若属于 large bins 范围 → 找到合适位置放入
   - 未分配成功 → 转入下一步
6. 从 large bins 查找，找到合适 chunk 后切割，一部分分配，剩余放入 unsorted bin
7. 若都没有合适 chunk，操作 top chunk：
   - top chunk 够大 → 分割为 User chunk + Remainder chunk（新 top chunk）
   - top chunk 不够 → 通过 sbrk（main arena）或 mmap（thread arena）扩容
8. top chunk 也不满足：主分配区调用 sbrk() 增加 top chunk；非主分配区调用 mmap 分配新 sub-heap
9. 若所需 chunk 大小 ≥ mmap 分配阈值（默认 128KB），直接 mmap 分配
10. 首次调用 malloc 时，主分配区需要先初始化，分配 `(chunk_size + 128KB) align 4KB` 作为初始 heap

**简而言之：** 获取分配区(arena)并加锁 → fast bin → unsorted bin → small bin → large bin → top chunk → 扩展堆

### 内存回收流程（free）

![](https://cdn.nlark.com/yuque/0/2025/webp/50402827/1755763951657-70a04486-3b92-4cf0-a150-7b611ba4b3a5.webp)

详细步骤：

1. 获取分配区的锁，保证线程安全
2. 若 free 空指针，则返回
3. 判断当前 chunk 是否是 mmap 映射的（M 标志），若是直接 munmap() 释放
4. 判断 chunk 是否与 top chunk 相邻，若相邻直接合并到 top chunk，转到步骤 8
5. 若 chunk 大小 > max_fast（64b），放入 unsorted bin，检查是否有合并情况
6. 若 chunk 大小 < max_fast（64b），直接放入 fast bin（无合并则 free）
7. 在 fast bin 中，若当前 chunk 的下一个 chunk 也空闲，合并后放入 unsorted bin。合并后大小 > 64B 会触发 fast bins 合并操作，合并后的 chunk 和 top chunk 相邻则合并到 top chunk
8. 判断 top chunk 大小是否大于 mmap 收缩阈值（默认 128KB），若是则尝试归还一部分给操作系统

### 主分配区和非主分配区

ptmalloc 为解决多线程锁争夺问题，分为主分配区 main_arena 和非主分配区 non_main_arena：

1. 主分配区和非主分配区形成环形链表管理
2. 每个分配区利用互斥锁使线程对该分配区的访问互斥
3. 每个进程只有一个主分配区，可有多个非主分配区
4. ptmalloc 根据争用动态增加分配区数量，一旦增加则不会减少
5. 主分配区可用 brk 和 mmap 分配，非主分配区只能用 mmap
6. 申请小内存时产生内存碎片，ptmalloc 整理时需要加锁

**线程分配内存流程：** 查看线程私有变量是否已有分配区 → 存在则尝试加锁 → 加锁成功则使用该分配区 → 失败则遍历循环链表获取未加锁分配区 → 若整个链表都无未加锁分配区 → malloc 开辟新分配区加入循环链表并加锁 → 使用该分配区分配内存。

### 难点与易错点

**难点 1：空间复用导致的"向前借空间"**

使用中的 chunk 可以借用下一个 chunk 的 prev_size 域（4 字节）。这是因为下一个 chunk 在自身空闲之前不会需要 prev_size。实际分配大小：
```
in_use_size = (用户请求大小 + 8 - 4) align to 8 bytes
```
加 8 是存储 prev_size 和 size，减 4 是借用了下一个 chunk 的 prev_size。

**难点 2：fastbin 不合并机制**

fastbin 中的 chunk 释放后不会立即与相邻空闲 chunk 合并，目的是最大化小内存分配速度。只有当特定条件触发（如 malloc 遍历 fastbin 或请求合并后大小 > max_fast）时才会合并。这导致 fastbin 可能持有大量碎片。

**难点 3：mmap 分配的内存不经过 free 链表**

mmap 分配的内存在 free 时直接 munmap，不经过任何 bin 或链表。这就是为什么空闲 chunk 没有 M 状态位——它们根本不会出现在空闲链表中。

### 经验总结（补充）

1. ptmalloc 的多级 bin 架构体现了**分层缓存**思想：fastbin（L1 热缓存）→ unsorted bin（L2 缓存区）→ smallbin/largebin（L3 冷缓存）→ top chunk（主内存池）
2. 默认 128KB 的 mmap 阈值意味着：超过此大小的分配直接走 mmap，free 立即归还给 OS；小于此的走堆分配（brk），free 后不一定归还
3. 分配区数量只增不减的设计在高并发场景可能导致 arena 数量爆炸（tearing down 的线程 arena 不会回收）

## 六、面试准备（高频问法≥10个，反问点/一句话答案≥5个，均带回答）

### 6.1 高频问法（≥10个）

**基础理解：**

Q1：ptmalloc 是什么？为什么需要它？

A：ptmalloc 是 glibc 的默认用户态内存分配器。它通过批量从内核申请内存（brk/mmap）并在用户态管理（chunk/bin），避免每次 malloc/free 都陷入内核态，大幅提升小内存分配效率。

Q2：chunk 的结构是怎样的？使用中和空闲时有何区别？

A：chunk 包含 prev_size、size（含 A/M/P 标志位）、fd、bk 等字段。使用中时 fd/bk 等指针空间归用户使用；空闲时 fd/bk 用于形成双向链表。large bin 空闲 chunk 还有 fd_nextsize/bk_nextsize 用于按大小排序。

Q3：fastbin、smallbin、largebin 的区别是什么？

A：
- fastbin：16-160 字节，单链表（LIFO），不合并，最快
- smallbin：32-1024 字节，双向链表（FIFO），合并相邻 chunk
- largebin：>1024 字节，双向链表+按大小排序，合并相邻 chunk

**原理深入：**

Q4：ptmalloc 的 malloc 流程是怎样的？

A：获取 arena 锁 → fastbin → smallbin → 合并 fastbin 到 unsorted bin → 遍历 unsorted bin（匹配/归类到 smallbin/largebin）→ largebin → top chunk → sbrk/mmap 扩容。（10 步详细流程见上文）

Q5：unsorted bin 的作用是什么？

A：unsorted bin 是 chunk 缓存区，存储刚释放的或从 fastbin 合并来的 chunk。其核心目的是**回收小块内存，解决内存碎片问题**。malloc 时 unsorted bin 中的 chunk 会被分类到合适的 smallbin/largebin。

Q6：ptmalloc 如何处理多线程并发？

A：通过主分配区和非主分配区机制：每个 arena 有独立互斥锁，线程动态获取空闲 arena。线程首次 malloc 时尝试获取已存在的 arena 锁，失败则创建新 arena。arena 数量只增不减。

**实践应用：**

Q7：为什么会有内存碎片？ptmalloc 如何应对？

A：频繁分配和释放不同大小的内存会导致外部碎片（空闲内存块之间无法合并成连续大块）。ptmalloc 通过合并相邻空闲 chunk（coalescing）、unsorted bin 缓存、以及 large bin 的 size-sorted 链表来缓解。

Q8：mmap 分配阈值是什么？调优有什么影响？

A：默认 128KB（`M_MMAP_THRESHOLD`）。超过此值的分配直接用 mmap（而非 brk），free 时立即归还 OS。降低阈值可减少内存占用但增加系统调用；提高阈值可提升大块分配性能但内存不易归还。

Q9：tcmalloc 和 jemalloc 相比 ptmalloc 有什么优势？

A：tcmalloc 用 per-thread cache 减少锁竞争；jemalloc 用 size class + per-CPU cache 减少碎片和伪共享。两者在多线程高并发场景通常优于 ptmalloc。例如 Redis 默认使用 jemalloc。

Q10：为什么要避免频繁的 malloc/free？替代方案是什么？

A：频繁 malloc/free 导致：1) arena 锁竞争 2) 内存碎片 3) 系统调用开销。替代方案：内存池（预分配大块自行管理）、对象池（固定大小对象复用）、使用 pmr（C++17 多态分配器）。

### 6.2 反问点/陷阱点（≥5个）

**针对面试官的深度问题：**

- 贵公司在生产环境中使用哪个内存分配器？有没有针对特定负载做过分配器参数调优？
- 在遇到内存碎片问题时，团队是如何定位和解决的？有没有使用过 malloc_info/malloc_stats 等工具？

**常见陷阱问题：**

- 陷阱 1："free 后的内存是否立即归还给操作系统？" — 不一定。小内存（<128KB）free 后放入空闲链表或合并到 top chunk，不立即归还 OS。只有 mmap 分配的大内存（默认 >128KB）free 时才立即 munmap。
- 陷阱 2："`new` 和 `malloc` 的关系？" — `new` 底层调用 `operator new`，通常实现为对 `malloc` 的封装，额外调用构造函数。`delete` 同样底层通过 `free` 释放。
- 陷阱 3："为什么多线程程序中每个线程第一次 malloc 比较慢？" — 因为需要尝试获取 arena 锁或创建新 arena，涉及系统调用（mmap 初始化堆）。

### 6.3 一句话答案（≥5个）

- ptmalloc 的核心是：以 chunk 为基本单元，通过 fastbin/smallbin/largebin/unsorted bin 多级链表管理空闲内存的 glibc 默认分配器。
- 使用 ptmalloc 的关键是：理解其"惰性归还"特性，大内存用 mmap、小内存走堆，避免碎片化。
- 避免 ptmalloc 的常见陷阱是：以为 free 后内存就还给 OS——小内存可能永远不归还直到进程退出。
- ptmalloc 做对了但 tcmalloc 做得更好的是：线程局部缓存减少锁竞争，这在 64 核+场景下差距 10 倍以上。
- 调试 ptmalloc 内存问题的方法是：`malloc_info()`、`malloc_stats()`、`mtrace()` 和 valgrind massif。
- 当被问到"内存分配器如何选"时回答："ptmalloc 适合通用单线程/低并发场景；tcmalloc 适合线程频繁创建销毁；jemalloc 适合长生命周期多线程服务（减少碎片和内存占用）。"

## 附录（模板外原内容收纳）

> 原笔记中的全部图片链接已保留在正文中。
>
> 原内容核心数据结构定义已完整保留。
>
> malloc/free 的 10 步详细流程已完整纳入第五节。
