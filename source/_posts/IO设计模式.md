---
title: IO设计模式
date: 2026-06-20
categories:
  - ["项目学习", "设计模式"]
publish: true
---

# IO设计模式

# **两种高性能服务器模型Reactor、Proactor**

**Reactor模型：**   
1 向事件分发器注册事件回调   
2 事件发生   
4 事件分发器调用之前注册的函数   
4 在回调函数中读取数据，对数据进行后续处理   
Reactor模型实例：libevent，Redis、ACE

**Proactor模型：**   
1 向事件分发器注册事件回调   
2 事件发生   
3 操作系统读取数据，并放入应用缓冲区，然后通知事件分发器   
4 事件分发器调用之前注册的函数   
5 在回调函数中对数据进行后续处理   
Preactor模型实例：ASIO

reactor和proactor的主要区别：

### 主动和被动

以主动写为例：   
Reactor将handle放到select()，等待可写就绪，然后调用write()写入数据；写完处理后续逻辑；   
Proactor调用aoi\_write后立刻返回，由内核负责写操作，写完后调用相应的回调函数处理后续逻辑；

可以看出，Reactor被动的等待指示事件的到来并做出反应；它有一个等待的过程，做什么都要先放入到监听事件集合中等待handler可用时再进行操作；   
Proactor直接调用异步读写操作，调用完后立刻返回；

### 实现

Reactor实现了一个被动的事件分离和分发模型，服务等待请求事件的到来，再通过不受间断的同步处理事件，从而做出反应；

Proactor实现了一个主动的事件分离和分发模型；这种设计允许多个任务并发的执行，从而提高吞吐量；并可执行耗时长的任务（各个任务间互不影响）

### 优点

Reactor实现相对简单，对于耗时短的处理场景处理高效；   
操作系统可以在多个事件源上等待，并且避免了多线程编程相关的性能开销和编程复杂性；   
事件的串行化对应用是透明的，可以顺序的同步执行而不需要加锁；   
事务分离：将与应用无关的多路分解和分配机制和与应用相关的回调函数分离开来，

Proactor性能更高，能够处理耗时长的并发场景；

### 缺点

Reactor处理耗时长的操作会造成事件分发的阻塞，影响到后续事件的处理；

Proactor实现逻辑复杂；依赖操作系统对异步的支持，目前实现了纯异步操作的操作系统少，实现优秀的如windows IOCP，但由于其windows系统用于服务器的局限性，目前应用范围较小；而Unix/Linux系统对纯异步的支持有限，应用事件驱动的主流还是通过select/epoll来实现；

### 适用场景

Reactor：同时接收多个服务请求，并且依次同步的处理它们的事件驱动程序；   
Proactor：异步接收和同时处理多个服务请求的事件驱动程序；

## 五、源码解析和实践感悟

### 5.1 源码解析

#### Reactor 模式的核心骨架

```cpp
// Reactor 事件循环的精简实现
class Reactor {
    int epoll_fd_;
    std::unordered_map<int, EventHandler*> handlers_;
public:
    void register_handler(int fd, EventHandler* handler, uint32_t events) {
        struct epoll_event ev;
        ev.events = events;
        ev.data.ptr = handler;
        epoll_ctl(epoll_fd_, EPOLL_CTL_ADD, fd, &ev);
        handlers_[fd] = handler;
    }

    void loop() {
        struct epoll_event events[MAX_EVENTS];
        while (running_) {
            int n = epoll_wait(epoll_fd_, events, MAX_EVENTS, -1);
            for (int i = 0; i < n; ++i) {
                auto* handler = static_cast<EventHandler*>(events[i].data.ptr);
                if (events[i].events & EPOLLIN)  handler->handle_read();
                if (events[i].events & EPOLLOUT) handler->handle_write();
            }
        }
    }
};
```

关键设计：epoll 只负责通知"fd 就绪"，具体读/写由 handler 自行完成——这是 Reactor 与 Proactor 的本质区别。

#### Proactor 模式（以 IOCP 为例）

```cpp
// Proactor —— 内核替你完成 I/O
void proactor_loop() {
    HANDLE iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);
    DWORD bytes_transferred;
    ULONG_PTR completion_key;
    OVERLAPPED* overlapped;
    
    while (true) {
        GetQueuedCompletionStatus(iocp, &bytes_transferred,
                                  &completion_key, &overlapped, INFINITE);
        auto* op = CONTAINING_RECORD(overlapped, IoOperation, overlapped_);
        op->complete(bytes_transferred);  // 数据已由内核写入缓冲区
    }
}
```

Proactor 模式下，`ReadFile`/`WriteFile` 交给内核异步执行，完成后直接通知回调——应用从不主动读/写。

#### Asio 如何用 Reactor 模拟 Proactor

```cpp
// Asio 在 Linux 上的 Proactor 模拟
void async_read(socket& s, buffer buf, handler h) {
    // 1. 向 Reactor(epoll) 注册 EPOLLIN 事件
    s.async_wait(EPOLLIN, [&s, buf, h](error_code ec) {
        // 2. 事件就绪后，同步 read 数据到用户缓冲区
        size_t n = ::read(s.native_handle(), buf.data(), buf.size());
        // 3. 将结果传给用户回调
        h(ec, n);
    });
}
```

Asio 对外暴露 Proactor 接口（`async_read`、`async_write`），内部在 Linux 上用 epoll + 同步 I/O 模拟 Proactor 语义。

### 5.2 实践经验

1. **Reactor 选 epoll 的 ET 模式**：高并发场景 ET 比 LT 减少 epoll 触发次数，但要求每次读必须读到 EAGAIN，否则丢失事件
2. **Proactor 并不等于更高性能**：Windows IOCP 是真正的异步 I/O，但 Linux 的 io_uring 出现前，Asio 只是用 Reactor 模拟 Proactor，实际仍是同步 I/O
3. **Reactor 中耗时操作必须异步化**：回调中耗时 > 1ms 的操作应投递到线程池，避免阻塞事件循环
4. **Proactor 适合大块 I/O**：读写大文件时 Proactor 优势明显（内核直接搬运数据），小包场景 Reactor 反而更轻量
5. **混合使用不矛盾**：实际项目中可以将 Reactor 用于网络 I/O，配合线程池处理 CPU 密集型计算
6. **避免在 Reactor 线程中做阻塞操作**：包括 printf/glog 写磁盘、加重量锁、调用 sleep 等

## 六、面试准备

### 6.1 面试 Q&A

**Q1: Reactor 和 Proactor 的本质区别？**

Reactor 是**同步非阻塞 I/O + 事件通知**——内核通知你 fd 就绪，你自己去 read/write。Proactor 是**异步 I/O + 完成通知**——内核替你完成 read/write，完成时通知你。前者"你主动去取"，后者"内核送上门"。

**Q2: 为什么说 Asio 在 Linux 上是模拟 Proactor？**

Linux 原生不支持真正的异步 I/O（io_uring 出现前），Asio 用 epoll 监听 fd 就绪事件，回调中执行同步 read/write，包装成 Proactor 接口。Windows IOCP 才是原生 Proactor。

**Q3: Reactor 单线程 vs 多线程的权衡？**

单线程 Reactor（如 Redis）：回调串行执行，无需加锁，适合纯内存操作。多线程 Reactor（如 Memcached）：主线程 accept，子线程处理 I/O，利用多核但需考虑数据竞争。

**Q4: epoll 的 LT/ET 在 Reactor 中的选择？**

LT 更安全（没读完下次继续通知），适合简单场景。ET 要求一次读完直到 EAGAIN，减少系统调用但容易出错——漏读会导致事件永远不再触发。

**Q5: 为什么游戏服务器多用 Reactor 而非 Proactor？**

游戏服务器 I/O 密集但单包小，Reactor 的同步 I/O + epoll 足以应对（C10K）。Proactor 的异步编程复杂度高，而 io_uring 之前的 Linux 异步 I/O（libaio）对网络支持差。

**Q6: Reactor 模式下如何避免回调地狱？**

C++20 协程（co_await 挂起点）、状态机（每个回调推进一步状态）、future/promise 链式调用。C 语言的 libuv 用回调嵌套，C++ 的 Asio 用 completion token 实现多种回调风格。

**Q7: 主从 Reactor 多线程模型（muduo）的核心思想？**

主 Reactor 只负责 accept，将新连接分发给从 Reactor。每个从 Reactor 独占一个线程 + 一个 epoll 实例。优势：无锁（每个连接固定在一个线程处理）、利用多核、避免惊群。

**Q8: Proactor 在 Windows 和 Linux 上的实现差异？**

| 维度 | Windows IOCP | Linux io_uring |
|------|-------------|---------------|
| 接口 | ReadFile/WriteFile + OVERLAPPED | io_uring_submit/io_uring_wait_cqe |
| 线程模型 | 完成端口 + 线程池 | 用户自行管理线程 |
| 缓冲区 | 需固定（不能释放直到完成） | 需固定或使用 fixed buffers |
| 网络/文件 | 均支持 | 均支持（Linux 5.1+） |

### 6.2 常见陷阱与面试反问

1. **陷阱**：ET 模式下一次没读完就返回，后续事件永远丢失。**修复**：循环读取直到 `read() == -1 && errno == EAGAIN`。

2. **陷阱**：Reactor 回调中调用 `close(fd)` 后仍然返回事件循环——下次 epoll 触发该 fd 导致访问已释放内存。**修复**：先 `epoll_ctl(DEL)` 再 `close`。

3. **陷阱**：多 Reactor 线程模型中新连接全分给一个线程，负载严重不均。**修复**：Round-Robin 或最少连接数调度。

4. **反问**：「如果让你在 Linux 上从零实现一个高性能网络库，你会选 Reactor 还是 Proactor（io_uring）？」希望听到：io_uring 是未来方向但内核版本要求高（5.1+），Reactor + epoll 成熟稳定兼容性好；具体看目标环境的内核版本和性能需求。

5. **反问**：「如何解决 Reactor 中一个慢回调阻塞整个事件循环？」希望听到：将慢操作异步化（投递线程池）、设置超时、独立出慢任务通道、监控回调耗时。

### 6.3 一句话答案速记

| 问题 | 一句话答案 |
|------|------------|
| Reactor 核心？ | 事件就绪通知 + 同步 I/O，自己调用 read/write |
| Proactor 核心？ | I/O 完成通知 + 异步 I/O，内核替你 read/write |
| Asio 的 Reactor 模拟 Proactor？ | epoll 监听就绪 → 回调中同步 read → 伪装成异步完成 |
| ET vs LT 选择？ | LT 安全简单，ET 高效但必须读到 EAGAIN |
| 主从 Reactor 优势？ | 无锁 + 多核利用 + 避免惊群 |
| Reactor 适合场景？ | 高并发小包，如 Web 服务、即时通讯 |
| Proactor 适合场景？ | 大块 I/O，如文件传输、视频流
