---
title: InnoDB逻辑存储结构
date: 2026-06-20
categories:
  - ["项目学习", "数据库"]
publish: true
---

# InnoDB 逻辑存储结构

> 适用范围：InnoDB 存储引擎的表空间、段、区、页、行五个层次的逻辑存储结构，以及 Compact/Dynamic 行格式、行溢出机制和数据页内部结构。

## 一、核心概念

- **定义**：InnoDB 将所有数据逻辑地存放在表空间（Tablespace）中，表空间由段（Segment）、区（Extent）、页（Page）、行（Row）四级组成。页是磁盘管理的最小单位（默认 16KB），行是数据存储的最小逻辑单元。
- **关键词**：表空间、段（数据段/索引段/回滚段）、区（64页/1MB）、页（16KB）、Compact行格式、Dynamic行格式、行溢出、MVCC、trx_id、roll_ptr、页目录
- **适用场景/边界**：
  - 适用于理解 MySQL InnoDB 存储引擎的底层数据组织方式
  - 边界：聚焦逻辑存储结构，不涉及 Buffer Pool、Redo Log、Undo Log 等缓存和日志机制

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：五级存储层次**

InnoDB 的逻辑存储结构从大到小分为五层：

```
表空间（Tablespace）
  └── 段（Segment）：数据段、索引段、回滚段等
        └── 区（Extent）：64 个连续页 = 1MB
              └── 页（Page）：16KB，磁盘管理最小单位
                    └── 行（Row）：实际数据记录
```

InnoDB 默认有一个共享表空间 `ibdata1`，所有数据都存放在此表空间内。如果启用了参数 `innodb_file_per_table`，则每张表的数据可以单独放到一个表空间内——但只存放数据、索引和插入缓冲 Bitmap 页，其他数据（回滚信息、插入缓冲索引页、系统事务信息、二次写缓冲等）仍存放在共享表空间内。

**第二层：各层详解**

**表空间（Tablespace）**：
- 共享表空间 `ibdata1`：存放所有表的共享数据
- 独立表空间（`innodb_file_per_table=ON`）：每表一个 `.ibd` 文件，方便备份恢复。Truncate/Drop 表时直接回收磁盘空间

**段（Segment）**：
- 数据段：B+树的叶子节点（Leaf node segment）
- 索引段：B+树的非索引节点（Non-leaf node segment）
- 回滚段：存放 Undo Log，用于 MVCC 和事务回滚
- 段的管理由 InnoDB 引擎自动完成，DBA 无需手动控制，类似于 Oracle 的自动段空间管理（ASSM）

**区（Extent）**：
- 每个区由 64 个连续的页组成，大小为 1MB
- 区是 InnoDB 空间分配的单位。当段内空间不足时，InnoDB 按区为单位扩展

**页（Page）**：
- 页是 InnoDB 磁盘管理的最小单位，默认 16KB
- 可通过参数 `innodb_page_size` 设置为 4K/8K/16K 的倍数，设置后不可修改（除非通过 mysqldump 导出再导入）
- 常见页类型：数据页（B-tree Node）、Undo 页（Undo Log Page）、系统页（System Page）、事务数据页（Transaction System Page）、插入缓冲位图页（Insert Buffer Bitmap）、插入缓冲空闲列表页（Insert Buffer Free List）、未压缩 BLOB 页（Uncompressed BLOB Page）、压缩 BLOB 页（Compressed BLOB Page）

**行（Row）**：
- InnoDB 是面向行的（row-oriented），数据按行存放
- 每个页最多存放 16KB/2 - 200 = 7992 行记录
- 行存储格式有四种：Redundant、Compact（MySQL 5.1+ 默认）、Dynamic（MySQL 5.7+ 默认）、Compressed
- 对应还有面向列的（column-oriented）数据库，如 MySQL Infobright、HBase、Google BigTable

**第三层：Compact 行格式的底层字段布局**

Compact 行格式由以下部分组成（按顺序排列）：

| 组件 | 大小 | 说明 |
|------|------|------|
| 变长字段长度列表 | 变长 | 仅当表中有变长字段（如 VARCHAR）时出现。逆序存储各字段实际长度：<255 用 1 字节，≥255 用 2 字节 |
| NULL 标志位 | 变长 | 仅当有可为 NULL 的字段时出现。位图表示每个字段是否为 NULL，必须占整数个字节（不足 8 位高位补 0） |
| 记录头信息 | 5 字节 | `delete_mask`（删除标记）、`next_record`（下条记录相对地址，链表结构）、`record_type`（0=普通，1=非叶子节点，2=最小记录，3=最大记录） |
| row_id | 6 字节 | 仅在无主键且无非空唯一索引时自动添加作为主键 |
| trx_id | 6 字节 | 事务 ID，标识最后一次修改该行的事务（MVCC 关键字段） |
| roll_ptr | 7 字节 | 回滚指针，指向该记录在 Undo Log 中的上一版本（MVCC 版本链） |

变长字段长度列表和 NULL 标志位采用**逆序存储**（从右向左），以便快速寻址和解析。

### 行溢出数据机制

InnoDB 页为 16KB（16384 字节），但 MySQL VARCHAR 类型最大可声明 65535 字节（实际测试为 65532，因有其他开销）。一个页如何存下远超 16KB 的数据？

**行溢出机制**：当行数据超过阈值（约 8098 字节）时：
1. 前 768 字节前缀存于 B-tree Node 页中
2. 剩余数据存于 Uncompressed BLOB 页
3. 通过偏移量指针关联

阈值 8098 的来源：因为 B+树特性要求一个页中至少放入两行数据（否则退化为链表），经过多次测试得出 8098 字节为触发行溢出的临界值。

### 数据页（Page）内部结构

每个 16KB 数据页的内部结构如下：

```
┌──────────────────────┐
│ File Header (38B)    │ 页类型、页号、LSN、所属表空间等
├──────────────────────┤
│ Page Header (56B)    │ 记录数、空闲槽位数、最后插入位置等
├──────────────────────┤
│ Infimum + Supremum   │ 虚拟边界记录（最小记录和最大记录）
├──────────────────────┤
│ User Records         │ 实际数据行（B+树叶子节点存完整行）
├──────────────────────┤
│ Free Space           │ 空闲空间（链表管理，删除记录后回收）
├──────────────────────┤
│ Page Directory       │ 稀疏目录槽（二分查找定位记录）
├──────────────────────┤
│ File Trailer (8B)    │ checksum + LSN（页完整性校验）
└──────────────────────┘
```

**File Header（38 字节）**：记录页的元信息，包括页类型、页号、LSN（Log Sequence Number）等。

**Infimum 和 Supremum Record**：每个数据页中有两个虚拟行记录用于限定边界。Infimum 比页中任何主键值都小，Supremum 比任何可能大的值还大。这两个值在页创建时建立且永不删除。

**User Record 和 Free Space**：User Record 是实际存储的行记录内容。InnoDB 表总是 B+树索引组织的。Free Space 是空闲空间，以链表数据结构管理，记录被删除后空间加入空闲链表。

**页目录（Page Directory）**：页目录存放记录的页内相对位置（不是偏移量），这些记录指针称为 Slots（槽）或目录槽（Directory Slots）。InnoDB 的槽是稀疏目录（Sparse Directory），即一个槽包含 4-8 条记录：
- Infimum 的 `n_owned` 值总是 1
- Supremum 的 `n_owned` 取值范围 [1, 8]
- 其他用户记录的 `n_owned` 取值范围 [4, 8]

槽中记录按索引键值顺序存放，可利用二分查找迅速定位。由于是稀疏目录，二分查找只是粗略定位，需通过 `record header` 中的 `next_record` 链表继续精确查找。B+树索引本身只能找到记录所在的页，页载入内存后再进行二分查找。

**File Trailer（8 字节）**：检测页是否完整写入磁盘。前 4 字节为 checksum 值，后 4 字节与 File Header 中的 FIL_PAGE_LSN 相同。每次从磁盘读取页时检测完整性（可通过 `innodb_checksums` 开启或关闭）。MySQL 5.6.6 引入了 CRC32 checksum 算法，性能更高。

## 三、动手实践（代码案例）

```sql
-- 查看表空间类型
SHOW VARIABLES LIKE 'innodb_file_per_table';
-- ON: 每表独立 .ibd 文件

-- 查看页大小
SHOW VARIABLES LIKE 'innodb_page_size';
-- 默认 16384 (16KB)

-- 查看表的行格式
SHOW TABLE STATUS LIKE 'users';
-- Row_format: Dynamic

-- 指定行格式建表
CREATE TABLE test_compact (
    id INT PRIMARY KEY,
    name VARCHAR(100),
    content TEXT
) ENGINE=InnoDB ROW_FORMAT=COMPACT;

-- 查看表空间文件
-- Linux: /var/lib/mysql/database_name/
-- 每个 InnoDB 表对应一个 .ibd 文件（独立表空间模式下）
```

```python
# Python 解析 InnoDB 页结构（简化示例）
import struct

PAGE_SIZE = 16384  # 16KB

def parse_page_header(data):
    """解析 File Header（前 38 字节）"""
    # FIL_PAGE_SPACE_OR_CHKSUM (4B)
    checksum = struct.unpack('>I', data[0:4])[0]
    # FIL_PAGE_OFFSET (4B)
    page_no = struct.unpack('>I', data[4:8])[0]
    # FIL_PAGE_PREV (4B), FIL_PAGE_NEXT (4B) — B+树兄弟页指针
    prev_page = struct.unpack('>I', data[8:12])[0]
    next_page = struct.unpack('>I', data[12:16])[0]
    # FIL_PAGE_LSN (8B)
    lsn = struct.unpack('>Q', data[16:24])[0]
    # FIL_PAGE_TYPE (2B)
    page_type = struct.unpack('>H', data[24:26])[0]
    
    return {
        'checksum': checksum,
        'page_no': page_no,
        'prev_page': prev_page,
        'next_page': next_page,
        'lsn': lsn,
        'page_type': page_type,
    }

# 页类型映射
PAGE_TYPES = {
    0x45BF: 'B-tree Node (数据页)',
    0x0002: 'Undo Log Page',
    0x0003: 'Index Node (索引页)',
    0x0005: 'Insert Buffer Free List',
    0x0007: 'Insert Buffer Bitmap',
    0x000A: 'Uncompressed BLOB Page',
    0x000B: 'Compressed BLOB Page',
}
```

## 四、进阶应用（≥500字）

### 与其他主题的关联

- **MySQL 索引**：每个索引都是独立的 B+树，聚簇索引的叶子节点就是数据页（User Records），二级索引的叶子节点存的是索引列+主键值。理解页结构是理解索引的基础。
- **MVCC（多版本并发控制）**：Compact/Dynamic 行格式中的 trx_id（6B）和 roll_ptr（7B）是 MVCC 的核心字段。trx_id 标识最后一次修改的事务，roll_ptr 指向 Undo Log 中的上一个版本，多个版本形成版本链。ReadView 通过这两个字段判断可见性。
- **Buffer Pool**：InnoDB 以页为单位将数据从磁盘加载到 Buffer Pool，页的 16KB 大小直接决定了 Buffer Pool 的内存管理粒度。

### 工程中的真实用法

**行格式选型**：

| 行格式 | 特点 | 适用场景 |
|--------|------|----------|
| Redundant | 最老，MySQL 5.0 前默认，字段偏移列表冗余 | 兼容旧系统 |
| Compact | MySQL 5.1-5.6 默认，行溢出存前 768 字节前缀 | 常规 OLTP 场景 |
| Dynamic | MySQL 5.7+ 默认，行溢出存 20 字节指针（完全溢出） | 含 TEXT/BLOB 大字段的表 |
| Compressed | Dynamic + 页级压缩（zlib），以 CPU 换空间 | 存储成本敏感的归档库 |

Dynamic 格式相比 Compact 的改进：Compact 在大字段行溢出时存 768 字节前缀，Dynamic 只存 20 字节指针，行溢出更彻底，主索引页能存更多行。

**页大小选择的工程考量**：
- SSD 场景：推荐 4K/8K 页（减少写放大，SSD 随机 I/O 性能好）
- HDD 场景：推荐 16K 页（减少随机 I/O 次数，HDD 随机寻道成本高）
- 注意：页大小必须在初始化时设定，后期无法修改（除非 mysqldump 重建）

**`innodb_file_per_table` 的实践建议**：
- 建议开启：每表独立 `.ibd` 文件，Truncate/Drop 直接回收磁盘空间
- 共享表空间 `ibdata1` 只增不减（即使删除数据也不回收空间），独立表空间无此问题
- 缺点：打开表时需要更多文件描述符

### 常见优化策略

- **Compact → Dynamic 行格式迁移**：`ALTER TABLE t ROW_FORMAT=DYNAMIC;` 对含大字段的表有明显空间收益，但会锁表（MySQL 5.6+ 支持 Online DDL）
- **表空间碎片整理**：大量删除后，`OPTIMIZE TABLE t;` 或 `ALTER TABLE t ENGINE=InnoDB;` 重建表空间，回收碎片
- **页分裂预防**：自增主键保证数据顺序写入，减少页分裂。UUID 主键会导致随机插入和大量页分裂

## 五、源码解析和实践感悟（≥1000字）

### 关键实现路径

**InnoDB 页的完整性校验流程**（参考 MySQL 8.0 源码 `storage/innobase/include/page0page.h`）：

```c
// 页校验和计算（简化逻辑）
// 源码位置：storage/innobase/include/page0page.h
// 页大小宏定义
#define UNIV_PAGE_SIZE      (16 * 1024)  // 16KB

// 页头结构（部分字段）
// FIL_PAGE_SPACE_OR_CHKSUM  0-3   (4 bytes) 校验和
// FIL_PAGE_OFFSET           4-7   (4 bytes) 页号
// FIL_PAGE_PREV             8-11  (4 bytes) 前一页
// FIL_PAGE_NEXT             12-15 (4 bytes) 后一页
// FIL_PAGE_LSN              16-23 (8 bytes) LSN
// FIL_PAGE_TYPE             24-25 (2 bytes) 页类型
// FIL_PAGE_FILE_FLUSH_LSN   26-33 (8 bytes) 
// FIL_PAGE_ARCH_LOG_NO      34-37 (4 bytes) 

// 页尾结构
// FIL_PAGE_END_LSN_OR_CHKSUM  页尾前4字节：校验和
//                              页尾后4字节：LSN低4字节
```

**Compact 行格式的记录头解析**：

```c
// 记录头信息（5 字节）的位布局
// 源码：storage/innobase/include/rem0rec.h

// 记录头字段（Compact格式）：
// Bit 0:      info_bits (2 bits) — 0=普通, 1=delete mark, 2=min_rec
// Bit 2-4:    n_owned (3 bits)   — 该记录拥有的槽中记录数
// Bit 5-16:   heap_no (13 bits)  — 记录在页内堆中的序号
// Bit 17-19:  record_type (3 bits) — 0=普通,1=非叶子,2=Infimum,3=Supremum
// Bit 20:     (未使用)
// Bit 21-36:  next_record (16 bits) — 下一条记录的相对偏移

// C 语言表示（简化）
typedef struct {
    unsigned info_bits   : 2;   // 信息位
    unsigned n_owned     : 4;   // 拥有的记录数
    unsigned heap_no     : 13;  // 堆序号
    unsigned record_type : 3;   // 记录类型
    unsigned next_record : 16;  // 下一条记录偏移
} rec_header_t;  // 总共 38 bits ≈ 5 bytes
```

**页目录（Page Directory）槽的二分查找实现**：

```c
// 页目录二分查找（简化逻辑）
// 源码：storage/innobase/page/page0cur.cc 的 page_cur_search_with_match()

int page_cur_search_with_match(
    buf_block_t* block,    // 页块
    const dtuple_t* tuple, // 查找键
    ulint mode,            // 查找模式
    rec_t** cursor)        // 输出：定位到的记录
{
    page_t* page = buf_block_get_frame(block);
    
    // 1. 获取页目录槽数组
    page_dir_slot_t* slots = page_dir_get_nth_slot(page, 0);
    ulint n_slots = page_dir_get_n_slots(page);
    
    // 2. 二分查找槽位置
    ulint low = 0;
    ulint high = n_slots - 1;
    
    while (low < high) {
        ulint mid = (low + high) / 2;
        rec_t* rec = page_dir_slot_get_rec(slots[mid]);
        
        int cmp = cmp_dtuple_rec(tuple, rec);
        if (cmp > 0) {
            low = mid;       // 目标在右半部分
        } else if (cmp < 0) {
            high = mid;      // 目标在左半部分
        } else {
            // 精确匹配
            *cursor = rec;
            return 0;
        }
        
        if (high - low == 1) break;  // 二分结束
    }
    
    // 3. 二分结果只是粗略定位，通过 next_record 链精确查找
    rec_t* rec = page_dir_slot_get_rec(slots[low]);
    while (rec != NULL) {
        int cmp = cmp_dtuple_rec(tuple, rec);
        if (cmp <= 0) {
            *cursor = rec;
            return cmp;
        }
        rec = page_rec_get_next(rec);  // 沿链表继续
    }
    
    return 1;  // 未找到
}
```

### 难点与易错点

**陷阱1：VARCHAR(65535) 为什么实际最大只有 65532？**

MySQL VARCHAR 最大声明长度为 65535 字节，但实际测试只能存 65532。因为这 3 个字节用于：
- 变长字段长度列表中存储该字段实际长度的 2 字节（因为 >255）
- NULL 标志位占用 1 字节（至少 1 字节对齐）

如果使用 UTF-8 等变长编码，实际字符数会更少（一个中文字符占 3 字节，所以 VARCHAR(65535) UTF-8 实际只能存约 21845 个中文字符）。

**陷阱2：`innodb_file_per_table` 下存储的局限**

即使开启独立表空间，以下数据仍存于共享表空间：
- 回滚信息（Undo Log）
- 插入缓冲索引页
- 系统事务信息
- 二次写缓冲（Doublewrite Buffer）
- 数据字典信息

这意味着即使删除所有用户表，`ibdata1` 也不会缩小。要回收共享表空间，只能导出全部数据后重建实例。

**陷阱3：页内记录数上限的计算误区**

"每页最多 7992 行"是理论极限（16KB/2 - 200），前提是每行数据极小。实际每页能存的行数取决于行大小。若行大小为 1KB，每页最多约 15 行。若行很大（接近 8KB），每页只有 1 行。若超过 8KB，触发行溢出。

### 经验总结

1. **层次化存储是性能优化的基础**：表空间→段→区→页→行，每层都针对特定 I/O 模式优化。区由 64 个连续页组成（1MB），使得顺序扫描可以高效利用磁盘预读。理解这个层次，才能理解为什么 `SELECT COUNT(*)` 可能走二级索引而非聚簇索引（二级索引单页能存更多行）。
2. **trx_id + roll_ptr = 无锁一致性读**：InnoDB 通过行记录中的 6 字节 trx_id 和 7 字节 roll_ptr 串联起 Undo Log 版本链，配合 ReadView 实现了 MVCC。每次 UPDATE 不直接覆盖原数据，而是写入新版本 + Undo Log 旧版本，trx_id 标记事务可见性。
3. **页目录的稀疏设计是空间与速度的平衡**：如果每条记录一个槽，查找是 O(log n) 的纯二分；但槽本身占用空间。4-8 条记录共享一个槽，二分 + 少量线性查找，在大多数场景下性能不输全二分，空间开销减少 75-87%。
4. **Dynamic 行格式是现代默认的理由**：对大字段（TEXT/BLOB/VARCHAR(>8098)）只存 20 字节指针，完全行溢出，相比 Compact 的 768 字节前缀极大减少了主索引页的空间浪费。主索引越小，Buffer Pool 命中率越高。

## 六、面试准备

### 6.1 高频问法（≥10个）

**基础理解：**

Q1：InnoDB 的逻辑存储结构是怎样的？分为哪几层？

A：五层结构：表空间（Tablespace）→ 段（Segment：数据段/索引段/回滚段）→ 区（Extent：64 页/1MB）→ 页（Page：16KB）→ 行（Row）。表空间是最高层容器，页是磁盘管理的最小单位，行是实际数据的最小单元。

Q2：InnoDB 有哪几种行格式？默认是什么？

A：四种：Redundant（最老）、Compact（5.1-5.6 默认，行溢出存 768B 前缀）、Dynamic（5.7+ 默认，行溢出存 20B 指针）、Compressed（Dynamic + zlib 页压缩）。Dynamic 与 Compact 的核心区别是大字段行溢出方式——Dynamic 完全溢出，只存指针；Compact 存 768 字节前缀。

Q3：什么是行溢出？什么情况下触发？

A：当一行数据超过阈值约 8098 字节时触发行溢出。InnoDB 页 16KB，但 B+树要求每页至少两行（否则退化为链表），所以单行必须 < 约 8KB。超出的数据存到 Uncompressed BLOB 页，主索引页保留前 768 字节前缀（Compact）或 20 字节指针（Dynamic）。

**原理深入：**

Q4：Compact 行格式包含哪些字段？`trx_id` 和 `roll_ptr` 的作用？

A：变长字段长度列表（逆序）、NULL 标志位（位图）、5B 记录头（delete_mask + next_record + record_type）、6B row_id（无主键时自动生成）、6B trx_id（最后修改该行的事务 ID）、7B roll_ptr（指向 Undo Log 上一版本）。trx_id + roll_ptr 是 MVCC 核心——trx_id 判断版本归属事务，roll_ptr 串联 Undo Log 版本链，ReadView 通过这两个字段实现无锁一致性读。

Q5：页目录（Page Directory）如何工作？为什么是稀疏目录？

A：页目录以"槽"为单位组织，每个槽包含 4-8 条记录（稀疏）。查找流程：1）二分查找定位目标所在的槽；2）沿 `next_record` 链表在槽内精确查找。稀疏设计是空间与速度的平衡——相比每记录一个槽（全二分），稀疏目录减少 75-87% 的槽空间，额外几步链表查找开销可忽略。

Q6：InnoDB 页的完整性如何校验？

A：通过 File Header（页头）和 File Trailer（页尾）配合校验。File Header 包含 LSN 和 checksum，File Trailer 前 4 字节是 checksum，后 4 字节是 LSN 低 4 字节。每次读取页时比较两端值，不一致说明页损坏（部分写入/磁盘故障）。MySQL 5.6.6+ 引入 CRC32 算法替代旧 checksum。

**实践应用：**

Q7：`innodb_file_per_table` 开启与否，各自的优缺点？

A：开启（ON）：每表独立 `.ibd` 文件，Truncate/Drop 直接回收空间，方便备份迁移。缺点：需要更多文件描述符。关闭（OFF）：所有表数据存于共享 `ibdata1`，文件数少。缺点：`ibdata1` 只增不减，即使删除数据也不回收空间。

Q8：共享表空间（ibdata1）中存了什么？

A：数据字典、Undo Log（回滚信息）、Insert Buffer（插入缓冲）、Doublewrite Buffer（二次写缓冲）、Change Buffer。即使开启 `innodb_file_per_table`，这些数据仍存于共享表空间。

Q9：如何选择合适的 InnoDB 页大小？

A：SSD 推荐 4K/8K（减少写放大，SSD 无寻道开销）；HDD 推荐 16K（减少随机 I/O 次数，HDD 有寻道成本）。页大小必须在 MySQL 初始化时设置，后期不可修改。另外，页大小与 Buffer Pool 的 LRU 管理粒度直接相关。

Q10：一条 DELETE 语句执行后，数据页中发生了什么？

A：数据不会物理删除。InnoDB 在行记录的 `record header` 中设置 `delete_mask = 1`（标记删除），同时将空间加入 Free Space 空闲链表。真正的物理删除发生在 Purge 线程清理 Undo Log 时（或页重组时）。这种"标记删除"机制是 MVCC 的基础——旧事务可能需要看到已标记删除的行。

### 6.2 反问点/陷阱点（≥5个）

**针对面试官的深度问题：**

贵公司线上 MySQL 的行格式用的是 Compact 还是 Dynamic？有没有大字段行溢出导致主索引膨胀的问题？

你们的 `innodb_page_size` 是怎么选的？是在 SSD 还是 HDD 上跑的？有没有对比过不同页大小的性能差异？

共享表空间 ibdata1 膨胀问题你们遇到过吗？怎么处理的——是导出重建还是用其他方案？

**常见的陷阱问题：**

陷阱问题1：VARCHAR(100) 声明后存 "hello"（5 字节），实际占用多少空间？答案：Compact 格式下，除 5 字节数据外，还需：变长字段长度列表 1 字节（记录 5）、NULL 标志位 1 字节、记录头 5 字节、trx_id 6 字节、roll_ptr 7 字节。如果有主键，还需要主键存储空间。一条"hello"实际可能占用约 30 字节。

陷阱问题2：InnoDB 页 16KB，为什么一行最大只能约 8KB 而非 16KB？答案：B+树要求每页至少存两行数据（否则退化为链表，B+树失去意义）。所以单行不能超过 16KB/2 = 8KB，实际阈值约 8098 字节（留部分给页头和页目录）。

陷阱问题3：行溢出时，Dynamic 比 Compact 好在哪？答案：Compact 在主索引页存 768 字节前缀，Dynamic 只存 20 字节指针。对于一条 64KB 的大文本：Compact 额外占用 768 字节主索引页空间，Dynamic 只占 20 字节。在大量大字段场景下，Dynamic 可让主索引 B+树更紧凑，Buffer Pool 命中率更高。

### 6.3 一句话答案（≥5个）

InnoDB 五层存储结构：表空间 → 段（数据/索引/回滚）→ 区（64页/1MB）→ 页（16KB）→ 行。

Compact 行 = 变长列表（逆序）+ NULL 位图 + 5B 头 + row_id(6B) + trx_id(6B) + roll_ptr(7B) + 列值。

行溢出 = 前 768B（Compact）或 20B 指针（Dynamic）留主索引页 + 其余存 BLOB 页。

MVCC 核心字段 = trx_id（6B，标记事务）+ roll_ptr（7B，指向 Undo Log 上一版本）+ ReadView 可见性判断。

页目录 = 稀疏槽（4-8条/槽）+ 二分查找 + next_record 链表精确定位。

当被问到"DELETE 后数据去哪了"时，回答："InnoDB 做标记删除（delete_mask=1），空间加入 Free Space 链表，物理删除由 Purge 线程异步完成。这是 MVCC 的基础。"

当被问到"为什么用 Dynamic 不用 Compact"时，回答："Dynamic 对大字段只存 20B 指针而非 768B 前缀，主索引更紧凑，Buffer Pool 利用率更高。"

## 附录（原笔记图片归档）

> 以下为原笔记中所有 InnoDB 逻辑存储结构图，原样保留于此。

### 逻辑存储结构整体图

![](https://cdn.nlark.com/yuque/0/2025/jpeg/50402827/1758437053250-c676455e-d6dd-4958-9983-3dbd001bc93a.jpeg)![](https://cdn.nlark.com/yuque/0/2025/webp/50402827/1758437522347-58639224-3e11-4585-bb24-22f3cac740d7.webp)

### Compact 行格式组成

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1758437469094-65869184-de6c-4a18-92d3-14ed12705aed.png)

### 行溢出数据存放方式

![](https://cdn.nlark.com/yuque/0/2025/png/50402827/1758437489156-aca8c793-8664-4695-846c-fb1ae85d0ef0.png)

### 数据页结构

![](https://cdn.nlark.com/yuque/0/2025/jpeg/50402827/1758437398696-58299e84-e942-43fe-9888-745777002e06.jpeg)

### 文件头（File Header）组成

![](https://cdn.nlark.com/yuque/0/2025/jpeg/50402827/1758437412539-e3aa0822-1775-4331-8a5b-9cfd3eb1370d.jpeg)![](https://cdn.nlark.com/yuque/0/2025/jpeg/50402827/1758437417610-1f2a92ba-0fd9-4e1b-8069-6c38448a235d.jpeg)

### Infimum 和 Supremum Record

![](https://cdn.nlark.com/yuque/0/2025/jpeg/50402827/1758437433156-904e9a03-fa6c-4a7f-8e06-0b89a8d1cde0.jpeg)
