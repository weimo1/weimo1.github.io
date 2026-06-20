---
title: Socket发送接收队列与缓冲区详解
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "网络编程"]
publish: true
---

# Socket发送接收队列与缓冲区详解

> 适用范围：Linux 内核 Socket 缓冲区管理、sk_write_queue/sk_receive_queue、sk_buff 数据结构、TCP 流量控制、缓冲区调优

## 一、核心概念

- **定义**：Socket 发送/接收队列是 Linux 内核为每个 TCP 连接维护的数据缓冲机制。发送队列缓存待发送和未确认的数据，接收队列缓存已确认但尚未被用户读取的数据。两者通过 `sk_buff` 链表实现，是 TCP 可靠传输、流量控制、拥塞控制的基石
- **关键词**：sk_write_queue、sk_receive_queue、sk_buff、truesize、SO_SNDBUF、SO_RCVBUF、out_of_order_queue、BDP
- **适用场景/边界**：
  - TCP 性能调优（缓冲区大小对吞吐量的影响）
  - 网络问题诊断（发送/接收队列堆积意味着什么）
  - 边界：仅讨论 TCP socket 缓冲区；UDP socket 无发送队列（直接发包）

## 二、详细解析（≥200字）

### 2.1 Socket 缓冲区核心结构

```c
struct sock {
    struct sk_buff_head sk_write_queue;     // 发送队列（未确认数据）
    int sk_sndbuf;                          // 发送缓冲区大小限制
    atomic_t sk_wmem_alloc;                 // 已分配的发送内存
    struct sk_buff_head sk_receive_queue;   // 接收队列（已排序未读数据）
    int sk_rcvbuf;                          // 接收缓冲区大小限制
    atomic_t sk_rmem_alloc;                 // 已分配的接收内存
    struct sk_buff_head sk_error_queue;     // 错误队列
};

struct tcp_sock {
    u32 snd_nxt;            // 下一个要发送的序列号
    u32 snd_una;            // 最小的未确认序列号
    u32 rcv_nxt;            // 期望接收的下一个序列号
    u32 copied_seq;         // 用户已读取的序列号
    struct sk_buff_head out_of_order_queue; // 乱序数据队列
};
```

### 2.2 发送队列与接收队列的本质区别

| 特性 | 发送队列 (sk_write_queue) | 接收队列 (sk_receive_queue) |
|------|--------------------------|---------------------------|
| 数据状态 | 未确认（等待 ACK） | 已确认但未读（等待 recv） |
| 数据顺序 | 发送顺序 | 按 TCP 序列号严格有序 |
| 可变性 | 可能被重传/合并 | 不可变（只待消费） |
| 生命周期 | ACK 后释放 | recv 读取后释放 |
| 背压机制 | sk_stream_memory_free 检查 | sk_rmem_schedule 检查 |

## 三、动手实践（代码案例）

### 3.1 缓冲区大小设置

```c++
int sockfd = socket(AF_INET, SOCK_STREAM, 0);
int buf_size = 256 * 1024;  // 256KB
setsockopt(sockfd, SOL_SOCKET, SO_SNDBUF, &buf_size, sizeof(buf_size));
setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, &buf_size, sizeof(buf_size));

// 注意：内核实际分配值 = 设置值 * 2（为 sk_buff 开销预留）
socklen_t optlen = sizeof(buf_size);
getsockopt(sockfd, SOL_SOCKET, SO_SNDBUF, &buf_size, &optlen);
// buf_size 现在可能是 524288 (512KB = 256K * 2)
```

### 3.2 查看队列堆积状态

```bash
# ss 命令查看 socket 队列
ss -tnp | grep ESTAB
# Recv-Q: 接收队列中未读数据量
# Send-Q: 发送队列中未确认数据量

# /proc/net/tcp 查看队列（十六进制）
cat /proc/net/tcp
# 第5列: tx_queue:rx_queue（如 00000000:00000000）
```

## 四、进阶应用（≥500字）

### 4.1 BDP（带宽延迟积）与缓冲区调优

BDP = RTT × Bandwidth，决定了"在途"数据的最大量。缓冲区小于 BDP 会限制吞吐：

```
100ms RTT × 1Gbps = 0.1s × 125MB/s = 12.5MB
→ 需要至少 12.5MB 的缓冲区才能填满带宽

默认 Linux 缓冲区：net.ipv4.tcp_wmem = 4096 65536 16777216
→ 最大 16MB，能满足 1Gbps@100ms RTT 场景
```

### 4.2 发送队列内存管理

```c
// 发送缓冲区空间检查（决定 send() 是否返回 EAGAIN）
static inline bool sk_stream_memory_free(const struct sock *sk) {
    return sk->sk_wmem_queued < sk->sk_sndbuf;
}

// 分配 sk_buff 并计入发送内存
struct sk_buff *sk_stream_alloc_skb(struct sock *sk, int size, gfp_t gfp) {
    if (!sk_wmem_schedule(sk, size)) return NULL;  // 超限
    skb = alloc_skb_fclone(size, gfp);
    skb_set_owner_w(skb, sk);  // 计入 sk_wmem_alloc
    return skb;
}
```

### 4.3 乱序队列(out_of_order_queue)的作用

TCP 不丢弃乱序到达的包，暂存到 out_of_order_queue。缺 失的包到达后，从乱序队列逐个合并到有序队列，避免重传所有后续数据。SACK（Selective ACK）选项可告知发送方精确的乱序/缺失范围，减少不必要的重传。

### 4.4 与其他主题的关联

| 关联主题 | 关联点 |
|---------|--------|
| TCP 序列号 | 序列号决定数据在哪个队列和顺序 |
| 拥塞控制 | 拥塞窗口限制发送队列出队速率 |
| 零拷贝 | sendfile 绕过发送队列的管理开销 |
| epoll | epoll_wait 检查接收队列是否非空 |

## 五、源码解析和实践感悟（≥1000字）

### 5.1 tcp_sendmsg 数据入队流程

```c
int tcp_sendmsg(struct sock *sk, struct msghdr *msg, size_t size) {
    struct tcp_sock *tp = tcp_sk(sk);
    int copied = 0;
    
    while (size > 0) {
        // 1. 检查发送缓冲区空间
        if (!sk_stream_memory_free(sk)) {
            sk_stream_wait_memory(sk, &timeo);  // 阻塞或 EAGAIN
        }
        // 2. 分配 sk_buff
        skb = sk_stream_alloc_skb(sk, select_size(sk), sk->sk_allocation);
        // 3. 从用户空间拷贝数据
        err = skb_copy_from_iter(skb, &msg->msg_iter, copy);
        // 4. 设置 TCP 控制信息（序列号）
        TCP_SKB_CB(skb)->seq = tp->write_seq;
        TCP_SKB_CB(skb)->end_seq = tp->write_seq + copy;
        // 5. 加入发送队列
        __skb_queue_tail(&sk->sk_write_queue, skb);
        tp->write_seq += copy;
        // 6. 触发实际发送（可能受拥塞窗口限制）
        tcp_push(sk, flags, mss_now, TCP_NAGLE_PUSH, size_goal);
    }
    return copied;
}
```

### 5.2 tcp_clean_rtx_queue ACK 确认后清理

```c
static int tcp_clean_rtx_queue(struct sock *sk, int prior_fackets) {
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;
    
    skb_rbtree_walk_from(skb) {
        u32 ack_seq = TCP_SKB_CB(skb)->end_seq;
        // 检查是否被 ACK 完全确认
        if (after(ack_seq, tp->snd_una)) {
            if (before(TCP_SKB_CB(skb)->seq, tp->snd_una)) {
                tcp_fragment_tstamp(sk, skb);  // 部分确认，分割
            } else {
                break;  // 未确认，停止遍历
            }
        }
        // 完全确认：从队列移除并释放
        tcp_unlink_write_queue(skb, sk);
        sk_wmem_free_skb(sk, skb);
    }
}
```

### 5.3 动态接收缓冲区调节

```c
void tcp_rcv_space_adjust(struct sock *sk) {
    // 根据实际消费速率动态扩大接收缓冲区
    space = 2 * (tp->copied_seq - tp->rcvq_space.seq);
    if (tp->rcvq_space.space != space) {
        int rcvmem = SKB_TRUESIZE(min(space, sk->sk_rcvbuf >> 1));
        if (rcvmem > sk->sk_rcvbuf)
            sk->sk_rcvbuf = min(rcvmem, sysctl_tcp_rmem[2]);  // 不超过系统上限
    }
}
```

### 5.4 实践感悟

1. **SO_SNDBUF 实际值翻倍的原因**：内核为每个 sk_buff 预留 `skb_shared_info` 开销，`setsockopt` 的设置值被内核 ×2 → `getsockopt` 读出的是翻倍值。

2. **发送缓冲区满的连锁反应**：`send()` 返回 EAGAIN → 应用层需缓存数据 → 用户空间内存增长 → 若处理不当，应用层 OOM。

3. **接收队列堆积的信号**：`ss -tnp Recv-Q` 非零 → 应用消费速率 < 网络接收速率。解决方案：增大 SO_RCVBUF 或优化应用读取逻辑。

4. **GRO/LRO 对队列的影响**：网卡合并小包后，一次进入接收队列的 sk_buff 可达 64KB，可能导致小 SO_RCVBUF 设置下丢包。

5. **乱序队列的 DoS 风险**：攻击者可发送大量空洞包填满 out_of_order_queue，消耗内存。`tcp_max_reordering` 限制乱序重排程度。

## 六、面试准备

### 6.1 面试高频问答

### 1. 缓冲区类型

```
struct sock {
    // 发送相关
    struct sk_buff_head sk_write_queue;     // 发送队列
    int sk_sndbuf;                          // 发送缓冲区大小限制
    atomic_t sk_wmem_alloc;                 // 已分配的发送内存
    
    // 接收相关  
    struct sk_buff_head sk_receive_queue;   // 接收队列
    int sk_rcvbuf;                          // 接收缓冲区大小限制
    atomic_t sk_rmem_alloc;                 // 已分配的接收内存
    
    // 错误处理
    struct sk_buff_head sk_error_queue;     // 错误队列
};
```

### 2. 缓冲区大小控制

```
// 发送缓冲区大小检查
static inline bool sk_stream_memory_free(const struct sock *sk)
{
    return sk->sk_wmem_queued < sk->sk_sndbuf;
}

// 接收缓冲区大小检查
static inline bool sk_rmem_schedule(struct sock *sk, struct sk_buff *skb, int size)
{
    return size <= sk->sk_forward_alloc ||
           __sk_mem_schedule(sk, size, SK_MEM_RECV);
}
```

## 二、发送队列(sk\_write\_queue)详解

### 1. 发送队列结构

```
// TCP发送队列管理
struct tcp_sock {
    struct sk_buff_head sk_write_queue;     // 继承自sock
    u32 snd_nxt;                           // 下一个要发送的序列号
    u32 snd_una;                           // 未确认的最小序列号
    u32 packets_out;                       // 已发送但未确认的包数
    u32 retrans_out;                       // 重传的包数
};
```

### 2. 数据入队过程

```
// 用户调用send()时的处理流程
int tcp_sendmsg(struct sock *sk, struct msghdr *msg, size_t size)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;
    int copied = 0;
    
    // 检查连接状态
    if (sk->sk_state != TCP_ESTABLISHED) {
        return -ENOTCONN;
    }
    
    while (size > 0) {
        // 1. 检查发送缓冲区是否有空间
        if (!sk_stream_memory_free(sk)) {
            // 等待缓冲区空间或返回EAGAIN
            sk_stream_wait_memory(sk, &timeo);
        }
        
        // 2. 分配sk_buff
        skb = sk_stream_alloc_skb(sk, select_size(sk), sk->sk_allocation);
        if (!skb) {
            goto wait_for_memory;
        }
        
        // 3. 从用户空间拷贝数据
        copy = min_t(int, copy, skb_availroom(skb));
        err = skb_copy_from_iter(skb, &msg->msg_iter, copy);
        
        // 4. 设置TCP控制块
        TCP_SKB_CB(skb)->seq = tp->write_seq;
        TCP_SKB_CB(skb)->end_seq = tp->write_seq + copy;
        TCP_SKB_CB(skb)->tcp_flags = TCPHDR_PSH | TCPHDR_ACK;
        
        // 5. 加入发送队列尾部
        skb_entail(sk, skb);
        tp->write_seq += copy;
        
        copied += copy;
        size -= copy;
        
        // 6. 触发实际发送
        tcp_push(sk, flags & MSG_MORE, mss_now, 
                TCP_NAGLE_PUSH, size_goal);
    }
    
    return copied;
}
```

### 3. 发送队列的数据发送

```
// 从发送队列发送数据
void __tcp_push_pending_frames(struct sock *sk, unsigned int cur_mss)
{
    struct sk_buff *skb = tcp_send_head(sk);
    
    if (!skb) return;
    
    // 检查拥塞窗口
    if (tcp_packets_in_flight(tp) >= tp->snd_cwnd) {
        return; // 拥塞窗口已满，延迟发送
    }
    
    // 检查Nagle算法
    if (tcp_nagle_check(tp, skb, cur_mss, nonagle)) {
        return; // Nagle算法阻止发送小包
    }
    
    // 实际发送数据包
    if (tcp_transmit_skb(sk, skb, 1, sk->sk_allocation)) {
        // 发送失败，重置发送头指针
        tcp_check_probe_timer(sk);
        return;
    }
    
    // 更新发送状态
    tcp_advance_send_head(sk, skb);
    tp->snd_nxt = TCP_SKB_CB(skb)->end_seq;
    tp->packets_out++;
}
```

### 4. 发送队列的清理机制

```
// 收到ACK时清理已确认的数据
static int tcp_clean_rtx_queue(struct sock *sk, int prior_fackets)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb, *next;
    u32 now = tcp_jiffies32;
    int fully_acked = true;
    u32 packets_acked = 0;
    u32 bytes_acked = 0;
    
    // 遍历发送队列
    skb_rbtree_walk_from(skb) {
        u32 scb_seq = TCP_SKB_CB(skb)->seq;
        u32 ack_seq = TCP_SKB_CB(skb)->end_seq;
        
        // 检查是否被完全确认
        if (after(ack_seq, tp->snd_una)) {
            if (before(scb_seq, tp->snd_una)) {
                // 部分确认，分割skb
                tcp_fragment_tstamp(sk, skb);
            } else {
                fully_acked = false;
                break;
            }
        }
        
        // 完全确认，从队列移除
        next = skb_rb_next(skb);
        if (unlikely(skb == tp->retransmit_skb_hint))
            tp->retransmit_skb_hint = NULL;
        
        tcp_unlink_write_queue(skb, sk);
        sk_wmem_free_skb(sk, skb);
        
        packets_acked++;
        bytes_acked += skb->len;
    }
    
    return packets_acked;
}
```

## 三、接收队列(sk\_receive\_queue)详解

### 1. 接收队列结构

```
struct tcp_sock {
    // 接收相关队列
    struct sk_buff_head sk_receive_queue;   // 有序数据队列
    struct sk_buff_head out_of_order_queue; // 乱序数据队列
    
    // 接收状态
    u32 rcv_nxt;                           // 期望接收的下一个序列号
    u32 copied_seq;                        // 用户已读取的序列号
    u32 rcv_wnd;                          // 接收窗口大小
};
```

### 2. 数据包接收处理

```
// TCP数据包到达时的处理
static void tcp_data_queue(struct sock *sk, struct sk_buff *skb)
{
    struct tcp_sock *tp = tcp_sk(sk);
    u32 seq = TCP_SKB_CB(skb)->seq;
    u32 end_seq = TCP_SKB_CB(skb)->end_seq;
    
    // 检查序列号是否正确
    if (before(seq, tp->rcv_nxt)) {
        // 重复数据或旧数据，直接丢弃
        __kfree_skb(skb);
        return;
    }
    
    // 按序到达的数据
    if (seq == tp->rcv_nxt) {
        // 直接加入接收队列
        __skb_queue_tail(&sk->sk_receive_queue, skb);
        tp->rcv_nxt = end_seq;
        
        // 通知用户进程数据就绪
        sk_data_ready(sk);
        
        // 尝试处理乱序队列中的数据
        tcp_ofo_queue(sk);
        
        // 更新接收窗口
        tcp_rcv_space_adjust(sk);
    } 
    // 乱序到达的数据
    else if (after(seq, tp->rcv_nxt)) {
        // 加入乱序队列
        tcp_data_queue_ofo(sk, skb);
        
        // 发送SACK信息
        tcp_send_dupack(sk, skb);
    }
}
```

### 3. 乱序队列处理

```
// 处理乱序数据队列
static void tcp_ofo_queue(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    __u32 dsack_high = tp->rcv_nxt;
    bool fin, fragstolen, eaten;
    struct sk_buff *skb, *tail;
    struct rb_node *p;
    
    // 遍历乱序队列的红黑树
    p = rb_first(&tp->out_of_order_queue);
    while (p) {
        skb = rb_to_skb(p);
        
        if (after(TCP_SKB_CB(skb)->seq, tp->rcv_nxt))
            break;
            
        // 检查是否可以合并到有序队列
        if (TCP_SKB_CB(skb)->seq == tp->rcv_nxt) {
            // 移动到有序队列
            rb_erase(&skb->rbnode, &tp->out_of_order_queue);
            __skb_queue_tail(&sk->sk_receive_queue, skb);
            tp->rcv_nxt = TCP_SKB_CB(skb)->end_seq;
            
            // 通知应用程序
            sk_data_ready(sk);
        } else {
            // 重复数据，删除
            rb_erase(&skb->rbnode, &tp->out_of_order_queue);
            __kfree_skb(skb);
        }
        
        p = rb_first(&tp->out_of_order_queue);
    }
}
```

### 4. 用户读取数据

```
// 用户调用recv()时的处理
int tcp_recvmsg(struct sock *sk, struct msghdr *msg, size_t len, 
                int nonblock, int flags, int *addr_len)
{
    struct tcp_sock *tp = tcp_sk(sk);
    int copied = 0;
    u32 peek_seq = tp->copied_seq;
    
    while (len > 0) {
        struct sk_buff *skb;
        u32 offset;
        
        // 从接收队列获取数据包
        skb = skb_peek(&sk->sk_receive_queue);
        if (!skb) {
            // 没有数据，根据阻塞标志决定等待或返回
            if (nonblock) {
                copied = copied ? : -EAGAIN;
                break;
            }
            sk_wait_data(sk, &timeo, NULL);
            continue;
        }
        
        // 计算可复制的数据长度
        offset = peek_seq - TCP_SKB_CB(skb)->seq;
        if (offset < skb->len) {
            int used = skb->len - offset;
            if (len < used) used = len;
            
            // 复制数据到用户空间
            if (skb_copy_datagram_msg(skb, offset, msg, used)) {
                if (!copied) copied = -EFAULT;
                break;
            }
            
            copied += used;
            len -= used;
            peek_seq += used;
            
            // 如果skb数据全部被读取，从队列移除
            if (offset + used == skb->len) {
                __skb_unlink(skb, &sk->sk_receive_queue);
                __kfree_skb(skb);
            }
        }
    }
    
    // 更新已读取的序列号
    tp->copied_seq = peek_seq;
    
    // 更新接收窗口
    tcp_rcv_space_adjust(sk);
    
    return copied;
}
```

## 四、缓冲区内存管理

### 1. 发送缓冲区内存管理

```
// 发送缓冲区内存分配
struct sk_buff *sk_stream_alloc_skb(struct sock *sk, int size, gfp_t gfp)
{
    struct sk_buff *skb;
    
    // 检查socket内存限制
    if (!sk_wmem_schedule(sk, size))
        return NULL;
    
    // 分配sk_buff
    skb = alloc_skb_fclone(size, gfp);
    if (!skb) {
        sk->sk_prot->enter_memory_pressure(sk);
        sk_stream_moderate_sndbuf(sk);
        return NULL;
    }
    
    // 计入socket发送内存
    skb_set_owner_w(skb, sk);
    return skb;
}

// 释放发送缓冲区内存
void sk_wmem_free_skb(struct sock *sk, struct sk_buff *skb)
{
    sock_set_flag(sk, SOCK_QUEUE_SHRUNK);
    sk->sk_wmem_queued -= skb->truesize;
    sk_mem_uncharge(sk, skb->truesize);
    __kfree_skb(skb);
}
```

### 2. 接收缓冲区内存管理

```
// 接收缓冲区空间检查
bool sk_rmem_schedule(struct sock *sk, struct sk_buff *skb, int size)
{
    // 检查接收缓冲区限制
    if (atomic_read(&sk->sk_rmem_alloc) + size >= sk->sk_rcvbuf) {
        // 缓冲区已满，尝试清理
        if (!sk_rmem_schedule_force(sk, size))
            return false;
    }
    
    // 分配内存并计入socket接收内存
    atomic_add(size, &sk->sk_rmem_alloc);
    skb_set_owner_r(skb, sk);
    return true;
}

// 动态调整接收缓冲区大小
void tcp_rcv_space_adjust(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    int time, space;
    
    if (tp->rcvq_space.time == 0)
        goto new_measure;
        
    time = tcp_jiffies32 - tp->rcvq_space.time;
    if (time < (tp->rcv_rtt_est.rtt >> 3) || tp->rcv_rtt_est.rtt == 0)
        return;
        
    // 计算新的接收窗口大小
    space = 2 * (tp->copied_seq - tp->rcvq_space.seq);
    space = max(tp->rcvq_space.space, space);
    
    if (tp->rcvq_space.space != space) {
        int rcvmem;
        tp->rcvq_space.space = space;
        
        // 调整接收缓冲区大小
        if (sk->sk_userlocks & SOCK_RCVBUF_LOCK)
            return;
            
        rcvmem = SKB_TRUESIZE(min(tp->rcvq_space.space,
                                 sk->sk_rcvbuf >> 1));
        if (rcvmem > sk->sk_rcvbuf) {
            sk->sk_rcvbuf = min(rcvmem, sock_net(sk)->ipv4.sysctl_tcp_rmem[2]);
        }
    }

new_measure:
    tp->rcvq_space.seq = tp->copied_seq;
    tp->rcvq_space.time = tcp_jiffies32;
}
```

## 五、队列与缓冲区的协作机制

### 1. 流量控制

```
// TCP窗口通告计算
u16 tcp_select_window(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    u32 old_win = tp->rcv_wnd;
    u32 cur_win = tcp_receive_window(tp);
    u32 new_win = __tcp_select_window(sk);
    
    // 基于接收缓冲区可用空间计算窗口
    if (new_win < cur_win) {
        // 窗口收缩，需要特殊处理
        new_win = ALIGN(cur_win, 1 << tp->rx_opt.rcv_wscale);
    }
    tp->rcv_wnd = new_win;
    return new_win >> tp->rx_opt.rcv_wscale;
}
```

### 2. 背压机制

```
// 接收缓冲区满时的处理
static int tcp_prune_queue(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    
    // 清理乱序队列
    tcp_collapse_ofo_queue(sk);
    
    // 压缩接收队列
    tcp_collapse(sk, &sk->sk_receive_queue, NULL, NULL, 
                tp->copied_seq, tp->rcv_nxt);
    
    // 如果还是不够，丢弃数据
    if (atomic_read(&sk->sk_rmem_alloc) >= sk->sk_rcvbuf)
        tcp_prune_ofo_queue(sk);
        
    return 0;
}
```

### 3. 性能优化

```
// 批量接收优化(GRO - Generic Receive Offload)
void tcp_gro_receive(struct sk_buff *skb)
{
    // 将相关的小包合并成大包
    // 减少上层协议栈的处理次数
    if (tcp_gro_lookup(skb)) {
        // 合并到现有连接
        skb_gro_pull(skb, thlen);
    } else {
        // 创建新的GRO连接
        NAPI_GRO_CB(skb)->flush = 0;
    }
}
```

## 六、调优参数

### 1. 系统级参数

```
# 发送缓冲区大小 (最小值 默认值 最大值)
net.ipv4.tcp_wmem = 4096 65536 16777216

# 接收缓冲区大小 (最小值 默认值 最大值)  
net.ipv4.tcp_rmem = 4096 87380 16777216

# 总内存限制
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
```

### 2. Socket级调优

```
// 应用程序可以调整缓冲区大小
int buf_size = 256 * 1024; // 256KB
setsockopt(sockfd, SOL_SOCKET, SO_SNDBUF, &buf_size, sizeof(buf_size));
setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, &buf_size, sizeof(buf_size));
```

## 总结

Socket的发送接收队列和缓冲区是TCP可靠传输的核心机制：

**发送队列特点：**

* 存储用户数据直到被确认
* 支持重传机制
* 实现流量控制和拥塞控制
* 内存使用受到严格限制

**接收队列特点：**

* 按序存储已确认的数据
* 处理乱序数据重组
* 支持动态窗口调整
* 实现零拷贝优化

**缓冲区管理：**

* 动态内存分配和回收
* 背压机制防止内存耗尽
* 与网络层协作优化性能
* 支持多种调优策略

这些机制共同保证了TCP的可靠性、高效性和公平性。

## 六、面试准备

### 6.1 面试高频问答

**Q1：TCP 发送缓冲区满了会怎样？**

A：`send()` 返回 `EAGAIN`（非阻塞）或阻塞等待（阻塞模式）。内核通过 `sk_stream_memory_free()` 检查 `sk_wmem_queued < sk_sndbuf`。

**Q2：发送队列和接收队列的本质区别？**

A：发送队列存"未确认"数据（等待 ACK），接收队列存"已确认但未读"数据（等待 `recv`）。发送队列数据可能被重传，接收队列数据有序且不可变。

**Q3：sk_buff 为什么用链表管理？**

A：TCP 数据流可能被分段/合并，链表支持高效的插入、删除、重组操作，且支持零拷贝（共享数据页）。

**Q4：缓冲区大小如何影响吞吐？**

A：`RTT * Bandwidth` 决定了需要的缓冲区大小（BDP 带宽延迟积）。缓冲区小于 BDP 会限制吞吐，大于 BDP 浪费内存。`net.ipv4.tcp_rmem/wmem` 动态调整。

**Q5：乱序队列 (out_of_order_queue) 的作用？**

A：TCP 不丢弃乱序到达的包，暂存到乱序队列。当缺失的包到达后，从乱序队列合并到有序队列，避免重传所有后续数据。

**Q6：SO_SNDBUF 和 SO_RCVBUF 设置后实际值为什么翻倍？**

A：内核为每个 sk_buff 预留额外开销（skb_shared_info），实际分配 = 设置值 * 2。`getsockopt` 读取的值是内核实际分配的大小。

### 6.2 陷阱与反问

**陷阱1**：缓冲区设太大 → 内存压力大，单个连接可能占满所有内存
**陷阱2**：非阻塞 send 返回 EAGAIN 不重试 → 数据丢失
**陷阱3**：乱序队列无限增长 → 内存耗尽攻击（需配置 tcp_max_reordering）

**反问**：TCP 的零拷贝是怎么实现的？
*答案：sendfile/splice 系统调用直接将文件页映射到 sk_buff，跳过用户空间拷贝。内核用 page 引用计数管理共享。*

### 6.3 一句话答案

1. **发送队列**：未确认数据的缓存，支持重传和拥塞控制
2. **接收队列**：已确认未读数据，按序排列供 recv 读取
3. **sk_buff**：内核网络数据包核心结构，链表管理支持高效操作
4. **乱序队列**：暂存非顺序到达的数据包，缺失补齐后合并
5. **BDP**：带宽延迟积 = RTT * BW，决定最优缓冲区大小
6. **缓冲区翻倍**：内核预留 skb 开销，SO_SNDBUF 设 256K 实际 512K
