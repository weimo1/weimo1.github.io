---
title: MySQL慢查询优化
date: 2026-06-20
categories:
  - ["项目学习", "数据库"]
publish: true
---

# MySQL 慢查询原因与优化

> 适用范围：MySQL 慢查询分析、索引失效场景、深分页优化、EXPLAIN 执行计划

## 一、项目/模块概述

- **模块定位**：MySQL 慢查询诊断是数据库性能优化的核心入口，涵盖索引失效分析、SQL 改写、深分页优化等。
- **技术栈与依赖**：MySQL slow_query_log、EXPLAIN、mysqldumpslow、InnoDB 存储引擎。
- **模块边界**：输入为慢查询日志，输出为优化后的 SQL 和索引方案。

## 二、架构设计

### 设计拆解

**慢查询优化思路（五步法）：**
1. 检查是否走了索引 → 没有则优化 SQL 利用索引
2. 检查所用索引是否最优 → 可能选错索引
3. 检查查询字段是否过多 → 查出多余数据
4. 检查数据量是否过大 → 考虑分库分表
5. 检查机器配置 → 是否资源不足

**慢查询日志配置：**
```
slow_query_log = ON
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 1  # 单位：秒
```

## 三、核心实现

### 3.1 索引失效的常见场景

**1. 隐式类型转换**
```sql
-- 索引失效：name 是 VARCHAR，但传了 INT
SELECT * FROM user WHERE name = 123;
```

**2. OR 条件部分无索引**
OR + 无索引列 → MySQL 优化器可能放弃索引，改为全表扫描。解决方案：拆成两条 SQL 或用 UNION。

**3. LIKE 以 % 开头**
```sql
-- 索引失效
SELECT * FROM user WHERE name LIKE '%abc';
-- 索引有效
SELECT * FROM user WHERE name LIKE 'abc%';
```

**4. 不满足最左前缀**
联合索引 `(a,b,c)`，`WHERE b=1` 不走索引。必须从最左列开始。

**5. 索引列使用函数/运算**
```sql
-- 索引失效：对索引列用 DATE_ADD()
SELECT * FROM user WHERE DATE_ADD(login_time, INTERVAL 1 DAY) = '2022-05-22';
-- 优化：函数移到右边
SELECT * FROM user WHERE login_time = DATE_ADD('2022-05-22', INTERVAL -1 DAY);
```

**6. 其他失效场景**
- `!=` / `<>` 可能导致索引失效
- `IS NULL` / `IS NOT NULL` 可能失效
- 关联字段编码格式不一致

### 3.2 limit 深分页问题

```sql
-- 慢：扫描 100010 行，扔掉前 100000 行
SELECT * FROM account WHERE create_time > '2020-09-19' LIMIT 100000, 10;
```

**优化方案 1：标签记录法**
```sql
-- 上次查到 id=100000，这次从这开始
SELECT * FROM account WHERE id > 100000 LIMIT 10;
```

**优化方案 2：延迟关联法**
```sql
-- 先用二级索引过滤出主键，再回表
SELECT t1.* FROM account t1
INNER JOIN (SELECT id FROM account WHERE create_time > '2020-09-19' LIMIT 100000, 10) t2
ON t1.id = t2.id;
```

### 3.3 EXPLAIN 执行计划解读

| 字段 | 含义 | 优化标准 |
|------|------|----------|
| type | 访问类型 | const > eq_ref > ref > range > index > ALL |
| key | 实际使用的索引 | 不应为 NULL |
| rows | 预计扫描行数 | 越少越好 |
| filtered | 返回行占比 | 越大越好（过滤越有效） |
| Extra | 额外信息 | Using filesort/temporary 需优化 |

## 四、工程实践

- **配置慢查询日志**：生产环境 long_query_time 设 1s，定期分析。
- **mysqldumpslow**：聚合分析慢日志，找出高频慢 SQL。
- **FORCE INDEX**：查询优化器选错索引时强制指定。
- **STRAIGHT_JOIN**：强制指定驱动表顺序。
- **70% 的慢 SQL 可通过加索引解决**，20% 是优化器选错索引。

## 五、源码解析和实践感悟

### 5.1 MySQL 优化器索引选择核心路径（源码级）

```cpp
// MySQL 8.0 sql/opt_range.cc — 索引范围扫描的成本估算
// check_quick_select() → 为每个可行索引计算 cost
struct QUICK_SELECT_I {  // 索引范围扫描的抽象
    uint used_key_parts;  // 使用到的索引前缀列数
    ha_rows records;      // 预估返回行数（基于索引统计信息）
    Cost_estimate cost;   // 执行成本（IO + CPU）
};

// best_access_path() — 在多个索引 plan 中选择成本最低的
void Optimize_table_order::best_access_path(
    JOIN_TAB *tab, const AccessPath *path, uint idx) {
    // 计算每种访问方式的 cost
    double scan_cost = record_count * ROW_EVALUATE_COST;  // 全表扫描成本
    double range_cost = quick->records * (INDEX_LOOKUP_COST + ROW_EVALUATE_COST);
    // 回表成本：二级索引查到主键后，需要回到聚簇索引取行数据
    if (!covering_index)
        range_cost += quick->records * CLUSTER_KEY_LOOKUP_COST;
    // 选择 cost 最小的
    if (range_cost < scan_cost)
        tab->set_quick(quick);  // 采用索引范围扫描
    else
        tab->set_table_scan();  // 走全表扫描
}
```

### 5.2 EXPLAIN 输出中 key_len 的计算

```sql
-- key_len 告诉你使用了联合索引的哪些列
-- 示例：idx_name_age_status(name, age, status)
EXPLAIN SELECT * FROM t WHERE name='abc' AND age>20 AND status=1;
-- key_len = name_len + age_len（status 未被使用，因为 age 是范围查询导致其后列失效）

-- 底层代码：field->key_length() 返回每列在索引中的字节长度
uint calc_key_len(KEY *key_info, key_part_map keypart_map) {
    uint len = 0;
    for (uint i = 0; i < key_info->user_defined_key_parts; i++) {
        if (keypart_map & (1 << i)) {
            Field *field = key_info->key_part[i].field;
            len += field->key_length();
            // VARCHAR: key_length = 字符数*字符集字节数 + 2(变长前缀)
            // INT: key_length = 4, BIGINT: 8, NULL 允许 +1
        }
    }
    return len;
}
```

### 5.3 FORCE INDEX 底层实现

```cpp
// MySQL 解析 FORCE INDEX 后设置表的忽略/强制索引标志
// sql/sql_select.cc — 优化器在选择索引时的处理
bool JOIN_TAB::use_quick(int quick_type) {
    TABLE *table = this->table;
    // 如果指定了 FORCE INDEX，忽略 table->keys_in_use_for_order_by 之外的索引
    if (table->force_index) {
        allowed_keys &= table->keys_in_use_for_query;
        // 仅考虑 hint 指定的索引
        if (hint_key_state(tab, index, OPTIMIZER_SWITCH_FORCE_INDEX, &thd->optimizer_switch_flag)) {
            best_key = index;
            best = min(best, index_scan_cost);
        }
    }
    // optimizer_search_depth：多表 JOIN 时搜索深度（默认 62，调低可减少优化时间）
    if (thd->variables.optimizer_search_depth < join->table_count)
        greedy_search = true;
}
```

### 实践感悟

1. **EXPLAIN 的 type 列是第一筛查指标**：ALL（全表扫描）必优化，index（全索引扫描）通常也需优化。出现 Using filesort / Using temporary 一定要看是否能用索引排序替代。
2. **rows 是统计估算值，非实际值**：rows 基于索引基数（cardinality）估算，可能不准（尤其数据分布不均时）。用 `ANALYZE TABLE` 更新统计信息后再看。
3. **优化器不一定选最优索引**：当多个索引 cost 接近时，可能选错。FORCE INDEX 是最后手段——先用 optimizer_trace 看为什么选错了，再决定加索引还是 hint。
4. **覆盖索引是最廉价的优化**：Extra 出现 Using index 表示覆盖索引（无需回表），性能最优。设计索引时优先考虑常用查询列的覆盖。
5. **索引下推（ICP）是 5.6 后的自动优化**：索引条件下推让存储引擎层先过滤，减少回表次数。EXPLAIN Extra 中的 Using index condition 说明 ICP 已生效。
6. **生产环境慎用 FORCE INDEX**：索引名变更或删除会导致 SQL 直接报错。更好的做法是确保统计信息准确，让优化器自适应选择。
7. **索引不是万能**：不是每个查询都需要索引，全表扫描在小表上可能更快。
8. **最左前缀是复合索引的核心约束**：设计复合索引时要把常用查询条件放前面。
9. **深分页是分页查询的陷阱**：OFFSET 越大越慢，标签记录法是最佳实践。
10. **EXPLAIN 是最好的老师**：每次改 SQL 后必看执行计划，type=ALL 一定要优化。

## 六、面试准备

### Q1: 一条慢 SQL 摆在面前，排查步骤是什么？
**答**：① `EXPLAIN` 看 type（是否为 ALL/index）、key（实际用哪个索引）、rows（预估扫描行数）；② 看 Extra 有无 Using filesort/Using temporary；③ `SHOW PROFILES` 看各阶段耗时；④ optimizer_trace 看优化器为什么选这个索引。

### Q2: type 从好到差怎么排序？
**答**：system > const > eq_ref > ref > range > index > ALL。const 通过主键/唯一键等值查单行；eq_ref 联表时走唯一索引；ref 非唯一索引等值查；range 索引范围扫描；ALL 全表扫描必须优化。

### Q3: 什么是覆盖索引？怎么判断用到了？
**答**：查询的所有列都在索引中（SELECT 列 + WHERE 条件列 + ORDER/GROUP 列），不需要回表。EXPLAIN Extra 列出现 Using index（且 type 非 ALL）即为覆盖索引。

### Q4: 为什么 LIKE '%xxx' 不走索引？
**答**：B+树索引按列值的**前缀顺序**组织，LIKE '%xxx' 无法确定前缀范围，优化器只能选择全表扫描。LIKE 'xxx%' 可以走索引范围扫描。

### Q5: 什么是索引下推（ICP）？
**答**：MySQL 5.6+ 特性。把 WHERE 条件中能用索引判断的部分下推到存储引擎层过滤，减少回表行数。EXPLAIN Extra 中显示 Using index condition。

### Q6: FORCE INDEX 有什么风险？
**答**：① 索引名变更导致语法错误；② 表数据分布变化后强制走的索引可能更慢；③ 掩盖了统计信息不准确的根本问题。优先用 ANALYZE TABLE + 优化统计信息。

### Q7: count(*) 和 count(1) 和 count(column) 哪个快？
**答**：InnoDB 下 count(*) = count(1)（优化器会优化为取最小二级索引计数），count(column) 不统计 NULL 行且可能走全表，通常 count(*) 最快。MyISAM 下 count(*) 有常量级优化（表行数已记录）。

### Q8: 分页越往后越慢怎么优化？
**答**：① 用基于索引的延迟关联（子查询只取主键 ID + limit，再 JOIN 原表）；② 用记录上次最大 ID 的游标方式（WHERE id > last_id LIMIT n）；③ 避免用 OFFSET，大数据量下 OFFSET 需扫描并丢弃大量行。

### Q9：MySQL 慢查询怎么排查？
**答**：开启 slow_query_log → mysqldumpslow 聚合 → EXPLAIN 分析 → 加索引/改 SQL。

### Q10：索引失效的常见原因？
**答**：隐式类型转换、OR 条件、like '%x'、函数/运算、不满足最左前缀、!= / IS NULL。

### Q11：如何强制 MySQL 使用指定索引？
**答**：`SELECT * FROM t FORCE INDEX(idx_name) WHERE ...`，但优先让优化器自己选择。

### Q12：如何优化 JOIN 查询？
**答**：小表驱动大表；关联字段加索引；用 STRAIGHT_JOIN 控制驱动表顺序；避免 SELECT *。

### 面试陷阱

1. **「加索引就一定快」** → 错！低区分度列（性别、状态码）加索引可能比全表扫描更慢（回表开销 > 直接扫描）。
2. **「EXPLAIN 的 rows 是准确值」** → 错！是统计估值，实际可能相差数量级。结合 `SHOW STATUS LIKE 'Handler_read%'` 看实际读写次数。
3. **「Using filesort 一定用磁盘文件」** → 不一定！sort_buffer_size 够大时在内存排序，只是没走索引排序。
4. **「联合索引顺序无所谓」** → 错！最左前缀原则要求高区分度+高频查询的列在前。
5. **「optimizer_trace 生产随便开」** → 慎用！追踪开关是 session 级，但会消耗内存并增加优化时间，排查完及时关闭。

### 一句话答案速记表

| 关键词 | 一句话答案 |
|-------|-----------|
| 慢SQL排查 | EXPLAIN→type/key/rows→Extra→profile→optimizer_trace |
| type 优先级 | system>const>eq_ref>ref>range>index>ALL |
| 覆盖索引 | SELECT列在索引中，无需回表，Extra=Using index |
| LIKE索引失效 | %开头无法确定前缀范围，B+树不生效 |
| ICP | 索引条件下推，存储引擎层预过滤，减少回表 |
| FORCE INDEX | 强制索引但有风险，优先 ANALYZE TABLE |
| count(*) vs count(1) | InnoDB下等价，取最小二级索引计数 |
| 深分页优化 | 延迟关联或游标(WHERE id>last_id)，避免 OFFSET |

### 反问点/陷阱点
- 为什么索引有时比全表扫描慢？什么情况下优化器会选择全表扫描？
- 如何评估一个索引是否值得添加？（区分度、读写比例）
- 分库分表后索引策略如何调整？
- 唯一索引和普通索引在 change buffer 上的差异？

## 附录（图片与参考）

### 图片归档

![](../资源/图片/yuque_50f23cbe6f7f.webp)

![](../资源/图片/yuque_ccb07df667e7.webp)

### 参考链接
- [mysql索引优化实战](https://www.cnblogs.com/randolf/p/19068922)
- [MySQL慢查询分析](https://juejin.cn/post/7103315065352552456)
- [MySQL 原生慢查询日志配置](https://dev.mysql.com/doc/refman/8.0/en/slow-query-log.html)
