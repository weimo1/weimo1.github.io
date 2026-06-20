---
title: Poll
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "网络编程"]
publish: true
---

# Poll

> 适用范围：Linux poll(2) 系统调用、多路复用IO、pollfd结构体、内核poll_wait机制、与select对比

## 一、核心概念

- **定义**：`poll()` 是 Linux 提供的 IO 多路复用系统调用，允许同时监视多个文件描述符的读写就绪状态。与 select 不同，poll 使用 `struct pollfd` 链表管理事件，没有 FD_SETSIZE 的数量限制
- **关键词**：pollfd、nfds_t、POLLIN/POLLOUT、do_sys_poll、poll_wait、revents、内核轮询
- **适用场景/边界**：
  - 需要同时监听数十到数百个文件描述符（select 只能处理 <1024 个）
  - 不需要高性能（<1000 连接），作为 epoll 前的过渡方案
  - 边界：与 select 同为 O(n) 轮询，大规模连接（>1000）性能急剧下降，应使用 epoll

## 二、详细解析（≥200字）

### 2.1 poll 改进了什么

poll(2) 和 select(2) 类似，没有本质差别，管理多个描述符也是进行轮询，根据描述符的状态进行处理。但是 poll(2) 用链表管理监视事件，没有最大描述符数量的限制，并且传入的 fds 在 poll(2) 函数返回后不会清空，就绪事件记录在 revents 成员中。

```c
#include <poll.h>
int poll(struct pollfd *fds, nfds_t nfds, int timeout);

/// include/uapi/asm-generic/poll.h
struct pollfd {
    int fd;
    short events;
    short revents;
};
```

### 2.2 poll vs select 对比

| 特性 | select | poll |
| --- | --- | --- |
| 最大fd数 | FD_SETSIZE (1024) | 无限制（链表） |
| 数据结构 | fd_set位图 | pollfd数组 |
| 返回后状态 | 清空，需重新设置 | 不清空，revents记录就绪 |
| 时间复杂度 | O(n) 轮询 | O(n) 轮询 |
| 可移植性 | POSIX 广泛支持 | POSIX，但不如select普遍 |

## 三、动手实践（代码案例）

### 3.1 do_sys_poll() 拷贝数据

当调用 poll() 系统调用后，kernel 处理逻辑如下：

* 1）转换超时时间，将其转换为绝对时间（微秒级）
* 2）调用 do\_sys\_poll() 函数处理
* 3）拷贝剩余时间

```
/// fs/select.c
SYSCALL_DEFINE3(poll, struct pollfd __user *, ufds, unsigned int, nfds,
                int, timeout_msecs)
{
    struct timespec64 end_time, *to = NULL;
    int ret;

    if (timeout_msecs >= 0) { // 转换超时事件，微秒级
        to = &end_time;
        poll_select_set_timeout(to, timeout_msecs / MSEC_PER_SEC,
                                NSEC_PER_MSEC * (timeout_msecs % MSEC_PER_SEC));
    }

    ret = do_sys_poll(ufds, nfds, to); // 轮询

    if (ret == -ERESTARTNOHAND) {
        struct restart_block *restart_block;

        restart_block = &current->restart_block;
        restart_block->poll.ufds = ufds;
        restart_block->poll.nfds = nfds;

        if (timeout_msecs >= 0) {
            restart_block->poll.tv_sec = end_time.tv_sec;
            restart_block->poll.tv_nsec = end_time.tv_nsec;
            restart_block->poll.has_timeout = 1;
        } else
            restart_block->poll.has_timeout = 0;

        ret = set_restart_fn(restart_block, do_restart_poll);
    }
    return ret;
}
```

和 select(2) 一样，poll(2) 也会预先在栈空间申请大小为 POLL\_STACK\_ALLOC 的内存，栈空间可以处理 30 个文件描述符。不过和 select(2) 不同的是，即使栈空间太小，要从堆上申请内存，预先分配的栈空间也是被使用的。

```
/// fs/select.c
static int do_sys_poll(struct pollfd __user *ufds, unsigned int nfds,
                       struct timespec64 *end_time)
{
    struct poll_wqueues table;
    int err = -EFAULT, fdcount, len;
    /* Allocate small arguments on the stack to save memory and be
       faster - use long to make sure the buffer is aligned properly
       on 64 bit archs to avoid unaligned access */
    long stack_pps[POLL_STACK_ALLOC/sizeof(long)]; // 预先分配 256B
    struct poll_list *const head = (struct poll_list *)stack_pps;
    struct poll_list *walk = head;
    unsigned long todo = nfds;

    if (nfds > rlimit(RLIMIT_NOFILE))
        return -EINVAL;

    len = min_t(unsigned int, nfds, N_STACK_PPS);
    for (;;) {
        walk->next = NULL;
        walk->len = len;
        if (!len)
            break;
        // 从用于空间拷贝到内核空间
        if (copy_from_user(walk->entries, ufds + nfds-todo,
                           sizeof(struct pollfd) * walk->len))
            goto out_fds;

        todo -= walk->len;
        if (!todo)
            break;
        // 一次最大申请一页，可以 510 个文件描述符 
        len = min(todo, POLLFD_PER_PAGE);
        walk = walk->next = kmalloc(struct_size(walk, entries, len),
                                    GFP_KERNEL);
        if (!walk) {
            err = -ENOMEM;
            goto out_fds;
        }
    }

    poll_initwait(&table);
    fdcount = do_poll(head, &table, end_time);
    poll_freewait(&table);

    if (!user_write_access_begin(ufds, nfds * sizeof(*ufds)))
        goto out_fds;
    // 将结果从内核空间拷贝到用户空间
    for (walk = head; walk; walk = walk->next) {
        struct pollfd *fds = walk->entries;
        int j;

        for (j = walk->len; j; fds++, ufds++, j--)
            unsafe_put_user(fds->revents, &ufds->revents, Efault);
    }
    user_write_access_end();

    err = fdcount;
    out_fds:
    walk = head->next;
    while (walk) {
        struct poll_list *pos = walk;
        walk = walk->next;
        kfree(pos);
    }

    return err;

    Efault:
    user_write_access_end();
    err = -EFAULT;
    goto out_fds;
}
```

### do\_poll() 轮询检查每一个 fd

和 do\_select() 的原理一样，也是通过轮询的方法查看每个 fd 的状态。

```
/// fs/select.c
static int do_poll(struct poll_list *list, struct poll_wqueues *wait,
                   struct timespec64 *end_time)
{
    poll_table* pt = &wait->pt;
    ktime_t expire, *to = NULL;
    int timed_out = 0, count = 0;
    u64 slack = 0;
    __poll_t busy_flag = net_busy_loop_on() ? POLL_BUSY_LOOP : 0;
    unsigned long busy_start = 0;

    /* Optimise the no-wait case */
    if (end_time && !end_time->tv_sec && !end_time->tv_nsec) {
        pt->_qproc = NULL;
        timed_out = 1;
    }

    if (end_time && !timed_out)
        slack = select_estimate_accuracy(end_time);

    for (;;) { // 主循环
        struct poll_list *walk;
        bool can_busy_loop = false;
        // 处理每个 walk
        for (walk = list; walk != NULL; walk = walk->next) {
            struct pollfd * pfd, * pfd_end;

            pfd = walk->entries;
            pfd_end = pfd + walk->len;
            for (; pfd != pfd_end; pfd++) {
                /*
                 * Fish for events. If we found one, record it
                 * and kill poll_table->_qproc, so we don't
                 * needlessly register any other waiters after
                 * this. They'll get immediately deregistered
                 * when we break out and return.
                 */
                if (do_pollfd(pfd, pt, &can_busy_loop,
                              busy_flag)) {
                    count++;
                    pt->_qproc = NULL;
                    /* found something, stop busy polling */
                    busy_flag = 0;
                    can_busy_loop = false;
                }
            }
        }
        /*
         * All waiters have already been registered, so don't provide
         * a poll_table->_qproc to them on the next loop iteration.
         */
        pt->_qproc = NULL;
        if (!count) {
            count = wait->error;
            if (signal_pending(current))
                count = -ERESTARTNOHAND;
        }
        if (count || timed_out)
            break;

        /* only if found POLL_BUSY_LOOP sockets && not out of time */
        if (can_busy_loop && !need_resched()) {
            if (!busy_start) {
                busy_start = busy_loop_current_time();
                continue;
            }
            if (!busy_loop_timeout(busy_start))
                continue;
        }
        busy_flag = 0;

        /*
         * If this is the first loop and we have a timeout
         * given, then we convert to ktime_t and set the to
         * pointer to the expiry value.
         */
        if (end_time && !to) {
            expire = timespec64_to_ktime(*end_time);
            to = &expire;
        }
        // 睡眠
        if (!poll_schedule_timeout(wait, TASK_INTERRUPTIBLE, to, slack))
            timed_out = 1;
    }
    return count;
}
```

## 四、进阶应用（≥500字）

### 4.1 poll 的性能瓶颈分析

poll 与 select 同属 O(n) 级别的轮询模型，其性能瓶颈在于：
1. **用户态到内核态的数据拷贝**：每次调用 `poll()` 都需要将全部 `struct pollfd` 数组从用户空间复制到内核空间
2. **全量轮询**：内核在所有被监视的 fd 上调用 `poll_wait()`，即使只有个别 fd 就绪
3. **返回后的遍历成本**：用户程序仍需遍历整个 fds 数组检查 `revents` 来找出就绪的 fd

当 fd 数量超过 1000 时，这些瓶颈会导致 CPU 利用率急剧上升，延迟增加。epoll 通过事件驱动 + 红黑树 + 就绪链表三管齐下解决了这些瓶颈。

### 4.2 poll 的内核实现路径

`do_sys_poll()` → 遍历 fds → 为每个 fd 调用 `do_pollfd()` → 将当前进程添加到每个 fd 的等待队列 → 调用 `poll_schedule_timeout()` 休眠等待 → 被唤醒后遍历 `revents` 收集就绪事件 → 返回用户态。

关键数据结构：`struct poll_wqueues` 管理等待队列，`poll_table` 提供 `_qproc` 回调将进程挂到目标文件的等待队列上。

### 4.3 与其他主题的关联

- **select**：同为 O(n) 轮询模型，但 select 受 FD_SETSIZE 限制且每次调用需重置 fd_set
- **epoll**：O(1) 事件驱动模型，是 poll 的高级替代，解决了全量拷贝和全量遍历的瓶颈
- **io_uring**：更现代的异步IO框架，通过共享内存环形缓冲区彻底消除系统调用开销
- **ppoll**：poll 的变体，支持信号掩码控制，在信号处理场景下更安全

### 4.4 工程中的最佳实践

- **<100 fd**：poll 足够好用，代码简单
- **100~1000 fd**：poll 可用但性能开始下降，考虑 epoll
- **>1000 fd**：必须使用 epoll，poll 的延迟不可接受
- **跨平台代码**：优先select（最大兼容性），Windows 不支持 poll（但有 WSAPoll）


## 五、源码解析和实践感悟（≥1000字）

### 5.1 do_sys_poll 核心流程

上述第三节中的源码详细展示了 `do_sys_poll()` 的完整流程：分配 poll_list 链表 → 遍历用户态 fds 注册等待 → 调用 `poll_schedule_timeout()` 休眠 → 被唤醒后遍历 poll_list 收集就绪事件（`count++`）→ 返回用户态。

### 5.2 实践经验

1. **poll 的简单性优势**：API 比 epoll 简单（不需要 epoll_create/epoll_ctl 两步初始化），适合简单场景和原型开发
2. **revents 不清空**：与 select 不同，poll 返回后 `revents` 保留就绪标记，下次调用前需要手动清零
3. **POLLHUP/POLLERR 默认监听**：即使未在 events 中设置，内核也会在 revents 中报告这些异常事件
4. **ppoll 优于 poll**：在信号密集型应用中，`ppoll()` 比 `poll()` + `sigprocmask()` 搭配使用更安全（原子操作避免竞态）
5. **内核 poll_wait 机制**：底层依赖于文件系统的 `poll()` 虚函数（`file->f_op->poll`），socket 的实现是 `sock_poll()`→`tcp_poll()`


## 相关笔记

- [epoll](/posts/epoll/) — Linux epoll 多路复用
- [Select](/posts/Select/) — select 多路复用机制
- [io_uring](/posts/io_uring/) — Linux io_uring 异步 IO
- [网络编程](/posts/网络编程/) — 网络编程全景

## 六、面试准备

### 6.1 面试高频问答

**Q1：poll 相比 select 的核心改进？**

A：(1) 用 pollfd 链表代替 fd_set 位图，无 1024 限制；(2) events/revents 分离，poll 返回后 revents 保持不变无需重置；(3) 支持更多事件类型（POLLRDHUP 等）。

**Q2：poll 仍是 O(n) 的原因？**

A：内核仍遍历整个 pollfd 数组检查状态和注册等待队列，返回后用户仍需遍历检查 revents。epoll 通过就绪链表解决了这个问题。

**Q3：poll 的 events 和 revents 各是什么？**

A：events 是用户设置的关心事件（POLLIN/POLLOUT），revents 是内核返回的就绪事件。poll 不修改 events，只填充 revents。

**Q4：POLLRDHUP 事件的作用？**

A：对端关闭写端（shutdown write）时触发，让服务端区分"对端关闭"和"对端崩溃"。select 不支持此事件。

**Q5：poll 和 epoll 的性能差异在什么数量级？**

A：fd 数 < 100 时差异不大；1000+ 时 poll 每轮遍历开销显著；10000+ 时 poll 不可用而 epoll 仍能高效运行。

### 6.2 陷阱与反问

**陷阱1**：忘记检查 revents 中的 POLLERR/POLLHUP → 异常 fd 被当作正常处理
**陷阱2**：pollfd 数组元素过多 → 栈溢出（建议堆分配或限制数组大小）
**陷阱3**：timeout = 0 时 poll 立即返回，可能空转浪费 CPU

**反问**：为什么 poll 用链表但仍是 O(n)？
*答案：链表只解决了 fd_set 的容量限制，但内核处理逻辑仍是遍历+检查。O(n) 来自"每个 fd 都检查一遍"而非数据结构。*

### 6.3 一句话答案

1. **poll**：select 的升级版，用 pollfd 链表突破 1024 限制
2. **events/revents**：分离输入和输出，无需重置
3. **POLLRDHUP**：对端优雅关闭事件，select 不支持
4. **仍是 O(n)**：内核遍历所有 pollfd 的效率瓶颈
