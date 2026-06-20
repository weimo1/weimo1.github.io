---
title: io_uring
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "网络编程"]
publish: true
---

# io_uring

[[译] Linux 异步 I/O 框架 io\_uring：基本原理、程序示例与性能压测（2020）](https://arthurchiao.art/blog/intro-to-io-uring-zh/)

## 1. 什么是 `io_uring`

`io_uring` 是 Linux 5.1 及更高版本引入的一种高效异步 I/O 机制, 它提供了一个基于环形队列的接口, 用于高性能的异步 I/O 操作。它的设计目的是减少系统调用开销, 降低上下文切换的频率, 从而提升 I/O 性能。

### 1.1 主要特点

* 环形队列: `io_uring` 使用两个环形队列——提交队列(Submission Queue, SQ)和完成队列(Completion Queue, CQ)。应用程序将 I/O 请求放入提交队列, 内核处理这些请求并将结果放入完成队列。
* 批量处理: `io_uring` 支持批量提交和处理 I/O 请求, 通过减少系统调用次数来提高效率。(原来需要多次系统调用(读或写), 现在变成批处理一次提交。)
* 零拷贝: 支持直接从用户空间到内核空间的数据传输, 减少了不必要的数据拷贝操作。
* 低延迟: 通过减少系统调用和上下文切换的次数, `io_uring` 能够提供比传统 I/O 模型更低的延迟。

### 1.2 与 [IOCP](https://hengxin666.github.io/HXLoLi/docs/%E7%A8%8B%E5%BA%8F%E8%AF%AD%E8%A8%80/C++/tmp%E4%B8%B6C++%E4%B8%B6memo/C++%E7%BD%91%E7%BB%9C%E7%BC%96%E7%A8%8B/Windows%E7%BD%91%E7%BB%9C%E7%BC%96%E7%A8%8B/IOCP/) 的比较

* 设计理念: `io_uring` 和 Windows 的 I/O Completion Ports (IOCP) 都是为了提升异步 I/O 性能而设计的。它们都通过将 I/O 请求和完成事件排入队列来减少系统调用和上下文切换的开销。
* 实现细节:

+ `io_uring`: 在 Linux 中, `io_uring` 使用环形队列来处理提交和完成请求。它允许批量提交请求并批量获取完成事件, 从而减少系统调用的开销。
+ IOCP: 在 Windows 中, IOCP 使用线程池和完成端口来处理异步 I/O 操作。它允许将完成事件与线程池中的线程进行关联, 并使用队列来处理完成事件。

* API 和接口:

+ `io_uring`: 提供了更低层的 API 接口, 允许用户直接操作环形队列。
+ IOCP: 提供了更高级的 API, 通常需要与线程池和事件处理机制配合使用。

## 1.3 三种工作模式

1. 中断驱动模式(interrupt driven)

默认模式。可通过`io_uring_enter()`提交 I/O 请求, 然后直接检查 CQ 状态判断是否完成。

2. 轮询模式(polled)

Busy-waiting for an I/O completion, 而不是通过异步 IRQ(Interrupt Request)接收通知。

这种模式需要文件系统(如果有)和块设备(block device)支持轮询功能。 相比中断驱动方式, 这种方式延迟更低([连系统调用都省了](https://www.phoronix.com/scan.php?page=news_item&px=Linux-io_uring-Fast-Efficient)), 但可能会消耗更多 CPU 资源。

目前, 只有指定了`O_DIRECT`flag 打开的文件描述符, 才能使用这种模式。当一个读或写请求提交给轮询上下文(polled context)之后, 应用(application)必须调用`io_uring_enter()`来轮询 CQ 队列, 判断请求是否已经完成。

对一个 io\_uring 实例来说, 不支持混合使用轮询和非轮询模式。

3. 内核轮询模式(kernel polled)

这种模式中, 会 创建一个内核线程(kernel thread)来执行 SQ 的轮询工作。

使用这种模式的 io\_uring 实例, 应用无需切到到内核态 就能触发(issue)I/O 操作。 通过 SQ 来提交 SQE, 以及监控 CQ 的完成状态, 应用无需任何系统调用, 就能提交和收割 I/O(submit and reap I/Os)。

如果内核线程的空闲时间超过了用户的配置值, 它会通知应用, 然后进入 idle 状态。 这种情况下, 应用必须调用`io_uring_enter()`来唤醒内核线程。如果 I/O 一直很繁忙, 内核线性是不会`sleep`的。

## 2. 如何使用

### 2.1 原生调用

1. 初始化 `io_uring`:

```
struct io_uring ring;
io_uring_queue_init(QUEUE_SIZE, &ring, 0);
```

2. 准备请求:

```
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_readv(sqe, fd, &iov, 1, 0);
```

3. 提交请求:

```
io_uring_submit(&ring);
```

4. 等待和处理完成:

```
struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);
io_uring_cqe_seen(&ring, cqe);
```

5. 关闭 `io_uring`:

```
io_uring_queue_exit(&ring);
```

omg, 有点麻烦, pip 库! 我要库! わくわく!~ (不是哥们, 这里不是python捏)

### 2.2 liburing库

#### 2.2.1 初始化和退出

```
#include <liburing.h>

int main() {
    io_uring ring;
    /**
     * @brief 初始化长度为 32 (一般是2的幂) 的环形队列
     * 给 ring,
     * tag 是 0, 即没有标志
     */
    io_uring_queue_init(32, &ring, 0);

    // C语言魅力时刻 (因为他们没有析构函数)
    io_uring_queue_exit(&ring);
    return 0;
}
```

环形队列就是好比一个人在前面拉一个人在后面吃, 这样就不用频繁移动元素

#### 2.2.2 认识环形队列

```
struct io_uring {
    struct io_uring_sq sq; // 请求队列
    struct io_uring_cq cq; // 完成队列 (获取结果)
    unsigned flags;
    int ring_fd;

    unsigned features;
    int enter_ring_fd;
    __u8 int_flags;
    __u8 pad[3];
    unsigned pad2;
};
```

然后队列里面还有: `sqe`、`cqe` (e是指事件, 即完成的表项)

```
/*
 * Library interface to io_uring
 */
struct io_uring_sq {
    unsigned *khead; // 环形的头
    unsigned *ktail; // 环形的尾
    // Deprecated: use `ring_mask` instead of `*kring_mask`
    unsigned *kring_mask;
    // Deprecated: use `ring_entries` instead of `*kring_entries`
    unsigned *kring_entries;
    unsigned *kflags;
    unsigned *kdropped;
    unsigned *array;
    struct io_uring_sqe *sqes; // 提交的待完成任务的表项

    unsigned sqe_head;
    unsigned sqe_tail;

    size_t ring_sz; // 环形缓冲区的长度
    unsigned char *ring_ptr; // 环形缓冲区的基地址

    unsigned ring_mask;
    unsigned ring_entries;

    unsigned pad[2];
};

// 同上
struct io_uring_cq {
    unsigned *khead;
    unsigned *ktail;
    // Deprecated: use `ring_mask` instead of `*kring_mask`
    unsigned *kring_mask;
    // Deprecated: use `ring_entries` instead of `*kring_entries`
    unsigned *kring_entries;
    unsigned *kflags;
    unsigned *koverflow;
    struct io_uring_cqe *cqes;

    size_t ring_sz;
    unsigned char *ring_ptr;

    unsigned ring_mask;
    unsigned ring_entries;

    unsigned pad[2];
};
```

那为什么用环形缓冲区呢, 是因为我们早提交的数据, 他一定是希望早完成, (凡是讲究个先来后到嘛, 不然就会出现某个任务可能永远也轮不到它)

#### 2.2.3 添加任务与获取结果

在上面的`main()`的初始化和删除之间:

```
// 获取任务队列
io_uring_sqe* sqe = io_uring_get_sqe(&ring);
char buf[16];
/**
 * @brief 向任务队列添加异步读任务
 * sqe 需要添加任务的任务队列指针
 * STDIN_FILENO (输入流) fd (启动程序系统自动打开的文件)
 * buf 存放读取结果的数组
 * 16 一般是需要读取的长度(buf.size())
 * 0 文件偏移量
 */
// sqe->user_data = (u_int32_t)&A; 可以存放用户数据
io_uring_prep_read(sqe, STDIN_FILENO, buf, 16, 0);

// 提交任务队列给内核 (为什么不是sqe, 因为sqe是从ring中get出来的, 故其本身就包含了sqe)
io_uring_submit(&ring);

io_uring_cqe* cqe = nullptr;

// 阻塞等待内核, 返回是错误码; cqe是完成队列, 为传出参数
io_uring_wait_cqe(&ring, &cqe);
// io_uring_wait_cqe_timeout() 有带超时时间的

// 在销毁之前, 我们需要取出数据
int res = cqe->res; // 这个就是对应任务的返回值(read的返回值, 即读取的字节数)
// cqe->user_data 这个是 u_int64_t 到时候就可以放置指针, 从而回复协程 

// 销毁完成队列, 不然会一直在里面滞留(占用空间)
io_uring_cqe_seen(&ring, cqe);
```

当然他们也封装了set/get`data64`的方法:

```
// set
// sqe->user_data = (u_int32_t)&A;
io_uring_sqe_set_data64(sqe, (u_int32_t)&A);

// get
// u_int64_t data = cqe->user_data
u_int64_t data = io_uring_cqe_get_data64(cqe);

// 不想要类型强制转换可以使用: 其参数是void *, cqe同
io_uring_sqe_set_data(, void*)
```

注: 但它返回完成, 我们可以协程继续/回调到之前的位置, 此时`buf`已经是收到消息啦~

以上就是基本用法! 当然`io_uring_prep_`开头的还有很多, 支持一般读写/连接...

#### 2.2.4 示例

```
bool IoUringLoop::run(std::optional<std::chrono::system_clock::duration> timeout) {
    ::io_uring_cqe* cqe = nullptr;

    __kernel_timespec timespec = {0, 0}; // 设置超时为无限阻塞

    if (timeout.has_value()) {
        auto duration = timeout.value();
        auto seconds = std::chrono::duration_cast<std::chrono::seconds>(duration).count();
        auto nanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(duration).count() % 1000000000;
        timespec.tv_sec = static_cast<long>(seconds);
        timespec.tv_nsec = static_cast<long>(nanoseconds);
    }

    // 阻塞等待内核, 返回是错误码; cqe是完成队列, 为传出参数
    int res = io_uring_submit_and_wait_timeout(&_ring, &cqe, 1, &timespec, nullptr);
    if (res == -ETIME) {
        return false;
    } else if (res < 0) [unlikely](#) {
        if (res == -EINTR) {
            return false;
        }
        throw std::system_error(-res, std::system_category());
    }

    unsigned head, numGot = 0;
    std::vector<std::coroutine_handle<>> tasks;
    io_uring_for_each_cqe(&_ring, head, cqe) {
        auto* task = reinterpret_cast<IoUringTask *>(cqe->user_data);
        task->_res = cqe->res;
        tasks.emplace_back(task->_previous);
        ++numGot;
    }

    // 手动前进完成队列的头部 (相当于批量io_uring_cqe_seen)
    ::io_uring_cq_advance(&_ring, numGot);
    _numSqesPending -= static_cast<std::size_t>(numGot);
    for (auto&& it : tasks) {
        it.resume();
    }
    return true;
}
```

```
/**
 * @brief 链接超时操作
 * @param lhs 操作
 * @param rhs 空连接的超时操作 (prepLinkTimeout)
 * @return IoUringTask&& 
 */
static IoUringTask &&linkOps(IoUringTask &&lhs, IoUringTask &&rhs) {
    lhs._sqe->flags |= IOSQE_IO_LINK;
    rhs._previous = std::noop_coroutine();
    return std::move(lhs);
}

/**
 * @brief 创建未链接的超时操作
 * @param ts 超时时间
 * @param flags 
 * @return IoUringTask&& 
 */
IoUringTask &&prepLinkTimeout(
    struct __kernel_timespec *ts,
    unsigned int flags
) && {
    ::io_uring_prep_link_timeout(_sqe, ts, flags);
    return std::move(*this);
}

## 一、核心概念

- **定义**：`io_uring` 是 Linux 5.1+ 引入的下一代异步 I/O 框架，通过**共享内存环形队列**（SQ/CQ）实现应用与内核之间的零拷贝、批量 I/O 提交和收割。相比 epoll，io_uring 将"事件通知"升级为"直接 I/O 操作"——不仅告诉你 fd 就绪，还帮你把读写做完
- **关键词**：Submission Queue (SQ)、Completion Queue (CQ)、SQE（提交队列条目）、CQE（完成队列条目）、liburing、IORING_SETUP_SQPOLL（内核轮询）、IOSQE_IO_LINK（链式提交）、fixed buffers/files
- **适用场景/边界**：高并发网络服务器（替代 epoll）、高性能存储（NVMe 直通）、协程框架底层（C++20 协程 + io_uring）。适用 Linux 5.1+，Windows 对应 IOCP

## 二、详细解析（≥200字）

- **原理拆解（三层递进）**：
  - **第一层——双环形队列架构**：SQ（提交队列）存放待处理 I/O 请求（SQE），应用填充 SQE 后更新 tail 指针通知内核；CQ（完成队列）存放已完成结果（CQE），内核写入后更新 head。关键：SQ 和 CQ 都通过 `mmap` 映射到用户空间，用户态和内核态共享同一块内存，实现**零拷贝提交和收割**
  - **第二层——三种工作模式**：(1) 中断驱动（默认）：`io_uring_enter()` 系统调用提交+阻塞等待，CQ 完成通过 IRQ 通知；(2) 轮询模式（IORING_SETUP_IOPOLL）：应用主动轮询 CQ，绕过中断延迟但消耗 CPU；(3) 内核轮询（IORING_SETUP_SQPOLL）：内核线程持续轮询 SQ，应用无需系统调用即可提交 I/O（最低延迟）
  - **第三层——高级特性**：Fixed buffers/files 通过 `io_uring_register` 预注册资源，避免每次 I/O 操作中的 fd 查找和内存 pin/unpin。链式提交（IOSQE_IO_LINK）将多个 SQE 串联为原子操作序列。`io_uring_prep_readv/writev` 支持 scatter/gather I/O
- **关键数据结构/接口**：`io_uring` 含 `sq` + `cq` + `ring_fd`；`io_uring_sqe` 编码单个 I/O 操作；`io_uring_cqe` 含 `res`（结果码/字节数）+ `user_data`（关联用户上下文）；liburing API：`io_uring_queue_init` → `io_uring_get_sqe` → `io_uring_prep_xxx` → `io_uring_submit` → `io_uring_wait_cqe` → `io_uring_cqe_seen` → `io_uring_queue_exit`
- **关键公式**：SQE/CQE 环形队列索引 = `idx & ring_mask`（ring_mask = queue_size - 1，队列大小必须是 2 的幂）

## 三、动手实践（代码案例）

```c++
#include <liburing.h>
#include <fcntl.h>
#include <cstdio>

int main() {
    io_uring ring;
    io_uring_queue_init(32, &ring, 0);

    int fd = open("test.txt", O_RDONLY);
    char buf[4096];

    io_uring_sqe* sqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqe, fd, buf, sizeof(buf), 0);
    io_uring_sqe_set_data(sqe, buf);  // 关联用户数据
    io_uring_submit(&ring);

    io_uring_cqe* cqe;
    io_uring_wait_cqe(&ring, &cqe);
    int bytes = cqe->res;
    if (bytes > 0) printf("read %d bytes: %.*s\n", bytes, bytes, buf);
    io_uring_cqe_seen(&ring, cqe);

    close(fd);
    io_uring_queue_exit(&ring);
}
```

```bash
g++ io_demo.cpp -luring -o io_demo && ./io_demo
```

## 四、进阶应用（≥500字）

### 协程 + io_uring（C++20）

```c++
// 协程 suspend 时将 coroutine_handle 存入 sqe->user_data
// CQE 完成时通过 user_data 恢复协程
auto task = reinterpret_cast<IoUringTask*>(cqe->user_data);
task->_res = cqe->res;
task->_previous.resume();  // 恢复协程继续执行
```

### io_uring vs epoll 对比

| 维度 | epoll | io_uring |
|------|-------|----------|
| 系统调用次数 | 至少 2 次（epoll_wait + read/write） | 1 次（submit and reap） |
| 拷贝次数 | 数据从内核 buf → 用户 buf | 可零拷贝（fixed buffers + mmap） |
| 批量操作 | 需逐个处理就绪事件 | 原生批量提交+批量收割 |
| 文件 I/O | 不支持（仅网络 fd） | 支持所有 fd 类型 |
| 内核版本 | Linux 2.6+ | Linux 5.1+ |

### 关键内核参数

```bash
# 设置内核轮询线程空闲超时（毫秒）
sysctl kernel.io_uring_group=1
# 查看 io_uring 统计
cat /proc/self/io_uring
```

**工程经验**：(1) 队列大小必须是 2 的幂；(2) SQPOLL 模式消耗一个 CPU 核 100%，仅适合延迟极度敏感场景；(3) `user_data` 是 io_uring 与上层框架的桥梁——协程句柄、回调指针都通过它传递；(4) io_uring 彻底改变了 Linux 异步 I/O 格局，但需 5.1+ 内核，容器环境需确认宿主机内核版本。

## 五、源码解析和实践感悟

### 5.1 内核源码解析

#### 1. io_uring 系统调用的核心入口

```c
// fs/io_uring.c - io_uring_setup 系统调用
SYSCALL_DEFINE2(io_uring_setup, u32, entries, struct io_uring_params __user *, params)
{
    struct io_ring_ctx *ctx;
    int ret;

    // 1. 参数验证：队列深度不能超过 4096
    if (entries > IORING_MAX_ENTRIES)
        return -EINVAL;

    // 2. 分配 io_ring_ctx 上下文结构体
    ctx = io_ring_ctx_alloc(params);
    if (!ctx)
        return -ENOMEM;

    // 3. 映射 SQ/CQ 环形缓冲区到用户空间
    ret = io_allocate_scq_urings(ctx, params);
    if (ret)
        goto err;

    // 4. 创建文件描述符返回用户态
    ret = io_uring_get_fd(ctx);
    return ret;
err:
    io_ring_ctx_wait_and_kill(ctx);
    return ret;
}
```

**关键设计**：`io_uring_setup` 一次性完成全部内存映射，后续 `io_uring_enter` 只需操作共享内存，无需额外的内存分配。

#### 2. 提交与收割的核心路径

```c
// io_uring_enter - 提交 SQE 并收割 CQE
SYSCALL_DEFINE6(io_uring_enter, unsigned int, fd, u32, to_submit,
                u32, min_complete, u32, flags, const sigset_t __user *, sig, size_t, sigsz)
{
    struct io_ring_ctx *ctx;
    
    ctx = fd_file->private_data;
    
    // 1. 提交阶段：将 SQE 从 SQ 复制到内核内部队列
    if (to_submit) {
        submitted = io_submit_sqes(ctx, to_submit);
        // 内部调用 io_queue_sqe() 将 SQE 分发到具体的 I/O 处理函数
    }
    
    // 2. 收割阶段：等待 CQE 完成
    if (flags & IORING_ENTER_GETEVENTS) {
        ret = io_cqring_wait(ctx, min_complete);
    }
    
    return submitted;
}
```

**性能关键**：提交和收割可合并在一次系统调用中完成，这是 io_uring 优于 `epoll + read/write` 的根本原因。

#### 3. Fixed Buffer 零拷贝的内部机制

```c
// 注册用户态缓冲区，避免每次 I/O 时的 get_user_pages 调用
static int io_sqe_buffer_register(struct io_ring_ctx *ctx, struct iovec *iov,
                                   int nr_iovs)
{
    // 1. 对每个 iov 调用 get_user_pages 固定内存页
    for (i = 0; i < nr_iovs; i++) {
        ret = get_user_pages_fast(ubuf, nr_pages, FOLL_WRITE, pages);
        // 2. 将物理页信息记录在 ctx->user_bufs 中
        imu->bvec[j].bv_page = pages[j];
        imu->bvec[j].bv_offset = ...;
    }
    // 此后每次 I/O 直接使用已固定的物理页，跳过 get_user_pages
}
```

#### 4. 轮询模式的 busy-wait 核心

```c
// IORING_SETUP_IOPOLL 模式下的完成收割
static int io_do_iopoll(struct io_ring_ctx *ctx, unsigned int *nr_events, long min)
{
    // busy-wait 循环轮询设备驱动
    while (1) {
        list_for_each_entry_safe(req, tmp, &ctx->iopoll_list, list) {
            // 回调块设备驱动的 poll 方法检查完成
            ret = kiocb->ki_filp->f_op->iopoll(kiocb, &nr);
            if (ret == 0) continue;  // 未完成，继续轮询
            io_cqring_fill_event(ctx, req->user_data, ret, 0);
            (*nr_events)++;
        }
        if (*nr_events >= min) break;
        // 持续占用 CPU，直到收获足够完成事件
    }
    return 0;
}
```

### 5.2 实践经验

1. **SQ 深度选择**：高吞吐场景（如文件 I/O）设置 256-512 的 SQ 深度，低延迟场景（如网络 I/O）设置 32-64 即可。SQ 过大浪费内存且增加内核遍历开销。

2. **SQPOLL 模式的适用场景**：仅在 I/O 密度极高且 CPU 核心充足时启用 `IORING_SETUP_SQPOLL`，因为内核轮询线程会持续占用一个 CPU 核心。低负载时内核线程频繁 idle 反而增加延迟。

3. **Fixed Files/Buffers**：对高频 I/O（如数据库存储引擎），注册 fixed files 和 fixed buffers 可跳过每次 I/O 的 fd 查找和 `get_user_pages`，性能提升 5-15%。

4. **LINKED SQEs**：使用 `IOSQE_IO_LINK` 串联多个 SQE（如 `read + process + write`），保证严格有序执行，前一个失败则后续自动跳过。注意链中任一 SQE 使用异步 fd 将使整条链降级为非链路行为。

5. **io_uring_prep_timeout 与协程**：在 C++20 协程集成时，利用 `cqe->user_data` 存储协程句柄，完成时恢复协程。注意 `user_data` 仅 64 位，应存储指针而非嵌入数据。

6. **epoll vs io_uring 选择**：
   | 场景 | 推荐 | 原因 |
   |------|------|------|
   | 通用网络服务 | epoll | 成熟稳定，社区支持好 |
   | 极高并发文件 I/O | io_uring | batch 提交收割，减少 syscall |
   | 低延迟网络 | io_uring + SQPOLL | 消除内核态切换 |
   | 数据库存储层 | io_uring + fixed buffers | 零拷贝路径 |

## 相关笔记

- [epoll](/posts/epoll/) — Linux epoll 多路复用
- [Select](/posts/Select/) — select 多路复用机制
- [Poll](/posts/Poll/) — poll 多路复用机制
- [网络编程](/posts/网络编程/) — 网络编程全景

## 六、面试准备

### 6.1 面试 Q&A

**Q1: io_uring 相比 epoll + non-blocking I/O 的核心优势是什么？**

io_uring 的核心优势在于**批量系统调用**和**共享内存机制**。epoll 模式下，每次 I/O 都需要 `read/write` 系统调用进入内核，N 次 I/O = 2N 次系统调用（epoll_wait + read/write）。io_uring 通过 SQ/CQ 环形队列在用户态和内核态共享内存，一次 `io_uring_enter` 可批量提交多个 SQE 并收割多个 CQE，将系统调用从 O(N) 降为 O(1)。此外，fixed buffers/files 等机制可绕过内核的 `get_user_pages/文件查找` 操作，进一步降低延迟。

**Q2: 解释 io_uring 的三种工作模式及其使用场景。**

1. **中断驱动模式（默认）**：通过 `io_uring_enter` 提交，内核完成后以中断通知用户态检查 CQ。适合大多数通用场景。
2. **轮询模式（IORING_SETUP_IOPOLL）**：用户态 busy-wait 轮询 CQ，不需要中断通知。延迟最低，但持续占用 CPU。适合极低延迟要求的 NVMe/网络场景。
3. **内核轮询模式（IORING_SETUP_SQPOLL）**：内核创建专用线程轮询 SQ，应用提交 SQE 只需写内存不需系统调用。适合持续高流量 I/O，避免反复进出内核态。

**Q3: SQ 和 CQ 环形队列如何实现无锁并发？**

SQ 的生产者是用户态（应用），消费者是内核态。通过 `head` 和 `tail` 指针实现单生产者-单消费者模型：
- 应用更新 `tail`（写入 SQE 后推进），内核读取 `head` 直至追上 `tail`。
- CQ 相反：内核更新 `tail`（写入 CQE），应用读取 `head`。
- 利用内存屏障（memory barrier）保证指针更新的可见性，避免锁开销。

**Q4: io_uring 的 SQPOLL 模式有什么风险？**

1. **CPU 占用**：内核轮询线程持续运行，即使在无 I/O 时也会定期唤醒检查 SQ，消耗一个 CPU 核心。
2. **idle 延迟**：如果内核线程进入 idle（流量下降），下一次提交需额外 `io_uring_enter` 调用唤醒线程，反而增加延迟。
3. **安全性**：SQPOLL 会绕过用户权限检查，需确保内核配置 `kernel.io_uring_disabled` 适当。

**Q5: 如何用 io_uring 实现异步 TCP 服务器？**

```cpp
void async_tcp_server(int port) {
    io_uring ring;
    io_uring_queue_init(QUEUE_DEPTH, &ring, 0);

    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    bind(listen_fd, ...);
    listen(listen_fd, BACKLOG);

    // 提交 accept 请求
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_accept(sqe, listen_fd, NULL, NULL, 0);
    io_uring_submit(&ring);

    while (true) {
        struct io_uring_cqe *cqe;
        io_uring_wait_cqe(&ring, &cqe);
        int conn_fd = cqe->res;  // 新连接的 fd
        io_uring_cqe_seen(&ring, cqe);

        // 异步读取数据
        sqe = io_uring_get_sqe(&ring);
        io_uring_prep_recv(sqe, conn_fd, buf, BUF_SIZE, 0);
        sqe->user_data = conn_fd;  // 关联连接信息
        io_uring_submit(&ring);
    }
}
```

**Q6: io_uring 如何与 C++20 协程集成？**

利用 `cqe->user_data` 存储 `std::coroutine_handle<>`：
```cpp
struct Awaitable {
    bool await_ready() { return false; }
    void await_suspend(std::coroutine_handle<> h) {
        sqe->user_data = reinterpret_cast<uint64_t>(h.address());
        io_uring_submit(&ring);
    }
    int await_resume() { return cqe->res; }
};
```
完成收割时，从 CQE 取出 `user_data` 还原协程句柄并 `resume()`。

**Q7: io_uring 的 LINKED SQEs 有什么用途？**

LINKED SQEs 将多个操作串成原子链，后一个在前一个完成后自动执行。典型场景：
- 先 `read` 再 `write`，保证 `write` 的数据是刚读取的。
- 搭配 `timeout`：`accept + timeout`，超时则 `accept` 失败，避免无限阻塞。
- 前提：链接只对 `io_uring` 原生的异步操作生效（非 `ASYNC` fd 的链会被打断）。

**Q8: io_uring 的安全性风险有哪些？**

1. **共享内存暴露**：SQ/CQ 环形队列映射到用户态，恶意程序可直接读写内核可见内存。
2. **SQPOLL 特权提升**：内核线程以 root 权限运行，可能绕过文件权限检查。
3. **资源耗尽**：恶意填满 SQ 导致内核无限处理。

缓解：Linux 5.12+ 引入 `IORING_REGISTER_RING_FDS` 和 sysctl `kernel.io_uring_disabled`（0=启用, 1=禁用 io_uring_setup, 2=同时禁用 SQPOLL）。

**Q9: 为什么 io_uring 比 libaio 更高效？**

| 对比维度 | libaio | io_uring |
|----------|--------|----------|
| 系统调用 | 提交和收割分离（io_submit + io_getevents） | 一次 enter 同时完成 |
| O_DIRECT 要求 | 必须（否则可能同步执行） | 无要求 |
| 内存拷贝 | 每次需要用户/内核拷贝 | 共享内存，无拷贝 |
| 批量能力 | 有限 | 原生批量 SQE 提交和 CQE 收割 |
| 扩展操作 | 仅限读/写 | 支持 accept/connect/sendmsg/fsync 等 |

**Q10: io_uring 的 Fixed Files 机制如何提升性能？**

每次 I/O 操作通常需要 `fd → struct file*` 的查找（`fget()`）。注册 fixed files 后，`io_uring` 直接将文件引用计数绑定到内部的 `ctx->file_data` 数组上，提交 SQE 时使用索引（而非 fd）直接获取 struct file，跳过 fd 查找和引用计数增减操作。对高频小 I/O（如数百并发连接），减少的 CPU 开销显著。

### 6.2 常见陷阱与面试反问

1. **陷阱**：以为 io_uring 在所有场景下都比 epoll 快。
   **事实**：低并发（<500 fd）时 epoll 的简单性可能带来更低延迟。io_uring 的共享内存+批量提交有额外管理开销。

2. **陷阱**：在 SQPOLL 模式下忘记调用 `io_uring_submit()`。
   **事实**：SQPOLL 只负责轮询已提交的 SQE，不替你提交。仍需显式调用 io_uring_submit 或设置 `IORING_SQ_NEED_WAKEUP`。

3. **陷阱**：将 `cqe->user_data` 当作数据存储而非指针。
   **事实**：`user_data` 是 64 位无类型数据，应存储指针或索引。误将小型数据直接嵌入，可能在指针截断平台上出问题。

4. **反问**：「如果业务中大量使用 io_uring，你如何处理内核版本兼容性问题？」希望听到：最低内核版本检查（5.1+）、运行时特性探测（`io_uring_queue_init_params` + flags 回退）、基于 epoll 的 fallback 路径。

5. **反问**：「内存安全性如何保证？」希望听到：避免在 SQE 和回调间共享未固定内存、fixed buffers 需在 io_uring 生命周期内保持有效、使用 `IORING_OP_READ/WRITE` 后确认 CQE 再释放缓冲区。

### 6.3 一句话答案速记

| 问题 | 一句话答案 |
|------|------------|
| io_uring 核心思想？ | 共享内存环形队列 + 批量提交收割，减少系统调用 |
| SQ vs CQ？ | SQ 存待处理请求，CQ 存完成结果 |
| 为什么比 epoll 快？ | 一次 enter 替代 epoll_wait + read/write 三次调用 |
| SQPOLL 适合谁？ | 高 I/O 密度场景，需一个专用 CPU 核心 |
| fixed buffers 原理？ | 预注册物理页，跳过 get_user_pages |
| LINKED SQEs？ | 链式执行，前完成才走后，失败自动取消后继 |
| 内核版本要求？ | Linux 5.1+（基础），5.12+（安全增强）
```
