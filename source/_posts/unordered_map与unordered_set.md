---
title: unordered_map与unordered_set
date: 2026-06-20
categories:
  - ["系统底层408", "数据结构"]
publish: true
---

# unordered_map与unordered_set

[【C++】unordered\_set和unordered\_map的实现-腾讯云开发者社区-腾讯云](https://cloud.tencent.com/developer/article/2539447)

##### [C++ 手写实现 unordered\_map 和 unordered\_set：深入解析与源码实战-腾讯云开发者社区-腾讯云](https://cloud.tencent.com/developer/article/2530380)

工程里使用unordered\_map去充当local\_cache、黑白名单、路由表等功能时，所存储的key都是用户id、时间、版本号、设备号等拼接得到，大流量下各个桶整体负载均衡，并且因为都是内部请求，所以一般是不考虑大家说的hack的情况的；即使真的发生了，熔断、限流、容灾等基础设施也能快速发现和限制问题，所以和大家做coding题的场景考虑的点不一样

1. **默认选择 unordered\_map**

+ 在90%的业务场景中提供最佳性能
+ 适合基于键的快速查找场景

2. **为有序需求选择 map**

+ 需要范围查询、顺序遍历、有序键聚合
+ 数据规模较小时内存开销更优

##### 哈希表的基本概念

哈希表是现代计算机科学中最重要的数据结构之一。它通过一个神奇的"哈希函数"，将键映射到特定的存储位置，实现了近乎O(1)的查找、插入和删除操作。

###### 哈希表的数学模型

设计一个完美的哈希表需要考虑以下数学原理：

* 哈希函数的均匀分布性 装载率
* 冲突解决策略
* 负载因子的平衡 扩容

#### 从零构建哈希表框架

##### 4.1 哈希节点结构

```
template<class T>
struct HashNode {
T _data;
HashNode<T>* _next;
HashNode(const T& data) : _data(data), _next(nullptr) {}
};
```

##### 4.2 哈希函数定义

```
template<class K>
struct HashFunc {
size_t operator()(const K& key) const {
    return static_cast<size_t>(key);
}
};

// 特化版本支持 string
template<>
struct HashFunc<std::string> {
size_t operator()(const std::string& key) const {
    size_t hash = 0;
    for (char ch : key) hash = hash * 131 + ch;
    return hash;
}
};
```

##### 4.3 哈希表接口结构

```
template<class K, class T, class KeyOfT, class Hash>
class HashTable {
vector<HashNode<T>*> _tables;
size_t _n;

public:
bool Insert(const T& data);
Iterator Begin();
Iterator End();
};
```

#### 扩容机制与性能调优建议

##### 9.1 扩容策略：质数数组

采用质数作为哈希桶数量有助于减少哈希冲突。

```
static const size_t prime_list[] = {
53, 97, 193, 389, 769, 1543, 3079,
6151, 12289, 24593, 49157, 98317, 196613
};
```

##### 9.2 负载因子 (load factor)

常设阈值为 1.0，当元素个数达到桶总数时扩容，可动态调整：

```
if (_n >= _tables.size()) Expand();
```

##### 9.3 哈希冲突优化

* 自定义哈希函数（如 BKDRHash）
* 增加桶数量，减少冲突链长度
* 使用链表以外的冲突解决（如开放定址）

![](../../资源/图片/yuque_85f220b833c9.png)

##### 1.2 哈希函数的设计艺术

```
// 简单哈希函数示例
size_t simpleHash(const std::string& key) {
    size_t hash = 0;
    for (char c : key) {
        hash = hash * 31 + c;
    }
    return hash;
}

// 现代哈希函数（模板版本）
template <typename T>
struct HashFunction {
size_t operator()(const T& key) const {
    return std::hash<T>{}(key);
}
};
```

##### unordered\_map的内部实现原理

```
template <typename Key, typename Value, typename Hash = std::hash<Key>>
class MyUnorderedMap {
private:
    // 内部桶数组
    std::vector<std::list<std::pair<Key, Value>>> buckets;
    
    // 哈希函数
    Hash hashFunc;
    
    // 计算桶的索引
    size_t getBucketIndex(const Key& key) {
        return hashFunc(key) % buckets.size();
    }

public:
    // 插入操作
    void insert(const std::pair<Key, Value>& kvPair) {
        size_t index = getBucketIndex(kvPair.first);
        auto& bucket = buckets[index];
        
        // 检查是否已存在
        for (auto& item : bucket) {
            if (item.first == kvPair.first) {
                item.second = kvPair.second;
                return;
            }
        }
        
        bucket.push_back(kvPair);
    }
};
```

#### unordered_set的实现原理

---

# 五、源码解析和实践感悟

## 1. GCC std::unordered_map 的桶结构——单向链表+迭代器

GCC libstdc++ 的 unordered_map 采用开链法：桶数组存指向单向链表头的指针，所有节点通过 `_M_nxt` 串联。迭代器遍历整个哈希表时跳过空桶。

```cpp
// GCC libstdc++ unordered_map 内部结构（简化）
// hashtable.h
template<typename Key, typename Value, typename Hash, typename Alloc>
class _Hashtable {
    // 桶数组：存指向各桶链表头节点的指针
    __bucket_type*    _M_buckets;          // HashNode** 数组
    size_type         _M_bucket_count;     // 桶数量（质数）
    __node_base       _M_before_begin;     // 哨兵头节点
    size_type         _M_element_count;    // 元素总数
    float             _M_max_load_factor;  // 默认 1.0
    
    // 核心查找：计算 hash → 定位桶 → 遍历该桶链表
    iterator find(const key_type& __k) {
        auto __code = this->_M_hash_code(__k);  // 计算哈希值
        size_type __bkt = _M_bucket_index(__code); // hash % bucket_count
        auto __node = _M_find_node(__bkt, __k, __code);
        return __node ? iterator(__node) : end();
    }
    
    // 当 _M_element_count > bucket_count * max_load_factor 时触发 rehash
    void rehash(size_type __n) {
        // 1. 找到 >= n 的下一个质数
        auto __nbuckets = __next_prime(__n);
        // 2. 分配新桶数组
        auto __new_buckets = allocate_buckets(__nbuckets);
        // 3. 逐个节点重新计算桶索引，插入新桶（头插法）
        for (auto __node = _M_begin(); __node; ) {
            auto __next = __node->_M_next();
            size_type __bkt = _M_bucket_index(__node, __nbuckets);
            __node->_M_nxt = __new_buckets[__bkt];
            __new_buckets[__bkt] = __node;
            __node = __next;
        }
        _M_buckets = __new_buckets;
        _M_bucket_count = __nbuckets;
    }
};
```

## 2. 字符串哈希——BKDR Hash 与 std::hash 特化

BKDR 是生产中最常用的字符串哈希（种子 131/1313/13131），分布均匀、冲突少。std::hash 的字符串特化在不同编译器实现各异。

```cpp
// BKDR Hash（被广泛使用，包括 Redis、Java String.hashCode）
size_t BKDRHash(const char* str) {
    size_t hash = 0;
    size_t seed = 131;  // 31, 131, 1313, 13131 均可
    while (*str) {
        hash = hash * seed + (*str++);
    }
    return hash;
}
// 原理：多项式哈希 h = s[0]*seed^(n-1) + s[1]*seed^(n-2) + ... + s[n-1]
// 种子为质数减少 hash 碰撞，131 是经典选择

// std::hash<std::string> 特化（libstdc++ 使用 MurmurHash / CityHash）
template<>
struct hash<std::string> {
    size_t operator()(const std::string& s) const {
        return std::_Hash_impl::hash(s.data(), s.size());
    }
};
// 编译期选择：64 位下可能用 MurmurHash2_64，追求速度和分布均匀
```

## 3. 开链法 vs 开放寻址法——两种冲突解决策略

std::unordered_map 用开链法（链表），但近年来开放寻址法（如 Google SwissTable、absl::flat_hash_map）因缓存友好而崛起。

```cpp
// 开放寻址法——线性探测（简化版）
// 优势：所有数据在同一连续数组中，缓存友好，无指针开销
template<typename K, typename V>
class OpenAddressingHashMap {
    enum State { EMPTY, OCCUPIED, DELETED };
    struct Slot { State state = EMPTY; K key; V value; };
    std::vector<Slot> table_;
    
    bool insert(const K& key, const V& val) {
        size_t idx = hash(key) % table_.size();
        // 线性探测找空位或已删除位
        while (table_[idx].state == OCCUPIED) {
            if (table_[idx].key == key) {
                table_[idx].value = val;  // 更新已有 key
                return true;
            }
            idx = (idx + 1) % table_.size();  // 线性探测
        }
        table_[idx] = {OCCUPIED, key, val};
        return true;
    }
};
// 注意：开放寻址法负载因子需严格控制在 0.7 以下
// SwissTable 用 SIMD 并行探测 16 个槽，是 absl::flat_hash_map 的底层
```

## 实践经验

1. **默认用 unordered_map，需要有序才用 map**：90% 的业务场景不需要有序遍历。unordered_map 的 O(1) 查找 vs map 的 O(logN) 在百万级数据下差距明显（约 5-10 倍）。只有需要范围查询或顺序输出时才选 map。
2. **rehash 是 unordered_map 最大的性能陷阱**：rehash 时所有元素重新哈希+重新插入，O(n) 代价。`reserve()` 提前分配足够桶数可避免多次 rehash，已知元素数量时务必 reserve。
3. **负载因子默认 1.0 是性能和空间的折中**：负载因子高→桶利用率高→内存省但链表变长→查找变慢。降低 `max_load_factor` 到 0.5 可加速查找但多占一倍内存。生产环境根据读写比调整。
4. **自定义类型做 key 必须实现两个东西**：`std::hash<MyType>` 特化（提供哈希函数）和 `operator==`（解决哈希冲突后的等值判断）。漏一个就编译失败。
5. **工程中不考虑哈希碰撞攻击**：理论上攻击者可构造大量碰撞 key 使 unordered_map 退化到 O(n)。但内部请求场景（用户 ID、版本号做 key）负载均衡，结合熔断限流等基础设施，实际风险可控。
6. **absl::flat_hash_map 在多数场景优于 std::unordered_map**：Google 的 SwissTable 实现用开放寻址+SIMD，缓存友好度碾压 std 的开链法。但接口不完全兼容标准（如 bucket API 缺失），迁移需评估。

---

# 六、面试准备

## 面试问答

**Q1: unordered_map 的底层实现原理？**
A: 开链法哈希表：(1) 桶数组（`vector<node*>`），桶数通常为质数减少冲突；(2) 插入时 hash(key) % bucket_count 定位桶，头插法加入链表；(3) 查找时先定位桶再遍历链表；(4) 当 `size > bucket_count * max_load_factor` 时触发 rehash——找下个质数，所有元素重新哈希插入。平均 O(1)，最坏 O(n)（全碰撞）。

**Q2: map vs unordered_map 怎么选？**
A: map 是红黑树，O(logN) 且有序遍历；unordered_map 是哈希表，O(1) 但无序。选 unordered_map 除非需要：(1) 有序遍历/范围查询；(2) 按 key 排序输出；(3) 数据量很小（<100，此时红黑树内存开销更低）；(4) key 类型无良好哈希函数。

**Q3: 为什么桶数取质数？**
A: 减少哈希冲突。如果桶数是合数（如 2^n），hash % 2^n 只取低 n 位，高位信息丢失，分布不均。质数取模使得所有 bit 参与运算，分布更均匀。GCC 的桶数取质数序列：53, 97, 193, 389, 769...

**Q4: rehash 的过程是怎样的？**
A: (1) 当前元素数超过 `bucket_count * max_load_factor`；(2) 找到 ≥ 当前桶数 2 倍的下一个质数作为新桶数；(3) 分配新桶数组（全为空）；(4) 遍历旧表每个节点，重新 hash 计算新桶索引，头插法插入新桶；(5) 释放旧桶数组。整个过程 O(n)，期间所有迭代器失效。

**Q5: 如何为自定义类型实现 unordered_map 的 key？**
A: 必须提供：(1) `std::hash<MyType>` 特化——实现 `size_t operator()(const MyType&)`；(2) `operator==`——两个对象相等时哈希值也必须相等（hash(key1)==hash(key2) ⇒ key1==key2）。缺一不可：hash 函数确定桶，operator== 在桶内链表精确匹配。

**Q6: 开链法和开放寻址法的区别？各自优劣？**
A: (1) 开链法（std::unordered_map）：每个桶存链表头指针，冲突时链尾追加。优势：负载因子可 >1，删除简单；劣势：指针开销+缓存不友好。(2) 开放寻址法（absl::flat_hash_map）：所有数据在一个数组，冲突时线性/二次探测。优势：缓存友好+无指针开销+省内存；劣势：负载因子必须 <0.7，删除需惰性标记。现代推荐开放寻址（SwissTable 用 SIMD 加速）。

**Q7: 哈希碰撞攻击是什么？怎么防御？**
A: 攻击者构造大量碰撞 key 使哈希表退化为 O(n) 链表，DoS 攻击。防御：(1) 使用随机种子哈希（GCC 已默认启用 per-process random seed）；(2) 用加密哈希（SHA256/SipHash）替代简单哈希，攻击者无法预测碰撞；(3) 桶内链表过长时转红黑树（Java HashMap 做法，C++ 未采用）。

**Q8: `std::hash` 对整数类型的实现是什么？**
A: 对整数类型，`std::hash<int>` 直接返回原值（identity hash）：`return static_cast<size_t>(__val)`。对指针类型，返回 `reinterpret_cast<size_t>(ptr)`。这种设计下，连续 int 的 hash 值也连续，若桶数为 2^n 则严重不均匀——这解释了为什么桶数必须取质数。

## 陷阱与反问

| 陷阱 | 错误认知 | 正确理解 |
|------|---------|---------|
| unordered_map 的遍历顺序会保持 | 遍历顺序取决于桶分布+插入顺序，与 key 大小无关 | rehash 后遍历顺序可能完全改变，不要依赖遍历顺序 |
| `reserve` 和 `rehash` 一样 | reserve 保证能存 n 个元素不 rehash（考虑负载因子），rehash 强制设桶数 | reserve(n) ≈ rehash(ceil(n/max_load_factor)) |
| map 一定比 unordered_map 内存省 | 小数据量时红黑树节点少，但大数据量时哈希表的桶数组+节点指针开销可能更大 | 实际对比取决于 key/value 大小和数据量 |
| 所有平台 std::hash<string> 都一样 | libstdc++ 用 MurmurHash/CityHash，libc++ 用 MurmurHash2，MSVC 用 FNV-1a | 跨平台 hash 值不同，不要持久化 std::hash 的结果 |
| 删除元素后桶的链表自动收缩 | unordered_map 从不自动缩容（rehash 只增不减） | 需要手动 `rehash` 或 swap 技巧收缩 |

## 一句话答案速记表

| 关键词 | 一句话 |
|--------|--------|
| unordered_map | 开链法哈希表，O(1) 平均查找，桶数取质数，负载因子超阈值 rehash |
| map vs unordered_map | 红黑树 O(logN) 有序 vs 哈希表 O(1) 无序，默认选 unordered |
| rehash | 元素数 > 桶数 × 负载因子 → 找下个质数 → 全元素重新哈希插入 |
| 质数桶 | hash % prime 让所有 bit 参与运算，分布均匀减少冲突 |
| 自定义 key | 必须实现 hash<MyType> + operator==，两者缺一不可 |
| BKDR Hash | hash = hash * 131 + c，分布均匀，Redis/Java 默认字符串哈希 |
| 开链 vs 开放寻址 | 开链可 >1 负载但缓存差，开放寻址缓存好但必须 <0.7 |
| SwissTable | Google 的开放寻址+SIMD 并行探测，absl::flat_hash_map 的底层 |
