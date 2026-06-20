---
title: MySQL慢查询原因分析
date: 2026-06-20
categories:
  - ["项目学习", "数据库"]
publish: true
---

# MySQL 慢查询原因分析

> 适用范围：MySQL 慢查询根因诊断——十大索引失效场景、深分页问题、统计信息偏差、EXPLAIN 验证。

## 一、核心概念

- **定义**：MySQL 慢查询的根本原因可分为索引问题（未加索引/索引失效）、SQL 写法问题（深分页、SELECT *）、数据量问题（单表过大）和统计信息问题（优化器选错索引）。
- **关键词**：索引失效、隐式类型转换、最左前缀、OR 条件、深分页、统计信息、ANALYZE TABLE
- **适用场景/边界**：
  - 慢查询日志中出现高频慢 SQL 的根因分析
  - 索引优化前的失效场景识别
  - 不适合：硬件资源瓶颈（需用 iostat/vmstat 分析）、锁竞争导致的慢查询

## 二、详细解析

### 十大索引失效场景

#### 2.1 SQL 没加索引

最基础的慢查询原因——WHERE 条件的列上没有索引，只能全表扫描。

#### 2.2 隐式类型转换，索引失效

当字符串列与数字进行比较时，MySQL 按类型优先级将字符串列 CAST 为 DOUBLE，导致索引失效：

```sql
-- ❌ 索引失效：name 是 VARCHAR，传入数字
SELECT * FROM user WHERE name = 123;

-- ✅ 正确：传入字符串
SELECT * FROM user WHERE name = '123';
```

**底层原因**：MySQL 比较操作数类型不匹配时，按优先级转换——DOUBLE > DECIMAL > BIGINT > INT > ... > VARCHAR。字符串列被转为 DOUBLE 后，索引存的是原始字符串值，无法匹配。

#### 2.3 OR 条件可能导致索引失效

对于 `WHERE userId = 1 OR age = 20`（age 无索引），MySQL 优化器面临两个选择：
- 方案 A：走 userId 索引 → 全表扫描 age → 合并结果（索引扫描 + 全表扫描 + 合并，三步）
- 方案 B：直接全表扫描（一步）

优化器出于效率考虑，通常选方案 B，让索引失效。**注意**：如果 OR 条件的列都加了索引，索引可能走也可能不走。

**解决方案**：拆成两条 SQL 用 UNION。

#### 2.4 LIKE 通配符导致索引失效

```sql
-- ❌ % 开头：无法确定前缀范围，索引失效
SELECT * FROM user WHERE name LIKE '%abc';

-- ✅ % 放后面：可确定前缀 [abc, abd)，走索引范围扫描
SELECT * FROM user WHERE name LIKE 'abc%';
```

**优化方案**：使用覆盖索引（SELECT 的列都在索引中），即使 % 开头也能避免回表。

#### 2.5 不满足联合索引的最左前缀

联合索引 `(a,b,c)` 按 a→b→c 顺序排序存储，相当于建立了 `(a)`、`(a,b)`、`(a,b,c)` 三个逻辑索引：

```sql
-- 索引 (a,b,c)：
✅ WHERE a = 1                     -- 走 a
✅ WHERE a = 1 AND b = 2           -- 走 a,b
✅ WHERE a = 1 AND b = 2 AND c = 3 -- 走 a,b,c
❌ WHERE b = 2                     -- 缺少 a，不走索引
❌ WHERE a = 1 AND c = 3           -- b 断了，只有 a 能用
❌ WHERE a = 1 AND b > 2 AND c = 3 -- b 是范围，c 无法用
```

**为什么 b 使用范围查询后 c 还能走索引？**

MySQL 5.6+ 的索引下推（ICP）会在引擎层先过滤 c 的条件再回表，但 c 不参与索引定位（只参与过滤）。key_len 只算 a+b 的长度。

#### 2.6 索引列使用 MySQL 内置函数

```sql
-- ❌ 函数在索引列上：索引失效
SELECT * FROM user WHERE DATE_ADD(login_time, INTERVAL 1 DAY) = '2022-05-22';

-- ✅ 函数移到右边：索引可用
SELECT * FROM user WHERE login_time = DATE_ADD('2022-05-22', INTERVAL -1 DAY);
```

#### 2.7 索引列进行运算（+、-、*、/）

```sql
-- ❌ 运算在索引列上
SELECT * FROM user WHERE age + 1 = 20;

-- ✅ 运算移到右边
SELECT * FROM user WHERE age = 19;
```

#### 2.8 != 或 <> 可能导致索引失效

不等于查询返回的结果集通常很大，优化器可能认为全表扫描成本更低而放弃索引。

#### 2.9 IS NULL / IS NOT NULL 可能失效

InnoDB 对 NULL 值也有索引记录。`IS NULL` 通常走索引（等值查询），`IS NOT NULL` 等同于范围查询，某些情况可能不走索引。

#### 2.10 关联字段编码格式不一致

```sql
-- ❌ t1.name 用 utf8mb4，t2.name 用 utf8，JOIN 时索引失效
SELECT * FROM t1 JOIN t2 ON t1.name = t2.name;
```

#### 2.11 优化器选错了索引

MySQL 通过成本模型决定用哪个索引。频繁增删数据导致统计信息（cardinality）不准时，优化器可能选错索引。

**解决方案**：
- `ANALYZE TABLE` 重新采样统计信息
- `FORCE INDEX` 强制指定（最后手段）
- 修改 SQL 引导优化器选择正确索引
- 删除误用的索引或新建更合适的索引

## 三、动手实践

### 3.1 EXPLAIN 验证索引失效

```sql
-- 创建测试表
CREATE TABLE test_user (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(24),
    age INT,
    login_time DATETIME,
    INDEX idx_name_age (name, age),
    INDEX idx_login (login_time)
);

-- 验证隐式转换
EXPLAIN SELECT * FROM test_user WHERE name = 123;
-- type=ALL, key=NULL → 全表扫描，索引失效

-- 验证 LIKE %
EXPLAIN SELECT * FROM test_user WHERE name LIKE '%abc';
-- type=ALL, key=NULL

-- 验证最左前缀
EXPLAIN SELECT * FROM test_user WHERE age = 20;
-- type=ALL（或 index），不走 idx_name_age

-- 验证索引列函数
EXPLAIN SELECT * FROM test_user WHERE YEAR(login_time) = 2025;
-- type=ALL, key=NULL
```

## 四、进阶应用

### 4.1 limit 深分页问题

```sql
-- 慢：扫描 100010 行，扔掉前 100000 行
SELECT * FROM account WHERE create_time > '2020-09-19' LIMIT 100000, 10;
```

**执行流程**：
1. 通过二级索引 `idx_create_time` 过滤，找到满足条件的主键 id
2. 通过主键 id 回表，找到完整行
3. 扫描 100010 行，丢弃前 100000 行，返回最后 10 行

**慢的原因**：扫描行数多 + 回表次数多。

#### 优化方案 1：标签记录法（游标法）

```sql
-- 上次查到 id=100000，这次从这开始
SELECT * FROM account WHERE id > 100000 LIMIT 10;
```

要求：主键连续自增，结果按主键排序。局限性：需要连续自增字段。

#### 优化方案 2：延迟关联法

```sql
-- 子查询只取主键 ID（走覆盖索引，无回表）+ JOIN 回表取完整行
SELECT t1.* FROM account t1
INNER JOIN (SELECT id FROM account WHERE create_time > '2020-09-19' LIMIT 100000, 10) t2
ON t1.id = t2.id;
```

**优化原理**：子查询在二级索引上只取 id（覆盖索引），无需回表。外层 JOIN 通过主键等值匹配回表，效率高。

### 4.2 统计信息维护

```sql
-- 重新采样统计信息（推荐定期执行）
ANALYZE TABLE account;

-- 调大采样页数提高准确性（默认 20，大表可增至 200）
SET GLOBAL innodb_stats_persistent_sample_pages = 200;
```

### 4.3 OR 条件优化：UNION 替代

```sql
-- ❌ 可能不走索引
SELECT * FROM t WHERE a = 1 OR b = 2;

-- ✅ 拆成 UNION，各走各的索引
SELECT * FROM t WHERE a = 1
UNION
SELECT * FROM t WHERE b = 2;
```

---

## 五、源码解析和实践感悟

### 5.1 InnoDB 索引选择与成本估算核心路径（源码级）

```cpp
// MySQL 8.0 sql/opt_range.cc — check_quick_select 用索引统计信息估算行数
// 索引基数（cardinality）来自 InnoDB 对 B+树的采样统计
ha_rows check_quick_select(PARAM *param, uint idx, SEL_ARG *tree, bool update_tbl_stats) {
    KEY *key_info = &param->table->key_info[idx];
    // 范围查询的行数估算：用 key_part 的 rec_per_key 统计
    // rec_per_key：每个不同键值的平均行数，由 innodb_stats_method 决定（nulls_equal/null_unequal）
    ha_rows found_rows = 1.0;
    for (uint part = 0; part < key_info->user_defined_key_parts; part++) {
        if (tree->type == SEL_ARG::KEY_RANGE) {
            double rows_per_key = key_info->rec_per_key[part];  // 1/keys_per_key
            if (rows_per_key > 0)
                found_rows *= rows_per_key;
        }
    }
    table->quick_rows[key] = found_rows;
    // 成本：range_cost = found_rows × (INDEX_LOOKUP_COST + ROW_EVALUATE_COST)
    // 如果 found_rows 过低（统计信息偏差），优化器可能错误选择全表扫描
}

// InnoDB 的索引统计信息采集（dict_stats_update）
void dict_stats_update(DICT_TABLE *table, dict_stats_update_option option) {
    // 对每个索引采样 N 个叶子页（innodb_stats_persistent_sample_pages 默认 20）
    for (uint i = 0; i < n_sample_pages; i++) {
        page = btr_pcur_get_page(&pcur);
        n_recs += page_get_n_recs(page);
        // 统计不同键值数
        n_diff += btr_page_get_n_diff(page, index);
    }
    index->stat_n_diff_key_vals[i] = n_diff;  // 不同键值数
    index->stat_n_leaf_pages = n_leaf_pages;   // 叶子页数
    // cardinality ≈ n_diff * (n_leaf_pages / n_sample_pages)
}
```

### 5.2 隐式类型转换导致的索引失效（源码级）

```cpp
// MySQL sql/item_cmpfunc.cc — 比较时的类型转换
// 当 WHERE varchar_col = 123（数字）时，字符串列会被转为 DOUBLE
bool Arg_comparator::set_cmp_func() {
    // 规则：当操作数类型不匹配时，MySQL 按优先级转换
    // 优先级：DOUBLE > DECIMAL > BIGINT > INT > ... > VARCHAR
    if (a->field_type() == MYSQL_TYPE_VARCHAR && b->field_type() == MYSQL_TYPE_LONGLONG) {
        // 字符串列被 CAST 为 DOUBLE，导致索引失效！
        // 因为索引存的是原始字符串值，转换后的 DOUBLE 无法使用索引
        cmp_func = &Arg_comparator::compare_string_to_double;
        *a = new Item_func_conv_charset(a, &my_charset_numeric);  // 隐式 CAST
    }
    // 正确写法：WHERE varchar_col = '123'（字符串比较，可走索引）
}
```

### 5.3 联合索引最左前缀匹配的内核逻辑

```cpp
// InnoDB B+树比较函数 — 按索引列顺序逐列比较
// btr/btr0cur.cc — 页内二分搜索时调用
int cmp_dtuple_rec_with_match_low(
    dtuple_t *dtuple, rec_t *rec, const ulint *offsets,
    ulint n_cmp, ulint *matched_fields) {
    ulint cur_field = 0;
    while (cur_field < n_cmp) {
        dfield_t *dfield = &dtuple->fields[cur_field];
        ulint rec_field_len = rec_off_nth_sql_null_size(index, offsets, cur_field);
        int cmp = cmp_data_data(dfield->data, dfield->len,
                                rec + rec_off, rec_field_len);
        if (cmp != 0) {
            *matched_fields = cur_field;  // 在此列上不匹配，停止
            return cmp;
        }
        cur_field++;  // 匹配成功，继续比较下一列
    }
    *matched_fields = cur_field;  // 所有列都匹配
    return 0;
}
// 关键：range查询后的列不再参与比较 → 这就是最左前缀匹配的根源
```

### 实践感悟

1. **隐式转换是性能杀手第一位**：代码里 `WHERE id = '123'` 和 `WHERE id = 123` 区别巨大。字符串列传入数字参数时，MySQL 会 CAST 字符串列为 DOUBLE，直接让索引废掉。
2. **OR 条件的处理是 MySQL 优化器的弱点**：`WHERE a=1 OR b=2` 即使 a 和 b 各有索引，优化器也可能选择全表扫描（合并两个索引结果的 cost 可能更高）。拆成 UNION 是稳妥方案。
3. **最左前缀原则是面试高频**：联合索引 (a,b,c) 本质是建了三棵 B+树的逻辑前缀：(a)、(a,b)、(a,b,c)。单独查 b 或 c 不走索引不是 bug 是设计。
4. **limit 深分页的根因是回表**：`LIMIT 100000,10` 需要扫描 100010 行然后丢弃前 100000 行，大量数据做了无用回表。延迟关联（子查询只取 ID + limit + JOIN 主表）能大幅优化。
5. **统计信息的准确度决定索引是否有效**：`ANALYZE TABLE` 默认采样 20 个页估算 cardinality，大表可能严重偏离。`innodb_stats_persistent_sample_pages` 可调大（如 200）提高准确性。
6. **IS NULL 走不走索引取决于具体场景**：InnoDB 对 NULL 值也有索引记录，`ref IS NULL` 通常走索引，但 `not_ref IS NULL` 不一定。关键看优化器 cost 估算。

---

## 六、面试准备

### Q1: 索引失效的十大场景列举至少 5 个？
**答**：① 隐式类型转换（varchar 传入数字）；② OR 条件列不全有索引；③ LIKE '%xxx' 前缀模糊；④ 联合索引不满足最左前缀；⑤ 索引列上使用函数（DATE(column)）；⑥ 索引列上进行运算（column+1）；⑦ != 或 <>；⑧ IS NULL / IS NOT NULL（某些情况）；⑨ JOIN 关联字段编码不一致；⑩ 优化器选错索引。

### Q2: 最左前缀原则的原理是什么？
**答**：联合索引按列顺序构建 B+树。如 (a,b,c) 的索引，数据先按 a 排序，a 相同时按 b 排序，b 相同时按 c 排序。所以单独 b 或 c 查询无法利用索引的有序性。查询需以索引第一列为起始才能利用 B+树的排序特性。

### Q3: 为什么 OR 条件会导致索引失效？
**答**：MySQL 处理 OR 的两种方式：① 合并索引（index merge），分别用两个索引查再并集，cost 可能比全表扫描还高；② 直接全表扫描一行行判断。优化器选 cost 最低的方案，OR 场景下全表扫描往往最优。

### Q4: 隐式类型转换为什么会导致索引失效？
**答**：当字符串列与数字进行比较时，MySQL 按类型优先级将字符串列 CAST 为 DOUBLE，索引中存的是原始字符串值而非转换后的 DOUBLE，无法使用索引进行快速定位。

### Q5: LIKE 'abc%' 走索引，LIKE '%abc' 为什么不走？
**答**：B+树索引按列值前缀顺序组织叶子节点。LIKE 'abc%' 可以确定扫描范围 [abc, abd)，而 LIKE '%abc' 的前缀不确定，无法利用 B+树的有序性缩小扫描范围。

### Q6: 标签记录法和延迟关联法解决深分页的原理？
**答**：标签记录法：用自增 ID 作为游标（WHERE id > last_id LIMIT n），始终走主键索引等值查询。延迟关联法：子查询只取主键 ID + LIMIT（覆盖索引，无回表），再 JOIN 原表取完整行数据。两者都避免了 OFFSET 的无效行扫描。

### Q7: 统计信息不准导致选错索引怎么修复？
**答**：① `ANALYZE TABLE` 重新采样统计信息；② 调大 `innodb_stats_persistent_sample_pages`（默认 20，可增至 200）；③ 设置 `innodb_stats_auto_recalc=ON`；④ 极端情况用 FORCE INDEX 临时修复。

### Q8: 函数索引能解决索引列上使用函数的问题吗？
**答**：能。MySQL 8.0+ 支持函数索引（Functional Index），如 `CREATE INDEX idx ON t((DATE(create_time)))`，对 `WHERE DATE(create_time)='2024-01-01'` 可走索引。本质是为函数计算结果额外建了一棵 B+树。

### 面试陷阱

1. **「索引失效一定是 bug」** → 不是！索引失效是优化器基于 cost 模型的选择，只是统计信息偏差或 SQL 写法不当导致选择了更差的方案。
2. **「!= 一定不走索引」** → 不一定！MySQL 5.6+ 的 ICP 可能让 != 走索引（用索引过滤 + 回表验证）。关键看优化器 cost。
3. **「IS NULL 一定不走索引」** → 错！InnoDB 对 NULL 也有索引项，WHERE col IS NULL 通常可以走 ref 类型的索引。
4. **「只要 key 列有值就是走了索引」** → 错！Extra 出现 Using index condition 才是 ICP 走索引，key 列有值但 type 是 index 表示全索引扫描（相当于索引版全表扫描）。
5. **「覆盖索引可以解决一切回表问题」** → 覆盖索引确能消除回表，但索引的维护成本（INSERT/UPDATE 时更新所有索引页）同样存在，不是列越多越好。

### 一句话答案速记表

| 关键词 | 一句话答案 |
|-------|-----------|
| 最左前缀 | 联合索引按列序建B+树，查后列不单独走索引 |
| 隐式转换 | 字符串→DOUBLE CAST，索引废 |
| OR 失效 | index merge cost 可能高于全表扫描 |
| LIKE %前缀 | 无法确定 B+树扫描范围 |
| 索引列函数 | 索引存原始值，函数后无法匹配；8.0+用函数索引解决 |
| 深分页 | 延迟关联（子查询ID+JOIN）或游标法 |
| 统计信息 | ANALYZE TABLE 重采样，调大 sample_pages |
| 函数索引 | MySQL 8.0，为函数值单独建 B+树 |

## 附录（图片归档）

### 索引失效场景总览

![](../资源/图片/yuque_ca2d5cdbf9f7.jpeg)

### 内置函数导致索引失效

![](../资源/图片/yuque_bd59588179c3.webp)

### 函数移到右边的修复

![](../资源/图片/yuque_0ebb808ca922.webp)

### 深分页回表示意

![](../资源/图片/yuque_2161e05d73eb.webp)

### 参考链接

- [MySQL 索引失效场景总结 - JavaGuide](https://javaguide.cn/database/mysql/mysql-index-invalidation.html)
- [MySQL 联合索引最左前缀 - 知乎](https://www.zhihu.com/question/549956786/answer/3568495995)
- [MySQL 深分页优化 - 掘金](https://juejin.cn/post/7103315065352552456)
