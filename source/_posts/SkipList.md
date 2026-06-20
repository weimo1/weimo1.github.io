---
title: SkipList
date: 2026-06-20
categories:
  - ["项目学习", "存储引擎"]
publish: true
---

# SkipList

> 适用范围：LevelDB 内存表（MemTable）的核心数据结构——并发安全的跳表

## 写作约束（铁律）

- **原内容一字不删**：所有原有文字、代码、注释、图片必须全部保留。
- **只做归纳重组+增加**：在原有内容基础上调整结构、归类，新增内容以"补充"标记。
- **代码块必须标注语言**：C++ 代码用 `c++`，禁止无语言标注的裸代码块。
- **字数硬指标**：二≥200字、四≥500字、五≥1000字、六≥10问法+5反问+5一句话。

## 一、项目/模块概述

- **模块定位**：SkipList（跳表）是 LevelDB 内存表 MemTable 的底层数据结构，负责在内存中维护有序的 key-value 对，支持 O(log n) 的插入和查找。它是 LSM-Tree 写入路径的第一站——所有写入首先进入跳表。
- **技术栈与依赖**：C++ 模板实现，`std::atomic` 提供无锁并发读，自定义内存分配器（Arena）
- **模块边界**：
  - 输入：有序 key（InternalKey = UserKey + SequenceNumber）
  - 输出：支持 `Insert`、`Contains`、迭代器遍历
  - 上下游：MemTable 封装跳表，上层写操作写入跳表，读操作在跳表中查找

<https://zhuanlan.zhihu.com/p/600729377>

### 什么是跳表

跳表全称为跳跃列表，它允许快速查询，插入和删除一个有序连续元素的数据链表。跳跃列表的平均查找和插入时间复杂度都是O(logn)。快速查询是通过维护一个多层次的链表，且每一层链表中的元素是前一层链表元素的子集。一开始时，算法在最稀疏的层次进行搜索，直至需要查找的元素在该层两个相邻的元素中间。这时，算法将跳转到下一个层次，重复刚才的搜索，直到找到需要查找的元素为止。

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1765714167616-26b5c300-03e5-4ee3-a81b-1ef0a4a33e09.png)

一张跳跃列表的示意图。每个带有箭头的框表示一个指针, 而每行是一个稀疏子序列的链表；底部的编号框（黄色）表示有序的数据序列。查找从顶部最稀疏的子序列向下进行, 直至需要查找的元素在该层两个相邻的元素中间。

> 补充：跳表由 William Pugh 于 1990 年提出，作为平衡树（AVL/红黑树）的替代品。其核心优势是实现简单（不需要复杂的旋转操作），且天然支持并发——LevelDB 的选择正是因为跳表能轻松实现 lock-free 读。

## 二、架构设计（≥200字）

### 第一层：跳表 vs 平衡树

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1765714356268-52f66903-eacf-4574-9725-2d0fafc2d453.png)

跳表本质上是**链表 + 多层索引**：
- 第 0 层：完整的排序链表（所有节点）
- 第 1 层：每隔约 k 个节点取一个（k = kBranching = 4）
- 第 2 层：每隔约 k² 个节点取一个
- ...
- 最高层：仅头节点和少量节点

### 第二层：查找流程

从最高层开始，每层向右走到下一个节点 key ≥ 目标 key 时，下降到下一层继续。最后一层（level 0）走到的位置即为目标位置或其前驱。

### 第三层：关键设计决策

| 设计决策 | LevelDB 选择 | 理由 |
|----------|-------------|------|
| 高度随机 | 1/kBranching 概率递增 | 概率保证 O(log n) 期望高度 |
| 并发策略 | 写单线程 + 读无锁 | MemTable 写入串行（单线程），读用 acquire 屏障 |
| 内存管理 | Arena 分配器 | 批量申请内存，节点连续分配，减少碎片 |
| 节点 next_ 数组 | 柔性数组 `atomic<Node*>[1]` | 节点大小随高度变化，一次分配 |

## 三、核心实现（代码走读）

### 3.1 时间复杂度分析

**跳表具体有多快**

通过上边的例子我们知道，跳表的查询效率比链表高，那具体高多少呢？下面我们一起来看一下。

衡量一个算法的效率我们可以用时间复杂度，这里我们也用时间复杂度来比较一下链表和跳表。前面我们已经讲过了，链表的查询的时间复杂度为 O(n)，那跳表的呢？

如果一个链表有 n 个结点，如果每两个结点抽取出一个结点建立索引的话，那么第一级索引的结点数大约就是 n/2，第二级索引的结点数大约为 n/4，以此类推第 m 级索引的节点数大约为 n/(2^m)。

假如一共有 m 级索引，第 m 级的结点数为两个，通过上边我们找到的规律，那么得出 n/(2^m)=2，从而求得 m=log(n)-1。如果加上原始链表，那么整个跳表的高度就是 log(n)。我们在查询跳表的时候，如果每一层都需要遍历 k 个结点，那么最终的时间复杂度就为 O(k * log(n))。

那这个 k 值为多少呢，按照我们每两个结点提取一个基点建立索引的情况，我们每一级最多需要遍历两个个结点，所以 k=2。为什么每一层最多遍历两个结点呢？

因为我们是每两个结点提取一个结点建立索引，最高一级索引只有两个结点，然后下一层索引比上一层索引两个结点之间增加了一个结点，也就是上一层索引两结点的中值，看到这里是不是想起来我们前边讲过的二分查找，每次我们只需要判断要找的值在不在当前结点和下一个结点之间即可。

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1765714186778-4ccd8936-41de-4efe-ae1a-9a0210dcd8ec.png)

如上图所示，我们要查询红色结点，我们查询的路线即黄线表示出的路径查询，每一级最多遍历两个结点即可。

所以跳表的查询任意数据的时间复杂度为 O(2 * log(n))，前边的常数 2 可以忽略，为 O(log(n))。

> 补充：LevelDB 使用 `kBranching = 4` 而非 2，意味着每层遍历期望 4 个节点，高度 ≈ log₄(n)。节点高度随机——每层有 1/4 的概率再向上一层。这使得高度分布更均匀，减少了极端情况。

### 3.2 LevelDB SkipList 完整实现

```c++
#ifndef DB_SKIPLIST_H_
#define DB_SKIPLIST_H_

#include <assert.h>
#include <stdint.h>

#include <atomic>
#include <new>

#include "logger/log.h"
#include "logger/log_level.h"
#include "utils/random_util.h"
namespace corekv {
struct SkipListOption {
  static constexpr int32_t kMaxHeight = 20;
  //有多少概率被选中, 空间和时间的折中
  static constexpr unsigned int kBranching = 4;
};

template <typename _KeyType, typename _KeyComparator, typename _Allocator>
class SkipList final {
  struct Node;

 public:
  SkipList(_KeyComparator comparator);

  SkipList(const SkipList&) = delete;
  SkipList& operator=(const SkipList&) = delete;
  void Insert(const _KeyType& key) {
    // 该对象记录的是要节点要插入位置的前一个对象，本质是链表的插入
    Node* prev[SkipListOption::kMaxHeight] = {nullptr};
    //在key的构造过程中，有一个持续递增的序号，因此理论上不会有重复的key
    Node* node = FindGreaterOrEqual(key, prev);
    if (nullptr != node) {
      if (Equal(key, node->key)) {
        LOG(WARN, "key:%s has existed", key);
        return;
      }
    }

    int32_t new_level = RandomHeight();
    int32_t cur_max_level = GetMaxHeight();
    if (new_level > cur_max_level) {
      //因为skiplist存在多层，而刚开始的时候只是分配kMaxHeight个空间，每一层的next并没有真正使用
      for (int32_t index = cur_max_level; index < new_level; ++index) {
        prev[index] = head_;
      }
      // 更新当前的最大值
      cur_height_.store(new_level, std::memory_order_relaxed);
    }
    Node* new_node = NewNode(key, new_level);
    for (int32_t index = 0; index < new_level; ++index) {
      new_node->NoBarrier_SetNext(index, prev[index]->NoBarrier_Next(index));
      prev[index]->NoBarrier_SetNext(index, new_node);
    }
  }
  bool Contains(const _KeyType& key) {
    Node* node = FindGreaterOrEqual(key, nullptr);
    return nullptr != node && Equal(key, node->key);
  }
  bool Equal(const _KeyType& a, const _KeyType& b) {
    return comparator_.Compare(a, b) == 0;
  }

 private:
  Node* NewNode(const _KeyType& key, int32_t height);
  int32_t RandomHeight();
  int32_t GetMaxHeight() { return cur_height_.load(std::memory_order_relaxed); }
  bool KeyIsAfterNode(const _KeyType& key, Node* n) {
    return (nullptr != n && comparator_.Compare( n->key, key) < 0);
  }
  //找到一个大于等于key的node
  Node* FindGreaterOrEqual(const _KeyType& key, Node** prev) {
    Node* cur = head_;
    //当前有效的最高层
    int32_t level = GetMaxHeight() - 1;
    Node* near_bigger_node = nullptr;
    while (true) {
      // 根据跳表原理，他是从最上层开始，向左或者向下遍历
      Node* next = cur->Next(level);
      // 说明key比next要大，直接往后next即可
      if (KeyIsAfterNode(key, next)) {
        cur = next;
      } else {
        if (prev != NULL) {
          prev[level] = cur;
        }
        if (level == 0) {
          return next;
        }
        //进入下一层
        level--;
      }
    }
  }
  // 找到小于key中最大的key
  Node* FindLessThan(const _KeyType& key) {
    Node* cur = head_;
    int32_t level = GetMaxHeight() - 1;
    while (true) {
      Node* next = cur->Next(level);
      int32_t cmp = (next == nullptr) ? 1 : comparator_.Compare(next->key, key);
      //刚好next大于等于0
      if (cmp >= 0) {
        // 因为高度是随机生成的，在这里只有level=0才能确定到底是哪个node
        if (level == 0) {
          return cur;
        } else {
          level--;
        }
      } else {
        cur = next;
      }
    }
  }
  //查找最后一个节点的数据
  Node* FindLast() {
    Node* cur = head_;
    static constexpr uint32_t kBaseLevel = 0;
    while (true) {
      Node* next = cur->Next(kBaseLevel);
      if (nullptr == next) {
        return cur;
      }
      cur = next;
    }
  }

 private:
  _KeyComparator comparator_;  //比较器
  _Allocator arena_;           //内存管理对象
  Node* head_ = nullptr;
  std::atomic<int32_t> cur_height_;  //当前有效的层数
  RandomUtil rnd_;
};

// Implementation details follow
template <typename _KeyType, class _KeyComparator, typename _Allocator>
struct SkipList<_KeyType, _KeyComparator, _Allocator>::Node {
  explicit Node(const _KeyType& k) : key(k) {}

  const _KeyType key;

  // Accessors/mutators for links.  Wrapped in methods so we can
  // add the appropriate barriers as necessary.
  Node* Next(int32_t n) {
    // Use an 'acquire load' so that we observe a fully initialized
    // version of the returned Node.
    return next_[n].load(std::memory_order_acquire);
  }
  void SetNext(int n, Node* x) {
    assert(n >= 0);
    // Use a 'release store' so that anybody who reads through this
    // pointer observes a fully initialized version of the inserted node.
    next_[n].store(x, std::memory_order_release);
  }

  // No-barrier variants that can be safely used in a few locations.
  Node* NoBarrier_Next(int n) {
    return next_[n].load(std::memory_order_relaxed);
  }
  void NoBarrier_SetNext(int n, Node* x) {
    next_[n].store(x, std::memory_order_relaxed);
  }

 private:
  // Array of length equal to the node height.  next_[0] is lowest level link.
  std::atomic<Node*> next_[1];
};

template <typename _KeyType, class _Comparator, typename _Allocator>
SkipList<_KeyType, _Comparator, _Allocator>::SkipList(_Comparator cmp)
    : comparator_(cmp),
      cur_height_(1),
      head_(NewNode(0, SkipListOption::kMaxHeight)) {
  for (int i = 0; i < SkipListOption::kMaxHeight; i++) {
    head_->SetNext(i, nullptr);
  }
}

template <typename _KeyType, typename _Comparator, typename _Allocator>
typename SkipList<_KeyType, _Comparator, _Allocator>::Node*
SkipList<_KeyType, _Comparator, _Allocator>::NewNode(const _KeyType& key,
                                                     int32_t height) {
  char* node_memory = (char*)arena_.Allocate(
      sizeof(Node) + sizeof(std::atomic<Node*>) * (height - 1));
  //定位new写法
  return new (node_memory) Node(key);
}

template <typename _KeyType, typename _Comparator, typename _Allocator>
int32_t SkipList<_KeyType, _Comparator, _Allocator>::RandomHeight() {
  int32_t height = 1;
  while (height < SkipListOption::kMaxHeight &&
         ((rnd_.GetSimpleRandomNum() % SkipListOption::kBranching) == 0)) {
    height++;
  }
  return height;
}

}  // namespace corekv
#endif
```

## 四、工程实践（≥500字）

### 4.1 与项目中其他模块的集成方式

- **MemTable**：跳表被 MemTable 封装，外部通过 `MemTable::Add()` 写入，`MemTable::Get()` 查询
- **Compaction**：MemTable 写满后 → 转为 Immutable MemTable → dump 为 SSTable，跳表数据转为磁盘文件
- **WAL（Write-Ahead Log）**：写入跳表前先写 WAL，崩溃恢复时重放 WAL 重建跳表

### 4.2 生产环境考量

**并发安全**
- 写操作串行（LevelDB 单写线程），插入时用 `NoBarrier_SetNext`（relaxed 内存序），无锁开销
- 读操作用 `acquire` 语义——确保读到完全初始化的节点（`Next()` 用 `memory_order_acquire`）
- 关键：不存在写-写竞争，只存在写-读竞争，acquire-release 配对即可

**内存管理**
- Arena 分配器批量申请 4KB 内存块，节点在其中顺序分配——减少 malloc 调用、减少内存碎片
- 节点柔性数组 `next_[1]` + placement new 实现可变大小分配，比 `std::vector` 更紧凑
- 所有节点统一在 Arena 析构时释放——无需逐个 delete

**性能特征**
- 查找 O(log₄ n)，n=百万时约 10 层遍历，每层最多 4 个节点 → 约 40 次比较
- 插入 O(log₄ n) 查找位置 + O(height) 修改指针
- kMaxHeight=20 硬限制，千万级数据足够

### 4.3 常见优化策略

- **RandomHeight 优化**：用位运算替代取模——`rnd_.Next() & 0x3 == 0` 比 `% 4` 更快
- **预取 (prefetch)**：遍历时对下一个节点预取 `__builtin_prefetch(next)`
- **批量插入**：先排序再批量插入可减少查找路径的重复遍历

## 五、源码解析和实践感悟（≥1000字）

### 5.1 LevelDB 跳表的并发哲学

LevelDB 跳表不是完全 lock-free 的——它依赖一个关键假设：**只有一个写线程**。这个假设让并发控制大幅简化：
- 不需要 CAS（Compare-And-Swap）原子操作做链表插入
- 不需要担心写-写 ABA 问题
- 只需要保证读线程能看到完整初始化的节点

**内存序的精准选择**：
- 读线程用 `acquire`：防止 CPU/编译器将 `next_->load()` 后面的读操作重排到 load 之前
- 写线程用 `release`：防止 CPU/编译器将节点初始化重排到 `store` 之后
- 同一层内写线程用 `relaxed`：写线程自己保证顺序，不需要额外的同步开销

### 5.2 难点与易错点

**陷阱1：柔性数组 + placement new 的内存布局**

```c++
// Node 的实际内存布局：
// [key][padding][next_[0]][next_[1]]...[next_[height-1]]
// 
// 分配公式：
// sizeof(Node) + sizeof(atomic<Node*>) * (height - 1)
// 因为 Node 定义中已经包含 next_[1]（1个元素），所以只需要额外分配 height-1 个
```

**陷阱2：max_height 的懒增长**

```c++
// 跳表刚创建时 cur_height_ = 1
// 只有当随机高度超过当前最大高度时，才提升 cur_height_
// 这避免了在数据量小时维护高空层级的开销
```

**陷阱3：FindGreaterOrEqual 的 prev 数组**

```c++
// prev 数组记录每一层上"插入位置的前驱节点"
// 遍历时：如果 key > next，cur 前进（prev 不记录）
//         如果 key ≤ next，记录 cur 到 prev[level]，下降一层
// 这确保插入时知道每一层应该在哪里插入新节点
```

### 5.3 经验总结

1. **跳表是 MemTable 的最佳选择**——有序、高效、并发友好，比红黑树实现简单得多
2. **LevelDB 的"单写线程"假设是关键工程权衡**——牺牲了写并发，换来了极简的并发控制
3. **Arena 内存管理是性能基石**——批量分配 + 统一释放，避免了频繁的 new/delete
4. **跳表的高度随机性至关重要**——如果高度分布不均（如都低或都高），性能退化严重

## 六、面试准备（≥10问法+5反问+5一句话，均带回答）

### 6.1 高频问法（≥10个）

**Q1：跳表是什么？为什么 LevelDB 用它而不是红黑树？**
A：跳表是有序链表的概率性多层索引结构，查找/插入 O(log n)。LevelDB 选它因为：1) 实现比红黑树简单；2) 天然支持并发读（不需要全局锁）；3) 范围扫描只需沿 level 0 遍历。

**Q2：跳表的高度是如何确定的？**
A：每个新节点插入时随机生成高度——从 1 开始，每次以 1/kBranching（1/4）的概率递增，直到达到 kMaxHeight=20。这种概率分布保证期望高度 ≈ log₄(n)。

**Q3：跳表的查找过程是怎样的？**
A：从头节点的最高层开始——如果当前层下一个节点的 key ≤ 目标 key，向右移动；否则下降一层。重复直到 level 0，此时的下一个节点就是 ≥ 目标 key 的第一个节点。

**Q4：LevelDB 跳表如何保证并发安全？**
A：依赖"单写线程"前提——写线程用 release 语义写入节点指针，读线程用 acquire 语义读取。无 CAS 操作，无写-写竞争，只需保证读者看到完全初始化的节点。

**Q5：为什么插入时用 NoBarrier_SetNext（relaxed）而不是 SetNext（release）？**
A：因为同一个写线程内操作的顺序由程序顺序保证，不需要额外的内存屏障。release 只对跨线程可见性有意义——在此场景中写线程是唯一的。

**Q6：Node 中的 next_ 数组为什么声明为 `atomic<Node*> next_[1]`？**
A：这是 C 风格的柔性数组技巧——声明大小为 1，实际分配时多分配 `height - 1` 个额外元素，实现可变长度数组，避免额外的堆分配。

**Q7：LevelDB 跳表的 kBranching 为什么是 4 而不是 2？**
A：kBranching=4 使每层期望遍历 4 个节点，高度 ≈ log₄(n)。相比 2（log₂(n)），内存开销减半（少一半层），但每次查找多遍历约 2 倍节点——是空间换时间的折中。

**Q8：跳表不支持删除操作——LevelDB 如何处理删除？**
A：LevelDB 跳表确实没有 Delete 方法。删除通过插入一个带删除标记（tombstone）的 key 实现，在 Compaction 时真正清理。MemTable 是临时的——写满后整体 dump 为 SSTable。

**Q9：跳表的空间复杂度是多少？**
A：期望 O(n) 个指针。每个节点的期望高度 = 1/(1 - 1/kBranching) = 1/(1 - 1/4) ≈ 1.33 层。即 n 个节点使用约 1.33n 个指针（不含 key 和 value 存储），比平衡树（2n 个指针+颜色位）更省。

**Q10：如果 RandomHeight 一直随机到很高，会不会出问题？**
A：kMaxHeight=20 硬限制。即使 n=10 亿，log₄(10⁹) ≈ 15，20 层绰绰有余。概率上超过 20 层的概率 = (1/4)^20 ≈ 10⁻¹²——可忽略。

### 6.2 反问点/陷阱点（≥5个）

- 在实际的 LevelDB 生产部署中，你们是否遇到过跳表高度不均匀导致的性能问题？
- 贵团队是否有考虑过用 B+树或 ART（Adaptive Radix Tree）替代跳表做内存索引？

- **陷阱问题1**："跳表和红黑树谁更快？"——没有绝对答案。跳表插入更简单（无旋转），并发读更好（无锁）。红黑树空间更紧凑，确定性更强。LevelDB 选跳表主要因为并发和实现复杂度。
- **陷阱问题2**："跳表退化到 O(n) 的情况？"——如果随机数发生器坏掉（始终返回 0），所有节点高度=1，退化为普通有序链表。但概率极低（(1/4)^n）。
- **陷阱问题3**："跳表支持范围查询吗？"——支持。level 0 是完整的有序链表，直接沿 next_[0] 遍历即可。这是跳表相比哈希表的天然优势。

### 6.3 一句话答案（≥5个）

- 跳表的核心设计理念是：**用随机化的多层索引换取 O(log n) 查找——概率保证性能，实现极简。**
- LevelDB 跳表的并发模型是：**单写线程 + acquire-release 内存序——写不锁、读无锁。**
- 跳表高度随机生成，期望高度 ≈ log₄(n)：**每增加一层概率 1/4，最多 20 层。**
- 与红黑树相比：**跳表实现更简单、并发更友好，但空间略多（1.33n 指针 vs 2n 指针+颜色位）。**
- 避免的常见错误是：**假设跳表是线程安全的多写者数据结构——LevelDB 的跳表只支持单写者。**

- 当被问到"跳表能替代 B+树吗？"——回答："内存场景可以（如 MemTable），磁盘场景不行——B+树的节点大小匹配磁盘页，跳表的链表结构在磁盘上随机 IO 严重。"

## 附录（模板外原内容收纳）

> 原笔记全部内容已按六大段结构组织完毕。跳表定义与原理图收入一段，时间复杂度推导收入三段 3.1，完整源码收入三段 3.2，所有原代码和注释一字未删。知乎参考链接收入一段末尾。
