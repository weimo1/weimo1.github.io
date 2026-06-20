---
title: 为什么MySQL数据库索引选择使用B+树而不是跳表？
date: 2026-06-20
categories:
  - ["系统底层408", "数据结构"]
publish: true
---

# 为什么MySQL数据库索引选择使用B+树而不是跳表？

**1、**[**查询效率**](https://zhida.zhihu.com/search?content_id=610269578&content_type=Answer&match_order=1&q=%E6%9F%A5%E8%AF%A2%E6%95%88%E7%8E%87&zhida_source=entity)**：**

B+tree：查询效率相对稳定，因为它的每个节点都包含多个键值和子节点，可以减少查询过程中需要访问的[节点数](https://zhida.zhihu.com/search?content_id=610269578&content_type=Answer&match_order=1&q=%E8%8A%82%E7%82%B9%E6%95%B0&zhida_source=entity)。

跳表：在查找过程中可能需要跳跃多个节点，特别是在[长尾分布](https://zhida.zhihu.com/search?content_id=610269578&content_type=Answer&match_order=1&q=%E9%95%BF%E5%B0%BE%E5%88%86%E5%B8%83&zhida_source=entity)的数据中，查询效率可能会降低。

B+树在范围查询时表现更好。B+树的叶子节点之间通过链表连接，可以支持高效的范围查询操作。跳表在范围查询时需要遍历整个跳表，性能较低。

**2、稳定性：**

[B+tree](https://zhida.zhihu.com/search?content_id=610269578&content_type=Answer&match_order=2&q=B%2Btree&zhida_source=entity)：是一种自平衡的树，可以在插入、删除和更新操作中自动进行平衡，确保树的高度保持相对稳定，从而保证了查询效率的稳定性。

[跳表](https://zhida.zhihu.com/search?content_id=610269578&content_type=Answer&match_order=2&q=%E8%B7%B3%E8%A1%A8&zhida_source=entity)：跳表需要通过手动调整节点的插入和删除来实现平衡，操作相对复杂。

**3、磁盘IO效率：**

B+tree：[B+树](https://zhida.zhihu.com/search?content_id=610269578&content_type=Answer&match_order=1&q=B%2B%E6%A0%91&zhida_source=entity)在物理存储上更加紧凑，每个节点存储的键值对数量更多，可以减少磁盘IO操作次数。

跳表：而跳表需要频繁地访问多个节点，可能会导致较高的磁盘IO开销。

磁盘IO：B+树的结构更适合于磁盘访问。B+树的节点通常比跳表的节点更大，可以减少磁盘IO的次数。此外，由于B+树的叶子节点形成了一个有序链表，可以利用磁盘预读技术提高查询性能。

**4、数据库优化**

MySQL的存储引擎如InnoDB和MyISAM都选择了B+树作为索引结构，这使得[数据库系统](https://zhida.zhihu.com/search?content_id=610269578&content_type=Answer&match_order=1&q=%E6%95%B0%E6%8D%AE%E5%BA%93%E7%B3%BB%E7%BB%9F&zhida_source=entity)内部对B+树的优化更加成熟，性能更优。

**5、内存占用**

B+树的内存占用比跳表更小。B+树的节点通常包含多个键值对，而跳表的每个节点只包含一个键值对。这意味着在相同的数据量下，B+树需要更少的内存来存储索引

B+树更适合保存在硬盘上，并且读取数据时更快。B+树也更擅长做范围查询，就是一次找一大堆接近的数据。跳表虽然也不错，但在这些方面通常不如B+树。

## 为什么MySQL要用[B+树](https://zhida.zhihu.com/search?content_id=241459891&content_type=Article&match_order=1&q=B%2B%E6%A0%91&zhida_source=entity)？

1. 需要[自平衡二叉搜索树](https://zhida.zhihu.com/search?content_id=241459891&content_type=Article&match_order=1&q=%E8%87%AA%E5%B9%B3%E8%A1%A1%E4%BA%8C%E5%8F%89%E6%90%9C%E7%B4%A2%E6%A0%91&zhida_source=entity)
2. 需要尽量降低磁盘IO，也就是说降低树的高度。**基于1，2两点，B树应运而生。**
3. 需要稳定的查询性能。由于B树的数据分布在树的所有结点中，有些数据可能在根节点就查到，有些可能在叶子节点才查到。两者查询时间相差很大，即查询时间不稳定。
4. 需要高效的范围查找。由于B树的数据分布在树的所有结点中，想要查询范围数据就要在不同节点中进进出出，频繁访问节点，由于访问一次节点就要进行一次IO，因此这造成了低效的范围查找。

**基于3，我们把B树的所有节点中的数据部分放到叶子节点中；基于4，我们把B树的所有节点用链表穿起来。**

## 为什么[Redis](https://zhida.zhihu.com/search?content_id=241459891&content_type=Article&match_order=1&q=Redis&zhida_source=entity)要用[跳表](https://zhida.zhihu.com/search?content_id=241459891&content_type=Article&match_order=1&q=%E8%B7%B3%E8%A1%A8&zhida_source=entity)？

1. 跳表实现更加简单方便。
2. 跳表的插入删除操作效率更高**。**B+树需要考虑平衡，节点的分裂合并等复杂的操作，但是跳表的插入删除就比较简单。
3. 跳表的一个节点所占的内存更少。
4. 我们可以发现跳表一般高度都很高，但是B+树的高度很低。这是Redis是存在于内存的，因而不需要想数据库那样想办法尽量减少磁盘IO，也就是降低B+树的高度。

## 总结

* B+树是多叉平衡[搜索树](https://zhida.zhihu.com/search?content_id=202858446&content_type=Article&match_order=1&q=%E6%90%9C%E7%B4%A2%E6%A0%91&zhida_source=entity)，扇出高，只需要3层左右就能存放2kw左右的数据，同样情况下跳表则需要24层左右，假设层高对应**磁盘IO**，那么B+树的读性能会比跳表要好，因此mysql选了B+树做索引。
* redis的读写全在内存里进行操作，不涉及磁盘IO，同时跳表实现简单，相比B+树、AVL树、少了旋转树结构的开销，因此redis使用跳表来实现ZSET，而不是树结构。
* 存储引擎RocksDB内部使用了跳表，对比使用B+树的innodb，虽然写性能更好，但读性能属实差了些。在读多写少的场景下，B+树依旧YYDS。

---

# 五、源码解析和实践感悟

## 1. 跳表内存布局 vs B+树磁盘页——IO 模型决定选择

跳表节点分散在堆内存各处，每个节点通过指针跳跃访问；B+树每个节点恰好一个磁盘页（16KB），一次 IO 加载整个节点，充分利用磁盘预读。

```cpp
// 跳表节点——内存分散
struct SkipListNode {
    int key;
    vector<SkipListNode*> forward;  // 每层指针分散在堆上
};
// 查找第 k 个元素：从最高层开始，逐层下降
SkipListNode* find(int key) {
    auto cur = head;
    for (int level = maxLevel - 1; level >= 0; --level) {
        while (cur->forward[level] && cur->forward[level]->key < key)
            cur = cur->forward[level];  // 每步跳跃到新节点（新 cache line）
    }
    return cur->forward[0];
}
// 问题：每次 forward[level] 都可能 cache miss
// 磁盘场景下每个节点可能在不同磁盘页 → 随机 IO 灾难
```

```cpp
// B+树节点——恰好一个磁盘页
// InnoDB 页大小 16KB，内部二分查找全在已加载的页内完成
struct BPlusTreeNode {
    int num_keys;
    int keys[M];         // M 个 key，连续存储在同一 16KB 页内
    void* children[M];   // M+1 个子节点页号
    bool is_leaf;
};
// 查找路径：根 → 内部节点 → 叶子
// 每步 1 次 IO 加载整页，页内 O(logM) 比较全在内存
// 2000 万行：h=3 → 2 次 IO（根常驻内存）
```

## 2. 为什么 Redis 用跳表而不用 B+树——内存 vs 磁盘

Redis ZSet 用跳表实现有序集合，核心原因：内存中无磁盘 IO，跳表实现简单+插入删除无需旋转。

```c
// Redis 跳表插入（t_zset.c 简化）
zskiplistNode *zslInsert(zskiplist *zsl, double score, sds ele) {
    zskiplistNode *update[ZSKIPLIST_MAXLEVEL];  // 每层前驱
    unsigned int rank[ZSKIPLIST_MAXLEVEL];       // 每层排名
    x = zsl->header;
    for (int i = zsl->level-1; i >= 0; i--) {
        rank[i] = (i == zsl->level-1) ? 0 : rank[i+1];
        while (x->level[i].forward &&
               (x->level[i].forward->score < score ||
                (x->level[i].forward->score == score &&
                 sdscmp(x->level[i].forward->ele, ele) < 0))) {
            rank[i] += x->level[i].span;
            x = x->level[i].forward;
        }
        update[i] = x;
    }
    // 随机生成 level，插入各层
    int level = zslRandomLevel();
    // span 更新：新节点每层的 span = update[i].span - (rank[0] - rank[i])
    // 这就是 ZRANK 能 O(logN) 的原因：span 预计算了排名偏移
}
// 收益：内存中节点分配快（zmalloc），无旋转开销，插入仅改指针
```

## 3. RocksDB 跳表——写优化的内存表

RocksDB 的内存表（MemTable）默认使用跳表而非 B+树，因为跳表的无锁并发写入和简单插入使其成为写入密集型引擎的首选。

```cpp
// RocksDB InlineSkipList——支持并发读的跳表
// 关键设计：
// 1. 节点高度用最低位存"是否完全链接"标记（并发读可见性控制）
// 2. 插入从底层逐层向上链接（保证读到的节点一定完整）
// 3. 不需要全局锁——读写并发安全（写写仍需外部同步）
template<typename Comparator>
void InlineSkipList<Comparator>::Insert(const char* key) {
    // 1. 分配节点 + 随机高度
    // 2. 从最高层向下找每层前驱
    // 3. 从底层向上逐层插入（SetNext + 内存屏障）
    // 4. 顶层最后设置——并发读看到顶层链接=节点完全可用
}
// 为什么 RocksDB 不用 B+树做 MemTable：
// - B+树插入可能触发节点分裂，分裂时需要锁住父节点
// - 跳表插入只影响局部指针，并发度更高
// - MemTable 只读一次就 flush，B+树的读优势（缓存友好）在短暂生命周期中不显著
```

## 实践经验

1. **IO 模型决定数据结构选择**：磁盘场景 B+树胜出（页对齐+低树高→少 IO），内存场景跳表胜出（实现简单+无旋转开销）。判断标准：一次随机 IO ≈ 10ms = 1000 万次 CPU 指令，磁盘上省 1 次 IO 远大于省 100 次 CPU 比较。
2. **B+树高度 vs 跳表高度**：2000 万行数据，B+树约 3 层（2 次 IO），跳表约 24 层（log2(2000万)）。磁盘场景下 24 次随机 IO vs 2 次 IO，差距天壤之别。
3. **跳表的"概率平衡"是双刃剑**：实现比 B+树简单（无需旋转/分裂），但极端情况下可能退化（概率极小）。Redis 的跳表 max level 为 32（2^32 个节点才可能满），实际退化风险可忽略。
4. **MySQL 选 B+树还有生态原因**：InnoDB 对 B+树的优化已经积累了 20+ 年（自适应哈希索引、Change Buffer、AHI 等）。换跳表意味着重写整个存储引擎的页管理、崩溃恢复、MVCC 逻辑——机会成本太高。
5. **RocksDB 证明了"正确的数据结构放对地方"**：内存用跳表（MemTable）+ 磁盘用归并排序（SSTable），写性能优于 InnoDB 的 B+树。不是因为跳表优于 B+树，而是 LSM 架构 + 跳表的组合匹配了写密集型 workload。
6. **不要迷信"理论最优"**：跳表的 O(logN) 和 B+树的 O(logN) 常数差异在磁盘 IO 面前不值一提。工程决策永远是"场景 + 硬件特性 + 实现复杂度"的综合权衡。

---

# 六、面试准备

## 面试问答

**Q1: MySQL 为什么选 B+树而不是跳表？**
A: 四个原因：(1) **磁盘 IO 模型**：B+树每个节点恰好一个磁盘页（16KB），一次 IO 加载数百个 key，跳表节点分散需要多次随机 IO；(2) **树高更低**：B+树分支因子可达 1170，2000 万行仅 3 层，跳表约 24 层；(3) **范围查询**：B+树叶子有链表，一次定位后顺序扫描，跳表需要逐节点跳跃；(4) **稳定性**：B+树严格平衡，跳表是概率平衡。

**Q2: Redis 为什么选跳表而不是 B+树？**
A: (1) 全内存操作，无磁盘 IO，跳表 O(logN) 完全满足；(2) 实现简单——插入删除只改指针，不需要分裂合并+旋转；(3) 内存占用——跳表每个节点存数据+指针，B+树每个节点有大量空槽（页未满），内存利用率低；(4) ZSet 同时存 dict + 跳表，跳表负责排序，复杂度和 B+树相当但代码量小得多。

**Q3: 跳表的高度如何确定？查找复杂度？**
A: 高度随机生成，第 n 层的概率为 1/2^n（Redis 实现）。每个节点平均高度为 2（期望值 ∑1/2^(n-1) = 2），查找/插入/删除复杂度期望 O(logN)，最坏 O(N)（概率极低）。Redis 限制最大高度 32（支持 2^32 个元素）。

**Q4: B+树和跳表在范围查询上的性能差异？**
A: B+树明显更优：叶子节点有双向链表，一次定位后顺序读下一个叶子（可能已在 Buffer Pool 中，不用 IO）。跳表范围查询需要逐节点遍历每层 forward 指针，每个节点都可能 cache miss（内存场景）或随机 IO（磁盘场景）。

**Q5: 为什么 RocksDB 用跳表做 MemTable？**
A: (1) 并发写入友好——跳表插入只修改局部指针，B+树分裂需要锁父节点；(2) 写路径简单——跳表插入无旋转开销；(3) MemTable 生命周期短（几 MB 就 flush），B+树的读优化（缓存友好）在这个场景收益有限；(4) MemTable 是 LSM 架构的写缓冲，写性能优先于读性能。

**Q6: B+树和跳表的空间占用对比？**
A: 内存场景：B+树每个节点有 ~30% 空槽（填充率 ~70%），跳表每个节点额外 2 个指针（平均）+ level 数组。小数据量跳表省，大数据量 B+树因紧凑存储更省（连续内存+无单独节点分配开销）。磁盘场景：B+树完美适配页结构，跳表节点分散导致大量碎片。

**Q7: 跳表的 level 如何生成？Redis 的随机算法？**
A: Redis 用 `zslRandomLevel()`：while (random() & 0xFFFF) < (0.25 * 0xFFFF) level++。每层概率 25%（而非标准的 50%），使跳表更"矮胖"，层数期望更低。上限 32 层。这个 0.25 是经验值，平衡了查找效率和内存开销。

**Q8: "B+树比跳表更适合磁盘"——如果未来磁盘消失（全内存数据库），结论会变吗？**
A: 全内存场景下跳表优势增大：实现简单、无旋转、并发友好。但 B+树的缓存友好性（连续内存）在内存中同样适用。实际趋势：内存数据库（如 Redis）用跳表，嵌入式 KV（如 LevelDB）用跳表做 MemTable + B+树风格的 SSTable 文件格式。两者不是替代关系，而是在不同层各司其职。

## 陷阱与反问

| 陷阱 | 错误认知 | 正确理解 |
|------|---------|---------|
| 跳表一定比 B+树快 | 内存场景跳表插入略快（无旋转），但范围查询和缓存友好性不如 B+树 | 看场景：写密集+内存→跳表，读密集+磁盘→B+树 |
| B+树是严格平衡的所以一定更好 | 平衡的代价是分裂+合并+旋转的复杂逻辑 | 跳表的概率平衡代码量少得多，适合嵌入式场景 |
| RocksDB 用跳表说明跳表比 B+树好 | RocksDB 只在 MemTable 用跳表，磁盘层是 SSTable（类似 B+树的有序文件） | LSM 架构是分层组合：跳表（内存）+ 有序文件（磁盘） |
| 跳表不能持久化 | RocksDB 的 MemTable（跳表）通过 WAL 持久化，然后定期 flush 到 SSTable | 跳表本身不持久，但可作为持久化流程的一部分 |
| B+树和跳表选一个就行 | 现代系统多采用混合方案 | 如 TiKV：Raft Log（顺序）+ RocksDB MemTable（跳表）+ SSTable（有序文件） |

## 一句话答案速记表

| 关键词 | 一句话 |
|--------|--------|
| MySQL 选 B+树 | 磁盘 IO 模型决定：节点=页，3 层存 2000 万行，2 次 IO |
| Redis 选跳表 | 纯内存无 IO，实现简单+无旋转，ZRANK 用 span O(logN) |
| 树高对比 | B+树 3 层，跳表 24 层（2000 万行），磁盘场景差距巨大 |
| 范围查询 | B+树叶子链表一次定位顺序扫，跳表逐节点跳跃 |
| RocksDB MemTable | 跳表并发写友好+简单，写优先场景 |
| 平衡性 | B+树严格平衡（分裂合并），跳表概率平衡（随机层高） |
| 空间 | 磁盘 B+树紧凑（页对齐），内存跳表无空槽浪费 |
| 结论 | 磁盘选 B+树，内存选跳表，LSM 架构两者并用 |
