---
title: Redis慢查询日志
date: 2026-06-20
categories:
  - ["项目学习", "数据库"]
publish: true
---

# Redis 慢查询日志

> 适用范围：Redis 性能诊断——slowlog 配置、慢命令识别、源码级记录机制与监控策略。

## 一、核心概念

- **定义**：Redis 慢查询日志（slowlog）用于记录执行时间超过阈值的命令，存储在内存链表中，是 Redis 性能排查的第一入口。
- **关键词**：slowlog-log-slower-than、slowlog-max-len、命令执行时长、内存链表、FIFO
- **适用场景/边界**：
  - 定位执行缓慢的 Redis 命令（KEYS、HGETALL 大 key、ZRANGE 大 ZSet 等）
  - 与 latency monitor 互补：slowlog 按命令粒度，latency 按事件粒度（fork、AOF write 等）
  - 不适合：网络延迟排查（slowlog 不含网络传输时间）、持久化慢查询采集（slowlog 重启丢失）

## 二、详细解析

### slowlog 机制原理

| 维度 | 说明 |
|------|------|
| **存储位置** | `server.slowlog` 双向链表（内存），不写入磁盘，**重启丢失** |
| **记录内容** | id（全局递增）、timestamp（Unix 时间戳）、duration（微秒）、command（命令及参数数组） |
| **记录时机** | 命令执行完成后，在 `call() → processCommand() → slowlogPushEntryIfNeeded()` 中判断 |
| **淘汰策略** | 新记录插入链表头，超过 `slowlog-max-len` 则删除尾部（FIFO） |
| **时间测量** | `ustime() - call_timer`，仅含命令执行时长（微秒），**不含**网络 IO、事件循环等待 |

### 配置参数

```bash
# redis.conf 或 CONFIG SET 动态设置
slowlog-log-slower-than 10000   # 阈值（微秒），10000=10ms，-1=关闭
slowlog-max-len 128             # 最大记录条数，建议 128-1024

# 持久化到配置文件
CONFIG REWRITE
```

**注意**：`slowlog-log-slower-than` 单位是**微秒**，10000 表示记录超过 10ms 的命令。生产建议 10000-50000 微秒（10-50ms）。

### slowlog 不记录的场景

- 命令执行很快但网络延迟高（客户端感知慢 ≠ 服务端执行慢）
- 时间花在事件循环的排队等待上（单线程模型下，前面命令慢会导致后面排队，但排队时间不计入）
- 阻塞性操作如 `BGSAVE`、`BGREWRITEAOF`（这些用 latency monitor 监控）

## 三、动手实践

### 3.1 基本操作

```bash
# 查看最近 10 条慢查询
SLOWLOG GET 10
# 返回示例：
# 1) 1) (integer) 158     # id
#    2) (integer) 1712345678  # timestamp
#    3) (integer) 15000       # duration (微秒)
#    4) 1) "KEYS"             # command
#       2) "*"

# 查看当前慢查询条数
SLOWLOG LEN
# (integer) 42

# 清空慢查询日志（entry_id 不重置！）
SLOWLOG RESET
# OK
```

### 3.2 动态调整配置

```bash
# 设置阈值为 5ms
CONFIG SET slowlog-log-slower-than 5000

# 设置最大 512 条
CONFIG SET slowlog-max-len 512

# 查看当前配置
CONFIG GET slowlog*
```

### 3.3 慢查询巡检脚本（bash）

```bash
#!/bin/bash
# 定时采集 slowlog 存入外部系统
redis-cli SLOWLOG GET 10 | while read line; do
    echo "$(date) $line"
done >> /var/log/redis_slowlog.log
```

## 四、进阶应用

### 4.1 slowlog vs latency monitor 配合

| 工具 | 粒度 | 监控内容 | 典型用途 |
|------|------|---------|---------|
| **SLOWLOG** | 命令级 | 单条命令执行时长 | 定位慢命令（KEYS、HGETALL 大 key） |
| **LATENCY** | 事件级 | fork 耗时、AOF write、过期删除 | 定位阻塞事件（BGSAVE 卡顿） |

**最佳实践**：slowlog 阈值设 10ms，latency monitor 设 50ms。slowlog 先筛出慢命令，若命令本身不慢但系统卡顿，再用 latency monitor 排查阻塞事件。

### 4.2 Redis 7.0+ MONITOR 替代

```bash
# Redis 6.0+ 可用 INFO commandstats 看命令统计
INFO commandstats
# cmdstat_keys:calls=5,usec=50000,usec_per_call=10000.00

# Redis 7.0+ 可用 CLIENT TRACKING 配合 RESP3 推送
```

### 4.3 容易产生慢查询的命令

| 命令 | 风险 | 替代方案 |
|------|------|---------|
| `KEYS *` | 全库扫描，O(N) | `SCAN` 游标迭代 |
| `SMEMBERS` 大集合 | 一次性返回全部元素 | `SSCAN` 分批 |
| `HGETALL` 大哈希 | 返回全部 field-value | `HSCAN` 分批 |
| `SORT` | 复杂度 O(N+M*logM) | 限制排序范围 |
| `ZRANGE` 大 ZSet | 范围查询耗时 | 限制 LIMIT |
| `DEL` 大 key | 阻塞释放内存 | Redis 4.0+ `UNLINK` 异步删除 |
| `FLUSHDB/FLUSHALL` | 同步清理 | `FLUSHDB ASYNC`（4.0+） |

### 4.4 生产巡检策略

```bash
# 1. 定时检查 slowlog 趋势
redis-cli SLOWLOG GET 5 | grep duration

# 2. 看命令统计
redis-cli INFO commandstats | grep -E "cmdstat_(keys|hgetall|smembers)"

# 3. 检查大 key（Redis 4.0+）
redis-cli --bigkeys

# 4. 延迟基线
redis-cli --latency-history
```

---

## 五、源码解析和实践感悟

### 5.1 Redis slowlog 记录机制（源码级）

```c
// Redis slowlog.c — 命令执行完成后记录慢日志
// 每个命令执行后，call() → processCommand() → slowlogPushEntryIfNeeded()
void slowlogPushEntryIfNeeded(client *c, robj **argv, int argc, long long duration) {
    // duration 是命令执行耗时（微秒），在 call() 中用 ustime()-call_timer 计算
    if (server.slowlog_log_slower_than < 0 ||       // -1 表示关闭 slowlog
        duration < server.slowlog_log_slower_than)   // 耗时不达标
        return;
    // 创建 slowlogEntry
    slowlogEntry *se = zmalloc(sizeof(*se));
    se->argc = argc;
    se->argv = zmalloc(sizeof(robj*) * argc);
    for (int j = 0; j < argc; j++) {
        se->argv[j] = decrRefCountVoid ? createStringObject(...) : argv[j];
    }
    se->id = server.slowlog_entry_id++;          // 全剧唯一递增 ID
    se->unix_time = time(NULL);                   // Unix 时间戳
    se->duration = duration;                      // 微秒
    // 插入链表头
    listAddNodeHead(server.slowlog, se);
    // 超过 slowlog-max-len 则移除尾部
    while (listLength(server.slowlog) > server.slowlog_max_len)
        listDelNode(server.slowlog, listLast(server.slowlog));
}
```

### 5.2 SLOWLOG GET 命令实现

```c
// slowlog 存储在 server.slowlog 双向链表中（非磁盘文件）
void slowlogCommand(client *c) {
    if (!strcasecmp(c->argv[1]->ptr, "get")) {
        long count = c->argc == 3 ? strtol(c->argv[2]->ptr, NULL, 10)
                                  : server.slowlog_max_len;
        listIter li;
        listNode *ln;
        listRewind(server.slowlog, &li);
        addReplyArrayLen(c, min(count, listLength(server.slowlog)));
        while (count-- && (ln = listNext(&li))) {
            slowlogEntry *se = ln->value;
            addReplyMapLen(c, 4);
            addReplyBulkCString(c, "id");       addReplyLongLong(c, se->id);
            addReplyBulkCString(c, "timestamp");addReplyLongLong(c, se->unix_time);
            addReplyBulkCString(c, "duration"); addReplyLongLong(c, se->duration);
            addReplyBulkCString(c, "command");  addReplyArrayLen(c, se->argc);
            for (int j = 0; j < se->argc; j++)
                addReplyBulk(c, se->argv[j]);
        }
    } else if (!strcasecmp(c->argv[1]->ptr, "reset")) {
        listEmpty(server.slowlog);  // SLOWLOG RESET 清空链表
        addReply(c, shared.ok);
    } else if (!strcasecmp(c->argv[1]->ptr, "len")) {
        addReplyLongLong(c, listLength(server.slowlog));  // 当前条数
    }
}
```

### 5.3 慢查询配置参数底层存储

```c
// server.h 中的配置项
struct redisServer {
    list *slowlog;                    // 慢查询日志链表（FIFO，新记录插头部）
    long long slowlog_entry_id;       // 全局递增 ID（不会因 RESET 重置）
    long long slowlog_log_slower_than;// 阈值（微秒），-1 关闭
    long long slowlog_max_len;        // 最大条数（CONFIG SET 可动态修改）
};
// 注意：slowlog 仅存内存，不写入磁盘！Redis 重启即丢失。
```

### 实践感悟

1. **slowlog-log-slower-than 单位是微秒**：配置 10000 表示记录超过 10ms 的命令。生产建议 10000-50000 微秒（10-50ms），根据 SLA 调整。
2. **slowlog-max-len 不宜过大**：每条 slowlogEntry 持有命令参数的 robj 引用，内存持续增长。建议 128-1024，足够排查问题。
3. **slowlog 不持久化**：重启丢失，需要持久化采集应使用定时 SLOWLOG GET 存入外部系统，或 INFO commandstats。
4. **慢查询≠阻塞**：slowlog 仅记录命令执行时长，不包含事件循环等待时间，线程模型的空闲时间不计入。
5. **主动 slowlog 巡检**：CRON 定时 `SLOWLOG GET 10` 并对比 duration 是否持续增长，可作为 Redis 性能劣化的早期预警。
6. **latency monitor 互补**：slowlog 按命令粒度，latency monitor 按事件粒度（fork、AOF write、过期删除等），两者结合更全面。

---

## 六、面试准备

### Q1: Redis 慢查询日志如何配置？
**答**：① `CONFIG SET slowlog-log-slower-than 10000`（微秒，10000=10ms）；② `CONFIG SET slowlog-max-len 128`（最大条数）；③ 持久化写入 redis.conf 或 CONFIG REWRITE。

### Q2: SLOWLOG 存储在哪？重启会丢失吗？
**答**：存储在 `server.slowlog` 内存链表中，**重启丢失**。不写入 RDB/AOF。如需持久化采集，用 client 定时 SLOWLOG GET 存入外部系统。

### Q3: slowlog 记录什么时间？为什么我的命令慢但 slowlog 没记录？
**答**：记录命令**执行时长**（微秒），不包含网络 IO、排队等待时间。如果 slowlog 没记录，可能是命令实际执行很快，慢在网络延迟或客户端处理。

### Q4: SLOWLOG GET 返回的 (integer) 是什么？
**答**：返回数组包含 id（全局递增ID）、timestamp（Unix时间戳）、duration（微秒）、command（命令及参数数组）。id 不会因 SLOWLOG RESET 重置。

### Q5: 生产环境 slowlog 设多少合适？
**答**：slowlog-log-slower-than 建议 10000-50000 微秒（10-50ms），取决于业务 SLA；slowlog-max-len 建议 128-1024，过大占内存（每条持有完整命令对象引用）。

### Q6: Redis 慢查询和 MySQL 慢查询的区别？
**答**：Redis slowlog 存内存（重启丢失），MySQL slow_query_log 写文件（持久化）；Redis 记录单命令耗时（微秒级），MySQL 记录 SQL 语句执行时间（秒级）。Redis 的排查更轻量但不够持久。

### Q7: 哪些 Redis 命令最容易产生慢查询？
**答**：KEYS *（全库扫描）、SMEMBERS 大集合、HGETALL 大哈希、SORT、ZRANGE 大ZSet、DEL 大 key（阻塞释放内存）。生产环境用 SCAN 替代 KEYS，控制单次返回量，大 key 用 UNLINK 异步删除。

### Q8: 如何主动监控 Redis 慢查询趋势？
**答**：① 定时执行 `SLOWLOG GET 10` 分析 duration 分布；② 用 `INFO commandstats` 看每个命令调用次数和总耗时（含微秒统计）；③ Redis 4.0+ 的 `--bigkeys` 扫描大 key。

### 面试陷阱

1. **「slowlog 写入 AOF」** → 错！slowlog 纯内存，不参与持久化。
2. **「slowlog 记录总响应时间」** → 错！仅记录命令执行时长（从命令解析完到返回结果前），不含网络传输。
3. **「SLOWLOG RESET 重置 entry_id」** → 错！RESET 清空链表但 entry_id 继续递增。
4. **「slowlog-max-len 越大越好」** → 错！每条持有完整 command robj，128 条足够，1024 以上可能占用显著内存。
5. **「慢查询日志能替代 MONITOR」** → 不能！MONITOR 输出所有命令（含快命令），slowlog 只记录慢命令，两者用途不同。

### 一句话答案速记表

| 关键词 | 一句话答案 |
|-------|-----------|
| slowlog-log-slower-than | 单位微秒，-1关闭，建议 10000-50000 |
| slowlog-max-len | 最大记录条数，FIFO 链表，头插尾删 |
| 存储位置 | 内存 server.slowlog 链表，重启丢失 |
| SLOWLOG GET N | 返回最近 N 条的 id/timestamp/duration/command |
| SLOWLOG RESET | 清空链表，但 entry_id 不重置 |
| KEYS vs SCAN | KEYS 阻塞全库扫描易产生慢查询，用 SCAN 替代 |
| 配合 latency monitor | slowlog 看命令粒度，latency 看事件粒度，互补 |
| 生产巡检 | 定时 SLOWLOG GET + INFO commandstats |

## 附录

### 图片归档

![](../资源/图片/yuque_94b83fee1e4c.png)

### 参考链接

- [Redis 慢查询-腾讯云开发者社区](https://cloud.tencent.com/developer/article/1773944)
- [Redis技术专区：慢查询日志及分析指南](https://juejin.cn/post/7191875255991238693)
- [一文弄懂Redis慢查询](https://juejin.cn/post/7102772566812524552)
