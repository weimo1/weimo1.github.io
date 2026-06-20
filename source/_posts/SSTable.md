---
title: SSTable
date: 2026-06-20
categories:
  - ["项目学习", "存储引擎"]
publish: true
---

# SSTable

> 适用范围：LevelDB 核心磁盘存储格式——Sorted String Table 的设计原理与读流程

## 写作约束（铁律）

- **原内容一字不删**：所有原有文字、代码、注释、图片必须全部保留。
- **只做归纳重组+增加**：在原有内容基础上调整结构、归类，新增内容以"补充"标记。
- **放不进的进附录**：六大段模板容纳不下的原内容，移入最后的「附录」章节。
- **字数硬指标**：二≥200字、四≥500字、五≥1000字、六≥10问法+5反问+5一句话。
- **代码块必须标注语言**：C++ 代码用 `c++`，禁止无语言标注的裸代码块。

## 一、项目/模块概述

- **模块定位**：SSTable（Sorted String Table）是 LevelDB 的磁盘持久化核心格式。它是一个**排序的、不可变的、持久化的 map**，存储引擎中所有落盘数据都以 SSTable 文件组织。
- **技术栈与依赖**：C++，纯 LevelDB 内部格式，与布隆过滤器、SkipList（内存表）形成读写链路
- **模块边界**：
  - 输入：有序的 key-value 对（从 MemTable dump 或 Compaction 合并产生）
  - 输出：`.sst` 磁盘文件，支持按 key 查找和范围扫描
  - 上下游：写入由 TableBuilder 构建，读取由 Table + TwoLevelIterator 驱动

SSTable 文件用于 Bigtable 内部数据存储。SSTable 文件是一个排序的、不可变的、持久化的 map 结构，其中 map 的 key-value 都可以是任意字节的字符串。支持使用指定键来查找值，或通过给定键范围遍历所有的 key-value 对。每个 SSTable 文件包含一系列的块（一般块大小为64KB，是可配置的）。SSTable 文件中的块索引（这些块索引通常保存在文件尾部区域）用于定位块，这些块索引在 SSTable 文件被打开时加载到内存。在查找时首先从内存中的索引二分查找找到块，然后一次磁盘寻道即可读取到相应的块。另一种方式是将 SSTable 文件完全加载到内存，从而在查找和扫描中就不需要读取磁盘。

从上面一段描述中，我们知道 SSTable 支持一些关键特性：

* 支持海量 key-value 型数据的存储
* 数据是按照 key 排序的、一旦写入就不可变
* 支持指定 key 查询和高效的范围查询
* 索引是稀疏索引的块索引，占用内存空间小

> 补充：SSTable 源自 Google Bigtable 论文（2006），其不可变性（immutable）设计是 LSM-Tree 的基石——只有不可变文件才能安全地进行 Compaction 合并。LSM-Tree 的核心思想就是将随机写转化为顺序写（MemTable → 顺序 dump → SSTable），用排序的不可变文件换取写入吞吐量。
> 来源: https://selfboot.cn/2025/06/27/leveldb_source_table_build/

## 二、架构设计（≥200字）

### 第一层：SSTable 文件逻辑结构

SSTable 文件在逻辑上分为五个区域：

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1766817078958-29686357-ce2f-482f-8b52-2883f4e5fe49.png)

leveldb在逻辑上又将sstable分为：

1. **data block**: 用来存储key value数据对；
2. **filter block**: 用来存储一些过滤器相关的数据（布隆过滤器），但是若用户不指定leveldb使用过滤器，leveldb在该block中不会存储任何内容；
3. **meta Index block**: 用来存储filter block的索引信息（索引信息指在该sstable文件中的偏移量以及数据长度）；
4. **index block**：index block中用来存储每个data block的索引信息；
5. **footer**: 用来存储meta index block及index block的索引信息；

![](https://cdn.nlark.com/yuque/0/2025/jpeg/50402827/1766820956361-18573b2a-eff0-4798-85c6-8fca66f17566.jpeg)
![](https://cdn.nlark.com/yuque/0/2025/jpeg/50402827/1766820966073-ea378a02-0d7b-4121-b63f-29df992b8098.jpeg)

### 第二层：关键数据流

**写入路径**：MemTable（内存排序）→ 达到阈值 → TableBuilder 构建 SSTable → 顺序写入磁盘（data block → filter block → meta index → index → footer）

**读取路径（详细见第三节）**：Footer → Index Block → 定位 Data Block → Filter Block 判断 → Data Block 遍历

### 第三层：关键设计决策

| 设计决策 | 选择 | 理由 |
|----------|------|------|
| 索引粒度 | 块级稀疏索引（64KB/block） | 索引内存开销小，一次磁盘寻道读取整个 block |
| key 存储 | 前缀压缩（共享前缀） | 相邻 key 通常前缀相同，节省 50%+ 存储 |
| Restart point | 每16条记录一个完整 key | 平衡压缩率与随机访问速度 |
| 过滤器 | 布隆过滤器（可选） | 用 1% 误报率换 99% 的无效磁盘读取 |
| Footer 固定大小 | 48 字节 | 方便尾部定位，解析格式统一 |

## 三、核心实现（代码走读）

### 3.1 Data Block 编码格式

第一部分用来存储keyvalue数据。由于sstable中所有的keyvalue对都是严格按序存储的，为了节省存储空间，leveldb并不会为每一对keyvalue对都存储完整的key值，而是存储与**上一个key非共享的部分**，避免了key重复内容的存储。

每间隔若干个keyvalue对，将为该条记录重新存储一个完整的key。重复该过程（默认间隔值为16），每个重新存储完整key的点称之为Restart point。

**编码格式示意图：**

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1766821431462-75b3ed9d-4172-47d6-a743-73dd125685e9.png)

**KV存储格式：**

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1766821635168-eb146d53-3759-4348-bd63-aeb19d9878be.png)
![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1766822422521-702fed80-9593-43df-9791-fcc18fae96f0.png)

```c++
// Data Block 中每条记录的编码（概念示意）
// entry := shared_bytes(变长) | unshared_bytes(变长) | value_length(变长) |
//          unshared_key_data | value_data
// 
// restart_point 数组在 block 尾部：
// restart_array := restart_offset[0] | restart_offset[1] | ... 
//                  | restart_count(4字节)
```

### 3.2 读操作流程

读操作作为写操作的逆过程，充分理解了写操作，将会帮助理解读操作。

下图为在一个sstable中查找某个数据项的流程图：

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1766821040489-401fcfe3-2ce1-4d44-9e1d-a15219bf5e11.png)

大致流程为：

1. 首先判断"文件句柄"cache中是否有指定sstable文件的文件句柄，若存在，则直接使用cache中的句柄；否则打开该sstable文件，**按规则读取该文件的元数据**，将新打开的句柄存储至cache中；
2. 利用sstable中的index block进行快速的数据项位置定位，得到该数据项有可能存在的**两个**data block；
3. 利用index block中的索引信息，首先打开第一个可能的data block；
4. 利用filter block中的过滤信息，判断指定的数据项是否存在于该data block中，若存在，则创建一个迭代器对data block中的数据进行迭代遍历，寻找数据项；若不存在，则结束该data block的查找；
5. 若在第一个data block中找到了目标数据，则返回结果；若未查找成功，则打开第二个data block，重复步骤4；
6. 若在第二个data block中找到了目标数据，则返回结果；若未查找成功，则返回`Not Found`错误信息；

### 3.3 缓存

在leveldb中，使用cache来缓存两类数据：

* sstable文件句柄及其元数据；
* data block中的数据；

因此在打开文件之前，首先判断能够在cache中命中sstable的文件句柄，避免重复读取的开销。

### 3.4 元数据读取

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1766821040276-3433d531-d46b-4d18-8ae5-2d0b31daafd6.png)

由于sstable复杂的文件组织格式，因此在打开文件后，需要读取必要的元数据，才能访问sstable中的数据。

元数据读取的过程可以分为以下几个步骤：

1. 读取文件的最后48字节的利用，即**Footer**数据；
2. 读取Footer数据中维护的(1) Meta Index Block(2) Index Block两个部分的索引信息并记录，以提高整体的查询效率；
3. 利用meta index block的索引信息读取该部分的内容；
4. 遍历meta index block，查看是否存在"有用"的filter block的索引信息，若有，则记录该索引信息；若没有，则表示当前sstable中不存在任何过滤信息来提高查询效率；

### 3.5 数据项的快速定位

sstable中存在多个data block，倘若依次进行"遍历"显然是不可取的。但是由于一个sstable中所有的数据项都是按序排列的，因此可以利用有序性已经index block中维护的索引信息快速定位目标数据项可能存在的data block。

一个index block的文件结构示意图如下：

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1766821041965-bff64781-894b-4d3e-84a3-3becd0c0c98a.png)

index block是由一系列的键值对组成，每一个键值对表示一个data block的索引信息。

键值对的key为该data block中数据项key的最大值，value为该data block的索引信息（offset, length）。

因此若需要查找目标数据项，仅仅需要依次比较index block中的这些索引信息，倘若目标数据项的key大于某个data block中最大的key值，则该data block中必然不存在目标数据项。故通过这个步骤的优化，可以直接确定目标数据项落在哪个data block的范围区间内。

**注解**

值得注意的是，与data block一样，index block中的索引信息同样也进行了key值截取，即第二个索引信息的key并不是存储完整的key，而是存储与前一个索引信息的key不共享的部分，区别在于data block中这种范围的划分粒度为16，而index block中为2 。

也就是说，index block连续两条索引信息会被作为一个最小的"比较单元"，在查找的过程中，若第一个索引信息的key小于目标数据项的key，则紧接着会比较第三条索引信息的key。

这就导致最终目标数据项的范围区间为某"两个"data block。

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1766821040916-2a08bf20-5d77-450b-a7fb-df2b55e6a6e9.png)

### 3.6 过滤 data block

若sstable存有每一个data block的过滤数据，则可以利用这些过滤数据对data block中的内容进行判断，"确定"目标数据是否存在于data block中。

过滤的原理为：

* 若过滤数据显示目标数据不存在于data block中，则目标数据**一定不**存在于data block中；
* 若过滤数据显示目标数据存在于data block中，则目标数据**可能存在**于data block中；

具体的原理可能参见《布隆过滤器》。

因此利用过滤数据可以过滤掉部分data block，避免发生无谓的查找。

### 3.7 查找 data block

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1766821042030-e80e7cbb-3119-4003-984b-d084a916f143.png)

在data block中查找目标数据项是一个简单的迭代遍历过程。虽然data block中所有数据项都是按序排序的，但是作者并没有采用"二分查找"来提高查找的效率，而是使用了更大的查找单元进行快速定位。

与index block的查找类似，data block中，以16条记录为一个查找单元，若entry 1的key小于目标数据项的key，则下一条比较的是entry 17。

因此查找的过程中，利用更大的查找单元快速定位目标数据项可能存在于哪个区间内，之后依次比较判断其是否存在与data block中。

可以看到，sstable很多文件格式设计（例如restart point， index block，filter block，max key）在查找的过程中，都极大地提升了整体的查找效率。

## 四、工程实践（≥500字）

### 4.1 与项目中其他模块的集成方式

- **MemTable → SSTable**：内存表写满后通过 `BuildTable()` 函数 dump 为 SSTable 文件，标记为 Level 0
- **Compaction**：多个 Level N 的 SSTable 合并生成新的 Level N+1 SSTable，删除旧文件
- **Version/Manifest**：SSTable 的元数据（文件编号、key 范围）记录在 Version 中，持久化到 Manifest
- **布隆过滤器**：每个 SSTable 可附带一个 filter block，加速 key 不存在时的否定判断

### 4.2 生产环境考量

**错误处理与容错策略**
- SSTable 文件损坏时（如磁盘坏道），Footer 中的 magic number 校验可检测
- 读取时 CRC 校验 data block 完整性（LevelDB 的 Block 格式含 CRC32）
- Compaction 失败不删除旧文件——先写新文件，成功后再标记删除旧文件

**资源管理**
- SSTable 的 index block 常驻内存（通过 TableCache 管理），内存占用 ≈ (文件大小 / block_size) × 索引条目大小
- 文件句柄通过 LRU Cache 管理，避免同时打开过多文件
- SSTable 不可变天然无锁——多线程并发读无需任何同步

**监控与日志**
- 监控各层 SSTable 文件数量和总大小——判断 Compaction 是否滞后
- 监控布隆过滤器的假阳性率——bits_per_key=10 时约 1%

**性能优化策略**
- block_size 默认 4KB（可配置到 64KB），更大 block → 更少索引内存 + 更多单次磁盘读取
- 读操作充分利用 OS 页缓存——SSTable 文件被 mmap 或 read 后缓存在 OS page cache

### 4.3 常见优化策略

- **两级迭代器**：LevelDB 用 `TwoLevelIterator`——外层迭代 index block，内层迭代 data block，透明支持跨 block 遍历
- **前缀压缩自适应**：相邻 key 共享前缀越长，压缩效果越好——LSM-Tree 的有序性天然友好
- **批量预读**：范围扫描时，预读下一个 data block，减少磁盘寻道

## 五、源码解析和实践感悟（≥1000字）

### 5.1 Footer 的精妙设计

Footer 固定 48 字节布局：
```
metaindex_handle (offset+size)   // 指向 meta index block
index_handle (offset+size)       // 指向 index block
padding                          // 补齐到 48 字节
magic (8字节)                    // 0xdb4775248b80fb57（校验用）
```

Footer 是读取 SSTable 的入口——从文件末尾倒数 48 字节即得到。这种"尾部索引"设计在文件格式中非常经典（类似 .tar 的尾部包头、PNG 的 IEND chunk），让文件自描述。

### 5.2 前缀压缩的权衡

前缀压缩按每 16 条记录存储一个完整 key（Restart point）。16 这个数字是经验值——压缩率与查找延迟的平衡：间隔更小 = 更快定位 + 更少解压，间隔更大 = 更高压缩率 + 更多解压开销。

### 5.3 难点与易错点

**陷阱1：Index Block 的"两个 block"语义**

Index Block 中由于也使用了前缀压缩（restart 间隔=2），定位结果是一个**区间**而非精确的某个 block——需要检查两个候选 data block。很多人会误以为 index 定位就是精确的一个 block。

**陷阱2：SSTable 不可变 ≠ 不删除**

SSTable 的不可变性指内容不可原地修改。但文件本身会在 Compaction 后被删除——Compaction 生成新文件后，旧文件被 unlink。

**陷阱3：Footer 的 magic number 校验**

如果 Footer 损坏（48 字节无法正确读取），整个 SSTable 文件不可用——需要从 Manifest/Version 恢复过程中跳过该文件。

### 5.4 经验总结

1. **SSTable 是 LSM-Tree 写入性能的来源**——顺序写入不可变文件，避免了 B+树的随机写
2. **稀疏索引 + 布隆过滤器 = 高效点查**——一次磁盘读取即可定位数据
3. **前缀压缩是 LSM 的"免费午餐"**——有序数据天然相邻 key 共享前缀
4. **SSTable 的读放大需要 Compaction 策略控制**——层级越深，读一个 key 可能需要检查多个文件

<https://my.feishu.cn/file/boxcn1XBTHKMyKTxHhhxT63NeGc>

![](https://cdn.nlark.com/yuque/0/2026/png/50402827/1768834437249-b823f50b-8b69-4cfd-8ec8-b2f159630d2c.png)
![](https://cdn.nlark.com/yuque/0/2026/png/50402827/1768834487955-7aa21915-dc9c-43fa-82c8-a1deebbc8d58.png)
![](https://cdn.nlark.com/yuque/0/2026/png/50402827/1768834502133-334ee149-4c5a-468c-8812-74e2cfb82320.png)
![](https://cdn.nlark.com/yuque/0/2026/png/50402827/1768834961056-6a5bfae5-33e1-47bc-807f-e64acda1580a.png)
![](https://cdn.nlark.com/yuque/0/2026/png/50402827/1768835491608-088bc3b3-b07f-4368-be8c-5e1ae5e3a1b5.png)
![](https://cdn.nlark.com/yuque/0/2026/png/50402827/1768835851107-b78a8020-9b78-4c5d-a56f-320f3e849b63.png)
![](https://cdn.nlark.com/yuque/0/2026/png/50402827/1768836241077-777a0e17-0c3d-4fd5-b018-31041db4ea53.png)

## 六、面试准备（≥10问法+5反问+5一句话，均带回答）

### 6.1 高频问法（≥10个）

**Q1：SSTable 是什么？为什么 LevelDB 用它？**
A：SSTable 是排序的、不可变的、持久化的 key-value map 文件。LevelDB 用它因为不可变文件可以安全地进行 Compaction 合并，排序结构支持高效范围查询和稀疏索引，顺序写入最大化磁盘吞吐。

**Q2：SSTable 的文件结构由哪几部分组成？**
A：五部分——Data Block（存 KV 数据）、Filter Block（布隆过滤器）、Meta Index Block（filter 的索引）、Index Block（data block 的索引）、Footer（Meta Index 和 Index 的元信息 + magic number）。

**Q3：Data Block 中如何压缩 key？**
A：使用前缀压缩——只存储与前一个 key 不共享的部分。每 16 条记录设一个 Restart Point 存储完整 key，作为二分查找的锚点，平衡压缩率与随机访问速度。

**Q4：SSTable 的读操作是如何定位到 key 的？**
A：读 Footer → 读 Index Block → 二分定位到候选 data block（两个，因 index 也有前缀压缩）→ 读 Filter Block 判断 key 是否可能存在 → 读取 data block → 二分定位到 restart point 区间 → 线性遍历找到 key。

**Q5：Index Block 为什么定位结果是两个 data block 而不是一个？**
A：因为 Index Block 也使用了前缀压缩（restart 间隔=2），连续两条索引信息作为一个比较单元。定位结果是 key 落在某一对索引之间，所以可能是两个相邻 data block 之一。

**Q6：Footer 的作用和格式是什么？**
A：Footer 是 SSTable 文件最后 48 字节。包含 Meta Index Block 和 Index Block 的位置信息（offset + size）和一个 8 字节 magic number（0xdb4775248b80fb57）。尾部设计让解析器可以直接从文件末尾定位。

**Q7：布隆过滤器在 SSTable 中起什么作用？**
A：在读取 data block 之前快速判断 key 是否**一定不在**（或**可能在**）该 block 中。如果过滤器说"不在"，则跳过该 block 的磁盘读取。用 ~1% 误报率换取大量无效读的消除。

**Q8：为什么 SSTable 不可变？**
A：不可变性是 LSM-Tree Compaction 的前提——只有不可变文件才能在合并时安全地读取和删除。同时不可变文件天然无锁支持多线程并发读。

**Q9：SSTable 的一次点查最多需要几次磁盘 IO？**
A：Cache 未命中最坏情况：读 Footer（可能已缓存）→ 读 Index Block（可能已缓存）→ 读 Filter Block → 读 Data Block。如果都未缓存，约 2-3 次 IO。如果 data block 在 cache 中，0 次 IO。

**Q10：如何选择 SSTable 的 block_size？**
A：小 block（如 1KB）：更多索引项→更多内存，更细的查找粒度。大 block（如 64KB）：更少索引内存，更大的单次 IO。LevelDB 默认 4KB，在 SSD 上可考虑 16-64KB。

### 6.2 反问点/陷阱点（≥5个）

- 贵团队的存储引擎中，SSTable 的 block_size 是如何选定的？是否针对 SSD/NVMe 做过调优？
- 在实际生产环境中，你们是否遇到过 SSTable 文件损坏的情况？是如何检测和修复的？

- **陷阱问题1**："SSTable 中的 key 是排序的，查找用的是二分查找吗？"——是也不是。Index Block 用二分定位到 data block 区间，Data Block 内部用 Restart Point 做跳表式搜索（非严格二分），最终区间内线性遍历。
- **陷阱问题2**："SSTable 文件可以修改吗？"——不可以原地修改。但可以通过 Compaction 生成新文件删除旧文件来实现逻辑上的更新。
- **陷阱问题3**："Footer 损坏了怎么办？"——该 SSTable 文件不可用。LevelDB 会从 Manifest 中知道这个文件应该存在，但无法读取。需要依赖 Compaction 或备份恢复。

### 6.3 一句话答案（≥5个）

- SSTable 的核心设计理念是：**排序+不可变+稀疏索引——用顺序写换取吞吐量，用稀疏索引换取内存效率。**
- 定位 key 的关键路径是：**Footer → Index Block → Filter Block → Data Block，最多 2-3 次磁盘 IO。**
- 前缀压缩能节省约 50%+ 存储空间，代价是：**每次查找需要从最近的 Restart Point 开始解压。**
- SSTable 与布隆过滤器的关系：**每个 SSTable 可附带一个布隆过滤器，用 1% 误报率减 99% 无效磁盘读取。**
- 这个设计的最大优点是**顺序写入的极高吞吐量**；最大代价是**读放大——同一 key 可能存在于多层多个 SSTable 中。**

- 当被问到"SSTable 和 B+树页的区别？"——回答："SSTable 不可变、顺序写友好、按文件合并；B+树页可变、随机写、按页分裂合并。SSTable 写入性能远超 B+树，但点查可能更慢（读放大）。"

## 附录（模板外原内容收纳）

> 原笔记全部内容已按六大段结构组织完毕。SSTable 定义与特性收入一段，文件逻辑五区域收入二段，Data Block 编码与 Restart Point 收入三段 3.1，读操作七大步骤收入三段 3.2-3.7，缓存/元数据/索引/过滤/查找各子节均完整保留。末尾的 feishu 链接和 7 张补充图片收入五段末尾。
