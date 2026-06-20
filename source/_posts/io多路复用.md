---
title: io多路复用
date: 2026-06-20
categories:
  - ["系统底层408", "计算机网络"]
publish: true
---




---

# **1. select**  
**底层原理补充**：  
- **内核实现**：  
  - 在`fs/select.c`中，`do_select`函数通过遍历`fd_set`位图中的每个fd，调用`vfs_poll`检查设备驱动层的就绪状态。  
  - **时间复杂度**：O(n)，每次调用需遍历所有注册的fd。  

**多连接示例**：  
```c
fd_set read_fds;
int max_fd = listen_sock;
while (1) {
    FD_ZERO(&read_fds);
    FD_SET(listen_sock, &read_fds);
    // 添加所有客户端fd到read_fds
    for (int i = 0; i < client_count; i++) {
        FD_SET(client_fds[i], &read_fds);
        if (client_fds[i] > max_fd) max_fd = client_fds[i];
    }
    // 调用select
    int ret = select(max_fd + 1, &read_fds, NULL, NULL, NULL);
    // 处理新连接
    if (FD_ISSET(listen_sock, &read_fds)) {
        int new_fd = accept(listen_sock, ...);
        client_fds[client_count++] = new_fd;
    }
    // 处理客户端数据
    for (int i = 0; i < client_count; i++) {
        if (FD_ISSET(client_fds[i], &read_fds)) {
            read(client_fds[i], ...);
        }
    }
}
```

---

#  **2. poll**  
**底层原理补充**：  
- **内核实现**：  
  - 在`fs/select.c`中，`do_poll`函数遍历`struct pollfd`数组，对每个fd调用`vfs_poll`。  
  - **时间复杂度**：O(n)，与select相同，但支持动态fd数量。  

**多连接示例**：  
```c
struct pollfd *fds = malloc(MAX_CLIENTS * sizeof(struct pollfd));
fds[0].fd = listen_sock;
fds[0].events = POLLIN;
int nfds = 1;
while (1) {
    int ret = poll(fds, nfds, -1);
    // 处理新连接
    if (fds[0].revents & POLLIN) {
        int new_fd = accept(listen_sock, ...);
        fds[nfds].fd = new_fd;
        fds[nfds].events = POLLIN;
        nfds++;
    }
    // 处理客户端数据
    for (int i = 1; i < nfds; i++) {
        if (fds[i].revents & POLLIN) {
            read(fds[i].fd, ...);
        }
    }
}
```

---

#  **3. epoll**  
**底层原理详细解析**：  
- **核心数据结构**：  
  1. **`struct eventpoll`**：  
     - 定义在`fs/eventpoll.c`中，表示一个epoll实例。  
     - 包含两个关键成员：  
       ```c
       struct rb_root_cached rbr;  // 红黑树根节点，存储所有监听的fd（epitem）
       struct list_head rdllist;   // 就绪队列（rdlist），保存已就绪的epitem
       ```
  2. **`struct epitem`**：  
     - 红黑树节点，代表一个被监听的fd：  
       ```c
       struct epitem {
           struct rb_node rbn;          // 红黑树节点
           struct list_head rdllink;    // 就绪队列链表节点
           struct epoll_filefd ffd;     // 包含被监听的fd和其对应的file指针
           struct eventpoll *ep;        // 指向所属的eventpoll实例
           struct epoll_event event;    // 用户设置的监听事件（EPOLLIN等）
       };  
       ```
  3. **`rdllist`（就绪队列）**：  
     - 双向链表，保存所有已就绪的epitem。当fd有事件触发时，内核通过回调函数`ep_poll_callback`将其添加到rdllist。  

- **关键流程**：  
  1. **`epoll_create`**：  
     - 创建一个`eventpoll`对象，并返回其文件描述符（epfd）。  
  2. **`epoll_ctl`**：  
     - 操作红黑树：添加（EPOLL_CTL_ADD）、删除（EPOLL_CTL_DEL）或修改（EPOLL_CTL_MOD）一个epitem。  
     - 内核调用`ep_insert`函数：  
       - 初始化epitem，注册回调`ep_poll_callback`到设备的等待队列（例如socket的sk_wq）。  
  3. **`epoll_wait`**：  
     - 检查`rdllist`是否为空：  
       - 若不为空，直接拷贝就绪的`epoll_event`到用户空间。  
       - 若为空，进程进入阻塞状态，直到超时或rdllist非空（通过`ep_poll`函数实现）。  

- **回调机制**：  
  - 当socket数据到达时，网卡触发中断，内核协议栈处理数据后，调用socket的唤醒回调（例如`sock_def_readable`）。  
  - 该回调最终调用`ep_poll_callback`，将对应的epitem添加到`rdllist`，并唤醒阻塞在`epoll_wait`的进程。  

**多连接示例**：  
```c
#define MAX_EVENTS 64
int epfd = epoll_create1(0);
struct epoll_event event, events[MAX_EVENTS];
// 监听listen_sock
event.events = EPOLLIN;
event.data.fd = listen_sock;
epoll_ctl(epfd, EPOLL_CTL_ADD, listen_sock, &event);

while (1) {
    int nready = epoll_wait(epfd, events, MAX_EVENTS, -1);
    for (int i = 0; i < nready; i++) {
        if (events[i].data.fd == listen_sock) {
            // 接受新连接
            int new_fd = accept(listen_sock, ...);
            event.events = EPOLLIN | EPOLLET; // ET模式
            event.data.fd = new_fd;
            epoll_ctl(epfd, EPOLL_CTL_ADD, new_fd, &event);
        } else {
            // 处理客户端数据（需一次性读完，ET模式）
            char buf[1024];
            while (1) {
                ssize_t n = read(events[i].data.fd, buf, sizeof(buf));
                if (n <= 0) break; // EAGAIN或EOF
                // 处理数据...
            }
        }
    }
}
```

---

#  关键问题

## **1. select vs poll**

- **数据结构**：
  
    - `select`使用固定大小的`fd_set`位图（上限`FD_SETSIZE`）。
      
    - `poll`使用动态数组`struct pollfd`，无数量限制。
    
- **性能**：两者均为`O(n)`遍历，性能差异不大。

##  **epoll高效的核心原因**  
1. **红黑树管理fd**：  
   - 插入/删除时间复杂度为O(log n)，适合动态增删高并发场景。  
2. **就绪队列（rdllist）**：  
   - 事件触发时，通过回调直接加入队列，`epoll_wait`只需遍历就绪队列（O(1)复杂度）。  
3. **零遍历开销**：  
   - 无需像select/poll全量遍历所有fd，仅处理活跃事件。  

#  **ET vs LT的底层差异**  
- **LT模式**：  
  - 当fd处于就绪状态时，`ep_poll_callback`会不断将epitem加入rdllist，直到状态被处理。  
- **ET模式**：  
  - 仅在fd状态变化时触发一次`ep_poll_callback`，后续即使仍有数据，也不会重复加入rdllist，除非有新事件触发。  

---

# I/O多路复用技术中的用户态/内核态切换与数据拷贝

## **1. select**

### **用户态/内核态切换**  
1. **调用`select`时**：  
   - 用户程序调用`select`，进入内核态。  
   - 内核遍历所有注册的fd，检查其就绪状态。  
2. **返回时**：  
   - 内核将就绪的fd集合（`fd_set`）返回给用户程序，切换回用户态。  

每次调用`select`都会发生**两次用户态/内核态切换**（调用和返回）。

### **数据拷贝**  
1. **调用`select`时**：  
   - 用户程序将`fd_set`（包含所有监听的fd）从用户态拷贝到内核态。  
2. **返回时**：  
   - 内核将修改后的`fd_set`（标记就绪的fd）从内核态拷贝回用户态。  

每次调用`select`都会发生**两次数据拷贝**（传入和传出）。

---

## **2. poll**

### **用户态/内核态切换**  
1. **调用`poll`时**：  
   - 用户程序调用`poll`，进入内核态。  
   - 内核遍历所有注册的fd（`struct pollfd`数组），检查其就绪状态。  
2. **返回时**：  
   - 内核将修改后的`struct pollfd`数组返回给用户程序，切换回用户态。  

每次调用`poll`都会发生**两次用户态/内核态切换**（调用和返回）。

### **数据拷贝**  
1. **调用`poll`时**：  
   - 用户程序将`struct pollfd`数组从用户态拷贝到内核态。  
2. **返回时**：  
   - 内核将修改后的`struct pollfd`数组从内核态拷贝回用户态。  

每次调用`poll`都会发生**两次数据拷贝**（传入和传出）。

---

## **3. epoll**

### **用户态/内核态切换**  
1. **调用`epoll_ctl`时**：  
   - 用户程序调用`epoll_ctl`（添加、删除或修改fd），进入内核态。  
   - 内核更新红黑树中的`epitem`节点。  
   - 操作完成后，切换回用户态。  
2. **调用`epoll_wait`时**：  
   - 用户程序调用`epoll_wait`，进入内核态。  
   - 内核检查`rdllist`（就绪队列），若不为空，则拷贝就绪事件到用户空间；若为空，则阻塞等待。  
   - 返回时，切换回用户态。  

每次调用`epoll_ctl`和`epoll_wait`都会发生**两次用户态/内核态切换**（调用和返回）。但`epoll_wait`的切换频率远低于`select/poll`，因为它只处理活跃事件。

### **数据拷贝**  
1. **调用`epoll_ctl`时**：  
   - 用户程序将`struct epoll_event`从用户态拷贝到内核态（仅注册时一次）。  
2. **调用`epoll_wait`时**：  
   - 内核将就绪的`struct epoll_event`从内核态拷贝回用户态。  

`epoll`的**数据拷贝次数显著减少**：  
- `epoll_ctl`仅在注册fd时拷贝一次。  
- `epoll_wait`只拷贝就绪事件，而不是全量fd集合。

---

## 对比总结

| 机制   | 用户态/内核态切换次数（每次调用） | 数据拷贝次数（每次调用） |  
|--------|-----------------------------------|--------------------------|  
| select | 2次（调用+返回）                  | 2次（传入fd_set+传出fd_set） |  
| poll   | 2次（调用+返回）                  | 2次（传入pollfd数组+传出pollfd数组） |  
| epoll  | 2次（调用+返回）                  | 1次（仅传出就绪事件） |  

---

## 详细场景分析

### **1. select**  
- **用户态/内核态切换**：  
  - 每次调用`select`时，用户程序进入内核态，内核遍历所有fd后返回用户态。  
  - 例如：监控1000个fd，每次调用`select`都会遍历1000个fd，发生2次切换。  
- **数据拷贝**：  
  - 每次调用`select`时，用户程序将1000个fd的`fd_set`拷贝到内核态。  
  - 内核返回时，将修改后的`fd_set`拷贝回用户态。  

### **2. poll**  
- **用户态/内核态切换**：  
  - 每次调用`poll`时，用户程序进入内核态，内核遍历所有fd后返回用户态。  
  - 例如：监控1000个fd，每次调用`poll`都会遍历1000个fd，发生2次切换。  
- **数据拷贝**：  
  - 每次调用`poll`时，用户程序将1000个`struct pollfd`拷贝到内核态。  
  - 内核返回时，将修改后的`struct pollfd`数组拷贝回用户态。  

### **3. epoll**  
- **用户态/内核态切换**：  
  - 调用`epoll_ctl`时，用户程序进入内核态，更新红黑树后返回用户态。  
  - 调用`epoll_wait`时，用户程序进入内核态，检查`rdllist`后返回用户态。  
  - 例如：监控1000个fd，只有10个fd就绪时，`epoll_wait`只需处理10个fd，发生2次切换。  
- **数据拷贝**：  
  - 调用`epoll_ctl`时，用户程序将`struct epoll_event`拷贝到内核态（仅注册时一次）。  
  - 调用`epoll_wait`时，内核将10个就绪的`struct epoll_event`拷贝回用户态。  

---

在 Linux 高性能网络编程中，`epoll` 的性能优势显著，但 `select` 和 `poll` 仍被使用的原因可以从多个角度分析。以下是关键点：

------

### **1. 跨平台兼容性**

- **`select` 和 `poll`** 是 **POSIX 标准**，支持所有主流操作系统（Linux、Windows、macOS、BSD 等）。

- 

  `epoll`

   是 

  Linux 特有

   的机制，无法直接移植到其他系统。

  

  适用场景

  ：

  - 跨平台项目（如 Nginx 通过抽象层支持多平台）。
  - 需兼容旧系统（如嵌入式设备使用旧内核）。

------

### **2. 简单场景下的轻量级需求**

- 

  连接数少时

  ：

  ```
  select
  ```

   

  和

   

  ```
  poll
  ```

   

  的代码更简单，无需处理复杂的事件注册机制。

  示例：

  c

  复制

  ```c
  // select 示例（监听单个 socket）
  fd_set read_fds;
  FD_ZERO(&read_fds);
  FD_SET(sockfd, &read_fds);
  select(sockfd + 1, &read_fds, NULL, NULL, NULL);
  ```

- **`epoll` 需要初始化、事件注册等步骤**，代码复杂度更高。

------

### **3. 历史遗留代码和维护成本**

- 

  旧项目依赖

  ：早期代码基于

   

  ```
  select
  ```

  /

  ```
  poll
  ```

   

  实现，若运行稳定，重构风险高。

  - 如 Apache 1.x 使用 `select`，而 Apache 2.x 引入多模块支持（包括 `epoll`）。

- **团队熟悉度**：维护者对 `select`/`poll` 更熟悉，短期无需切换。

------

### **4. 文件描述符类型的支持**

- **`select` 和 `poll`** 支持 **所有文件描述符类型**（如管道、终端、套接字）。
- **`epoll`** 主要优化 **网络套接字**，对其他类型支持较弱（如无法直接监视普通文件）。

------

### **5. 性能并非唯一考量**

- **低并发场景**：当连接数小于 1000 时，`select`/`poll` 的性能与 `epoll` 差异不大。
- **资源占用**：`epoll` 需要内核维护事件表，可能占用更多内存（极端场景需权衡）。

------

### **6. 特殊场景下的行为差异**

- **信号处理**：`select` 在等待时可能被信号中断，需手动处理 `EINTR`，而 `epoll` 通过 `epoll_pwait` 支持原子操作。
- **超时精度**：`poll` 支持毫秒级超时，`select` 支持微秒（但实际精度依赖内核），`epoll` 支持纳秒级（`epoll_wait` 的 `timeout` 参数）。

------

### **7. 设计哲学对比**

| **机制** |                  **优势**                   |                  **劣势**                  |
| :------: | :-----------------------------------------: | :----------------------------------------: |
| `select` |              跨平台、简单易用               | 文件描述符数量限制（1024）、线性扫描效率低 |
|  `poll`  |            无文件描述符数量限制             |       仍需线性扫描、跨平台但性能一般       |
| `epoll`  | 高性能（事件驱动，O(1) 复杂度）、支持大并发 |     Linux 独有、代码复杂、需内核 2.6+      |

------

### **8. 实际应用场景示例**

- 

  使用 `select`/`poll` 的场景

  ：

  - 跨平台工具（如 `libevent` 内部根据平台选择后端）。
  - 旧版服务器或低并发控制程序（如小型 IoT 设备）。
  - 需同时监听多种文件描述符（如串口 + 网络）。

- 

  必须用 `epoll` 的场景

  ：

  - 高性能服务器（如 Nginx、Redis）。
  - 单机数十万并发连接（如 WebSocket 推送服务）。

------

### **总结**

- **优先用 `epoll`**：若项目是 Linux 专用且需要高并发。
- **选择 `select`/`poll`**：若需跨平台、维护旧代码，或连接数较少。
- **混合使用**：现代框架（如 libuv）通过抽象层封装多种机制，自动选择最优实现。

---

# 五、源码解析和实践感悟

## 1. epoll 红黑树+就绪队列——为什么是 O(1)

epoll 用红黑树管理所有监听 fd（O(logN) 增删），用就绪队列 rdllist 收集活跃事件（内核回调驱动），epoll_wait 只需拷贝就绪事件到用户空间。

```c
// Linux 内核 epoll 核心数据结构（fs/eventpoll.c 简化）
struct eventpoll {
    struct rb_root_cached rbr;   // 红黑树：存储所有监听的 epitem（fd）
    struct list_head rdllist;    // 就绪队列：双向链表
    wait_queue_head_t wq;        // 等待队列：阻塞在 epoll_wait 的进程
};

struct epitem {
    struct rb_node rbn;          // 红黑树节点
    struct list_head rdllink;    // 就绪队列链表节点
    struct epoll_filefd ffd;     // {fd, file*}
    struct eventpoll *ep;        // 所属 eventpoll
    struct epoll_event event;    // 用户注册的事件（EPOLLIN/EPOLLOUT 等）
};

// ep_poll_callback——设备就绪时的回调
// 网卡收包→协议栈→sock_def_readable→ep_poll_callback
static int ep_poll_callback(wait_queue_entry_t *wait, ...) {
    struct epitem *epi = ...;
    // 将 epitem 加入 rdllist（如果不在列表中）
    if (!ep_is_linked(&epi->rdllink))
        list_add_tail(&epi->rdllink, &ep->rdllist);
    // 唤醒阻塞在 epoll_wait 的进程
    wake_up(&ep->wq);
}
// 关键：事件触发才加入就绪队列，无事件时完全无开销
// select/poll 每次调用都要遍历所有 fd——这是本质差距
```

## 2. ET vs LT 的底层实现差异

LT（Level Triggered）是 epoll 默认模式，只要 fd 可读就持续通知；ET（Edge Triggered）仅在状态变化时通知一次。高性能场景必须用 ET + 非阻塞 IO。

```c
// ET 模式的核心：一次通知，一次性读完
// ep_poll_callback 中 LT vs ET 的判断逻辑（简化）
if (events & EPOLLET) {
    // ET：仅在状态从"不就绪"变为"就绪"时添加一次
    if (!(epi->event.events & EPOLLIN))  // 之前不就绪
        list_add_tail(&epi->rdllink, &ep->rdllist);
} else {
    // LT：每次 epoll_wait 只要 fd 仍就绪就重新加入 rdllist
    list_add_tail(&epi->rdllink, &ep->rdllist);
}

// ET 模式下的正确读法：循环读到 EAGAIN
while (1) {
    ssize_t n = read(fd, buf, sizeof(buf));
    if (n == -1 && errno == EAGAIN) break;  // 内核缓冲区已空
    if (n == 0) { close(fd); break; }       // 对端关闭
    process(buf, n);
}
// 错误做法：只读一次 → 剩余数据永远丢失（不会再触发 ET 通知）
```

## 3. epoll 的惊群问题与 EPOLLEXCLUSIVE

多进程/多线程同时 epoll_wait 同一 epfd 时，一个事件可能唤醒所有等待者（惊群），只有一人能处理，其他人白醒。

```c
// 惊群场景：N 个 worker 进程共享同一 listen_fd + epfd
// 一个新连接到来 → 所有 worker 被唤醒 → 只有一个 accept 成功 → 其余 EAGAIN

// Linux 4.5+ 解决方案：EPOLLEXCLUSIVE
struct epoll_event ev;
ev.events = EPOLLIN | EPOLLEXCLUSIVE;  // 独占唤醒
epoll_ctl(epfd, EPOLL_CTL_ADD, listen_fd, &ev);
// 此时内核只唤醒一个等待者（而非全部），类似 SO_REUSEPORT 的效果

// 或者用更现代的方案：
// 1. SO_REUSEPORT：每个 worker bind 同一端口，内核分发连接
// 2. 每个 worker 独立创建 epfd，避免共享 epfd 的惊群
```

## 实践经验

1. **epoll 的"零拷贝"不是真的零**：epoll_wait 仍需将就绪事件从内核拷贝到用户空间。但对比 select/poll 每次拷贝全部 fd_set（O(n)），epoll 只拷贝就绪事件（O(1)），这就是 100 万连接下 epoll 比 select 快 1000 倍的原因。
2. **ET 模式必须配合非阻塞 IO**：否则 read 可能阻塞导致事件循环停滞。这是 epoll 新手最常犯的错误——用了 ET 但 socket 仍是阻塞模式。
3. **epoll 不适合短连接场景**：每个连接都需要 epoll_ctl 注册/注销（系统调用+红黑树操作）。短连接（如 HTTP/1.0）下 epoll_ctl 开销可能超过 select 的遍历开销。这也是为什么短连接基准测试中 select 有时反而更快。
4. **EPOLLONESHOT 防止多线程竞态**：设置后 fd 触发一次后自动从 epoll 移除，处理完后手动重新注册。确保同一 fd 同时只被一个线程处理，避免竞态条件。
5. **select 的 fd_set 大小限制是编译期常量**：FD_SETSIZE 默认 1024，可通过重新编译内核改变但会影响 ABI。poll 用动态数组突破此限制，但仍是 O(n) 扫描。
6. **io_uring 是 epoll 的继任者**：内核 5.1+ 引入，用共享环形缓冲区（SQ/CQ）实现真正的零拷贝和异步 IO，延迟比 epoll 低 50%+。但生态尚不成熟，多数框架（libuv/nginx）仍用 epoll。

---

# 六、面试准备

## 面试问答

**Q1: select、poll、epoll 的核心区别？**
A: (1) **select**：fd_set 位图，最大 1024，每次 O(n) 遍历，需拷贝整个 fd_set；(2) **poll**：动态 pollfd 数组，无数量限制，仍是 O(n) 遍历；(3) **epoll**：红黑树管理 fd（O(logN) 增删）+ 就绪队列（O(1) 获取就绪事件），仅拷贝就绪事件。epoll 是 Linux 特有，select/poll 是 POSIX 标准跨平台。

**Q2: epoll 为什么高效？**
A: 三个原因：(1) **事件驱动**——fd 就绪时通过回调 `ep_poll_callback` 将事件加入就绪队列，无事发生时零开销；(2) **O(1) 获取就绪事件**——epoll_wait 只遍历就绪队列而非所有 fd；(3) **内存复用**——epoll_ctl 一次性注册 fd 到内核红黑树，后续无需重复拷贝。100 万连接下 epoll 比 select 快 1000 倍。

**Q3: ET（边缘触发）和 LT（水平触发）的区别？**
A: (1) **LT**（默认）：只要 fd 可读，每次 epoll_wait 都通知，不处理会反复通知。(2) **ET**：仅在 fd 状态从不可读变为可读时通知一次，必须一次性读完（循环读到 EAGAIN），必须配合非阻塞 IO。ET 减少系统调用次数，高性能场景必选。

**Q4: epoll 的惊群问题怎么解决？**
A: 惊群：多进程/线程同时 epoll_wait 同一 epfd，一个事件唤醒所有等待者。解决：(1) Linux 4.5+ 用 `EPOLLEXCLUSIVE` 标志，内核仅唤醒一个等待者；(2) 用 `SO_REUSEPORT` 每个 worker 独立 listen+accept，内核分发连接；(3) 每个 worker 独立创建 epfd 避免共享。

**Q5: select 的 fd_set 为什么限制 1024？**
A: FD_SETSIZE 是编译期常量（默认 1024），因为 fd_set 是固定大小的位图。修改需重新编译内核且影响所有依赖的程序。poll 用动态数组（struct pollfd）解决了此限制。现代 Linux 系统单进程可打开的文件描述符数（ulimit -n）已达百万级，select 已成为历史瓶颈。

**Q6: 为什么 epoll 不能用于普通文件？**
A: epoll 基于"设备就绪回调"机制——socket 收到数据时网卡中断→协议栈→回调通知。普通文件（磁盘）始终处于"可读"状态（除非 EOF），没有"从不就绪变为就绪"的状态变化。`epoll_ctl` 对普通文件会返回 EPERM。普通文件的异步 IO 应使用 AIO 或 io_uring。

**Q7: epoll 和 io_uring 的区别？**
A: epoll 是 IO 多路复用（通知哪些 fd 就绪），仍需用户态执行 read/write（至少一次系统调用+数据拷贝）。io_uring 是真正的异步 IO：通过共享环形缓冲区（SQ/CQ）提交 IO 请求，内核直接完成，零系统调用+零拷贝（在支持的情况下）。io_uring 是 Linux 5.1+ 的新一代异步 IO 接口。

**Q8: 高并发服务器为什么用 epoll + 非阻塞 IO + ET？**
A: (1) epoll 保证 O(1) 事件获取；(2) 非阻塞 IO 确保不会因单个慢连接阻塞事件循环；(3) ET 减少不必要的 epoll_wait 唤醒次数。这三个组合是"事件驱动"（Reactor 模式）的基石，Nginx/Redis/Libevent 均采用此模式。

## 陷阱与反问

| 陷阱 | 错误认知 | 正确理解 |
|------|---------|---------|
| epoll 在任何场景都比 select 快 | 短连接+低并发下 epoll_ctl 注册/注销开销可能高于 select 遍历 | 场景决定：长连接+高并发选 epoll，短连接+低并发均可 |
| ET 模式更高效所以默认用 ET | ET 要求一次性读完数据，实现复杂度远高于 LT | 除非追求极致性能，LT 模式更简单可靠 |
| epoll_wait 返回的事件数就是就绪 fd 数 | 一个 fd 可能同时有 EPOLLIN 和 EPOLLOUT 两个事件 | 需遍历 events 数组处理每个事件，fd 可能重复 |
| epoll 完全零拷贝 | epoll_wait 仍需拷贝 events 到用户空间 | 只是从拷贝全部→只拷贝就绪，并非真正零拷贝 |
| epoll_ctl 不需要考虑线程安全 | 多线程同时 epoll_ctl 同一 epfd 需要同步 | epoll 内部有锁但最好一个线程管理 epfd |

## 一句话答案速记表

| 关键词 | 一句话 |
|--------|--------|
| select | fd_set 位图，1024 上限，O(n) 遍历+全量拷贝 |
| poll | 动态 pollfd 数组，无上限，O(n) 遍历 |
| epoll | 红黑树+就绪队列，O(1) 事件获取，仅拷贝就绪事件 |
| ET vs LT | ET 一次通知（状态变化），LT 持续通知（状态保持） |
| epoll 回调 | 设备就绪→ep_poll_callback→加入 rdllist→唤醒进程 |
| 惊群 | 多等者同时唤醒，EPOLLEXCLUSIVE 或 SO_REUSEPORT 解决 |
| 非阻塞 IO | ET 必须配合非阻塞 IO，循环读到 EAGAIN |
| io_uring | 共享环形缓冲区，真正的异步 IO，下一代 epoll |
