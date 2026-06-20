---
title: std__sort
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "基础知识", "实践与杂项"]
publish: true
---

# std::sort

## `std::sort` 的内部实现

![](../../资源/图片/yuque_efcf740eff02.png)

![](../../资源/图片/yuque_2e2f28e5dcac.png)

C++ 标准库的 `std::sort` **通常基于** **IntroSort（混合排序算法）**，它结合了：

1. **快速排序（QuickSort）** —— **当递归深度较小**时，使用快速排序（O(n log n)）。
2. **堆排序（HeapSort）** —— **当递归深度超过阈值**（~2 \* log(n)）时，改用堆排序（O(n log n)）。
3. **插入排序（InsertionSort）** —— **当数据量较小时（如 n ≤ 16）**，使用插入排序（O(n²)）。

**IntroSort 结合了三种排序的优点**：

* **快速排序** 通常最快，但最坏情况（已排序数据）可能变成 O(n²)。
* **堆排序** 保证最坏情况下 O(n log n)。
* **插入排序** 适用于小数组，减少递归开销。

#### （1）QuickSort（快速排序）

* 选择 **“三数中值”（Median of Three）** 作为基准值（pivot）。
* 使用 **Hoare Partition** 或 **Lomuto Partition** 进行分区。

```
void quickSort(int arr[], int low, int high) {
    if (low < high) {
        int pivot = partition(arr, low, high);
        quickSort(arr, low, pivot - 1);
        quickSort(arr, pivot + 1, high);
    }
}
```

#### 2）HeapSort（堆排序）

* 用 **最大堆** 保证最坏情况下 O(n log n)。

```
void heapSort(int arr[], int n) {
    std::make_heap(arr, arr + n);
    std::sort_heap(arr, arr + n);
}
```

#### 3）InsertionSort（插入排序）

* 当 **子数组长度 ≤ 16** 时，使用插入排序。

```
void insertionSort(int arr[], int n) {
    for (int i = 1; i < n; i++) {
        int key = arr[i];
        int j = i - 1;
        while (j >= 0 && arr[j] > key) {
            arr[j + 1] = arr[j];
            j--;
        }
        arr[j + 1] = key;
    }
}
```

### `std::sort` 时间复杂度

|  |  |  |  |
| --- | --- | --- | --- |
| **排序算法** | **最优情况** | **平均情况** | **最坏情况** |
| 快速排序 | O(n log n) | O(n log n) | O(n²) |
| 堆排序 | O(n log n) | O(n log n) | O(n log n) |
| 插入排序 | O(n) | O(n²) | O(n²) |

* `std::sort`**保证 O(n log n) 的最坏情况时间复杂度**（由于 IntroSort）。
* **比** `qsort()` **更快**（因为 `std::sort` 可以内联，避免 `qsort()` 的函数指针调用开销）。

### std::sort `vs` std::stable\_sort

|  |  |  |  |
| --- | --- | --- | --- |
| **函数** | **稳定性** | **时间复杂度** | **适用情况** |
| `std::sort` | ❌ 不稳定 | O(n log n) | 一般情况，最快 |
| `std::stable_sort` | ✅ 稳定 | O(n log² n) | 需要保留相同元素顺序 |

* `std::sort`**不保证相等元素的相对顺序**。
* `std::stable_sort` **使用归并排序，保证稳定性**。

### 总结

1. `std::sort`**是 C++ 的标准排序函数**，基于 **IntroSort（快速排序 + 堆排序 + 插入排序）**。
2. **时间复杂度 O(n log n)**，比 `qsort()` **更快**，因为 **支持内联**。
3. **默认升序排序**，可 **使用自定义比较函数** 进行 **降序或其他排序方式**。
4. **适用于随机访问迭代器（如** `vector`**,** `array`**），但不能用于** `list`**（用** `list::sort`**）。**

![](../../资源/图片/yuque_0d65fdf4013e.png)

![](../../资源/图片/yuque_65c12b96d0b6.png)

## 一、核心概念

- **定义**：`std::sort` 是 C++ 标准库通用排序函数，基于 **IntroSort（内省排序）** 混合算法，保证 O(n log n) 最坏时间复杂度
- **关键词**：IntroSort、三数取中（Median of Three）、递归深度限制、严格弱序（Strict Weak Ordering）、内联比较器
- **适用场景/边界**：适用于随机访问迭代器容器（`vector`、`array`、`deque`）；不适用于 `list`（用 `list::sort`）、关联容器（`map`/`set` 已有序）、无序容器；比较器必须满足严格弱序

## 二、详细解析（≥200字）

- **原理拆解（三层递进）**：
  - **第一层——混合策略**：IntroSort 不是单一算法，而是根据输入规模和递归深度动态切换三种排序算法的自适应框架
  - **第二层——三阶段工作流**：① 快速排序阶段：以三数取中选 pivot、Hoare 分区，递归深度在 `2*log₂(n)` 以内；② 堆排序兜底：当递归深度超限时切换到堆排序，保证 O(n log n)；③ 插入排序收尾：当子数组长度 ≤ 16 时改用插入排序
  - **第三层——底层机制**：三数取中防最坏分区（已排序/逆序）；`__unguarded_partition` 不检查边界以提升性能；插入排序对近似有序数据接近 O(n)，且无递归开销、指令缓存友好
- **关键数据结构/接口**：`_S_threshold = 16`（插入排序阈值），递归深度限制 `__lg(n) * 2`
- **关键公式/复杂度**：平均 O(n log n)，最坏 O(n log n)（由堆排序保证）。额外空间 O(log n)（递归栈）。比较次数 ≈ `1.38 n log n`（快排期望）

## 三、动手实践（代码案例）

```c++
#include <algorithm>
#include <vector>
#include <iostream>

int main() {
    // 1. 基础升序排序
    std::vector<int> v = {5, 2, 8, 1, 9, 3};
    std::sort(v.begin(), v.end());
    // v = {1, 2, 3, 5, 8, 9}

    // 2. 自定义降序比较器（lambda）
    std::sort(v.begin(), v.end(), [](int a, int b) { return a > b; });
    // v = {9, 8, 5, 3, 2, 1}

    // 3. 对结构体排序（按年龄降序，同名按名升序）
    struct Person { std::string name; int age; };
    std::vector<Person> people = {{"Alice", 30}, {"Bob", 25}, {"Charlie", 30}};
    std::sort(people.begin(), people.end(),
        [](const Person& a, const Person& b) {
            return std::tie(b.age, a.name) < std::tie(a.age, b.name);
        });

    // 4. 部分排序：只关心前 k 小
    std::partial_sort(v.begin(), v.begin() + 3, v.end());  // 前3个有序，其余任意

    return 0;
}
```

- **预期**：`std::sort` 对 int、string、自定义类型均可正确排序
- **补充**：`std::nth_element` 找第 k 小只需 O(n)，比完全排序更高效

## 四、进阶应用（≥500字）

- **与其他主题的关联**：与算法复杂度分析、迭代器设计、比较器语义强相关；`std::partial_sort`、`std::nth_element`、`std::inplace_merge` 构成排序系列工具链
- **工程中的真实用法**：
  - **稳定排序需求**：当等值元素顺序有语义含义（如先到先服务）时，用 `std::stable_sort`（归并排序）
  - **TopK 场景**：只需前 k 个元素有序时，`std::partial_sort` 比 `std::sort` 快（O(n log k) vs O(n log n)）；`std::nth_element` 更快（O(n)）
  - **比较器设计**：推荐 lambda 或函数对象（可内联），避免函数指针（间接跳转开销）。比较器必须满足**严格弱序**：`comp(a,b) ⇒ !comp(b,a)`, `comp(a,b) && comp(b,c) ⇒ comp(a,c)`
  - **性能陷阱**：比较器中避免动态内存分配、虚函数调用或 IO，这些都严重拖慢排序速度
- **常见优化策略**：
  - **算法层面**：已知数据近乎有序时优先插入排序；大量重复键时考虑三向切分快排（可用 `boost::sort::spreadsort`）
  - **数据结构**：用 `std::vector` 而非 `std::deque`——连续内存更利于 cache 和分支预测。预分配容量避免排序中重新分配
  - **内存访问**：比较器尽量按值比较，减少间接访问；对大对象排序可先构建索引数组排序避免移动大对象
  - **并发处理**：C++17 引入 `std::sort(std::execution::par, ...)` 并行排序，对 >1000 元素通常有 3-5x 加速；Intel TBB `parallel_sort` 性能更优
  - **具体技巧**：`std::sort` 比 C 的 `qsort` 快 2-3 倍（比较器完全内联）；对基本类型可尝试基数排序（O(n)）；小数据集直接用插入排序

## 五、源码解析和实践感悟

### 1. IntroSort 的三阶段骨架

```c++
// libstdc++ std::sort 核心结构
template<typename _RandomAccessIterator, typename _Compare>
void sort(_RandomAccessIterator __first, _RandomAccessIterator __last, _Compare __comp) {
    if (__first == __last) return;
    // 阶段1：快速排序，递归深度限制为 2*log₂(n)
    std::__introsort_loop(__first, __last,
        std::__lg(__last - __first) * 2, __comp);
    // 阶段2：插入排序收尾（对接近有序的短序列高效）
    std::__final_insertion_sort(__first, __last, __comp);
}

template<typename _RandomAccessIterator, typename _Size, typename _Compare>
void __introsort_loop(_RandomAccessIterator __first, _RandomAccessIterator __last,
                      _Size __depth_limit, _Compare __comp) {
    while (__last - __first > int(_S_threshold)) {
        if (__depth_limit == 0) {
            // 递归深度超限 → 切换到堆排序，保证 O(n log n)
            std::__partial_sort(__first, __last, __last, __comp);
            return;
        }
        --__depth_limit;
        auto __cut = std::__unguarded_partition_pivot(__first, __last, __comp);
        std::__introsort_loop(__cut, __last, __depth_limit, __comp);
        __last = __cut;
    }
}
```

### 2. 三数取中选 pivot

```c++
// 取 first, mid, last 的中位数作为 pivot，对抗已排序数据的退化
auto __mid = __first + (__last - __first) / 2;
// 三次比较确定中位数位置
if (__comp(*__first, *__mid)) {         // first < mid
    if (__comp(*__mid, *__last))        // first < mid < last → pivot=mid
        return __mid;
    else if (__comp(*__first, *__last)) // first < last ≤ mid → pivot=last
        return __last;
    else                                // last ≤ first < mid → pivot=first
        return __first;
}
// ...对称处理
```

### 3. 插入排序对小规模数据的优势

```c++
constexpr int _S_threshold = 16;  // 小于16个元素不做快速排序

// 小数组插入排序：cache 友好，无递归开销
for (auto __i = __first + 1; __i != __last; ++__i) {
    if (__comp(*__i, *__first)) {
        auto __val = _GLIBCXX_MOVE(*__i);
        std::move_backward(__first, __i, __i + 1);  // 整体后移
        *__first = _GLIBCXX_MOVE(__val);
    }
    // ...
}
```

### 实践经验

1. **递归深度限制**：`2*log₂(n)` 是堆排序的触发线，防止 QuickSort 退化为 O(n²)
2. **插入排序收尾**：经过 IntroSort 后数据已近似有序，插入排序在近似有序数据上接近 O(n)
3. **分支预测友好**：三数取中减少了最坏分区的概率，让 CPU 分支预测更准确
4. **qsort 对比**：C 的 qsort 通过函数指针回调比较，无法内联；sort 的比较器是模板参数，完全内联
5. **不稳定排序的代价**：sort 不保证稳定，换来更高的整体性能；需要稳定用 stable_sort（归并，O(n log² n)）
6. **非随机访问容器**：list 不能直接用 sort，需用 list::sort（链表归并，O(n log n)）

## 六、面试准备

### Q&A（10题）

**Q1: std::sort 的实现是什么？**
A: IntroSort = 快排 + 堆排 + 插入排序。递归深 ≤ 2log₂n 时快排，超限切堆排，子数组 ≤16 用插入排序

**Q2: 为什么需要堆排序兜底？**
A: 快排对已排序/逆序数据退化为 O(n²)，堆排序保证最坏 O(n log n)

**Q3: 三数取中的目的是什么？**
A: 选择合理的 pivot 避免最坏分区，将退化概率降到极低

**Q4: 为什么小数组用插入排序？**
A: 插入排序对短数组常数因子小、无递归开销、cache 局部性好。16 是经验阈值

**Q5: std::sort 比 qsort 快的原因？**
A: sort 的比较器是模板参数可内联；qsort 通过函数指针调用，每次比较都有间接跳转开销

**Q6: std::sort 稳定吗？**
A: 不保证稳定。等值元素的相对顺序可能改变。需要稳定用 std::stable_sort

**Q7: stable_sort 的实现和复杂度？**
A: 归并排序，O(n log n) 有额外内存时为 O(n log n)，内存不足退化为 O(n log² n)

**Q8: 哪些容器不能用 std::sort？**
A: 无随机访问迭代器的：list（用 list::sort）、forward_list、关联容器（map/set 已排序）、unordered 容器

**Q9: 自定义比较器的要求？**
A: 必须满足严格弱序（strict weak ordering）：反自反、传递、等价传递。违反则 UB

**Q10: 递归深度限制公式为什么是 2log₂n？**
A: 每次分区期望减半，log₂n 次深度足够。2 倍是安全余量，保证几乎不会误切到堆排

### 陷阱与反问（5个）

1. **陷阱**：比较器不满足严格弱序（如 `a<=b` 而非 `a<b`）→ UB，可能导致越界
2. **反问**：全部改用堆排序不是更安全？→ 堆排序常数因子大、cache 不友好，实际比快排慢 2-3 倍
3. **陷阱**：排序包含重复键的大量数据 → 快排退化时三向切分更好
4. **反问**：partial_sort 和 sort 的区别？→ partial_sort 只保证前 k 个有序，内部用堆，适合 TopK
5. **陷阱**：迭代器失效 — sort 期间任何外部对容器的修改都是 UB

### 一句话答案（5个）

1. **sort 本质**：IntroSort，快排 + 堆排兜底 + 插入排序收尾
2. **复杂度**：平均/最坏均为 O(n log n)
3. **比 qsort 快**：比较器内联，无函数指针开销
4. **不稳定原因**：快排分区过程不保留等值元素相对顺序
5. **自定义比较器规则**：严格弱序，不可用 ≤ 替代 <
