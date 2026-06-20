---
title: Redis内存淘汰
date: 2026-06-20
categories:
  - ["项目学习", "数据库"]
publish: true
---

# Redis 内存淘汰

> 适用范围：Redis 内存管理、缓存淘汰策略、LRU/LFU 算法原理与 C++ 实现

## 一、项目/模块概述

- **模块定位**：Redis 内存淘汰机制是 Redis 缓存系统的关键组件，当内存达到 `maxmemory` 上限时，自动淘汰旧 key 为新 key 腾出空间。
- **技术栈与依赖**：Redis 内核（纯 C）、zmalloc 内存分配器、24 位 LRU 时钟。
- **模块边界**：输入为内存压力信号，输出为被淘汰的 key。上游是写命令，下游是内存释放。

## 二、架构设计

### 设计拆解

**第一层：策略体系**
Redis 提供 8 种淘汰策略：
| 策略 | 范围 | 算法 |
|------|------|------|
| noeviction | — | 直接报错（默认） |
| allkeys-lru | 全部 key | 近似 LRU |
| volatile-lru | 有过期时间的 key | 近似 LRU |
| allkeys-lfu | 全部 key | 近似 LFU |
| volatile-lfu | 有过期时间的 key | 近似 LFU |
| allkeys-random | 全部 key | 随机 |
| volatile-random | 有过期时间的 key | 随机 |
| volatile-ttl | 有过期时间的 key | 按 TTL |

**第二层：近似算法**
Redis 不使用真正的 LRU（需要双向链表 + 哈希表），而是随机采样 N 个 key（默认 5），淘汰其中最久未访问的。每个 key 只多存 24 位时间戳，零链表开销。

**第三层：过期删除的混合策略**
- 惰性删除：访问时检查，CPU 友好但内存可能膨胀
- 定期删除：每 100ms 随机抽查 20 个，过期比例 > 25% 继续扫
- 定时删除：为每个 key 建定时器，大量 key 时 CPU 不可接受（Redis 不用）

### 关键数据结构
```c++
// Redis 近似 LRU 核心：每个对象只需一个 lru 字段
struct RedisObject {
    uint64_t lru;  // 24位LRU时钟或LFU计数器
    void*    ptr;
};
```

## 三、核心实现

### 3.1 近似 LRU 淘汰
```c++
template<size_t SampleSize = 5>
RedisObject* evictByApproximateLRU(std::vector<RedisObject*>& pool) {
    RedisObject* best = nullptr;
    uint64_t best_idle = 0;
    uint64_t now = current_time();
    for (size_t i = 0; i < SampleSize; ++i) {
        size_t idx = random() % pool.size();
        RedisObject* obj = pool[idx];
        uint64_t idle_time = now - obj->lru;
        if (idle_time > best_idle) {
            best_idle = idle_time;
            best = obj;
        }
    }
    return best;
}
```

### 3.2 LFU 对数计数器
```c++
uint8_t LFULogIncr(uint8_t counter) {
    if (counter == 255) return 255;
    double r = (double)rand() / RAND_MAX;
    double baseval = counter - LFU_INIT_VAL;
    if (baseval < 0) baseval = 0;
    double p = 1.0 / (baseval * lfu_log_factor + 1);
    if (r < p) counter++;
    return counter;
}
// 访问 100 次 → counter ≈ 20，访问 1000 次 → 75，访问 100 万次 → 255
```

### 3.3 定期删除的自适应控制
```c++
void activeExpireCycle() {
    const int LOOKUPS = 20;
    const double STALE = 0.25;
    do {
        int expired = 0, sampled = 0;
        for (int i = 0; i < LOOKUPS; ++i) {
            auto key = randomKeyWithTTL();
            if (key && isExpired(key)) { deleteKey(key); expired++; }
            sampled++;
        }
        if (expired <= sampled * STALE) break;
    } while (withinTimeLimit());
}
```

## 四、工程实践

- **与项目中其他模块的集成**：Redis 作为 IM 系统的缓存层，登录 token 存储、在线状态记录均依赖 Redis，淘汰策略直接影响 token 有效性和状态一致性。
- **生产环境考量**：volatile-lru 用于可淘汰的缓存数据（token、验证码）；noeviction 用于不可丢的持久标记数据。错误处理：maxmemory 达上限 + noeviction 时所有写命令返回 OOM 错误。监控：键空间通知 + INFO memory 指标。
- **常见优化策略**：增大 `maxmemory-samples` 到 10（准确度接近真 LRU）；lfu_log_factor 调大以区分高频和超高频 key。

### RDB 和 AOF 的过期键处理

在 RDB 中，以快照形式获取内存中某一时间点的数据副本。**`save` 和 `bgsave` 命令都不会把过期的 key 保存到 RDB 文件中**。当启动 Redis 载入 RDB 文件时：`Master` 不会把过期的 key 载入，而 `Slave` 会把过期的 key 载入（等 Master 同步删除指令后再删，保证主从一致）。

在 AOF 模式下，`REWRITEAOF` 和 `BGREWRITEAOF` 命令也**不会把过期的 key 写入到 AOF 文件中**，能自动删除过期 key。

## 五、源码解析和实践感悟

### 5.1 C++ STL 风格的 O(1) LRU
```c++
template<typename K, typename V>
class LRUCache {
    size_t capacity_;
    std::list<std::pair<K, V>> list_;
    std::unordered_map<K, typename std::list<std::pair<K, V>>::iterator> map_;
public:
    V* get(const K& key) {
        auto it = map_.find(key);
        if (it == map_.end()) return nullptr;
        list_.splice(list_.begin(), list_, it->second); // O(1) 移到头部
        return &list_.front().second;
    }
    void put(const K& key, const V& val) {
        auto it = map_.find(key);
        if (it != map_.end()) { it->second->second = val; list_.splice(...); return; }
        if (list_.size() >= capacity_) { map_.erase(list_.back().first); list_.pop_back(); }
        list_.emplace_front(key, val);
        map_[key] = list_.begin();
    }
};
```

### 感悟
1. **近似算法 > 精确算法**：采样 5 个 key 的 O(1) 代价远低于维护双向链表。
2. **8 位计数器做 LFU 是天才设计**：对数增长 + 时间衰减，一字节表达访问频率的相对热度。
3. **过期比例 > 25% 继续扫**：工程智慧——不是"时间到了就停"而是"势态严重才加班"。
4. **惰性 + 定期 = 责任分摊**：惰性保证热点路径零浪费，定期保底不会无限累积。

## 六、面试准备

### 6.1 高频问法

**Q1：Redis 有哪些内存淘汰策略？**
8 种：noeviction、allkeys-lru/volatile-lru、allkeys-lfu/volatile-lfu、allkeys-random/volatile-random、volatile-ttl。

**Q2：Redis 的 LRU 和真正 LRU 区别？**
Redis 是近似 LRU：随机采样 5 个 key，淘汰最久未访问的。不需要维护全局链表，每个 key 只多 24 位时间戳。

**Q3：LFU 计数器 8 位不会溢出吗？**
对数概率递增，counter 越高递增概率越低。同时有衰减机制。8 位可达 255，够用。

**Q4：为什么用定期删除 + 惰性删除？**
定时删除 CPU 不可接受。惰性删除零 CPU 但内存膨胀。定期删除折中：每 100ms 抽查，自适应控制。

**Q5：C++ 如何实现 O(1) LRU？**
`std::list` + `std::unordered_map`，`splice` 移到头部是 O(1) 关键。

**Q6：allkeys-lru 和 volatile-lru 怎么选？**
全部缓存可淘汰 → allkeys-lru。有持久数据不能丢 → volatile-lru。

**Q7：RDB 时过期键怎么处理？**
写入跳过过期键。载入时 Master 跳过，Slave 保留等同步删除。

**Q8：maxmemory 达上限写命令一定失败？**
noeviction 下写命令全部报错。其他策略先淘汰再写入。一次性写入数据大于已淘汰空间仍会失败。

**Q9：Redis 内存淘汰和 C++ malloc 淘汰关系？**
本质相同——空间不够选择牺牲者。jemalloc dirty page 衰减借鉴 LRU 思想。

**Q10：如何设计支持 TTL 的 C++ 缓存？**
用 `std::map<time_point, iterator>` 做 TTL 索引，或用 `folly::EvictingCacheMap`。工业级用时间轮管理过期。

**Q11：为什么 LFU 比 LRU 更能反映"热度"？**
LRU 只看"最近什么时候被访问"——一个 key 偶然被访问一次就可能被保留，老的热点也可能被新来的冷数据挤出。LFU 看"最近被访问了多少次"——需要持续被访问才能保持高 counter，偶然访问影响小。LFU 更适合有明显冷热区分的场景。

### 6.2 反问点

| # | 反问 | 要点 |
|---|------|------|
| 1 | maxmemory 没设上限配了淘汰策略？ | maxmemory 默认 0（无限制），策略不生效 |
| 2 | volatile-lru 下无过期时间 key？ | 永远不会被淘汰，退化为 noeviction |
| 3 | 大量 key 集中过期？ | 定期删除持续扫描，CPU 飙升，lazyfree-lazy-expire 缓解 |
| 4 | `std::list::splice` 复杂度？ | O(1)，只调整指针，是 LRU O(1) 关键 |
| 5 | Redis 为什么不用 C++ STL？ | 纯 C 实现 + 自定义 zmalloc 灵活控制内存 |
| 6 | LFU 的对数计数器精度够吗？lfu_log_factor 调整的是什么？ | 调整的是增长速度：factor=10 时 100 次访问 counter≈25，factor=100 时≈10。factor 越大越区分高频和超高频。 |

### 6.3 一句话答案
- Redis LRU = 随机采样 + 最久未访问，近似但省内存
- LFU = 对数概率递增 + 时间衰减，8 位表达热度
- 定期删除 = 过期比例 > 25% 继续扫，CPU 与内存动态平衡
- C++ LRU = `list` + `unordered_map`，splice O(1) 是精髓
- volatile vs allkeys：volatile 只淘汰有 TTL 的，allkeys 全淘汰
- RDB 过期处理：写入跳过，载入 Master 跳过 Slave 保留
- noeviction = 写失败读正常，绝不丢数据

## 附录

### 参考链接
- [Redis内存满了怎么办？8种内存淘汰策略](https://developer.aliyun.com/article/1253882)
- [Redis内存淘汰](https://zhuanlan.zhihu.com/p/142893249)
