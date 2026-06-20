---
title: std__uninitialized_copy_n
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "基础知识", "基础概念"]
publish: true
---

# std::uninitialized_copy_n

> 参考：https://cloud.tencent.com/developer/article/2541884

## 一、核心概念

- **定义**：`std::uninitialized_copy_n` 是 C++ 标准库的未初始化内存算法，将指定数量的元素从源范围拷贝到未初始化的目标内存区域，使用 placement new 逐个构造元素
- **关键词**：未初始化内存、placement new、commit-or-rollback、RAII 守卫、类型平凡优化
- **适用场景/边界**：自定义容器（vector-like）的底层实现、内存池管理、避免默认构造 + 赋值的二次开销；边界：目标内存必须未初始化（已初始化则双重构造 UB），失败时回滚已构造元素

## 二、详细解析（≥200字）

- **原理拆解（三层递进）**：
  - **第一层——与 `std::copy` 的区别**：`std::copy` 用 `operator=` 赋值，要求目标已初始化；`std::uninitialized_copy_n` 用 placement new 构造，目标必须是原始未初始化内存。前者快但限制多，后者有构造开销但灵活
  - **第二层——异常安全保证**：如果第 N 个元素构造时抛出异常，算法会逆序析构前 N-1 个已构造元素（commit-or-rollback），保证不会泄漏。这是通过 RAII 守卫对象实现的
  - **第三层——平凡类型优化**：对于 `std::is_trivially_copyable` 的类型（如 int、POD struct），编译器会用 `memmove` 替代逐个 placement new，性能接近直接内存拷贝
- **关键数据结构/接口**：`std::uninitialized_copy_n(InputIt first, Size count, ForwardIt d_first)` 返回指向最后一个构造元素之后的位置
- **关键公式**：时间复杂度 O(n)（平凡类型可用 memmove 接近 O(1) 批量拷贝）

## 三、动手实践（代码案例）

```c++
#include <memory>
#include <iostream>
#include <string>

template<typename T>
class SimpleVec {
    T* data_ = nullptr;
    size_t size_ = 0;
    size_t cap_ = 0;
    
    static T* allocate(size_t n) {
        return static_cast<T*>(::operator new(n * sizeof(T)));
    }
    
    void destroy() {
        std::destroy_n(data_, size_);
        ::operator delete(data_);
    }
    
public:
    ~SimpleVec() { destroy(); }
    
    // push_back 使用 uninitialized_copy_n 扩容
    void push_back(const T& val) {
        if (size_ == cap_) {
            size_t new_cap = cap_ ? cap_ * 2 : 4;
            T* new_data = allocate(new_cap);
            
            // ★ 将已有元素拷贝到新内存（未初始化 → placement new）
            std::uninitialized_copy_n(data_, size_, new_data);
            
            destroy();          // 释放旧内存
            data_ = new_data;
            cap_ = new_cap;
        }
        // 在新位置构造元素
        ::new (data_ + size_) T(val);
        ++size_;
    }
    
    T& operator[](size_t i) { return data_[i]; }
    size_t size() const { return size_; }
};

int main() {
    SimpleVec<std::string> v;
    v.push_back("hello");
    v.push_back("world");
    v.push_back("C++");
    
    for (size_t i = 0; i < v.size(); ++i)
        std::cout << v[i] << " ";
    // hello world C++
    
    return 0;
}
```

- **预期**：理解 uninitialized_copy_n 在容器扩容中的核心角色
- **补充**：`std::uninitialized_move_n` 用于移动而非拷贝，可复用源对象资源

## 四、进阶应用（≥500字）

- **与其他主题的关联**：与自定义容器实现（vector/string 底层）、内存管理（原始内存分配 + placement new）、异常安全（commit-or-rollback）、移动语义（uninitialized_move_n 减少拷贝）强相关
- **工程中的真实用法**：
  - **vector 扩容实现**：`std::vector::push_back` 扩容时：`allocate(new_cap)` → `uninitialized_copy_n` 迁移旧元素 → `destroy + deallocate` 释放旧内存。这是避免"默认构造+赋值"二次开销的关键
  - **内存池管理**：从预分配池中构造对象序列，`uninitialized_copy_n` 批量构造
  - **平凡类型优化**：对 `int`/`double` 等 POD 类型，编译器自动用 `memmove`，扩容效率接近 realloc
- **相关算法家族**：
  - `std::uninitialized_copy`：拷贝迭代器范围（而非指定数量）
  - `std::uninitialized_move_n`：移动而非拷贝，源对象被置于"有效但未指定"状态
  - `std::uninitialized_fill_n`：在未初始化内存中构造 N 个相同值
  - `std::uninitialized_default_construct_n`：默认构造 N 个元素
  - `std::destroy_n`：逆操作——析构指定数量的对象
- **注意事项**：目标内存必须对齐（`alignof(T)`），否则 placement new 是 UB；迭代器类型需满足 LegacyInputIterator（源）和 LegacyForwardIterator（目标）

## 五、源码解析和实践感悟

### 1. 异常安全的回滚实现

```c++
// libstdc++ uninitialized_copy_n 简化实现
template<typename InputIt, typename Size, typename ForwardIt>
ForwardIt uninitialized_copy_n(InputIt first, Size count, ForwardIt d_first) {
    using T = typename iterator_traits<ForwardIt>::value_type;
    ForwardIt current = d_first;
    try {
        for (Size i = 0; i < count; ++i, ++first, ++current) {
            ::new (static_cast<void*>(addressof(*current))) T(*first);
        }
        return current;
    } catch (...) {
        // ★ 异常安全：销毁已构造的元素
        destroy(d_first, current);
        throw;
    }
}
```

### 2. 平凡类型的 memmove 优化

```c++
// 编译器检测 is_trivially_copyable 时优化为：
if constexpr (std::is_trivially_copyable_v<T>) {
    memmove(d_first, first, count * sizeof(T));
    return d_first + count;
}
// 对 int/double/POD struct 跳过逐个 placement new
```

### 实践经验

1. **`uninitialized_copy` vs `copy`**：内存区域未初始化时只能用前者——后者调用 `operator=` 在垃圾内存上赋值是 UB
2. **移动优于拷贝**：扩容时优先用 `uninitialized_move_n`——如果类型有 noexcept 移动构造，完全免拷贝
3. **对齐要求**：`::operator new` 分配的内存保证 alignof(std::max_align_t)，但对更高对齐要求需用 `aligned_alloc`
4. **trivial 优化是自动的**：不需要手动检测 `is_trivially_copyable`，标准库实现已内置此优化
5. **与 `std::relocate`（C++23 提案）对比**：relocate = move + destroy，可一次完成元素迁移和析构

## 六、面试准备

### Q&A（8题）

**Q1: `std::copy` 和 `std::uninitialized_copy_n` 的区别？**
A: copy 用 operator= 赋给已初始化对象；uninitialized_copy_n 用 placement new 在原始内存构造。目标区域状态不同

**Q2: 为什么 vector 扩容用 uninitialized_copy_n 而非 copy？**
A: 新分配的内存是未初始化的——用 copy=赋值会在垃圾数据上调用 operator=，是 UB

**Q3: 如果构造中途抛异常怎么办？**
A: 异常安全保证——逆序析构已构造元素（commit-or-rollback），不泄漏、不破坏未被构造的内存

**Q4: 平凡类型（trivial）有什么优化？**
A: `is_trivially_copyable` 的类型用 memmove 批量拷贝，跳过逐个 placement new，性能提升显著

**Q5: uninitialized_copy_n 返回什么？**
A: 返回指向最后一个构造元素之后位置的迭代器（类似 end 指针）

**Q6: 什么时候该用 uninitialized_move_n？**
A: 源对象不再需要时——如 vector 扩容可移动旧数据到新内存，避免拷贝

**Q7: `destroy_n` 的作用？**
A: 显式调用析构函数销毁 N 个元素，将内存回退到未初始化状态

**Q8: 为什么不直接用 malloc + 循环 placement new？**
A: 功能相同但需要手动实现异常安全回滚，uninitialized_copy_n 已内置

### 陷阱与反问（5个）

1. **陷阱**：在已初始化内存上调用 uninitialized_copy_n——双重构造，原有元素泄漏且新元素构造在"脏"内存上
2. **反问**：为什么不用 realloc 扩容？→ realloc 对非平凡类型无法调用拷贝/移动构造，行为未定义
3. **陷阱**：未对齐内存上的 placement new——`alignof(T)` 不对齐是 UB
4. **反问**：相比直接用 `new T[n]` 有什么优势？→ 分离内存分配和对象构造，更灵活（预分配大块内存，延迟构造）
5. **陷阱**：`destroy_n` 后忘记释放内存——析构不回收内存，需手动 `::operator delete`

### 一句话答案（5个）

1. **uninitialized_copy_n 本质**：在原始内存中用 placement new 构造 N 个元素
2. **异常安全**：commit-or-rollback，逆序析构已构造元素
3. **trivial 优化**：POD 类型自动 memmove
4. **返回迭代器**：指向最后一个构造元素之后
5. **适用场景**：vector 扩容、内存池、自定义容器
