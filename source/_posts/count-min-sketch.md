---
title: count min sketch
date: 2026-06-20
categories:
  - ["项目学习", "基础库与工具"]
publish: true
---

# Count-Min Sketch

> 适用范围：概率计数数据结构，大数据流频率估计，服务于缓存淘汰策略（TinyLFU），保持可复用、可检索。

## 写作约束（铁律）

- **原内容一字不删**：所有原有文字、代码、注释、图片必须全部保留，禁止删除任何原内容。
- **只做归纳重组+增加**：在原有内容基础上调整结构、归类，新增内容以"补充"标记。新增量须让最终篇幅 ≥ 原版。
- **放不进的进附录**：六大段模板容纳不下的原内容，移入最后的「附录」章节，不得丢弃。
- **动笔前先搜索**：做相关知识准备；源码要贴原始代码，有需要可贴汇编。
- **字数硬指标**：详细解析(二)≥200字、进阶应用(四)≥500字、源码解析与实践感悟(五)≥1000字、面试准备(六)高频问法≥8个且带回答，反问点和一句话答案各≥5个。
- 先结论后细节，避免长段堆砌。
- 每节至少 3 条要点。
- 代码必须可运行或可推导，配清楚输入/输出或预期。
- **代码块必须标注语言**：所有代码块必须根据实际语言标注，C++ 代码用 `c++`（不可用 `cpp` 或 `c`），Python 用 `python`，汇编用 `asm`/`x86asm`，shell 用 `bash` 等。禁止无语言标注的裸代码块。
- 图示统一放在 `资源/图片/`，文内使用相对路径引用。
- 有流程的用流程图或其他类型的图。

## 一、模块概述

- 模块定位：概率型数据结构，用亚线性空间（sub-linear space）估计数据流中每个元素的出现频率。核心服务于 TinyLFU 缓存淘汰策略，解决 LFU 方案中"每个 key 维护精确计数器导致内存爆炸"的问题。
- 技术栈：Go 语言实现，纯算法，无外部依赖。核心依赖多个独立 Hash 函数 + 二维计数器数组。
- 模块边界：输入→元素的 Hash 值（uint64），输出→该元素的估计频次（保证 `真实值 ≤ 估计值 ≤ 真实值 + ε*N`，误差单边偏大）。与 Bloom Filter 类似，都是"用空间换精度"的概率数据结构。

## 二、架构设计

- **设计拆解（三层递进）**：
  - 第一层：整体架构——CMS 由 `depth` 行 × `width` 列的二维计数器矩阵构成，每行对应一个独立 Hash 函数。元素到达时，分别用 `depth` 个 Hash 计算列位置，对应计数器 +1。查询时取所有行对应位置的最小值作为估计频次。
  - 第二层：关键流程——Increment(hashed)→对每行 `i`，用 `(hashed ^ seed[i]) & mask` 计算列位置，调用 `cmRow.increment()`。Estimate(hashed)→同样计算列位置，对每行调用 `cmRow.get()` 取计数值，返回所有行的最小值。Reset→所有计数器减半（保鲜机制），让老数据随时间衰减。
  - 第三层：关键设计决策与权衡——为什么取 min 而非 avg？因为 Hash 冲突只会使计数偏大（假阳性），取 min 可以最小化高估误差。`depth=4`（原文设置）意味着用 4 个独立 Hash 函数，误差概率 ≈ `(1/2)^4` 级别。`width` 越大误差越小但内存越大，典型场景根据期望误差率 `ε` 和置信度 `δ` 计算：`width = ⌈e/ε⌉`，`depth = ⌈ln(1/δ)⌉`。

- 关键数据结构：`cmRow`（每个 uint8 压缩存储2个4-bit计数器，节省空间），`cmSketch`（depth 行 × width/2 列 uint8 + depth 个随机种子）。
- 生命周期管理：`newCmSketch(numCounters)` → 正常运行（Increment/Estimate）→ Reset（计数器减半）或 Clear（清空）。Reset 不是一次性清空，而是减半，实现"时间衰减"效果。

## 三、核心实现

### 3.1 计数器行（cmRow）

每个 byte 存两个 4-bit 计数器（最大计数值 15），用位操作定位和更新。

```go
type cmRow []byte // byte = uint8 = 0000,0000 = COUNTER 4BIT = 2 counter

// 64 counter
// 1 uint8 = 2 counter
// 32 uint8 = 64 counter
func newCmRow(numCounters int64) cmRow {
    return make(cmRow, numCounters/2)
}

func (r cmRow) get(n uint64) byte {
    return byte(r[n/2]>>((n&1)*4)) & 0x0f
}

func (r cmRow) increment(n uint64) {
    // 定位到第i个Counter
    i := n / 2 // r[i]
    // 右移距离，偶数为0，奇数为4
    s := (n & 1) * 4
    // 取前4Bit还是后4Bit
    v := (r[i] >> s) & 0x0f // 0000, 1111
    // 没有超出最大计数时，计数+1
    if v < 15 {
        r[i] += 1 << s
    }
}

// 保鲜：所有计数器减半
func (r cmRow) reset() {
    for i := range r {
        r[i] = (r[i] >> 1) & 0x77 // 0111,0111
    }
}

func (r cmRow) clear() {
    for i := range r {
        r[i] = 0
    }
}
```

> 解读：`get(n)` 用 `n/2` 定位 byte，`(n&1)*4` 决定取高4位还是低4位。`increment(n)` 同理定位后检查是否 <15（防溢出），再用 `1 << s` 对目标半位 +1。`reset()` 中 `0x77 = 01110111` 掩码保证每个半字节独立右移后高位归零。

### 3.2 向上取2的幂（next2Power）

```go
// 快速计算最接近x的二次幂的算法
// 比如x=5，返回8
// x = 110，返回128

func next2Power(x int64) int64 {
    x--
    x |= x >> 1
    x |= x >> 2
    x |= x >> 4
    x |= x >> 8
    x |= x >> 16
    x |= x >> 32
    x++
    return x
}
```

> 经典位运算技巧：将最高位1后面的所有位都置1，然后+1。如 `x=5 (101)→x--=4 (100)→111→1000=8`。这里用 CMS 的 width 必须是2的幂，方便用 `& mask` 替代 `% width`。

### 3.3 CMS 主体

```go
const cmDepth = 4

type cmSketch struct {
    rows [cmDepth]cmRow
    seed [cmDepth]uint64
    mask uint64
}

func newCmSketch(numCounters int64) *cmSketch {
    if numCounters == 0 {
        panic("cmSketch: bad numCounters")
    }

    numCounters = next2Power(numCounters)
    sketch := &cmSketch{mask: uint64(numCounters - 1)}
    source := rand.New(rand.NewSource(time.Now().UnixNano()))

    for i := 0; i < cmDepth; i++ {
        sketch.seed[i] = source.Uint64()
        sketch.rows[i] = newCmRow(numCounters)
    }
    return sketch
}

func (s *cmSketch) Increment(hashed uint64) {
    for i := range s.rows {
        s.rows[i].increment((hashed ^ s.seed[i]) & s.mask)
    }
}

// 找到最小的计数值
func (s *cmSketch) Estimate(hashed uint64) int64 {
    min := byte(255)
    for i := range s.rows {
        val := s.rows[i].get((hashed ^ s.seed[i]) & s.mask)
        if val < min {
            min = val
        }
    }
    return int64(min)
}

// 保鲜机制：所有计数器减半
func (s *cmSketch) Reset() {
    for _, r := range s.rows {
        r.reset()
    }
}

func (s *cmSketch) Clear() {
    for _, r := range s.rows {
        r.clear()
    }
}
```

> 解读：`mask = numCounters - 1`，因为 `numCounters` 是2的幂，`& mask` 等价于 `% numCounters` 但更快。每行用独立 `seed[i]` 与 hashed 异或后取模，保证多行之间的 Hash 位置不相关（避免所有行同时冲突）。`Estimate` 取所有行的最小值——这是 CMS 的核心 trick。

## 四、工程实践

- 与项目中其他模块的集成方式：CMS 在缓存系统中作为 TinyLFU 的频率统计组件。TinyLFU 用 CMS 记录每个 key 的访问频率，配合 LRU 做主缓存，形成 W-TinyLFU（Window-TinyLFU）策略——这是 Caffeine（Java高性能缓存库）的核心算法。
- 生产环境考量：
  - 错误处理与容错策略：4-bit 计数器上限15，`increment` 中 `if v < 15` 防溢出。对于极热 key 不会无限增长——这恰好符合"保鲜"需求，因为真正需要淘汰策略介入的场景是区分相对热度。
  - 资源管理：`numCounters` 决定内存占用。如 `numCounters=1024`，4行×512 bytes=2KB，可统计任意数量 key 的频率。与存 Map[key]count 对比：后者随 key 数量增长无上限，CMS 恒定占用。
  - 监控与日志：可暴露 CMS 的 fill rate（所有计数器平均值 / 15），如果长期接近饱和说明需要调大 width 或缩短 Reset 周期。
- 常见优化策略：
  - 计数器位宽选择：4-bit 最大15——为什么不是8-bit？因为 CMS 靠 Reset（减半）来衰减，高频 key 很快触及15后不再增长，低频 key 经过几次 Reset 归零自动淘汰。15 在缓存场景够用。如果需要更大计数，可扩展到8-bit（牺牲一半容量）。
  - Hash 函数优化：原实现每次 `hashed ^ seed[i]` 只用一个源 Hash + 不同 seed 异或，而非真正独立 Hash 函数。这在统计上近似独立，足够工程使用。如果要求理论保证，应使用独立 Hash 族（如 `h_i(x) = (a_i * x + b_i) mod p`）。
  - 保鲜 Reset：减半而非清空——这实现了指数衰减。经过 k 次 Reset，原计数 ≈ `count / 2^k`。这使得最近访问的数据权重更高。

## 五、源码解析和实践感悟

- 关键实现路径：核心路径极短——`Increment` 就是 d 次 `cmRow.increment`，`Estimate` 就是 d 次 `cmRow.get` 取 min。复杂度 O(d)，d=4 时几乎常数时间。真正精巧的是 `cmRow` 的位操作：一个 byte 存两个4-bit counter，用 `n/2` 和 `(n&1)*4` 定位，比用 `[]uint8` 每个 counter 占一个 byte 省一半内存。

- 难点与易错点：
  1. **位操作优先级**：`r[i] >> ((n&1)*4) & 0x0f` 中 `>>` 优先级高于 `&`，如果不加括号写成 `r[i] >> (n&1)*4 & 0x0f` 会在 `(n&1)*4` 之后先做 `& 0x0f`。这里原代码的括号是正确的。
  2. **`& 0x77` reset 掩码**：`0x77 = 0111 0111`。减半操作 `r[i] >> 1` 会把每个半字节高位清零（因为原来最高位是0），但需要再 `& 0x77` 确保相邻半字节不受影响。如果写成 `& 0x0F` 会错误清零高半字节。
  3. **mask = numCounters - 1**：依赖 numCounters 是2的幂。如果传入的 `numCounters` 没经过 `next2Power`，`& mask` 不等于取模，会导致越界。构造函数中 `numCounters = next2Power(numCounters)` 保证了这一点。
  4. **种子随机化**：`source.Uint64()` 用 `time.Now().UnixNano()` 作为种子。单实例没问题，但多实例快速连续创建可能种子相同（纳秒级相同）。生产环境可用 `crypto/rand` 或全局递增计数器。
  5. **Estimate 的 min 初始值**：`min := byte(255)`，而 `byte` 最大255，计数器最大15。初始化为255保证第一次比较一定更新。如果改为8-bit计数器（最大255），这里需要改为更大的初始值或 bool 标记。

- 经验总结（补充）：
  - **CMS vs 精确计数**：CMS 的内存占用是固定的 O(d×w)，与 key 数量无关。100万个 key 和 10个 key 占用相同内存。代价是查询结果偏大（但不会偏小）。适用场景：只需要"哪些 key 足够热"而非精确计数。
  - **与 Bloom Filter 的关系**：两者都用多个 Hash + 共享数组，但 BF 存"是否存在"（1 bit），CMS 存"出现几次"（4 bits/counter）。CMS 可以看作 Bloom Filter 的计数扩展版。
  - **TinyLFU 的局限**：CMS 应对突发稀疏流量表现不佳——这些流量的访问频次不足以在 CMS 中积累足够计数，很快被 Reset 衰减淘汰。Caffeine 的 W-TinyLFU 通过增加一个小的 Window-LRU 在前端吸收突发流量来解决。

TinyLFU解决了LFU统计的内存消耗问题，和缓存保鲜的问题，但是TinyLFU是否还有缺点呢？

有，论文中是这么描述的，根据实测TinyLFU应对突发的稀疏流量时表现不佳。大概思考一下也可以得知，这些稀疏流量的访问频次不足以让他们在LFU缓存中占据位置，很快就又被淘汰了。

我们回顾之前讲过的，LRU对于稀疏流量效果很好，那可以不可以把LRU和LFU结合一下呢？就出现了下面这种缓存策略。

## 六、面试准备

### 6.1 高频问法（≥10个）

Q1：Count-Min Sketch 是什么，解决什么问题？

A：概率型数据结构，用固定大小的二维计数器矩阵估计数据流中元素的频率。解决"海量 key 无法为每个维护精确计数器"的问题，空间复杂度 O(d×w)，与 key 数量无关。

Q2：为什么查询时取 min 而不是 avg？

A：Hash 冲突只会让计数偏大（多个 key 映射到同一位置），取 min 可以最小化高估误差。这是 CMS 的核心设计——保证"真实值 ≤ 估计值"，误差单边向上。

Q3：depth=4 和 width 如何选择？

A：depth 控制置信度（误差概率），width 控制误差大小。公式：`width = ⌈e/ε⌉`, `depth = ⌈ln(1/δ)⌉`。depth=4 时误差概率 ≈ (1/2)^4 = 6.25%。width 根据期望误差率 ε 和总计数 N 估算。

Q4：4-bit 计数器最大15，遇到极热 key 怎么办？

A：达到15后不再递增——这恰好配合 Reset 机制。经过几次 Reset 后计数衰减，热 key 会维持在较高的相对值。如果真的需要更大范围，可扩展到 8-bit（内存翻倍）。

Q5：Reset（减半）和 Clear（清零）有什么区别，为什么用减半？

A：Clear 是一次性清零，丢失所有历史信息。Reset 减半实现指数衰减，最近访问的数据保留更高权重，历史数据自然衰减。这是"保鲜"机制的核心。

Q6：CMS 和 Bloom Filter 有什么关系？

A：都是概率数据结构，都用多 Hash + 共享数组。BF 存 0/1（是否存在），CMS 存计数（出现几次）。CMS 可视为 BF 的计数扩展版（Counting Bloom Filter 是另一种扩展，差别在于 BF 支持删除）。

Q7：为什么 numCounters 必须是 2 的幂？

A：`& mask`（mask = numCounters - 1）等价于 `% numCounters`，但位运算更快。2的幂保证 mask 是连续的全1二进制，`& mask` 才等于取模。

Q8：`hashed ^ seed[i]` 为什么能实现"独立 Hash"？

A：严格说不独立，但工程上足够：用一个真实 Hash 值异或不同的随机 seed，得到的值在统计上分布均匀且不相关。如果需要理论保证，应使用独立 Hash 族（如 `h_i(x) = (a_i*x + b_i) mod p`）。

Q9：CMS 在 TinyLFU/缓存淘汰中扮演什么角色？

A：CMS 是 TinyLFU 的频率统计引擎。当缓存满需要淘汰时，TinyLFU 查询 CMS 比较候选 victim 和新 item 的频率，保留频率更高的。CMS 的 Reset 则保证频率有时效性。

Q10：CMS 的误差有多大？

A：以概率 1-δ 保证：估计值 ≤ 真实值 + ε*N（N 为所有元素计数之和）。如 depth=10, width=2000，ε=0.1%, 置信度 99.9%。误差单边向上，不会低估。

### 6.2 反问点/陷阱点（≥5个）

- 在你们系统中，CMS 的 width 和 depth 是怎么调的？有没有根据 traffic pattern 动态调整？
- TinyLFU 之外还评估过其他频率估计算法吗（如 Count Sketch, Lossy Counting）？
- CMS 的计数器位宽在你们的场景下够用吗？有没有因为计数器饱和导致的精度问题？

陷阱问题：
- 陷阱1：`& mask` 取模的前提是什么？答：numCounters 是2的幂。
- 陷阱2：reset 中 `& 0x77` 如果写成 `& 0x0F` 会怎样？答：高半字节被清零，丢失一半计数器的数据。
- 陷阱3：Estimate 的 min 初始值为什么是 255？答：byte 最大值255 确保第一次比较必定更新。计数器实际最大15，远小于255。

### 6.3 一句话答案（≥5个）

- CMS 的核心是：d 行 × w 列计数器 + d 个 Hash，存 min 值。空间固定 O(dw)，误差单边向上。
- `& mask` 等于取模的前提是 numCounters 是2的幂。
- Reset 减半而非清空，实现计数指数衰减，保留最近数据的权重。
- CMS 和 Bloom Filter 同源：多 Hash + 共享数组，CMS 存计数，BF 存存在性。
- TinyLFU 用 CMS 估计频率 + LRU 兜底突发流量 = W-TinyLFU。
- 一个 uint8 存两个4-bit counter，比 naive `[]uint8` 省一半内存。

## 附录（模板外原内容收纳）

> 以下为原笔记中不直接适配六大段结构、但仍有价值的内容，原样保留于此。

Count-min Sketch算法是一个可以用来计数的算法，在数据大小非常大时，一种高效的计数算法，通过牺牲准确性提高的效率。

- 是一个概率数据机构
- 算法效率高
- 提供计数上线

我们给要计数的值计算一个Hash，然后在位图中给这个Hash值对应的位置累加1就可以了，但是BloomFilter中的一个典型问题是假阳性，可以说只要是用Hash计算就有存在冲突的可能，那么cmSketch计数法如果出现冲突会怎么样呢？会给同一个位置多计算访问次数。这里cmSketch选择了以最小的统计数据值作为结果。这是一个不那么精确地统计方法，但是可以大致的反应访问分布的规律。

因为这个算法也就有了一个名字，叫做Count-Min Sketch

下面我们来手撕这个算法。

如果我们要给n个数据计数，那么每4Bit当做一个计数器Counter，我们一共需要几个uint8来计数呢？答案是n/2
