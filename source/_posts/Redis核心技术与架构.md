---
title: Redis核心技术与架构
date: 2026-06-20
categories:
  - ["项目学习", "数据库"]
publish: true
---

# Redis 核心技术与架构

> 适用范围：Redis 分布式缓存——数据结构底层、持久化 RDB/AOF、主从复制与哨兵、缓存穿透/击穿/雪崩、过期与淘汰策略。

## 写作约束（铁律）

- **原内容一字不删**：所有原有文字、代码、注释、图片必须全部保留，禁止删除任何原内容。
- **只做归纳重组+增加**：在原有内容基础上调整结构、归类，新增内容以"补充"标记。
- **放不进的进附录**：六大段模板容纳不下的原内容，移入最后的「附录」章节，不得丢弃。
- **动笔前先搜索**：做相关知识准备。
- **字数硬指标**：详细解析(二)≥200字、进阶应用(四)≥500字、源码解析与实践感悟(五)≥1000字、面试准备(六)高频问法≥10个且带回答，反问点和一句话答案各≥5个。
- **代码块必须标注语言**：bash 用 `bash`，Redis 命令用 `redis`，禁止无语言标注的裸代码块。

## 一、核心概念

- **定义**：Redis（Remote Dictionary Server）是开源的基于内存的键值存储系统，支持多种数据结构（String、Hash、List、Set、ZSet、Stream 等），常用于缓存、消息队列、分布式锁等场景。核心特性：单线程事件驱动、内存存储 + 持久化、高可用集群方案。
- **关键词**：内存数据库、数据结构服务器、RDB/AOF、主从复制、哨兵、Cluster、缓存穿透/击穿/雪崩、过期删除
- **适用场景/边界**：
  - 缓存（降低数据库压力，热点数据加速）
  - 分布式锁（SETNX + Lua 原子操作）
  - 消息队列（List/Stream/Pub-Sub）
  - 排行榜、计数器（ZSet、String 自增）
  - 不适合：大量大数据存储（内存成本高）、复杂关系查询（用 SQL）

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：单线程模型与高性能**

Redis 采用单线程 Reactor 模型处理命令请求，通过 IO 多路复用（epoll）监听多个客户端连接。单线程避免了锁竞争和上下文切换，配合内存操作，实现极高吞吐量（10 万+ QPS）。Redis 6.0 引入多线程 I/O（仅处理网络读写），核心命令执行仍是单线程。

**第二层：九大数据结构**

| 类型 | 底层实现 | 典型场景 |
|------|---------|---------|
| **String** | SDS（简单动态字符串）/ int | 缓存 JSON、计数器、分布式锁 |
| **Hash** | ziplist / hashtable | 存储对象属性 |
| **List** | quicklist（ziplist + linkedlist） | 消息队列、最新列表 |
| **Set** | intset / hashtable | 去重、共同好友 |
| **ZSet** | ziplist / skiplist + dict | 排行榜、延迟队列 |
| **Stream** | rax 基数树 | 消息队列（持久化+消费组） |

**第三层：持久化机制**

- **RDB（快照）**：定时将内存数据 dump 到磁盘。`save`/`bgsave` 触发，恢复速度快，但可能丢失最后一次快照后的数据。
- **AOF（追加日志）**：记录每条写命令。三种刷盘策略：`always`（每条同步，最安全）、`everysec`（每秒同步，推荐）、`no`（由 OS 决定）。AOF 文件可通过 `bgrewriteaof` 压缩。
- **混合持久化（Redis 4.0+）**：RDB + AOF 结合，RDB 做全量快照，AOF 记录增量，兼顾恢复速度和数据安全。

> 来源: [Redis 高可用配置及持久化 - 腾讯云](https://cloud.tencent.com/developer/article/2654491)

## 三、动手实践（代码案例）

### 3.1 持久化配置

```bash
# RDB 配置（redis.conf）
save 900 1     # 900 秒内至少 1 次修改触发 bgsave
save 300 10    # 300 秒内至少 10 次修改
save 60 10000  # 60 秒内至少 10000 次修改

# AOF 配置
appendonly yes
appendfsync everysec   # 每秒刷盘（推荐）
auto-aof-rewrite-percentage 100  # AOF 文件增长 100% 时自动重写
auto-aof-rewrite-min-size 64mb   # AOF 文件最小 64MB 才触发重写
```

### 3.2 主从复制配置

```bash
# 从节点配置
replicaof 192.168.1.100 6379   # 指定主节点 IP 和端口
replica-read-only yes          # 从节点只读

# 哨兵配置（sentinel.conf）
sentinel monitor mymaster 192.168.1.100 6379 2  # 2 个哨兵同意才判定下线
sentinel down-after-milliseconds mymaster 30000   # 30 秒无响应判定主观下线
sentinel parallel-syncs mymaster 1                # 故障转移时最多 1 个从节点同步
```

### 3.3 缓存穿透/击穿/雪崩解决方案

```redis
# 缓存穿透（查不存在的数据）→ 布隆过滤器 + 缓存空值
SETNX "null:key:id" "" EX 60

# 缓存击穿（热点 key 过期）→ 互斥锁 + 逻辑过期
SET lock:product:1 "locked" NX EX 10  # 获取锁
if lock_acquired: query DB, SET cache, DEL lock

# 缓存雪崩（大量 key 同时过期）→ TTL 加随机值
SET product:1 data EX $((3600 + RANDOM % 300))
```

### 3.4 分布式锁

```redis
# 加锁（SETNX + 过期时间，原子操作）
SET lock:order:123 "client-uuid" NX EX 30

# 解锁（Lua 脚本保证原子性：只释放自己加的锁）
EVAL "
    if redis.call('get', KEYS[1]) == ARGV[1] then
        return redis.call('del', KEYS[1])
    else
        return 0
    end
" 1 lock:order:123 client-uuid
```

> 来源: [Redis 高频面试题总结 - 腾讯云](https://cloud.tencent.com/developer/article/2226772)

## 四、进阶应用（≥500字）

### 主从复制原理

1. **全量同步（RDB）**：
   - Slave 发起 `PSYNC ? -1`
   - Master 执行 `bgsave` 生成 RDB 快照发送给 Slave
   - Slave 清空旧数据，加载 RDB
   - Master 将期间新写入的命令通过 replication buffer 发送给 Slave

2. **增量同步（repl_backlog）**：
   - Master 维护环形 replication backlog buffer
   - Slave 上报 offset，Master 从 backlog 中找到差异指令发送
   - 如果 Slave 的 offset 不在 backlog 中 → 退化为全量同步

### 哨兵（Sentinel）机制

哨兵是 Redis 高可用的核心组件，负责：
- **监控**：定期 PING 主从节点
- **通知**：节点故障时通知管理员
- **自动故障转移**：主节点下线后选举新主节点
- **配置提供者**：客户端通过哨兵获取当前主节点地址

```
Sentinel 集群（3-5 个节点） → 监控 → Redis 主从集群
```

> 来源: [Redis 持久化与高可用 - CSDN](https://blog.csdn.net/2301_78262805/article/details/154238904)

### Redis Cluster（分片集群）

Redis Cluster 通过 hash slot（16384 个槽）分配数据：
- 每个节点负责一部分 slot（`CRC16(key) % 16384`）
- 支持自动故障转移（Gossip 协议）
- 最少 3 主 3 从的高可用部署

### 过期删除与内存淘汰

**过期删除策略**：
- 惰性删除：访问 key 时检查是否过期
- 定期删除：每秒 10 次随机抽取一批 key 检查

**内存淘汰策略（8 种）**：
| 策略 | 行为 |
|------|------|
| `noeviction` | 不淘汰，写入报错（默认） |
| `allkeys-lru` | 全部 key 中 LRU 淘汰 |
| `volatile-lru` | 过期 key 中 LRU 淘汰 |
| `allkeys-lfu` | 全部 key 中 LFU 淘汰 |
| `allkeys-random` | 全部 key 中随机淘汰 |
| `volatile-random` | 过期 key 中随机淘汰 |
| `volatile-ttl` | 过期 key 中 TTL 最小优先淘汰 |

> 来源: [Redis 常见面试题 - 小林coding](https://www.xiaolincoding.com/redis/base/redis_interview.html)

## 五、源码解析和实践感悟（≥1000字）

### Redis 单线程高性能的秘密

Redis 单线程模型的核心是 Reactor 模式 + 非阻塞 I/O：

```
事件循环（aeMain）:
    while (running) {
        aeProcessEvents() → epoll_wait 等待事件
        → 读事件触发 → readQueryFromClient() 读取命令
        → processCommand() 执行命令
        → addReply() 将响应写入输出缓冲区
        → 写事件触发 → sendReplyToClient() 发送给客户端
    }
```

为什么单线程这么快：
1. 内存操作（微秒级）
2. 高效数据结构（ziplist、skiplist、dict 等都是精心优化的）
3. 非阻塞 I/O + epoll（避免线程切换）
4. 避免锁竞争（没有多线程同步开销）

### 难点与易错点

1. **RDB 持久化的写时复制（COW）**

`bgsave` 时 fork 子进程，父子共享内存页。父进程修改数据时触发 COW（复制页再修改），子进程始终看到快照时刻的数据。如果写入频繁，COW 会导致内存瞬时翻倍，需预留足够内存。

2. **AOF 重写的潜在问题**

`bgrewriteaof` 也会 fork 子进程，同样涉及 COW。如果 AOF 文件过大，重写过程中新命令积累在 AOF 重写缓冲区中，子进程完成后父进程需要将缓冲区数据追加到新 AOF 文件，高写入场景可能导致短暂阻塞。

3. **哨兵选举的"脑裂"**

哨兵集群通过 Raft 协议选举 leader 执行故障转移。如果网络分区导致两个哨兵组各自认为对方下线，可能同时进行故障转移。通过 `min-replicas-to-write` 和 `min-replicas-max-lag` 配置可一定程度规避。

4. **分布式锁的误删问题**

```redis
# 错误做法：直接 DEL（可能删除别人的锁）
SET lock:order "client-A" NX EX 30
   # ... 业务超时 30s+，锁过期自动释放
   # client-B 获取了相同的锁
DEL lock:order   # ❌ 删除了 client-B 的锁！

# 正确做法：Lua 原子判断 + 释放
# 必须用 SET 的值（UUID）验证锁的归属
```

5. **大 Key 风险**

单个 Key 的 Value 过大（如 10MB+）导致：
- 主从同步时网络阻塞
- `DEL` 大 Key 阻塞主线程（Redis 4.0+ 可用 `UNLINK` 异步删除）
- 集群 slot 迁移慢

解决方案：拆分大 Key、用 Hash 分 field 存储、UNLINK 异步删除。

### 经验总结（补充）

- **Redis 不适用于"需要强一致"的数据**：RDB 和 AOF 都有数据丢失窗口。金融交易等强一致性场景应直接写数据库，Redis 仅做缓存加速。
- **缓存不是银弹**：正确理解缓存穿透/击穿/雪崩三兄弟，用布隆过滤器防穿透、互斥锁防击穿、随机 TTL 防雪崩。
- **哨兵至少 3 个**：哨兵奇数节点部署（3 或 5），避免脑裂时平票。
- **监控关键指标**：命中率（应 > 95%）、内存使用率、连接数、慢查询日志（`slowlog get`）。

## 六、面试准备（高频问法≥10个，反问点/一句话答案≥5个，均带回答）

### 6.1 高频问法（≥10个）

**基础理解**：

Q1：Redis 为什么这么快？

A：1) 基于内存操作（微秒级）；2) 单线程避免锁竞争和上下文切换；3) I/O 多路复用（epoll）处理高并发连接；4) 高效数据结构（SDS、skiplist、ziplist）；5) Reactor 事件驱动模型。

Q2：Redis 支持哪些数据结构？各自适用什么场景？

A：String（缓存、计数器）、Hash（对象存储）、List（消息队列、时间线）、Set（去重、交并差集）、ZSet（排行榜、延迟队列）、Stream（消息队列，持久化+消费组）、Bitmap（签到统计）、HyperLogLog（UV 统计）、GEO（地理位置）。

Q3：RDB 和 AOF 的区别是什么？

A：RDB 是定时快照，恢复速度快、文件小，但可能丢失最后一次快照后的数据。AOF 是追加写命令日志，数据更安全（最多丢 1 秒），但文件更大、恢复更慢。Redis 4.0+ 推荐混合持久化。

**原理深入**：

Q4：Redis 的过期删除策略是怎样的？

A：惰性删除 + 定期删除结合。惰性删除：访问 key 时检查是否过期，过期则删除。定期删除：每秒 10 次，随机抽取一批 key，删除其中过期的。二者互补：惰性删除保证 CPU 友好，定期删除保证内存友好。

Q5：Redis 的主从复制流程是怎样的？

A：1) Slave 发送 PSYNC 命令；2) 首次连接或 offset 不在 backlog 中 → Master bgsave 生成 RDB 全量同步；3) 同步期间 Master 新命令写入 replication buffer；4) Slave 加载 RDB 后执行 buffer 中的命令；5) 之后通过 replication backlog 增量同步。

Q6：什么是哨兵（Sentinel）模式？它的工作原理是什么？

A：哨兵是 Redis 高可用的监控和自动故障转移组件。哨兵集群通过 Raft 协议选举 leader，leader 负责：监控主从节点（定期 PING）→ 主节点下线判定（主观 + 客观）→ 从节点中选新主（优先级→复制偏移量→ID）→ 通知其他从节点和新主同步 → 通知客户端。

**实践应用**：

Q7：缓存穿透、击穿、雪崩分别是什么？如何解决？

A：
- 穿透：查不存在的数据，请求直达 DB。解决：布隆过滤器 + 缓存空值（短过期）。
- 击穿：热点 key 过期瞬间大量请求打 DB。解决：互斥锁（SETNX）+ 逻辑过期（永不过期，异步更新）。
- 雪崩：大量 key 同时过期或 Redis 宕机。解决：TTL 加随机值 + 多级缓存 + 限流降级。

Q8：如何用 Redis 实现分布式锁？

A：`SET lock:key uuid NX EX 30` 加锁；业务执行；Lua 脚本判断 uuid 后 DEL 解锁。核心：SETNX 保证互斥，EX 防止死锁，UUID 防止误删，Lua 保证判断+删除原子性。生产级可用 Redisson 的 WatchDog 自动续期。

Q9：Redis 的内存淘汰策略有哪些？

A：noeviction（不淘汰）、allkeys-lru（全局 LRU）、volatile-lru（过期 key LRU）、allkeys-lfu（全局 LFU）、volatile-lfu、allkeys-random、volatile-random、volatile-ttl。缓存场景推荐 allkeys-lru。

Q10：Redis 集群方案有哪些？各自的优缺点？

A：1) 主从 + 哨兵：简单，但单主写瓶颈（容量受单机限制）；2) Redis Cluster：分片集群，支持水平扩展，最少 3 主 3 从，但不支持多 key 跨 slot 操作；3) Codis/Proxy 方案：客户端无感，但多一层代理延迟。

### 6.2 反问点/陷阱点（≥5个）

常见的陷阱问题：

- **陷阱问题1**：AOF everysec 一定不丢数据吗？ → 不一定。everysec 是每秒刷盘一次，最多丢 1 秒数据。且如果写入量很大，AOF 缓冲区可能未及时刷盘。追求零丢失用 always 但性能差，或结合主从复制使用。

- **陷阱问题2**：Redis 分布式锁在锁过期但业务未完成时怎么办？ → 这是分布式锁的经典问题。解决：1) 使用 Redisson 的 Watch Dog 自动续期（每 10s 检查并续期 30s）；2) 设置合理的过期时间（至少业务最大耗时 × 2）；3) 业务逻辑做幂等处理。

- **陷阱问题3**：Redis Cluster 支持事务吗？ → 仅支持同一 slot 内的事务。因为 Redis 事务需要所有 key 在同一个节点执行。跨 slot 操作不支持事务，也不支持 multi-key 操作（如 MGET 跨不同 slot 的 key）。

- **陷阱问题4**：为什么 Redis 过期 key 不立即删除？ → 1) 立即删除需要为每个 key 设置定时器，CPU 开销太大；2) Redis 采用惰性 + 定期删除的折中方案，用少量 CPU 换取内存不会无限增长；3) 配合内存淘汰策略兜底。

- **陷阱问题5**：Redis 单线程为什么还能这么高并发？ → 单线程指的是"命令处理"单线程，但网络 I/O 在 Redis 6.0+ 已经多线程化。核心原因：1) 内存操作极快（纳秒级）；2) 单线程省去了锁、上下文切换开销；3) epoll 允许单个线程管理数万连接。

### 6.3 一句话答案（≥5个）

快速记忆要点：

- Redis 快的原因是**内存操作 + 单线程无锁 + epoll 多路复用 + 高效数据结构**四合一
- 持久化选型口诀：**数据安全用 AOF，恢复快用 RDB，二者兼顾用混合持久化**
- 缓存三兄弟解决方案：**穿透加布隆，击穿加锁，雪崩随机 TTL**
- 分布式锁三要素：**SETNX 互斥、EX 防死锁、Lua 原子释放**
- 过期删除双策略：**惰性删除保 CPU，定期删除保内存**

情景模拟答案：

- 当被问到"你们的 Redis 部署架构"时，回答："生产环境 3 主 3 从 Cluster 分片集群，或 1 主 2 从 + 3 哨兵高可用。缓存>1000QPS 时加从节点分担读压力。开启 AOF everysec + 混合持久化。监控命中率（>95%）、内存使用率、慢查询。"

- 当被问到"Redis 和 Memcached 的区别"时，回答："Redis 支持丰富数据结构、持久化、集群方案和 Lua 脚本，功能更全。Memcached 只支持 String，但多线程模型在纯 KV 缓存场景可能有更高吞吐。现代项目优先选 Redis。"

- 当被问到"缓存和数据库一致性如何保证"时，回答："先更新数据库，再删除缓存（Cache Aside 模式）。高一致性要求用延迟双删（删缓存→写DB→延迟 N 秒再删缓存）或订阅 binlog（Canal）+ 异步更新缓存。强一致性场景应直接读写数据库。"

## 附录（模板外原内容收纳）

### 参考链接

**源码分析**：
- [硬核课堂 Redis 解读](https://hardcore.feishu.cn/mindnotes/bmncn1pO2ZhEyFkBgbQ2ttXncsc)

**入门与教程**：
- [Redis 详细入门教程 - 知乎](https://zhuanlan.zhihu.com/p/469102289)
- [Redis 进阶教程 - 知乎](https://zhuanlan.zhihu.com/p/567374196)

**知识总结**：
- [TX Redis 知识总结 - 知乎](https://zhuanlan.zhihu.com/p/534892012)
- [Redis 核心技术基础总结篇](https://chao-xi.github.io/jxredisbook/chap2/10redis_basic_sum/)

**面试参考**：
- [Redis 高频面试题总结 - 腾讯云](https://cloud.tencent.com/developer/article/2226772)
- [Redis 常见面试题 - 小林coding](https://www.xiaolincoding.com/redis/base/redis_interview.html)
