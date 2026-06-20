---
title: Socket在网络层中的底层实现原理
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "网络编程"]
publish: true
---

# Socket在网络层中的底层实现原理

> 适用范围：Linux 内核网络协议栈分层处理、Socket 系统调用路径（sys_socket→inet_create→tcp_prot）、各网络层中 Socket 的角色与协作、struct socket/struct sock/struct inet_sock 层次关系

## 一、核心概念

- **定义**：Socket 在 Linux 内核中体现为三层核心数据结构——`struct socket`（VFS 层，面向 fd）、`struct sock`（协议无关网络层）、`struct inet_sock`（IPv4 特定层）。用户空间的 `send()`/`recv()` 经过系统调用，逐层经过 TCP→IP→链路层→网卡驱动，每层从 socket 结构体获取必要信息
- **关键词**：sys_socket、inet_create、tcp_prot、sk_buff、NAPI、TSO/GSO、IP 分片、路由缓存、跨层协作
- **适用场景/边界**：
  - 理解内核网络协议栈的分层设计
  - 网络问题分层排查（哪一层丢包/延迟）
  - 边界：不涉及应用层协议（HTTP 等），聚焦内核协议栈路径

## 二、详细解析（≥200字）

### 2.1 Socket 核心数据结构层次

```
struct socket          // VFS 层（面向文件描述符）
  ├─ state             // SS_CONNECTED / SS_UNCONNECTED
  ├─ ops → ...         // 协议无关操作（connect/sendmsg/recvmsg）
  └─ *sk ─────────────→ struct sock       // 协议无关网络层
                            ├─ sk_receive_queue  // 接收 sk_buff 队列
                            ├─ sk_write_queue    // 发送 sk_buff 队列
                            └─ sk_prot → ...     // tcp_prot 操作表
                                  │
                                  ▼ (强制转换 inet_sk(sk))
                              struct inet_sock  // IPv4 特定
                                ├─ inet_saddr     // 源 IP
                                ├─ inet_daddr     // 目标 IP
                                ├─ inet_sport     // 源端口
                                └─ inet_dport     // 目标端口
```

### 2.2 send() 数据从用户态到网卡的完整路径

```
send() → sys_sendto() → sock_sendmsg()
  → inet_sendmsg() → tcp_sendmsg()       // TCP 层：拷贝用户数据到 sk_write_queue
    → __tcp_push_pending_frames()        // TCP 发送引擎
      → tcp_write_xmit()                 // 拥塞控制检查
        → tcp_transmit_skb()             // 构造 TCP 头
          → ip_queue_xmit()              // IP 层：构造 IP 头 + 路由查找
            → ip_local_out() → dst_output()
              → dev_queue_xmit()         // 链路层：选择网卡队列
                → ndo_start_xmit()       // 网卡驱动：写入 Ring Buffer
```

关键：用户数据在 `tcp_sendmsg` 阶段拷贝到内核 sk_buff，之后零拷贝沿协议栈流动。

### 2.3 硬件卸载特性

| 技术 | 方向 | 原理 | Socket 影响 |
|------|------|------|------------|
| TSO (TCP Segmentation Offload) | 发送 | TCP 发送大段(64KB)给网卡，硬件按 MSS 分片 | 一次 tcp_sendmsg 可发大块数据 |
| GSO (Generic Segmentation Offload) | 发送 | TSO 的软件模拟，内核中切分 | TSO 的 fallback |
| GRO (Generic Receive Offload) | 接收 | 内核协议栈合并连续小段后进入接收队列 | 一次 recv 可能收到大包 |

## 三、动手实践（代码案例）

### 3.1 Socket 创建到 Listen 的系统调用

```c++
// 用户空间
int sockfd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
bind(sockfd, (struct sockaddr*)&addr, sizeof(addr));
listen(sockfd, backlog);

// 内核调用链：
// sys_socket() → sock_create() → inet_create()
//   → sk_alloc()         // 分配 struct sock
//   → sock_init_data()   // 初始化收发队列
//   → sock_map_fd()      // 分配文件描述符
// sys_bind() → inet_bind() → tcp_v4_get_port()
// sys_listen() → inet_listen() → tcp_set_state(sk, TCP_LISTEN)
```

### 3.2 TCP 连接状态转换

```c++
// 客户端 connect() 路径
connect() → tcp_v4_connect()
  → tcp_set_state(sk, TCP_SYN_SENT)      // 进入 SYN_SENT
  → 收到 SYN+ACK → tcp_rcv_synsent_state_process()
    → tcp_set_state(sk, TCP_ESTABLISHED)  // 进入 ESTABLISHED

// 服务端 accept() 路径
listen() → tcp_set_state(sk, TCP_LISTEN)
  → 收到 SYN → 创建 request_sock（SYN_RECV 半连接）
    → inet_csk_clone_lock()              // 从 listen socket 克隆子 socket
      → tcp_set_state(newsk, TCP_SYN_RECV)
  → 收到第三次 ACK → tcp_set_state(newsk, TCP_ESTABLISHED)
```

## 四、进阶应用（≥500字）

### 4.1 ICMP 错误如何通过 Socket 返回应用

```c
// 路径：ICMP 不可达 → TCP 层 → socket 错误队列
icmp_unreach()
  → icmp_socket_deliver()
    → tcp_v4_err()
      → sk->sk_err = EHOSTUNREACH      // 设置 socket 错误
      → sk->sk_error_report(sk)          // 唤醒等待的应用

// 应用获取错误
int err;
socklen_t len = sizeof(err);
getsockopt(sockfd, SOL_SOCKET, SO_ERROR, &err, &len);
// sk_err 不会因 read 清除，需显式 getsockopt(SO_ERROR)
```

### 4.2 TCP 拥塞窗口对 IP 层发送的控制

```c
// tcp_write_xmit() 中的拥塞控制
if (tcp_packets_in_flight(tp) >= tp->snd_cwnd) {
    return false;  // 暂停调用 IP 层 ip_queue_xmit
}
// TCP 层的拥塞控制直接决定何时调用 IP 层发送
```

### 4.3 PMTUD（路径 MTU 发现）与 MSS 动态调整

```c
// IP 层 MTU 信息影响 TCP MSS
tcp_sync_mss(sk, pmtu) {
    mss_now = pmtu - sizeof(struct tcphdr) - sizeof(struct iphdr);
    tp->mss_cache = mss_now;  // MSS = PMTU - 40
}
// 发送大包设 DF 标志，收到 ICMP 不可达后缩小 PMTU
```

### 4.4 与其他主题的关联

| 关联主题 | 关联点 |
|---------|--------|
| epoll | epoll 监视 socket fd，收包路径触发回调 |
| 序列号 | TCP 层在发送/接收路径中管理序列号 |
| 发送/接收队列 | 数据路径的关键中转站 |
| 零拷贝 | sendfile 绕过 socket 层的用户空间拷贝 |

## 五、源码解析和实践感悟（≥1000字）

### 5.1 inet_create 协议栈初始化

```c
// net/ipv4/af_inet.c
static int inet_create(struct net *net, struct socket *sock, int protocol, int kern)
{
    struct sock *sk;
    
    // 1. 根据协议类型查找协议操作表
    list_for_each_entry_rcu(answer, &inetsw[sock->type], list) {
        if (protocol == answer->protocol) break;
    }
    // 2. 分配 struct sock
    sk = sk_alloc(net, PF_INET, GFP_KERNEL, answer_prot, kern);
    
    // 3. 初始化 socket 与 sock 的关联
    sock_init_data(sock, sk);
    sk->sk_protocol = protocol;
    
    // 4. 设置协议族特定的操作表
    sock->ops = answer->ops;          // inet_stream_ops
    sk->sk_prot = answer->prot;       // tcp_prot
    return 0;
}
```

### 5.2 NAPI 机制如何减少中 断开销

```c
// net/core/dev.c
static void net_rx_action(struct softirq_action *h)
{
    struct softnet_data *sd = this_cpu_ptr(&softnet_data);
    int budget = netdev_budget;  // 默认 300 包
    
    while (budget > 0 && !list_empty(&sd->poll_list)) {
        struct napi_struct *n = list_first_entry(&sd->poll_list, ...);
        int work = n->poll(n, weight);  // 批量收割数据包
        budget -= work;
        if (work < weight || budget <= 0)
            list_del_init(&n->poll_list);
    }
}
```

NAPI 核心思想：**中断 + 轮询混合**。第一个包触发硬件中断 → 中断处理程序关闭中断、加入 poll_list、触发软中断 → `net_rx_action` 在软中断上下文批量收割（默认 300 包/次）→ 处理完毕重新开启中断。

### 5.3 实践感悟

1. **分层排查思维**：`send()` 成功但对端未收到？分层排查：应用层（数据格式）→ TCP 层（检查重传计数，可能对端窗口为 0 或丢包）→ IP 层（路由可达性，ping）→ 链路层（ARP 表、网卡统计）。

2. **struct socket vs struct sock 的关系**：`struct socket` 是 VFS 层的抽象（面向 open/read/write），`struct sock` 是网络层的核心（面向协议状态机）。所有协议族共用 `struct sock`，通过 `sk->sk_prot` 函数指针表实现多态。

3. **TSO/GSO 的实践影响**：启用 TSO 后 `tcpdump` 可能看到 64KB 的大包，但线路上实际是多个 MSS 大小的小包——TSO 卸载给网卡硬件分片。

4. **sk_buff 的引用计数陷阱**：sk_buff 被多处引用（发送队列/重传队列/释放等待），通过 `skb->users` 管理。过早释放导致 UAF，忘记释放导致内存泄漏。

5. **connect() 成功后 send() 的误区**：`connect()` 只完成三次握手，`send()` 数据可能仍在内核发送缓冲区中（被拥塞窗口延迟），真正到达对端需要 ACK 确认。

## 六、面试准备

### 6.1 面试 Q&A

### 1. Socket创建阶段

```
// 用户空间调用
int sockfd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);

// 内核处理流程
sys_socket() -> sock_create() -> inet_create() -> tcp_prot.init()
```

**内核操作：**

* 分配`struct socket`和`struct sock`结构体
* 初始化协议相关的函数指针表
* 建立用户空间文件描述符与内核socket对象的映射

### 2. 地址绑定与监听

```
bind(sockfd, &addr, sizeof(addr));
listen(sockfd, backlog);

// 内核实现
inet_bind() -> tcp_v4_get_port() -> __inet_hash_connect()
```

## 二、应用层与Socket接口

### Socket API封装

```
// 应用层看到的接口
ssize_t send(int sockfd, const void *buf, size_t len, int flags);
ssize_t recv(int sockfd, void *buf, size_t len, int flags);

// 内核中的实际处理
sys_sendto() -> sock_sendmsg() -> inet_sendmsg() -> tcp_sendmsg()
sys_recvfrom() -> sock_recvmsg() -> inet_recvmsg() -> tcp_recvmsg()
```

**底层操作：**

* **缓冲区管理**：用户数据复制到内核发送缓冲区
* **协议选择**：根据socket类型选择相应协议栈
* **参数验证**：检查地址、长度、标志位等参数合法性

## 三、传输层（TCP）中的Socket处理

### 1. 连接建立过程

```
// 客户端connect流程
connect() -> tcp_v4_connect() -> ip_route_output_flow()

// 服务端accept流程  
accept() -> inet_csk_accept() -> tcp_check_req() -> tcp_create_openreq_child()
```

**TCP层Socket操作：**

* **状态管理**：维护TCP连接状态机(CLOSED→SYN\_SENT→ESTABLISHED)
* **序列号分配**：为每个连接分配初始序列号
* **端口管理**：绑定本地端口，管理端口哈希表

### 2. 数据传输机制

```
// TCP发送数据路径
tcp_sendmsg() {
    // 1. 检查连接状态
    if (sk->sk_state != TCP_ESTABLISHED)
        return -ENOTCONN;
    
    // 2. 拷贝用户数据到发送队列
    skb = sk_stream_alloc_skb(sk, select_size(sk));
    skb_copy_from_iter(skb, from, copy);
    
    // 3. 添加到发送队列
    tcp_queue_skb(sk, skb);
    
    // 4. 触发发送
    __tcp_push_pending_frames(sk, mss_now);
}
```

**关键功能：**

* **流量控制**：根据接收方窗口大小调整发送速率
* **拥塞控制**：实现慢启动、拥塞避免算法
* **可靠传输**：序列号确认、超时重传机制
* **数据分段**：将应用数据按MSS分割成TCP段

### 3. 接收数据处理

```
// TCP接收数据路径
tcp_rcv_established() -> tcp_data_queue() -> sk_data_ready()

// 用户读取数据
tcp_recvmsg() {
    // 从接收队列复制数据到用户缓冲区
    skb_copy_datagram_msg(skb, offset, msg, used);
    // 更新接收窗口
    tcp_rcv_space_adjust(sk);
}
```

## 四、网络层（IP）中的Socket处理

### 1. 路由决策

```
// TCP调用IP层发送
tcp_transmit_skb() -> ip_queue_xmit() -> ip_route_output_flow()

struct rtable *ip_route_output_flow(struct flowi4 *fl4) {
    // 1. 检查路由缓存
    struct rtable *rt = dst_cache_get(&fl4->dst_cache);
    
    // 2. 查询FIB路由表
    if (!rt) {
        fib_lookup(net, fl4, &res);
        rt = rt_dst_alloc(res.fi->fib_dev);
    }
    return rt;
}
```

**IP层Socket相关操作：**

* **路由查找**：确定数据包的下一跳地址和出接口
* **MTU发现**：确定路径最大传输单元，影响TCP分段
* **服务质量**：处理TOS/DSCP字段，影响数据包优先级

### 2. IP数据包构造

```
// IP头部构造
int ip_queue_xmit(struct sock *sk, struct sk_buff *skb) {
    struct iphdr *iph = ip_hdr(skb);
    
    // 从socket获取IP选项
    iph->protocol = sk->sk_protocol;  // IPPROTO_TCP
    iph->saddr = inet->inet_saddr;    // 源IP地址
    iph->daddr = inet->inet_daddr;    // 目标IP地址
    
    // 设置TTL
    iph->ttl = ip_select_ttl(inet, &rt->dst);
    
    return ip_local_out(net, sk, skb);
}
```

### 3. 分片处理

```
// IP层分片（当TCP段超过MTU时）
ip_fragment() {
    // 计算分片数量
    mtu = rt->dst.dev->mtu;
    hlen = iph->ihl * 4;
    
    // 创建分片
    while (left > 0) {
        len = left > mtu ? mtu : left;
        frag = ip_frag_create(skb, offset, len);
        output(net, sk, frag);
        left -= len;
        offset += len;
    }
}
```

## 五、数据链路层中的Socket影响

### 1. 网络设备选择

```
// 根据路由结果选择网络接口
dev_queue_xmit(skb) {
    // 从IP路由结果获取出接口
    struct net_device *dev = skb->dev;
    
    // 调用设备驱动发送
    dev->netdev_ops->ndo_start_xmit(skb, dev);
}
```

### 2. 硬件特性优化

```
// 利用网卡特性优化
if (dev->features & NETIF_F_TSO) {
    // TCP分段卸载到网卡
    tcp_tso_segs(skb, mss_now);
}

if (dev->features & NETIF_F_HW_CSUM) {
    // 校验和计算卸载到网卡
    skb->ip_summed = CHECKSUM_PARTIAL;
}
```

## 六、关键数据结构关系

### Socket核心结构体

```
struct socket {
    socket_state        state;      // socket状态
    struct sock        *sk;         // 协议相关socket结构
    const struct proto_ops *ops;    // 协议操作函数表
};

struct sock {
    struct sock_common  __sk_common;
    struct sk_buff_head sk_receive_queue;  // 接收队列
    struct sk_buff_head sk_write_queue;    // 发送队列
    struct dst_entry   *sk_dst_cache;      // 路由缓存
};

struct inet_sock {
    struct sock         sk;
    __be32             inet_saddr;   // 源IP地址  
    __be16             inet_sport;   // 源端口
    __be32             inet_daddr;   // 目标IP地址
    __be16             inet_dport;   // 目标端口
};
```

## 七、跨层协作机制

### 1. 错误传播

```
// IP层错误通过ICMP传递给TCP
icmp_unreach() -> tcp_v4_err() -> sk->sk_error_queue
```

### 2. 流量控制协作

```
// TCP拥塞窗口影响IP层发送
if (tcp_packets_in_flight(tp) >= tp->snd_cwnd)
    return false;  // 延迟IP层发送
```

### 3. 路径MTU发现

```
// IP层MTU信息影响TCP MSS
tcp_sync_mss(sk, pmtu) {
    mss_now = pmtu - sizeof(struct tcphdr) - sizeof(struct iphdr);
    tp->mss_cache = mss_now;
}
```

## 八、性能优化机制

### 1. 零拷贝技术

```
// sendfile系统调用避免用户空间拷贝
splice_to_pipe() -> pipe_to_sendpage() -> tcp_sendpage()
```

### 2. 批量处理

```
// NAPI网卡中断处理
net_rx_action() {
    while (!list_empty(&sd->poll_list)) {
        work = n->poll(n, weight);  // 批量处理多个数据包
    }
}
```

### 3. CPU亲和性

```
// RSS（接收端扩展）将不同连接分配到不同CPU
rps_map = rcu_dereference(rxqueue->rps_map);
cpu = map->cpus[reciprocal_scale(hash, map->len)];
```

## 总结

Socket在各网络层的底层工作体现了分层设计的精髓：

* **应用层**：提供统一的API接口，屏蔽底层复杂性
* **传输层**：实现端到端可靠通信，管理连接状态和数据流
* **网络层**：处理主机间路由，实现跨网络通信
* **数据链路层**：利用硬件特性优化传输性能

每一层都从socket结构体中获取必要信息，同时将处理结果反馈给上层，形成了高效的协作机制。

## Socket在各层的核心作用

**1. 系统调用层面**

* Socket实际上是内核中`struct socket`和`struct sock`结构体在用户空间的句柄
* 每个socket操作都会经过系统调用进入内核，触发相应的协议栈处理

**2. 状态同步机制**

* Socket状态（如TCP的ESTABLISHED状态）会影响所有网络层的处理逻辑
* IP层的路由信息会缓存在socket结构中，避免重复查找
* 网络设备的特性（如TSO、校验和卸载）通过socket传递给上层协议

**3. 缓冲区管理**

* 发送缓冲区：应用数据先进入socket发送缓冲区，再由TCP分段处理
* 接收缓冲区：IP重组完成的数据包进入socket接收缓冲区等待应用读取
* 缓冲区大小直接影响TCP的流量控制窗口计算

**4. 错误处理链路**

* 底层网络错误（如ICMP不可达）会通过socket的错误队列传递给应用
* 每一层的错误都有对应的错误码，最终通过socket API返回给用户程序

## 六、面试准备

### 6.1 面试 Q&A

**Q1: socket 系统调用在内核中是如何被处理的？**

以 `socket(AF_INET, SOCK_STREAM, 0)` 为例，调用链为：
```
sys_socket() → sock_create() → inet_create()
  → sk_alloc()        // 分配 struct sock
  → sock_init_data()   // 初始化接收/发送队列
  → 关联 tcp_prot 协议操作函数表
  → sock_map_fd()      // 分配文件描述符
```
核心：为每个 socket 分配 `struct socket` + `struct sock`（协议无关），并在 `inet_create` 中绑定 TCP 协议的具体操作函数集。

**Q2: send() 数据从用户态到网卡的完整路径是什么？**

```
send() → sys_sendto() → sock_sendmsg() → inet_sendmsg() → tcp_sendmsg()
  → 拷贝用户数据到 sk_write_queue 中的 sk_buff
  → __tcp_push_pending_frames()          // TCP 发送引擎
    → tcp_write_xmit()                   // 拥塞控制检查
    → tcp_transmit_skb()                 // 构造 TCP 头
      → ip_queue_xmit()                  // 构造 IP 头 + 路由查找
        → ip_local_out() → dst_output()
          → dev_queue_xmit()             // 网卡驱动发送
```
关键：用户数据在 `tcp_sendmsg` 阶段拷贝到内核 sk_buff，之后零拷贝沿协议栈流动。

**Q3: socket 接收缓冲区与接收队列的区别与联系？**

- **接收队列（sk_receive_queue）**：存放已收到但尚未被用户读取的完整 TCP 段（sk_buff 链表）。顺序按 TCP 序列号排列。
- **接收缓冲区**：逻辑概念，指应用通过 `recv()` 读数据的那块用户空间内存。
- **关系**：内核从 sk_receive_queue 取出 sk_buff，`skb_copy_datagram_msg()` 将数据拷贝到用户 recv 缓冲区，拷贝完成后标记该 sk_buff 可释放。
- **乱序包**：接收队列中 sk_buff 保证有序；未按序到达的段放入 `out_of_order_queue`，等待空洞补齐后再移入。

**Q4: TCP 连接从 SYN 到 ESTABLISHED，socket 状态如何变化？**

```c
// 客户端 connect() 流程
connect() → tcp_v4_connect()
  → tcp_set_state(sk, TCP_SYN_SENT)      // 进入 SYN_SENT
  → tcp_connect() 发送 SYN
  → tcp_rcv_synsent_state_process()      // 收到 SYN+ACK
    → tcp_send_ack()                     // 发送 ACK
    → tcp_set_state(sk, TCP_ESTABLISHED) // 进入 ESTABLISHED

// 服务端 accept() 流程
listen() → inet_listen()
  → tcp_set_state(sk, TCP_LISTEN)        // 进入 LISTEN
  → 收到 SYN 后创建 request_sock (SYN_RECV 状态的半连接)
  → tcp_v4_do_rcv() → tcp_rcv_state_process()
    → tcp_v4_syn_recv_sock()             // 创建子 socket
      → inet_csk_clone_lock()            // 从 listen socket 克隆
      → tcp_set_state(newsk, TCP_SYN_RECV)
  → 收到第三次 ACK
    → tcp_set_state(newsk, TCP_ESTABLISHED)
    → inet_csk_complete_hashdance()      // 移入 accept 队列
```

**Q5: IP 分片与 TCP MSS 的关系及其对 socket 的影响？**

- **MSS**（Maximum Segment Size）：TCP 层协商的最大数据段大小，计算公式 `MSS = MTU - IP头(20) - TCP头(20)`。TCP 保证发出的段 ≤ MSS，避免在 IP 层被分片。
- **IP 分片**：如果 TCP 段实际超出了路径 MTU（如路径中间有小 MTU 链路），IP 层会对其分片。分片后重组在接收端 IP 层完成，对 TCP/socket 透明。
- **socket 层面的影响**：
  - PMTUD（路径 MTU 发现）：`tcp_sync_mss()` 根据探测到的 PMTU 动态调整 MSS，socket 的 `sk_dst_cache` 缓存路由和 MTU 信息。
  - 分片丢包：任意一个分片丢失，整个 IP 数据报不可用，TCP 需重传整个段。因此 TCP 极力避免 IP 层分片。

**Q6: 内核网络协议栈如何利用网卡硬件卸载特性（TSO/GSO/LRO/GRO）优化 socket 性能？**

| 技术 | 方向 | 原理 | 对 socket 的影响 |
|------|------|------|------------------|
| TSO (TCP Segmentation Offload) | 发送 | TCP 发送大段（64KB）给网卡，由网卡硬件按 MSS 分片 | socket 一次 tcp_sendmsg 可发大块数据 |
| GSO (Generic Segmentation Offload) | 发送 | TSO 的软件模拟版，在内核中切分而非网卡 | 作为 TSO 的 fallback |
| LRO (Large Receive Offload) | 接收 | 网卡硬件合并多个小段为大段再交内核 | socket 一次 recv 收到更多数据 |
| GRO (Generic Receive Offload) | 接收 | LRO 的软件版，内核协议栈自动合并连续小段 | NAPI 收包时合并，进入 sk_receive_queue 前合并 |

**Q7: ICMP 错误如何通过 socket 返回到应用程序？**

```c
// 路径：ICMP 不可达 → TCP 层 → socket 错误队列
icmp_unreach()
  → icmp_socket_deliver()
    → raw_icmp_error() / tcp_v4_err()
      → sk->sk_err = 错误码（如 EHOSTUNREACH）
      → sk->sk_error_report(sk)          // 唤醒等待的应用

// 应用通过 getsockopt 获取：
int err;
socklen_t len = sizeof(err);
getsockopt(sockfd, SOL_SOCKET, SO_ERROR, &err, &len);
```
关键：`sk->sk_err` 是 socket 的错误缓存，不会因为应用 read 而清除，需显式 `getsockopt(SO_ERROR)`。

**Q8: 跨层协作中，TCP 拥塞窗口如何影响 IP 层的数据发送？**

```c
// tcp_write_xmit() 中的拥塞控制检查
bool tcp_write_xmit(struct sock *sk, unsigned int mss_now, ...) {
    while ((skb = tcp_send_head(sk))) {
        tcp_cwnd_validate(sk, skb);      // 校准拥塞窗口
        
        // 关键检查：已发出且未确认的段数 ≥ 拥塞窗口
        if (tcp_packets_in_flight(tp) >= tp->snd_cwnd) {
            // 暂停发送，等待 ACK 扩大窗口
            return false;
        }
        tcp_transmit_skb(sk, skb, ...);  // 通过 IP 层发送
    }
}
```
TCP 层的拥塞控制直接决定何时调用 IP 层的 `ip_queue_xmit`，保证网络不会被过量数据淹没。

**Q9: `struct socket`, `struct sock`, `struct inet_sock` 三者的层次关系？**

```
struct socket          // VFS 层（面向文件描述符）
  ├─ state             // SS_CONNECTED / SS_UNCONNECTED
  ├─ ops→ ...          // 协议不可知操作（connect/sendmsg/recvmsg）
  └─ *sk ─────────────→ struct sock       // 协议无关网络层
                            ├─ sk_receive_queue  // 接收 sk_buff 队列
                            ├─ sk_write_queue    // 发送 sk_buff 队列
                            ├─ sk_protocol       // IPPROTO_TCP
                            └─ sk_prot→ ...      // tcp_prot 操作表
                                  │
                                  ▼ (强制转换)
                              struct inet_sock  // IPv4 特定
                                ├─ inet_saddr     // 源 IP
                                ├─ inet_daddr     // 目标 IP
                                ├─ inet_sport     // 源端口
                                └─ inet_dport     // 目标端口
```
`struct sock` → `struct inet_sock` 的转换通过 `inet_sk(sk)` 宏实现（利用结构体继承）。

**Q10: NAPI（New API）机制如何减少网络接收的中断开销？**

NAPI 的核心思想是**中断 + 轮询混合**：
1. 第一个数据包到来触发硬件中断。
2. 中断处理程序不直接处理，而是将网卡加入 `poll_list`，**关闭中断**，触发软中断 `NET_RX_SOFTIRQ`。
3. `net_rx_action()` 在软中断上下文中调用 `n->poll()` 批量处理数据包（默认预算 300 个）。
4. 处理完毕后重新开启网卡中断。

```c
// net_rx_action 核心循环
while (!list_empty(&sd->poll_list)) {
    struct napi_struct *n = list_first_entry(&sd->poll_list, ...);
    int work = n->poll(n, weight);  // 批量收割数据包
    if (work == weight)  // 配额用完，延迟继续
        break;
}
```
对 socket 的影响：数据包在 NAPI 批量收割后（可能在 GRO 合并后）逐层上传，最终通过 `tcp_rcv_established()` 进入 socket 接收队列。

### 6.2 常见陷阱与面试反问

1. **陷阱**：在 `connect()` 返回成功后立即 `send()`，以为数据已送达对端。
   **事实**：`connect()` 只完成 TCP 三次握手，`send()` 数据可能仍在内核发送缓冲区中（被 TCP 栈管理），真正到达对端需要 ACK 确认。

2. **陷阱**：混淆 `struct socket` 和 `struct sock` 的作用域。
   **事实**：`struct socket` 是 VFS 层的抽象（面向 open/read/write），`struct sock` 是网络层的核心结构（面向协议状态机）。所有协议族共用 `struct sock`，但通过 `sk->sk_prot` 函数指针表实现多态。

3. **陷阱**：忽略 `sk_buff` 的生命周期管理。
   **事实**：`sk_buff` 被多处引用（发送队列/重传队列/释放等待），通过 `skb->users` 引用计数管理。过早释放或忘记释放都可能导致内存泄漏或 UAF。

4. **反问**：「如何定位 socket 连接在哪里卡住？」希望听到：
   - `/proc/net/tcp` 查看连接状态和发送/接收队列大小
   - `ss -tni` 输出拥塞窗口（cwnd）、重传超时（rto）、未确认数据量
   - eBPF/SystemTap 挂钩 `tcp_sendmsg`、`tcp_retransmit_skb` 等函数观察数据流
   - `netstat -s` 统计 TCP 超时重传等异常计数

5. **反问**：「如果 send() 能成功但数据一直未被对端确认，问题可能在哪一层？」希望有分层排查思路：应用层确认数据格式对端可解析 → TCP 层检查重传计数（可能对端窗口为 0 或网络丢包）→ IP 层检查路由是否可达（ping 测试）→ 数据链路层检查 ARP 表、网卡统计。

### 6.3 一句话答案速记

| 问题 | 一句话答案 |
|------|------------|
| socket() 返回什么？ | 指向 `struct socket + struct sock` 内核对象的文件描述符 |
| send 数据路径？ | 用户 buf → sk_write_queue → TCP 分段 → IP 路由 → 网卡 |
| recv 数据路径？ | 网卡 → NAPI 合并 → IP 重组 → TCP 排序 → sk_receive_queue → 用户 buf |
| TSO 干嘛的？ | 让网卡硬件替你 TCP 分段，释放 CPU |
| NAPI 优势？ | 中断 + 轮询混合，高负载时关闭中断批量收割 |
| MSS vs MTU？ | MTU=链路层最大包(1500)，MSS=TCP 净荷(1460)，MSS = MTU - 40 |
| PMTUD 原理？ | 发送大包设 DF 标志，收到 ICMP 不可达后缩小 PMTU |
| inet_sock 怎么从 sock 转？ | `inet_sk(sk)` 宏，利用结构体内存继承
