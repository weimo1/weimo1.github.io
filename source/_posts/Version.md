---
title: Version
date: 2026-06-20
categories:
  - ["项目学习", "存储引擎"]
publish: true
---

# Version

> 适用范围：LevelDB 版本管理系统——LSM-Tree 的元数据大脑

## 写作约束（铁律）

- **原内容一字不删**：所有原有文字、代码、注释、图片必须全部保留。
- **代码块必须标注语言**：C++ 代码用 `c++`。
- **字数硬指标**：二≥200字、四≥500字、五≥1000字、六≥10问法+5反问+5一句话。

## 一、项目/模块概述

- **模块定位**：Version 是 LevelDB 的版本管理系统，记录当前数据库状态的快照——包括每一层有哪些 SSTable 文件、文件的 key 范围。VersionSet 是版本的集合管理器，Manifest 是版本的持久化日志。三者构成 LSM-Tree 的"元数据大脑"。
- **技术栈与依赖**：纯 C++ 实现，依赖 Env（文件系统抽象）读写 Manifest 文件
- **模块边界**：
  - 输入：Compaction 结果（新增/删除文件信息）
  - 输出：当前活跃 SSTable 文件列表，供读操作定位数据
  - 上下游：驱动 Compaction 策略决策，为读操作提供文件定位

version: 记录当前版本的快照，记录每一层每一个sst的基本信息。

## 二、架构设计（≥200字）

### 第一层：三层元数据体系

```
VersionSet（版本集合管理器）
    │
    ├── dummy_versions_ (哨兵节点，循环双向链表)
    │   │
    │   ├── Version 1 (旧版本，可能还有读操作在使用)
    │   │   ├── files_[0]: [file1001, file1002]
    │   │   └── files_[1]: [file1003]
    │   │
    │   ├── Version 2 (当前版本)
    │   │   ├── files_[0]: [file1001, file1002, file1004]  ← 新增file1004
    │   │   └── files_[1]: [file1003]
    │   │
    │   └── Version 3 (准备中的新版本)
    │
    └── Manifest 文件（磁盘持久化日志）
```

VersionSet就是LSM-Tree的"大脑"，负责：

1. 版本管理 - 维护数据库状态的时间线
2. 并发控制 - 保证读写操作的隔离性
3. 持久化 - 通过manifest文件确保数据安全
4. 策略决策 - 智能的Compaction和文件管理

### 第二层：Version vs Manifest

**Version** 是内存中的当前状态（快照），用于快速查询。
**Manifest** 是磁盘上的变更历史（日志），用于持久化和恢复。

数据分离：
- Manifest: 元数据（有什么文件）
- SSTable: 实际数据（文件内容）

恢复流程：
- 从Manifest知道"应该有哪些SSTable"
- 到文件系统"找到这些SSTable文件"
- 打开SSTable文件读取数据

Manifest 确实不包含 SSTable 的完整数据，它只记录：
1. 有哪些 SSTable 文件（文件编号）
2. 每个 SSTable 的元数据（大小、键范围）
3. 文件之间的层级关系

SSTable 的实际数据存储在独立的 .sst 文件中。

重启恢复时：
1. 读取 Manifest 重建内存中的 Version（知道有哪些文件）
2. 根据 Version 中的文件编号找到对应的 .sst 文件
3. 打开这些文件进行读取

### 第三层：关键设计决策

| 设计决策 | 选择 | 理由 |
|----------|------|------|
| Version 引用计数 | Ref() / Unref() | 旧版本可能被正在进行的读操作持有 |
| VersionEdit | 增量变更记录 | 每次 Compaction 只记录变更，不复制完整文件列表 |
| Manifest 格式 | 顺序追加日志 | 每次 Compaction 后追加一条记录，崩溃恢复重放 |
| CURRENT 文件 | 指向当前 Manifest | Manifest 文件名含编号，CURRENT 指向最新 |

## 三、核心实现（代码走读）

### 3.1 核心数据结构

```c++
struct FileMetaData {
  uint64_t number = 0;          // 文件编号
  uint64_t file_size = 0;       // 文件大小
  std::string smallest;         // 最小 key (InternalKey 格式)
  std::string largest;          // 最大 key (InternalKey 格式)
  
  // 检查 key 是否在该文件的范围内
  bool Contains(const std::string_view& internal_key) const;
};

// Level 信息
struct LevelState {
  uint64_t level = 0;
  uint64_t level_size = 0;      // 该层总大小
  std::vector<FileMetaData> files;  // 该层的所有文件
  
  void AddFile(const FileMetaData& file);
  void RemoveFile(uint64_t file_number);
};

class Version {
 public:
  explicit Version(const Options* options);
  ~Version();
  
  Version(const Version&) = delete;
  Version& operator=(const Version&) = delete;
  
  // 获取指定 level 的文件列表
  const std::vector<FileMetaData>& GetFiles(uint64_t level) const;
  
  // 添加文件到指定 level
  void AddFile(uint64_t level, const FileMetaData& file);
  
  // 从指定 level 移除文件
  void RemoveFile(uint64_t level, uint64_t file_number);
  
  // 查找包含指定 key 的文件
  FileMetaData* FindFile(uint64_t level, const std::string_view& internal_key);
  
  // 获取所有 level 的迭代器（用于合并读）
  Iterator* NewConcatenatingIterator(uint64_t level) const;
  
  // 获取总大小
  uint64_t TotalFileSize() const;
  
  // 获取文件总数
  size_t NumFiles() const;
  
 private:
  const Options* options_;
  std::vector<LevelState> levels_;  // 每个 level 的状态
};
```

### 3.2 Version 的引用计数生命周期

```c++
// Version 通过引用计数管理生命周期
// 每次读操作开始时 Ref()，结束 Unref()
// 当引用计数归零且该 Version 不是 current_ 时，可以安全删除

// 典型场景：
// 1. Get 操作：获取 current_ → Ref() → 执行读取 → Unref()
// 2. Compaction：创建新 Version → 设置为 current_ → 旧 Version 等待所有读者释放
```

## 四、工程实践（≥500字）

### 4.1 与项目中其他模块的集成方式

- **读操作**：`Version::Get()` → 从 level 0 开始逐层查找包含 key 的 SSTable → 用布隆过滤器快速否定 → 读取 data block
- **Compaction**：`VersionSet::PickCompaction()` → 选择需要合并的 level → 执行合并 → `VersionSet::LogAndApply(edit)` 生成新版本
- **恢复**：`DB::Open()` → 读取 CURRENT 找到 Manifest → 重放所有 VersionEdit → 重建最新 Version

### 4.2 生产环境考量

**崩溃恢复**
- Manifest 顺序追加，每条记录有 CRC 校验
- 崩溃时 Manifest 可能不完整——读取到最后一个完整记录
- CURRENT 文件原子更新（先写临时文件再 rename），保证指向有效的 Manifest

**并发安全**
- Version 不可变（创建后不修改），多线程并发读安全
- VersionSet::current_ 由 mutex 保护写入，读用 atomic 或 mutex
- 旧 Version 由 Ref/Unref 管理生命周期，防止读者访问已删除的数据

**内存管理**
- Version 常驻内存，包含所有 SSTable 的元数据
- 每 1000 个文件约占用 100KB（FileMetaData 结构约 100 字节/文件）
- 过多的旧 Version（长期运行的读事务）会泄漏内存

### 4.3 常见优化策略

- **Manifest 压缩**：定期用当前 Version 的全量快照替代冗长的编辑日志
- **FileMetaData 允许重叠**：Level 0 的 SSTable 允许 key 范围重叠（因为直接从 MemTable dump）
- **分层大小倍数增长**：Level N+1 的大小 ≈ Level N × 10，控制 Compaction 频率

## 五、源码解析和实践感悟（≥1000字）

### 5.1 MVCC 的精妙实现

LevelDB 的 Version 系统本质上是一个简化版的多版本并发控制（MVCC）：
- 每次 Compaction 创建新 Version（新快照）
- 正在进行的读操作持有旧 Version 的引用
- 新写入不影响正在进行的读——天然快照隔离

**SequenceNumber 与 Version 的配合**：每个 key 有序列号，读操作记录自己的快照序列号，只读取序列号 ≤ 快照号的版本。

### 5.2 难点与易错点

**陷阱1：CURRENT 文件的更新不是幂等的**

```c++
// CURRENT 文件内容只是一个文件名，如 "MANIFEST-000003"
// 如果写 CURRENT 时崩溃，可能指向不存在的 Manifest
// 修复：启动时检查 CURRENT 指向的文件是否存在
```

**陷阱2：Level 0 的 SSTable key 范围重叠**

```c++
// Level 0 的 SSTable 直接从 MemTable dump，未经过排序合并
// key 范围可能重叠 → 读 Level 0 需要检查所有相关文件
// Level 1+ 的 SSTable 经过 Compaction，key 范围不重叠
```

**陷阱3：引用计数泄漏**

```c++
// 如果 Version::Ref() 后忘记 Unref()，该 Version 及其中引用的 SSTable 永不释放
// 长时间运行的迭代器是常见漏点
```

### 5.3 经验总结

1. **Version/Manifest 模式是 LSM 引擎的标配**——RocksDB、Cassandra、HBase 都有类似机制
2. **不可变性贯穿始终**——Version 不可变、SSTable 不可变、MemTable dump 后不可变
3. **Manifest 是恢复的"单一真相来源"**——即使数据文件都在，没有 Manifest 也无法恢复
4. **压缩 Manifest 是运维必修课**——长期运行的数据库 Manifest 可能超大

## 六、面试准备（≥10问法+5反问+5一句话，均带回答）

### 6.1 高频问法（≥10个）

**Q1：Version 在 LevelDB 中起什么作用？**
A：Version 是数据库状态的不可变快照——记录每一层有哪些 SSTable 文件及其 key 范围。读操作通过 Version 定位数据，Compaction 通过 VersionEdit 创建新版本。

**Q2：Version、VersionSet、Manifest 三者的关系？**
A：Version 是内存快照，VersionSet 管理所有 Version 的集合（双向链表），Manifest 是 Version 变更的磁盘日志。关系：Compaction → VersionEdit → LogAndApply → 写 Manifest + 创建新 Version。

**Q3：为什么需要多个 Version 同时存在？**
A：MVCC——正在进行的读操作持有旧 Version 的引用，确保读到自己快照时间点的数据。新 Compaction 产生的新 Version 不影响正在进行的读。

**Q4：Manifest 文件里存什么？不存什么？**
A：存：文件编号、文件大小、key 范围、层级关系。不存：SSTable 的实际 key-value 数据（在 .sst 文件中）。

**Q5：重启恢复时如何从 Manifest 重建状态？**
A：读 CURRENT 文件取得当前 Manifest 文件名 → 顺序读取 Manifest 中的 VersionEdit 记录 → 逐条重放到一个 Builder 中 → 生成最新的 Version。

**Q6：CURRENT 文件的作用？**
A：指向当前的 Manifest 文件名。因为 Manifest 文件名带编号（如 MANIFEST-000003），CURRENT 提供稳定的引用。原子更新（写临时文件→rename）保证一致性。

**Q7：Level 0 的 SSTable 和其他 Level 有什么区别？**
A：Level 0 的 SSTable key 范围可能重叠（直接从 MemTable dump），其他 Level 的 SSTable key 范围不重叠（经过 Compaction 排序合并）。这在 Version::Get() 中有不同的查找策略。

**Q8：VersionEdit 是什么？**
A：一次 Compaction 产生的增量变更——记录了新增了哪些文件、删除了哪些文件、以及 Compaction 的元信息。不复制整个文件列表。

**Q9：如何保证崩溃后 Manifest 的完整性？**
A：Manifest 以日志格式顺序追加，每条记录独立。崩溃时最后一条可能不完整——读取时校验 CRC，丢弃损坏的尾部记录。

**Q10：Version 的引用计数如何工作？**
A：每次读操作 `Ref()` 加引用，结束 `Unref()` 减引用。归零且非 current_ 时删除。这确保正在被读取的文件不会被 Compaction 删除。

### 6.2 反问点/陷阱点（≥5个）

- 你们在生产中 Manifest 文件的最大大小是多少？是否有自动压缩机制？
- 长期运行的读事务持有旧 Version 会影响 Compaction 的文件删除——你们如何监控和限制？

- **陷阱问题1**："Version 中的文件信息会变吗？"——不会。Version 一旦创建就不可变。新的 Compaction 结果通过创建新 Version 体现。
- **陷阱问题2**："如果 CURRENT 文件丢失了怎么办？"——无法确定最新的 Manifest。需要扫描所有 MANIFEST-* 文件，找编号最大且完整的那个。
- **陷阱问题3**："Level 0 的多个 SSTable 可以有相同的 key 吗？"——可以。不同时间对同一 key 的更新可能分布在不同的 Level 0 文件中（通过 SeqNumber 区分）。

### 6.3 一句话答案（≥5个）

- Version 系统的核心设计理念是：**不可变快照 + 增量变更日志 = MVCC + 崩溃恢复。**
- Version = 内存状态快照，Manifest = 磁盘变更日志：**Version 是结果，Manifest 是过程。**
- Level 0 的特殊性：**key 范围可重叠，因为直接从 MemTable dump 未经合并排序。**
- 崩溃恢复的关键是：**CURRENT → Manifest → VersionEdit 重放 → 重建 Version。**
- 这个设计的最大优点是**读操作无锁 + 崩溃可恢复**；最大代价是**旧 Version 持有期间文件不能删除（空间放大）。**

- 当被问到"为什么不用 WAL 统一管理？"——回答："WAL 管理的是数据日志（key-value变更），Manifest 管理的是元数据日志（文件结构变更）。二者关注点不同——分离后各自优化。"

## 附录

> 原笔记全部内容已按六大段结构组织完毕。Version 定义、FileMetaData/LevelState/Version 类代码收入三段 3.1，VersionSet 哨兵链表结构收入二段，Manifest 说明收入二段和五段。无遗漏。
