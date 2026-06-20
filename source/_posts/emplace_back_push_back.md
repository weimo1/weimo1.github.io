---
title: emplace_back_push_back
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "现代C++特性"]
publish: true
---

# emplace_back vs push_back

> 适用范围：C++ 容器操作——`emplace_back` 与 `push_back` 的区别、vector 扩容机制。

参考：<https://www.zhihu.com/question/387522517>、[STL之vector扩容机制](https://zhuanlan.zhihu.com/p/554384316)

## 一、核心概念

- **定义**：`push_back` 接受已构造的对象（拷贝/移动）添加到容器末尾；`emplace_back` 接受构造对象所需的参数列表，直接在容器内存中原地构造对象，避免临时对象的创建。
- **关键词**：`emplace_back`、`push_back`、原地构造、完美转发、vector 扩容、`realloc_insert`、`std::uninitialized_move`
- **适用场景/边界**：
  - `emplace_back`：构造开销大的对象、不可移动/不可拷贝类型、需要原地构造
  - `push_back`：对象已存在、需要隐式转换、代码可读性优先

## 二、详细解析（≥200字）

### 核心区别

| 特性 | `push_back` | `emplace_back` |
| --- | --- | --- |
| **参数类型** | 接受一个已构造的**对象**或**右值引用** | 接受构造对象所需的**参数列表** |
| **底层行为** | 拷贝或移动传入对象到容器 | 直接在容器内存中**构造对象**（避免临时对象） |
| **性能开销** | 可能触发拷贝/移动操作 | 通常更高效（减少临时对象生成） |
| **C++版本支持** | C++98 起支持 | C++11 起支持 |

### 原理拆解（三层递进）

**第一层：基本工作原理**

`push_back` 需要预先构造的对象，`emplace_back` 在容器内构造对象。主要区别：
1. **构造方式**：push_back 需要预先构造的对象，emplace_back 在容器内构造对象
2. **参数传递**：push_back 接受对象，emplace_back 接受构造函数参数
3. **效率**：emplace_back 可能避免不必要的临时对象创建和复制/移动操作
4. **灵活性**：emplace_back 可直接传递构造函数参数
5. **编译复杂度**：emplace_back 作为变参模板可能增加编译时间和内存使用

**第二层：关键步骤详解**

`push_back` 路径：`const char*` → 隐式构造 `string` 临时对象 → 移动进容器 → 析构临时对象。`emplace_back` 路径：`const char*` → 直接在容器内存中调用 `string(const char*)` 构造。显然 `emplace_back` 少了一次移动+一次析构。

**第三层：底层机制**

`emplace_back` 依赖完美转发，需确保参数类型与容器元素的构造函数匹配。`push_back` 可能触发隐式转换，而 `emplace_back` 需要显式传递参数。

- **关键数据结构**：`std::forward<_Args>(__args)...` 变参转发
- **关键公式**：`emplace_back` = 完美转发 + placement new；`push_back` = 构造临时对象 + 移动/拷贝

### 注意事项

1. **参数完美转发**：`emplace_back` 依赖完美转发，需确保参数类型与容器元素的构造函数匹配
2. **隐式转换陷阱**：`push_back` 可能触发隐式转换，而 `emplace_back` 需要显式传递参数
3. **异常安全**：`emplace_back` 在构造过程中抛出异常时，容器状态不变；`push_back` 在拷贝/移动时抛出异常可能导致部分修改
4. **可读性**：简单场景下，`push_back` 的意图更直观

## 三、动手实践（代码案例）

### 3.1 基本用法对比

```c++
std::vector<std::string> vec;
vec.push_back("hello");   // 隐式转换为 string
vec.emplace_back("hello"); // 直接构造 string
```

### 3.2 错误示例：参数不匹配

```c++
// 错误示例：参数不匹配
vec.emplace_back();  // 若元素类型无默认构造函数，编译失败
```

### 3.3 vector 扩容的内存布局变化

```c++
// 扩容前后的内存状态
void visualize_reallocation() {
    /*
    扩容前状态：
    [旧内存区域] data_ -> [obj1][obj2][obj3][unused][unused]
                         size_=3, capacity_=5
    
    扩容过程：
    1. 分配新内存：[新内存区域] new_data -> [][][][][][][][][] (capacity=10)
    2. 移动/复制数据：new_data -> [obj1][obj2][obj3][][][][][][][] 
    3. 销毁旧对象：[旧内存区域] -> [~~~~][~~~~][~~~~][unused][unused]
    4. 释放旧内存：[旧内存区域] -> 完全释放
    5. 更新指针：data_ = new_data
    
    扩容后状态：
    [新内存区域] data_ -> [obj1][obj2][obj3][][][][][][][]
                         size_=3, capacity_=10
    */
}
```

### 3.4 关键的类型萃取机制

```c++
// 编译期类型检查
if constexpr (std::is_trivially_copyable_v<T> && 
              std::is_trivially_destructible_v<T>) {
    // POD类型：直接memcpy，无需调用构造/析构函数
    std::memcpy(new_data, data_, size_ * sizeof(T));
} else if constexpr (std::is_nothrow_move_constructible_v<T>) {
    // 移动不抛异常：安全使用移动语义
    std::uninitialized_move(data_, data_ + size_, new_data);
} else if constexpr (std::is_copy_constructible_v<T>) {
    // 只能复制：使用复制语义
    std::uninitialized_copy(data_, data_ + size_, new_data);
} else {
    // 编译错误：类型不可复制也不可移动
    static_assert(false, "Type must be copyable or movable");
}
```

所以答案是：**vector扩容时会根据元素类型自动选择最优策略**——能移动就移动，不能移动就复制，对于POD类型甚至直接用memcpy。这种智能的类型感知机制是现代C++的精髓所在。

扩容图示：

![](../../../资源/图片/yuque_34b86f89d6f3.png)

![](../../../资源/图片/yuque_ca5c0715a1bb.png)

![](../../../资源/图片/yuque_c75871eed348.png)

都是调用 `Emplace_one_at_back`。

## 四、进阶应用（≥500字）

### 主要区别总结

1. **构造方式**：push_back 需要预先构造的对象，emplace_back 在容器内构造对象
2. **参数传递**：push_back 接受对象，emplace_back 接受构造函数参数
3. **效率**：emplace_back 可能避免不必要的临时对象创建和复制/移动操作
4. **灵活性**：emplace_back 可直接传递构造函数参数
5. **编译复杂度**：emplace_back 作为变参模板可能增加编译时间和内存使用

### 选择指南

选择 push_back 还是 emplace_back 取决于多个因素，包括对象类型、构造复杂度、代码可读性和具体的性能需求。emplace_back 经常被误认为比 push_back 更好，或者与移动语义相关，但这是错误的。在大多数情况下，选择最清晰、最直观的方法通常是最好的做法。

**建议在日常使用中优先选择 push_back。** 只有在需要 emplace_back 的特定功能时（例如，当处理 mutex 或其他不可移动的类型时），或者在性能确实成为问题时，才考虑 emplace_back。

### 与其他主题的关联

- **完美转发**：`emplace_back` 内部使用 `std::forward<Args>(args)...` 转发参数
- **类型萃取**：vector 扩容时用 `is_trivially_copyable`、`is_nothrow_move_constructible` 等选择最优策略
- **异常安全**：`emplace_back` 的强异常安全保证

### 常见优化策略

- **提前 reserve()**：避免连续 emplace_back 触发多次扩容
- **不可移动类型**：`std::mutex`、`std::atomic` 等只能用 `emplace_back`，`push_back` 无法传参
- **explicit 构造函数**：`emplace_back` 不能用于 explicit 构造——它依赖隐式调用
- **大括号初始化陷阱**：`v.emplace_back({1,2})` 编译失败，需写成 `v.emplace_back(1,2)`
- **性能无关场景**：对象已构造好时用 `push_back(move(obj))`，和 `emplace_back` 无差别
- **编译器优化**：简单类型（int/double）两者无差异，编译器会内联消去

## 五、源码解析和实践感悟（≥1000字）

### 1. emplace_back 的变参转发链路

```c++
// libstdc++ vector::emplace_back 核心实现
template<typename _Tp, typename _Alloc>
template<typename... _Args>
void vector<_Tp, _Alloc>::emplace_back(_Args&&... __args) {
    if (this->_M_impl._M_finish != this->_M_impl._M_end_of_storage) {
        // 有剩余空间：原地构造
        _Alloc_traits::construct(this->_M_alloc,
            this->_M_impl._M_finish,
            std::forward<_Args>(__args)...);
        ++this->_M_impl._M_finish;
    } else {
        // 需要扩容：在新内存中构造
        _M_realloc_insert(end(), std::forward<_Args>(__args)...);
    }
}
```

关键点：`std::forward<_Args>(__args)...` 将参数包完美转发给构造函数，中间没有任何临时对象。而 `push_back(const T&)` 和 `push_back(T&&)` 都需要先构造出 T 对象再传入。

### 2. push_back 的隐式转换隐患

```c++
std::vector<std::string> v;
v.push_back("hello");   // 隐式：const char* → string 临时对象 → 移动
v.emplace_back("hello"); // 直接：const char* → string 原地构造
```

push_back 路径：`const char*` → 隐式构造 `string` 临时对象 → 移动进容器 → 析构临时对象。emplace_back 路径：`const char*` → 直接在容器内存中调用 `string(const char*)` 构造。显然 emplace_back 少了一次移动+一次析构。

### 3. 扩容时的 realloc_insert 机制

```c++
template<typename... _Args>
void vector::_M_realloc_insert(iterator __pos, _Args&&... __args) {
    const size_type __len = _M_check_len(1, "vector::_M_realloc_insert");
    pointer __new_start = _M_allocate(__len);
    pointer __new_finish = __new_start;
    
    // 在目标位置构造新元素
    _Alloc_traits::construct(_M_impl, __new_start + offset,
        std::forward<_Args>(__args)...);
    
    // 迁移老元素：优先移动，回退复制
    if constexpr (is_nothrow_move_constructible_v<T>) {
        __new_finish = std::uninitialized_move(...);
    } else {
        __new_finish = std::uninitialized_copy(...);
    }
    // 析构老元素，释放旧内存
}
```

### 实践经验

1. **不可移动类型**：`std::mutex`、`std::atomic` 等只能用 `emplace_back`，`push_back` 无法传参
2. **explicit 构造函数**：`emplace_back` 不能用于 explicit 构造——它依赖隐式调用
3. **大括号初始化陷阱**：`v.emplace_back({1,2})` 编译失败，需写成 `v.emplace_back(1,2)`
4. **性能无关场景**：对象已构造好时用 `push_back(move(obj))`，和 `emplace_back` 无差别
5. **编译器优化**：简单类型（int/double）两者无差异，编译器会内联消去
6. **异常安全**：`emplace_back` 构造失败时容器不变；`push_back` 若移动构造抛异常，元素可能丢失

## 六、面试准备

### Q&A（8题）

**Q1: emplace_back 和 push_back 的本质区别？**
A: push_back 接受已构造对象（拷贝/移动），emplace_back 接受构造函数参数，直接在容器内存中原地构造，省去临时对象

**Q2: 为什么 emplace_back 不能传花括号列表？**
A: 编译器无法从 `{1,2}` 推导出参数类型，`emplace_back` 需要明确的类型用于完美转发

**Q3: 什么场景下 emplace_back 明显优于 push_back？**
A: 构造开销大的对象（如 `vector<pair<string,int>>`），或不可移动类型（mutex、atomic）

**Q4: push_back 相比 emplace_back 有什么优势？**
A: 支持隐式转换（`push_back("hello")` 自动构造 string），代码意图更明确，不易误用

**Q5: vector 扩容时元素如何迁移？**
A: 优先 `std::uninitialized_move`（移动不抛异常），否则 `std::uninitialized_copy`，POD 类型直接用 `memcpy`

**Q6: emplace_back 的异常安全性？**
A: 强异常安全——构造失败时 vector 状态完全不变，因为操作在提交前可回滚

**Q7: 如何判断类型是否支持 nothrow 移动？**
A: `std::is_nothrow_move_constructible_v<T>`，移动构造标记 `noexcept` 即可满足

**Q8: vector 扩容因子是多少？**
A: 通常 1.5x（GCC）或 2x（MSVC），1.5x 可复用之前释放的内存块

### 陷阱与反问（5个）

1. **陷阱**：`v.emplace_back(v[0])` — 扩容时引用失效，读已释放内存
2. **反问**：emplace_back 一定能替代 push_back 吗？→ 不能，explicit 构造、花括号列表场景不可用
3. **陷阱**：`v.push_back(nullptr)` 给 `vector<string>` — 调用 `string(const char*)`，nullptr 非 const char*
4. **反问**：为什么扩容选 1.5x 不选 2x？→ 1.5x 的内存块能复用之前释放的块，2x 每次都需全新地址
5. **陷阱**：连续 emplace_back 触发多次扩容 — 应提前 `reserve()`

### 一句话答案（5个）

1. **emplace_back 核心**：原地构造，省临时对象
2. **push_back 适用**：对象已存在，或需要隐式转换
3. **扩容本质**：新内存 + 迁移元素 + 释放旧内存
4. **不可移动类型**：只能用 emplace_back，push_back 需要先构造对象
5. **避免多次扩容**：提前 `reserve()` 预估大小
