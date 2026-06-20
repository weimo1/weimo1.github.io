---
title: mmap
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "内存模型"]
publish: true
---

# mmap

> 适用范围：mmap 内存映射的底层原理、文件映射与匿名映射、页表与缺页异常、共享内存实现、64 位虚拟地址空间

参考链接：

- <https://zhuanlan.zhihu.com/p/1935077455699384086>
- <https://zhuanlan.zhihu.com/p/656876044>
- <https://www.cnblogs.com/vinozly/p/5489138.html>

## 一、核心概念

- **定义**：mmap 是一种内存映射文件的方法，将一个文件或其他对象映射到进程的地址空间，实现文件磁盘地址和进程虚拟地址空间中一段虚拟地址的一一映射关系。进程可以像访问内存一样访问文件。
- **关键词**：mmap、内存映射、文件映射、匿名映射、缺页异常、页表、VMA、共享内存、memfd_create、MSYNC
- **适用场景/边界**：大文件读写（零拷贝）、进程间共享内存、内存分配器的底层实现（malloc 用 mmap 分配大块）、数据库的持久化存储映射；不适用频繁小 I/O（read/write 更高效）、需要细粒度锁控制的并发写入。

## 二、详细解析（≥200字）

### 第一层：mmap 内存映射的三个阶段

**阶段一：进程启动映射，在虚拟地址空间中创建虚拟映射区域**

1. 进程调用 `void* mmap(void* start, size_t length, int prot, int flags, int fd, off_t offset)`
2. 在当前进程虚拟地址空间中，寻找一段空闲的满足要求的连续虚拟地址
3. 为此虚拟区分配一个 `vm_area_struct` 结构并初始化
4. 将新建的虚拟区结构插入进程的虚拟地址区域链表或树中

**阶段二：内核建立文件物理地址与进程虚拟地址的映射**

5. 通过文件描述符找到对应的文件结构体
6. 链接到 `file_operations` 模块，调用内核函数 `int mmap(struct file* filp, struct vm_area_struct* vma)`
7. 通过虚拟文件系统 inode 模块定位到文件磁盘物理地址
8. 通过 `remap_pfn_range` 函数建立页表——此时虚拟地址还没有任何数据关联到主存

**阶段三：缺页异常触发文件内容拷贝到物理内存**

9. 进程的读写操作访问映射地址段，查询页表发现该地址不在物理页面中，引发缺页异常
10. 缺页异常进行一系列判断后，内核发起调页请求
11. 调页过程先在交换缓存空间中寻找，没有则调用 `nopage` 函数把所缺的页从磁盘装入主存
12. 进程即可对这片主存进行读写操作。如果写操作改变了内容，系统自动回写脏页面到对应的磁盘地址（可调用 `msync()` 强制同步）

### 第二层：64 位虚拟地址空间

64 位 CPU 地址空间可分为三个部分：128T 用户空间、128T 内核空间、其他保留空间。x86_64 架构的规范地址要求高 16 位全为 `0`（用户空间）或全为 `1`（内核空间），否则触发 #GP 异常。实际使用 48 位，256T 刚好覆盖。

```
63                47                 0
┌──────────────────┬──────────────────┐
│ 高16位           │ 实际使用的48位    │
└──────────────────┴──────────────────┘
```

48 位虚拟地址由五部分组成：pgd 表偏移（9位）、pud 表偏移（9位）、pmd 表偏移（9位）、ptl 表偏移（9位）、物理页偏移（12位）。每级 9 位是因为一个物理页（4KB）能存储 512 个表项（4KB / 8B = 512 = 2^9）；物理页偏移 12 位是因为 4KB = 2^12。

![](../../资源/图片/yuque_5babcfe1df60.png)

### 第三层：文件映射与匿名映射

- **文件映射**：将文件内容映射到虚拟地址空间，修改内存即修改文件（MAP_SHARED），或私有的 Copy-on-Write（MAP_PRIVATE）
- **匿名映射**：不关联文件（fd = -1），用于分配进程私有内存或共享内存。`malloc` 对大块内存（>128KB）使用 `mmap(MAP_ANONYMOUS)` 而非 `brk()`

## 三、动手实践（代码案例）

### 文件映射示例

```c++
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <iostream>

int main() {
    const char* filepath = "test.txt";
    int fd = open(filepath, O_RDWR | O_CREAT, 0644);
    ftruncate(fd, 4096);  // 扩展文件到 4KB
    
    // 将文件映射到进程地址空间
    char* mapped = static_cast<char*>(
        mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    );
    
    if (mapped == MAP_FAILED) {
        perror("mmap failed");
        return 1;
    }
    
    // 像操作普通内存一样写入文件
    strcpy(mapped, "Hello, mmap!");
    msync(mapped, 4096, MS_SYNC);  // 强制同步到磁盘
    
    munmap(mapped, 4096);
    close(fd);
    return 0;
}
```

### 共享内存：memfd_create + mmap + Unix Domain Socket

发送方进程：
1. `memfd_create` 创建内存文件（调用 `shmem_file_setup` 创建共享内存文件）
2. `mmap(..., MAP_SHARED, ...)` 申请跨进程可共享的物理内存
3. 通过 Unix Domain Socket 的 `sendmsg` 将文件句柄发送出去——内核将 `struct file` 指针封装到 skb 数据包中

接收方进程：`recvmsg` 系统调用取出 `struct file` 指针，在当前进程下申请新文件句柄。本质是共享内核对象 `struct file`，通过不同进程使用同一个 `struct file` 实现共享，同时 VMA 需带 `VM_SHARED` 标记。

![](../../资源/图片/yuque_2628f15c035d.jpeg)

## 四、进阶应用（≥500字）

### 4.1 malloc 与 mmap 的关系

malloc 分配内存时，会分配一块元数据，元数据包含：内存块大小、内存块状态、指向下一/上一内存块的指针、对齐信息、调试信息。对于大块分配（>128KB），`malloc` 直接调用 `mmap` 而非 `brk()`——因为 mmap 分配的內存放在独立的映射区，`free` 时可以直接 `munmap` 归还给 OS，避免堆顶空洞无法收缩的问题。

![](../../资源/图片/yuque_52579bcf7b60.jpeg)

### 4.2 msync 与数据一致性

修改过的脏页面并不会立即更新回文件，而是有一段时间延迟。可调用 `msync(addr, length, MS_SYNC)` 强制同步，确保写入立即保存到文件。对于需要持久化保证的场景（如数据库 WAL），`msync` 是关键操作。

### 4.3 mmap 的优缺点

**优点**：
- 零拷贝：数据直接从磁盘页缓存到用户空间，无需内核→用户缓冲区拷贝
- 懒加载：只有实际访问的页面才会触发缺页异常调入内存（Demand Paging）
- 进程共享：MAP_SHARED 使多个进程可共享同一物理页

**缺点**：
- 无法处理变长文件扩展：mmap 需要固定大小，扩展需 `ftruncate` + 重新映射
- 缺页异常开销：首次访问的每一页都触发 page fault，随机访问大文件时大量 page fault 抵消零拷贝优势
- 地址空间碎片：大量小文件 mmap 导致虚拟地址空间碎片化（32 位系统尤其严重）

### 4.4 mmap 的适用场景

- **RocksDB/LevelDB**：用 mmap 读取 SST 文件，利用 OS 页缓存管理冷热数据
- **MongoDB**（早期版本）：用 mmap 映射数据文件，依赖 OS 管理内存
- **共享内存 IPC**：`memfd_create` + `mmap` + Unix Domain Socket 是现代 Linux 共享内存的标准方案
- **零拷贝文件传输**：`sendfile` 内部依赖页缓存映射，与 mmap 原理相通

## 五、源码解析和实践感悟（≥1000字）

### 5.1 mmap 的缺页异常处理链路

mmap 的核心哲学是"延迟加载"（Demand Paging）——映射时只建立虚拟地址到文件的页表映射，不分配物理内存。首次访问时才触发缺页异常，内核从磁盘读取数据到物理页。这比 `read()` 的优势在于：①只有实际访问的页才占用物理内存；②OS 可以智能地根据内存压力回收干净页（clean page）。

### 5.2 memset 对 mmap 性能的影响

mmap 配合 `MAP_POPULATE` 可以预填充页表（在 mmap 调用时立即触发所有缺页异常），避免后续访问的 page fault 开销。但 `MAP_POPULATE` 将延迟从随机位置移动到 mmap 调用处——对于确实需要全部数据的场景（如数据库加载），这是一次性成本换后续零开销；对于稀疏访问场景，浪费了物理内存。

### 5.3 malloc 元数据的开销

每次 `malloc` 不只是分配用户请求的内存——还有额外的元数据：内存块大小（8B）、内存块状态标志（4B）、前后指针（各 8B）、对齐填充（不定）。对于小对象（如 8B 的 int），元数据开销可能超过实际数据大小。这正是内存池存在的理由——批量分配大块避免逐次元数据开销。

### 5.4 难点与易错点

1. **mmap 失败不一定是内存不足**：`MAP_FIXED` 标志会覆盖已有映射——除非确定地址范围空闲，否则不要用
2. **munmap 时机错误**：释放后继续访问映射地址会导致 SIGSEGV——所有引用该地址的指针必须失效
3. **文件大小与映射长度不匹配**：映射长度超过文件大小 → SIGBUS；文件扩展后旧映射看不到新数据 → 需重新映射
4. **MAP_SHARED 的并发写入**：多进程同时写同一页无同步保证——需要额外的进程间同步机制
5. **fork 后的 mmap 继承**：子进程继承父进程的 mmap 映射——MAP_SHARED 映射父子共享物理页（修改互相可见），MAP_PRIVATE 映射 fork 后触发 COW

### 经验总结

1. **mmap 不是银弹**：对于顺序读取一次的大文件，`read` 通常比 mmap 更快——避免缺页异常的开销和 TLB 压力
2. **适合随机访问模式**：数据库的随机读场景，mmap + OS 页缓存比自定义缓存更简单可靠
3. **共享内存是现代 IPC 的基石**：`memfd_create` + mmap + Unix Domain Socket 的句柄传递模式是高效的共享内存方案
4. **malloc 对大内存用 mmap**：>128KB 的分配走 mmap 而非 brk——`free` 时 `munmap` 归还给 OS，避免堆顶空洞问题

## 六、面试准备

### 6.1 高频问法（≥10个）

**Q1：mmap 是什么？和 read/write 的区别？**
A：mmap 将文件映射到进程虚拟地址空间，访问像内存一样。read/write 需要内核→用户缓冲区拷贝，mmap 零拷贝（直接访问页缓存）。mmap 适合随机访问，read 适合顺序访问一次的场景。

**Q2：mmap 的三个阶段是什么？**
A：①进程创建 VMA（虚拟内存区域）并插入地址空间；②内核建立页表映射（文件物理地址→虚拟地址）；③首次访问触发缺页异常，将磁盘数据加载到物理内存。

**Q3：MAP_SHARED 和 MAP_PRIVATE 的区别？**
A：MAP_SHARED——多个进程共享同一物理页，修改互相可见且回写文件；MAP_PRIVATE——进程间 Copy-on-Write，修改不影响到其他进程也不回写文件。

**Q4：什么是缺页异常（Page Fault）？mmap 中如何工作？**
A：虚拟地址访问时对应物理页不存在（页表条目无效）时触发的中断。mmap 的首次访问触发 minor/major page fault，内核将磁盘数据读入物理内存并更新页表。

**Q5：malloc 如何利用 mmap？**
A：大块内存（>128KB）分配时，malloc 调用 `mmap(NULL, size, ..., MAP_ANONYMOUS|MAP_PRIVATE, -1, 0)` 而非 brk()。free 时直接 munmap 归还给 OS，避免堆顶空洞。

**Q6：mmap 的内存何时归还给 OS？**
A：匿名映射通过 `munmap` 归还；文件映射的干净页（未修改）可以被 OS 随时回收（因为磁盘上有副本），脏页需要先写回磁盘。

**Q7：64 位虚拟地址中的页表层级结构？**
A：48 位虚拟地址分五层：PGD（9位）→ PUD（9位）→ PMD（9位）→ PTE（9位）→ 页内偏移（12位）。每级 9 位对应 512 个表项，12 位页内偏移对应 4KB 页面。

**Q8：memfd_create + mmap 实现共享内存的流程？**
A：①`memfd_create` 创建匿名文件获取 fd；②`ftruncate` 设置大小；③`mmap` 映射到进程地址空间；④通过 Unix Domain Socket 的 `sendmsg`/`recvmsg` 传递 fd 给其他进程；⑤其他进程同样 mmap 该 fd。

**Q9：msync 的作用是什么？**
A：强制将 mmap 写入的脏页刷新到磁盘。`MS_SYNC` 同步等待完成，`MS_ASYNC` 异步刷新，`MS_INVALIDATE` 使缓存失效（下次访问重新从磁盘读取）。

**Q10：为什么 mmap 比 read 大文件写入可能更慢？**
A：小写入会触发大量 page fault 和 TLB miss。每次写入一个页都需要建立映射、触发缺页。顺序大块写入使用 `write` 更高效（内核批量处理）。

**Q11：MAP_POPULATE 标志有什么作用？**
A：在 mmap 时预填充所有页表，一次性触发所有缺页异常。对于需要全部数据的场景，避免了后续访问的随机 page fault 开销。代价是 mmap 调用本身变慢且占用更多物理内存。

### 6.2 反问点/陷阱点（≥5个）

1. **mmap 的零拷贝是否真的是零？**——只免去了内核→用户缓冲区的一次拷贝。数据从磁盘到页缓存仍是必须的（DMA 传输）。相比 `read` 少一次 CPU 拷贝，但不是零 IO。
2. **mmap 后文件被其他进程 truncate 会怎样？**——SIGBUS 信号！映射范围内的页变为无效，访问即崩溃。处理 SIGBUS 或使用文件锁避免。
3. **fork 后 mmap 的行为？**——子进程继承父进程的 mmap。MAP_SHARED 父子共享同一物理页，MAP_PRIVATE fork 后标记 COW。`fork + exec` 中 MAP_PRIVATE 并无额外开销（因为 exec 会替换整个地址空间）。
4. **为什么 32 位系统很少用 mmap 大文件？**——32 位虚拟地址空间只有 4GB（用户空间通常 3GB），无法映射超过 3GB 的文件。64 位系统 256TB 用户空间消除此限制。
5. **mmap 的 MAP_SHARED 可以替代进程间锁吗？**——不能。MAP_SHARED 只保证同一物理页的可见性，不提供原子性。多进程并发写同一页仍会数据竞争，需要额外的同步机制。
6. **malloc 用 mmap 代替 brk 分配小块可以吗？**——不行。每个 mmap 映射最小 4KB（一个页面），对于 8B 的小分配浪费 99.8% 内存。这就是为什么 malloc 大块用 mmap、小块用 brk。

### 6.3 一句话答案（≥5个）

- mmap 的本质：**虚拟地址到文件物理地址的映射——零拷贝访问文件数据**。
- mmap 的三段论：**创建 VMA → 建立页表映射 → 缺页异常加载数据**。
- MAP_SHARED vs MAP_PRIVATE：**前者共享物理页修改可见，后者 COW 隔离**。
- malloc 用 mmap：**分配 >128KB 时用 mmap 替代 brk——free 可立即归还 OS**。
- 64 位页表结构：**PGD→PUD→PMD→PTE→页内偏移，每级 9 位索引 512 表项**。
- 共享内存 = **memfd_create + mmap + sendmsg 传 fd——共享的是 `struct file`**。
- msync = **强制脏页刷盘：MS_SYNC 同步等待，MS_ASYNC 异步，MS_INVALIDATE 废弃缓存**。

## 附录（原内容收纳）

> 本文原有 mmap 三阶段详解、64 位虚拟地址空间分析、页表层级结构、共享内存实现原理等内容已在各节中整合覆盖。
