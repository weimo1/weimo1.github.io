---
title: LSM树
date: 2026-06-20
categories:
  - ["系统底层408", "数据结构"]
publish: true
---

# LSM树

[WiscKey: 在SSD存储中分离键和值](https://zhuanlan.zhihu.com/p/486811231)

[WiscKey 发布的五年后，工业界用上了 KV 分离吗？](https://zhuanlan.zhihu.com/p/397466422)

常见的 LSM 存储引擎，如 LevelDB 和 RocksDB，将用户写入的一组的 key 和 value 存放在一起，按顺序写入 SST。在 compaction 过程中，**引擎将上层的 SST 与下层 SST 合并，产生新的 SST 文件。这一过程中，SST 里面的 key 和 value 都会被重写一遍，**带来较大的写放大。如果 value 的大小远大于 key，compaction 过程带来的写放大会引入巨大的开销。

![](../../资源/图片/yuque_124af861bc3f.png)

在 [WiscKey (FAST ‘16)](https://link.zhihu.com/?target=https%3A//www.usenix.org/conference/fast16/technical-sessions/presentation/lu) 中，作者提出了一种对 SSD 友好的基于 [LSM 树](https://zhida.zhihu.com/search?content_id=176456300&content_type=Article&match_order=1&q=LSM+%E6%A0%91&zhida_source=entity)的存储引擎设计。它通过 KV 分离降低了 LSM 树的写放大。 KV 分离就是将大 value 存放在其他地方，并在 LSM 树中存放一个 value pointer (vptr) 指向 value 所在的位置。在 WiscKey 中，这个存放 value 的地方被称为 Value Log ([vLog](https://zhida.zhihu.com/search?content_id=176456300&content_type=Article&match_order=1&q=vLog&zhida_source=entity))。由此，LSM 树 compaction 时就不需要重写 value，仅需重新组织 key 的索引。这样一来，就能大大减少写放大，减缓 SSD 的磨损。

[关于Wisckey的对话一：追求写性能的代价](https://zhuanlan.zhihu.com/p/443539765)

[关于Wisckey的对话二：新朋友的到来](https://zhuanlan.zhihu.com/p/443632618)

[关于Wisckey的对话三：机遇与挑战](https://zhuanlan.zhihu.com/p/449168046)

SSD的新特性主要集中在三方面：

1. 随机读写与[顺序读写](https://zhida.zhihu.com/search?content_id=186714983&content_type=Article&match_order=1&q=%E9%A1%BA%E5%BA%8F%E8%AF%BB%E5%86%99&zhida_source=entity)的性能差别没有HDD那么大了；
2. SSD拥有了并发随机读能力，速度很快；
3. SSD有数据擦写次数限制，过量的写入会导致SSD报废。

# 经典的LSM实现-LevelDB

适合磁盘的索引结构通常有两种,一种是就地更新(B+Tree),一种是非就地更新(LSM)。就地更新的索引结构拥有最好的读性能(随机读与顺序读)，而随机写性能很差，无法满足现实工业中的工作负载要求。而非就地更新的索引结构-LSM充分发挥顺序写入的高性能特性，成为写入密集的数据系统的基础。

**顺序写入**的写操作时间复杂度为O(1)，但是带来的第一个问题就是同一个key会占用多个存储空间(更新操作)，直观的想法就是有一个无限大的文件可以无限追加数据。那么读取数据就需要从尾部一直读取到头部，找到的第一个key就返回，但是假设第一个key写入后从未更新那么想要读取此key每次就要读取全量的数据其读取复杂度为O(n)，n为写入次数，同时范围查询就需要磁盘排序后输出O(NLogN)

第一个优化想法就是合并这个无限大的文件，将被覆盖的key清理掉，只保留最新的key，但这样就不能在一个文件中操作(你不能边压缩边更新,类似GC)，因此需要将**文件分段**。

每次合并本质上是一次**归并排序**的过程(为了支持范围查询，以及空间压缩)，那么就需要找到所有分段文件中有**重合范围**的文件，进行合并(min\_key与max\_key)。并且不能合并一个正在写入的文件(假设按大小划分文件)。

为了降低读取的复杂度，第一个想法就是**利用内存**，将最近最新写入的kv存储在内存数据结构中，红黑树，跳表等。 那么问题是何时将此数据结构dump到磁盘?最简单的是根据其大小的区别，然而在dump之前我们不能继续向其中写入数据，因此在内存中应该存在一个活跃内存表和一个不变内存表，二者相互交替，周期性的将不变内存表dump到内存中形成一个分段文件。

但这还不够，依旧没有解决最先写入且从未更新的key要读取全量数据的问题，为解决这个问题LSM结构引入了**分层设计**的思想。将所有的kv文件分为c0-ck 共k+1层。c0层是直接从不变的内存表中dump下的结果。而c1-ck是发生过合并的文件。由于ci+1 是ci中具有重叠部分的文件合并的产物，因此可以说在同一层内是不存在重叠key的，因为重叠key已经在其上一层被合并了。那么只有c0层是可能存在重叠的文件的。所以当要读取磁盘上的数据时，最坏情况下只需要读取c0的所有文件以及c1-ck每一层中的一个文件即c0+k个文件即可找到key的位置，分层合并思想使得非就地更新索引在常数次的IO中读取数据。

通常c0文件定义为2M，每一级比上一级大一个数量级的文件大小。所以高层的文件难以被一次性的加载到内存，因此需要一定的磁盘**索引机制**。我们对每个磁盘文件进行布局设计，分为元数据块，索引块，数据块三大块。元数据块中存储布隆过滤器快速的判断这个文件中是否存在某个key，同时通过对排序索引(通常缓存在内存中)二分查找定位key所在磁盘的位置。进而加速读取的速度，我们叫这种数据文件为SSTABLE(字符串排序表)。

为了标记哪些SStable属于那一层因此要存在一个sstable的元数据管理文件，在levelDB中叫做MANIFEST文件。其中存储每一个sstable的文件名，所属的级别，最大与最小key的前缀。

作为一个DB引擎，必须保证数据库进程崩溃前后的数据一致性，常见的做法就是使用**预写日志**。

将所有的操作记录在一个仅追加的log文件中(称之为WAL)，所有的写入操作都要保证写入WAL成功后才能继续，因此当数据库崩溃后写入WAL的操作将被回溯，反之则被丢弃(只有写入WAL成功才会回复客户端ack)。那么从尾部重放这个WAL文件的操作即可恢复DB。

但是这个过程由于会消耗磁盘的空间因此也需要不断的进行压缩，同时如果WAL过大也会使得数据库恢复的时间增大这是不可接受的，为此我们需要支持checkpoint**特性**。

综上我们得到了LSM Tree的实现，本质上他并非是一颗树他是一个整套算法的集合，本质上是一种思想，而非一种单一的数据结构，而对这种的一种经典实现即是[LevelDB](https://github.com/google/leveldb)。

![](../../资源/图片/yuque_461d2d8bda06.png)

# 机遇与挑战

LSM 是以牺牲读取性能以及空间利用率为代价而换取顺序写入性能的。因此，对LSM结构的优化目标就是想办法提高读取性能和空间利用率。

读取性能的瓶颈在于读写放大以及合并压缩过程的抖动,以下列出LSM可能选择的优化方向:

![](../../资源/图片/yuque_a3ef313b3762.png)

# KV分离对SSD的优化

在SSD上使用LSM技术带来两个问题，第一写放大缩短了SSD的使用寿命，第二，传统的LSM无法充分发挥SSD的并行读写特性。

相较于机械硬盘，随机读取与顺序读取的性能，固态硬盘远没有那么明显的差距，这就意味着过分追求顺序读取而进行的激进优化都将是没有必要的，其中最明显的就是将Key与Value放在一个文件内(sstable),在机械硬盘上这种结构能够保证一次读取就获得数据，减少了磁头寻道寻址的次数，而对于固态硬盘这样做会导致合并压缩过程中，对同一对kv进行多次写入与移动，进而降低了SSD的寿命。虽然也是读取一次但对于固态硬盘来说两次读取也要快于机械硬盘一次读取，而为了有效的减少LSM造成的读写放大，wisckey中将key与value分离存储，value仅存储在vlog中以仅追加的方式，而key存储在之前的lsm tree结构中。这样带来两个好处，第一不需要频繁移动vlaue的值，所以写放大减少，第二 lsm仅存储固定大小的key使得其存储占用变小，在内存中可以同时存储更多的key进而提高了缓存key的数量，间接的降低了读放大问题。

对于随机读请求，固态硬盘远高于机械硬盘，而对于范围查询，由于真正的value都存储在vLog中因此是无序的，所以进行范围查询就是需要进行随机读取(先从lsm顺序读key再逐个随机读value)，这必然造成性能的下降，传统的随机读取是串行的难以发挥固态硬盘并行随机读取的特性，因此在wisckey中根据迭代器的调用方法**prev,next** 来从排序好的lsm中预读取一定的key到内存中，加速随机的范围查询性能，这种预先读取是异步进行的，充分发挥固态硬盘的并行读取性能。

# KV分离带来的挑战

那么KV分离同时也带来许多问题，vLog文件会不断增大，那么就需要合并，如何合并才能保证对性能的影响最小化？同时由于移动了value的位置，LSM结构中维护的value的位置信息也要更新。数据具体如何布局？vLog日志如何拆分？wisckey崩溃后如何恢复才能保证数据的一致性呢?

# 实现细节

## 数据布局

![](../../资源/图片/yuque_2df06c1877ba.png)

### KV分离设计

1. 在sstable文件中数据布局: **<key, addr(vlogName,offset,size)>**
2. 在vlog文件中的数据布局: **<keySize,valueSize,key,Value>**

## 随机查询

1. 先访问内存表是否命中key，如果找到地址信息判断是在内存中还是磁盘中(LRU缓存)
2. 在内存中被缓存了value则直接返回，否则去磁盘中查找，根据vlog的名字找到具体的vlog文件
3. 然后根据offset定位字节的首地址，根据size读取内容并返回
4. 基于一定策略将整个vlog涉及的bolck缓存下来

## 范围查询

1. 根据迭代器 next 还是 prev判断 是在游标之前读还是之后读，
2. 预先读取一定的key，交由底层的线程池异步的取ssd中获取数据
3. 将异步结果缓存在内存中 等到迭代器的调用

## 随机/顺序写入

1. 将set操作先写入vlog日志中(存储key的作用之一就是既作为预写日志又作为值日志)
2. 然后将返回的地址信息写入LSM中返回
3. 返回写入成功

## 合并压缩

1. vlog分为多个文件 其中存在一个活跃vlog文件 用于写入数据作为head地址
2. 最先写入的的日志在最后的vlog中 存在tail地址
3. 多个写入线程运行在head地址处追加日志
4. 而只有一个后台线程执行垃圾收集运行在尾部
5. 每次选择一个vlog文件的内容去lsm结构中随机查询(可并行化) 将没有失效的key重新写会到head地址处重新追加到vlog中
6. 然后更新lsm中这些key的新地址
7. 并释放老的vlog文件
8. 这一过程中需要先将数据写入新的vlog文件后刷新到固态硬盘后异步更新索引
9. 最后删除老文件 以防止在此过程中进程崩溃造成数据丢失

## 故障恢复

1. 在wisckey的设计中预写日志就是值日志
2. 因此引擎进程只需要定时保存 head和tail的地址即可
3. 数据库恢复时需要获取崩溃前最新的地址然后从tail到head将日志进行redo即可
4. 同时为了保证一致性在查询key时要做一些必要的一致性检查

1. 当前key如果在tail与head索引范围外则忽略
2. 当前位置上的值具有的key与查询的key不匹配则忽略
3. 发生上述情况时，引擎直接返回错误信息

# 优化与改进

## 写缓冲区

为减少写入的系统调研次数，多个小key的写入会被缓存在内存中汇聚在一起统一的写入lsm的sstable中，但会优先写入vlog中当作预写日志处理。

## 空间放大率

数据存储的实际的大小与逻辑上的大小比值用来衡量空间放大情况，对于固态硬盘来说其价格昂贵，降低空间放大率会大大的节省存储成本。

## 在线垃圾收集

GC过程会造成引擎的性能尖刺，通过并发的在线的分批次的进行GC操作来对前台读写性能影响。

## 小Value的存储

经论文的测试数据value大于4KB时其读取性能才会有极大的提升，因此可以设置一个阈值，当value大于此阈值时才进行KV分离，而再次之前使用传统lsm-tree模式。

### B+树也不是十全十美的，它的主要缺点有两个：

1.如果写入的数据比较离散，那么寻找写入位置时，子节点有很大可能性不会在内存中，最终会产生大量的随机写，性能下降。

2.如果B+树已经运行了很长时间，写入了很多数据，随着叶子节点分裂，其对应的块会不再顺序存储，而变得分散。这时执行范围查询也会变成随机读，效率降低了

B+树没有成为主流分布式KV存储？B+树（和B树）是经典的就地更新结构，目标是优化随机读取和范围查询。

1. **写入性能差。** B+树的更新操作是要找到相应的磁盘页，然后直接覆盖或修改数据。如果发生页分裂，就还要修改父节点，会有大量的随机I/O。在高写入负载下，B+树的随机I/O和页分裂会放大，严重拖慢写入速度，没法做到分布式KV存储追求的高吞吐量。
2. 把B+树作为Raft的状态机，写入操作会经历两次持久化：写入操作先顺序写入Raft的日志（WAL）文件； Raft 把操作应用到B+树会执行随机写来更新内部结构，同时B+树引擎自身还要写入Redo Log/Undo Log来保证单机事务和崩溃恢复。**双重写入（Raft WAL的顺序写 + B+树的随机写）产生写放大和更差的写入性能，白白浪费 Raft WAL的顺序写优势。**
3. B+树的分布式代价很高： B+树把一个平衡树结构分散到集群上，保持平衡和一致性的代价非常大，实现难度很高。

# 参考资料

1. [WiscKey：在SSD存储上的键值分离设计](https://hardcore.feishu.cn/docs/doccn4WRb8aFRznvfyc8hRf9Chf)
2. [LSM-论文导读与Leveldb源码解读](https://hardcore.feishu.cn/docs/doccnKTUS5I0qkqYMg4mhfIVpOd)
3. [google/leveldb](https://github.com/google/leveldb)
4. [BadgerDB源码分析之Wisckey论文](https://shimingyah.github.io/2019/08/BadgerDB%E6%BA%90%E7%A0%81%E5%88%86%E6%9E%90%E4%B9%8Bwisckey%E8%AE%BA%E6%96%87/)
5. [dgraph-io/badger](https://github.com/dgraph-io/badger)
6. [[levelDB] Compaction](https://www.cnblogs.com/ym65536/p/10995048.html)

---

# 五、源码解析和实践感悟

## 1. MemTable 跳表插入——LevelDB 写路径第一步

LevelDB 写入首先进入内存中的 MemTable（基于跳表），跳表保证 O(logN) 的有序插入和查找。MemTable 满后转为 Immutable MemTable，后台线程 Flush 到磁盘生成 SSTable。

```cpp
// LevelDB SkipList::Insert —— 写路径的第一步
// db/skiplist.h (LevelDB)
template<typename Key, class Comparator>
void SkipList<Key, Comparator>::Insert(const Key& key) {
    // prev 数组记录每层的前驱节点
    Node* prev[kMaxHeight];
    Node* x = FindGreaterOrEqual(key, prev);  // 查找插入位置
    
    // 随机生成新节点高度（概率递增：第n层的概率为1/2^n）
    int height = RandomHeight();  // 典型值：平均1~2层，最大12层
    
    Node* new_node = NewNode(key, height);
    // 逐层插入
    for (int i = 0; i < height; i++) {
        new_node->NoBarrier_SetNext(i, prev[i]->NoBarrier_Next(i));
        prev[i]->SetNext(i, new_node);  // 内存屏障保证可见性
    }
}
// MemTable 用 Arena 内存池分配节点，减少碎片
// 插入在用户线程中完成，Flush 在后台线程——双 MemTable 设计避免阻塞写
```

## 2. SSTable 合并迭代器——Compaction 的核心

Compaction 是 LSM 引擎的核心：将上层多个有重叠 key 范围的 SSTable 与下层 SSTable 做归并排序，去掉已删除/覆盖的旧版本数据，产出新的 SSTable。

```cpp
// LevelDB Compaction 归并——MergingIterator
// table/merger.cc
class MergingIterator : public Iterator {
    // 小顶堆，按 key 排序所有子迭代器当前指向的 entry
    // 每次 Next() 弹出最小 key 的迭代器，推进它
    
    void SeekToFirst() override {
        for (auto& child : children_) {
            child->SeekToFirst();
            if (child->Valid())
                minHeap_.push(child.get());  // 入堆
        }
        current_ = minHeap_.top();  // 当前最小
    }
    
    void Next() override {
        current_->Next();        // 推进当前子迭代器
        minHeap_.pop();          // 弹出旧值
        if (current_->Valid())
            minHeap_.push(current_.get());  // 新值入堆
        current_ = minHeap_.empty() ? nullptr : minHeap_.top();
    }
    
    // Key() 返回 current_ 的 key
    // 归并规则：同 key 时 seq 大（新）的优先，seq=0 代表删除标记
};
// Compaction 过滤逻辑：同 key 只保留最新 seq，删除标记被丢弃（若下层无此key）
```

## 3. WiscKey KV 分离——vLog 垃圾回收

WiscKey 将 value 单独存在 vLog 文件中，LSM 树只存 `<key, vLog_addr>`。GC 线程从 tail 端回收旧 vLog 文件：读其中的有效 key 查询 LSM 确认地址是否仍有效，有效则重新追加到 head，无效则丢弃。

```cpp
// WiscKey vLog GC 伪代码
void GarbageCollect() {
    // 选择最旧的 vLog 文件（tail 端）
    auto vlog_file = pick_tail_vlog();
    
    // 遍历 vLog 中的每条记录
    while (auto record = vlog_file->next()) {
        // 查 LSM 树：该 key 的当前 value 地址是否仍指向本记录？
        auto addr = lsm_tree_->get_addr(record.key);
        
        if (addr == record.offset) {
            // 有效记录 → 重新追加到 head 端（追加到活跃 vLog）
            auto new_addr = active_vlog_->append(record.key, record.value);
            // 更新 LSM 中的地址映射
            lsm_tree_->put(record.key, new_addr);
        }
        // 若地址不匹配 → 已被覆盖/删除，直接丢弃（GC 回收空间）
    }
    
    // 整个旧 vLog 文件删除
    delete_vlog_file(vlog_file);
}
// 关键设计：(1) GC 在后台单线程运行，不影响前台读写
// (2) GC 过程中崩溃恢复：新 address 写入前不删旧文件
// (3) 写放大降低：GC 只移动 value（key 不再参与 compaction）
```

## 实践经验

1. **写放大是 LSM 最大的敌人**：一次写入可能经历多次 compaction（写→WAL→MemTable→L0→L1→...）。RocksDB 的 Leveled Compaction 写放大约 10-30 倍，Tiered Compaction 可降低到 4-10 倍。选择策略时需权衡读放大和空间放大。
2. **LevelDB 的写阻塞点**：L0 文件数达到阈值（`kL0_CompactionTrigger=4`）触发 compaction，若 compaction 速度跟不上写入速度，L0 文件数达到 `kL0_SlowdownWritesTrigger=8` 时会主动 sleep 1ms 限速写入，达到 12 时完全阻塞写入。这解释了为什么 LevelDB 在持续高写入下会有尖刺。
3. **Bloom Filter 对点查询至关重要**：LSM 查询需从 L0 到最底层逐层查找，每层先查 Bloom Filter 判断 key 是否存在，不存在直接跳过该层 SSTable。典型配置 10 bits/key 可达到 ~1% 假阳性率，大幅减少无效磁盘 IO。
4. **WAL 的 fsync 策略决定持久性和性能**：每条写入都 fsync 保证崩溃不丢数据但吞吐量极低；批量提交（group commit）将多个写操作的 fsync 合并为一次，吞吐量可提升 10 倍以上。
5. **SSD 上 LSM 的 KV 分离才有意义**：HDD 上随机读性能极差（~100 IOPS），KV 分离导致范围查询退化为随机读，得不偿失。SSD 的随机读可达数十万 IOPS，KV 分离的收益远大于代价。Titan（TiKV 的 KV 分离实现）默认 value ≥ 1KB 才分离。
6. **Compaction 策略直接影响系统表现**：Leveled Compaction 优化读（每层 key 不重叠）+ 空间利用率高；Tiered Compaction 优化写（减少写放大）但空间放大高；Universal Compaction 适合写多读少场景。没有银弹，需根据 workload 选择。

---

# 六、面试准备

## 面试问答

**Q1: LSM 树和 B+ 树的本质区别？各自适用什么场景？**
A: LSM 是**非就地更新**（追加写+后台合并），B+ 树是**就地更新**（原地覆盖+页分裂）。LSM 牺牲读性能换取写入吞吐量，适合写密集场景（日志、时序数据、消息队列）；B+ 树读写均衡，适合读密集+范围查询场景（OLTP 数据库）。核心差异：LSM 顺序写 O(1)、随机读 O(N_sstable)；B+ 树随机写 O(logN)、随机读 O(logN)。

**Q2: 什么是写放大（Write Amplification）？LSM 如何导致写放大？**
A: 写放大 = 实际写入存储的字节数 / 应用层写入的字节数。LSM 的写放大来源：(1) 同一 key 多次写入需多次 compaction 才能清理旧版本；(2) SSTable 归并时整文件读-合并-写回，不相关的 key 也被重写。例如 L1 合并 L2 时，L2 的一个 SSTable 可能只有部分 key 与 L1 重叠，但整个文件都要重写。WiscKey 通过 KV 分离将写放大从 10x+ 降到 ~2x。

**Q3: LevelDB 为什么采用 Leveled Compaction 而非 Tiered Compaction？**
A: Leveled Compaction 保证同一层内各 SSTable 的 key 范围不重叠，因此查询时每层最多访问 1 个 SSTable（读放大小）；缺点是每次 compaction 都涉及下层整个文件重写（写放大高）。Tiered Compaction（Cassandra 风格）每层允许多个有重叠的 SSTable，写放大低但读时需要合并更多文件。LevelDB 选择 Leveled 是因为 Google 的典型 workload 读多写少。

**Q4: SSTable（Sorted String Table）的内部结构是怎样的？**
A: LevelDB SSTable 分四个区域：(1) Data Block——存储实际 key-value，块内排好序，默认 4KB 一块，每块末尾有重启点用于前缀压缩；(2) Filter Block——存储 Bloom Filter，快速判断 key 是否可能在此 SSTable 中；(3) Index Block——存储每个 Data Block 的 last_key → offset，用于二分查找定位目标 Data Block；(4) Footer——48 字节定长尾部，存 Index Block 和 Filter Block 的偏移和大小，以及 Magic Number。

**Q5: WAL（Write-Ahead Log）在 LSM 中的作用？崩溃后如何恢复？**
A: WAL 是顺序追加的日志文件，写入先落 WAL 再写 MemTable。崩溃恢复时：(1) 从最后一个 checkpoint 开始回放 WAL，重建崩溃前未 flush 的 MemTable；(2) 因为 MemTable 可能已部分 flush 但 WAL 未截断，恢复时跳过已持久化的 key。RocksDB 的 `wal_recovery_mode` 参数控制恢复严格程度（绝对一致性 vs 容忍丢失最后几条记录）。

**Q6: KV 分离（WiscKey）为什么能降低写放大？有什么代价？**
A: **降低原因**：compaction 只重排 key（小），不搬运 value（大），写放大从 key+value 的多次重写降为仅 key 的重写。**代价**：(1) 范围查询退化为顺序读 key + 随机读 value（原本一次顺序 IO 的数据现在分散在 vLog 各处）；(2) vLog 需要独立的 GC 线程，GC 过程需要查 LSM 确认有效性；(3) 小 value 分离可能得不偿失（value 比 LSM 的地址元数据还小时分离没意义）。

**Q7: Bloom Filter 在 LSM 中怎么工作？为什么说它是读性能的关键？**
A: LSM 查询从 L0 开始逐层查找，每层有多个 SSTable。如果 key 不存在，盲目检查每层的 SSTable 会做大量无效 IO。Bloom Filter 以极少的内存（~10 bits/key）提供"肯定不存在"的判断能力：先查 Bloom Filter，不存在直接跳过该 SSTable，存在（可能误判）才真正读磁盘。将读放大从 O(N_sstable) 降到 O(1~2)，假阳性率 ~1% 时内存开销仅为数据量的 0.1%。

**Q8: LSM 的 Compaction 策略有哪些？如何选择？**
A: (1) **Leveled**（LevelDB/RocksDB 默认）：每层 key 不重叠，读放大低，写放大 ~10-30x；(2) **Tiered**（Cassandra/HBase）：同层 SSTable 可重叠，写放大低 ~4-10x，但读需合并更多文件；(3) **Universal**（RocksDB）：适合写多读少，一次合并多个连续文件，写放大更低；(4) **FIFO**：旧文件直接删除不做合并，适合 TTL 数据。选择原则：读多选 Leveled，写多选 Tiered/Universal，有 TTL 选 FIFO。

## 陷阱与反问

| 陷阱 | 错误认知 | 正确理解 |
|------|---------|---------|
| LSM 写入没有延迟尖刺 | Compaction 在后台持续运行，与前台写竞争 IO 和 CPU | RocksDB 的 write stall 机制在 compaction 落后时会主动限速甚至阻塞写入 |
| LSM 一定比 B+ 树写入快 | 当 value 很大时 B+ 树只需修改一个页的几字节，LSM 要完整写一遍 | 小更新场景（UPDATE 单字段）B+ 树可能更快，LSM 优势在大批量顺序写入 |
| 层数越多越好 | 层数多=数据被 compaction 搬运次数多=写放大大 | TiKV 默认 max 7 层，更多层数对写放大是灾难 |
| LevelDB 适合所有场景 | LevelDB 是单机嵌入式引擎，不支持网络访问和分布式事务 | 适合本地存储，分布式场景看 TiKV/RocksDB-on-Raft |
| vLog 满了直接删就行 | 删前必须逐个确认 key 是否仍指向此记录，否则会丢失最新数据 | GC 必须走"查询 LSM → 确认 → 重写有效记录"三步 |

## 一句话答案速记表

| 关键词 | 一句话 |
|--------|--------|
| LSM 核心思想 | 随机写转为顺序写+后台归并排序（compaction），牺牲读换写 |
| MemTable | 内存中的跳表/红黑树，写入先到 MemTable，满后 flush 成 SSTable |
| Compaction | 归并排序多层 SSTable，去重去删，是写放大的根源 |
| 写放大 | 实际写入磁盘字节 / 应用写入字节，Leveled ~10-30x，KV 分离可降至 ~2x |
| SSTable | 有序不可变文件，Data Block + Filter Block + Index Block + Footer |
| WAL | 预写日志，崩溃恢复回放，保证已 ack 操作不丢 |
| WiscKey | 键值分离存储：key 在 LSM 树，value 在 vLog，compaction 只排 key |
| Bloom Filter | 快速否决 key 不存在，减少无效 SSTable IO，1% 假阳性 10bits/key |
