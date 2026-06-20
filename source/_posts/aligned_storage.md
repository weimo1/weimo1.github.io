---
title: aligned_storage
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "内存模型"]
publish: true
---

# aligned_storage

> 适用范围：C++ `std::aligned_storage`——管理对齐内存的模板类及其 C++23 替代方案。

参考：<https://blog.csdn.net/weixin_61470881/article/details/144594288>、<https://dev59.com/vVEG5IYBdhLWcg3wKFbw>

## 一、核心概念

- **定义**：`std::aligned_storage` 是 C++ 标准库中用于**管理对齐内存的模板类**，定义在 `<type_traits>` 头文件中。它通过模板参数指定内存大小和对齐方式，提供未初始化的内存区域，适用于需要精确控制内存布局的场景。
- **关键词**：`std::aligned_storage`、`std::aligned_union`、对齐存储、placement new、显式析构、`std::aligned_flat_storage`（C++23）、SBO
- **适用场景/边界**：
  - 实现自定义容器（如 `std::optional`、`std::variant` 等）
  - 手动管理内存时保持布局一致性
  - 延迟构造对象（配合 placement new）
  - C++23 已弃用，应迁移至 `std::aligned_flat_storage` 或 `alignas(T) std::byte data[sizeof(T)]`

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：基本工作原理**

`std::aligned_storage` 的核心功能：
- **内存对齐管理**：通过模板参数设置内存大小（Len）和对齐方式（Align），确保数据按特定规则排列
- **类型安全保障**：提供 `type` 类型别名，避免直接操作未初始化内存导致的未定义行为

**第二层：关键步骤详解**

`std::aligned_storage` 的语法：

```c++
template <std::size_t Len, std::size_t Align = alignof(std::max_align_t)>
struct aligned_storage;
```

其中：
- `Len` 表示所要分配的存储空间的大小（以字节为单位）
- `Align` 表示存储空间的对齐要求（以字节为单位），默认值为 `std::max_align_t`，该值将会满足所有数据类型的对齐要求

例如，在 x86-64 平台上，最大对齐值通常是 16 个字节（因为 `long double` 类型的对齐值是 16 个字节）；在 ARM 平台上，最大对齐值可能会是 8 个字节（因为 `double` 类型的对齐值是 8 个字节）。

使用如下语句可以得到一个类型：

```c++
std::aligned_storage<20,4>::type  // 定义了一个20字节为大小，4字节对齐（地址为4的倍数）的内存块类型
```

上述语句定义了一个 20 字节为大小，4 字节对齐的内存块类型，使用该类型可以在堆空间或栈空间上分配该内存块。

`std::aligned_union` 与 `std::aligned_storage` 类似，也用于创建具有特定对齐要求的存储，不过它更侧重于联合类型的存储。

**第三层：底层机制**

```c++
template<std::size_t Len, std::size_t Align = alignof(max_align_t)>
struct aligned_storage {
    alignas(Align) unsigned char data[Len];  // 裸字节数组 + 对齐约束
};
```

编译器通过 `alignas` 确保 `data` 数组按 `Align` 对齐。使用时配合 placement new 构造对象，用完后显式调用析构函数。编译器不会为 `aligned_storage` 自动管理生命周期。

- **关键数据结构**：`aligned_storage<Len, Align>::type`、placement new 返回值
- **关键公式**：对齐存储字节数 ≥ `sizeof(T)`，对齐值 ≥ `alignof(T)`

### 被弃用的原因

`std::aligned_storage` 和 `std::aligned_union` 被弃用的主要原因是它们不能很好地满足实际使用需求。例如，`aligned_storage` 不能保证准确适应存储需求——保证 `aligned_storage<16>::type` 至少为 16 个字节，但是一个符合标准的实现可以轻松地提供 32 个字节或 4K 字节。这就可能导致意外使用，给开发者带来困扰。

### 替代方案

可以使用类似 `libstdc++` 的 `__aligned_membuf` 来替代：

```c++
template <typename T>
struct storage_for {
    alignas(T) std::byte data[sizeof(T)];
    // 可以添加一些有用的构造函数和方法
};
```

## 三、动手实践（代码案例）

### 3.1 基本使用

```c++
#include <type_traits>
#include <iostream>

typedef std::aligned_storage<sizeof(int), std::alignment_of<double>::value>::type new_type;

int main() {
    std::cout << "alignment_of<int> == " << std::alignment_of<int>::value << std::endl;
    std::cout << "aligned to double == " << std::alignment_of<new_type>::value << std::endl;
    return 0;
}
```

### 3.2 延迟构造与显式析构

```c++
aligned_storage_t<sizeof(MyClass), alignof(MyClass)> storage;
MyClass* p = new (&storage) MyClass(42);  // placement new 构造
p->~MyClass();  // 必须显式析构！
// 编译器不会为 aligned_storage 自动管理生命周期
```

### 3.3 aligned_storage 在自定义 variant 中的应用

```c++
#include <type_traits>
#include <new>
#include <iostream>

template<typename... Types>
class SimpleVariant {
    using Storage = std::aligned_union_t<0, Types...>;
    Storage data;
    int type_index = -1;
    
public:
    template<typename T, typename... Args>
    void emplace(Args&&... args) {
        new (&data) T(std::forward<Args>(args)...);
        type_index = /* find index of T */ 0;
    }
    
    template<typename T>
    T& get() {
        return *reinterpret_cast<T*>(&data);
    }
    
    ~SimpleVariant() {
        // 需要根据 type_index 调用对应类型的析构
    }
};
```

## 四、进阶应用（≥500字）

### 标准库中的实际应用

1. **`std::optional` 的底层存储**：
   ```c++
   // libstdc++ 的 std::optional 内部
   template<typename T>
   class optional {
       struct _Optional_payload {
           // 使用 aligned storage 存储 T，延迟构造
           aligned_storage_t<sizeof(T), alignof(T)> _M_storage;
           bool _M_engaged = false;
       };
   };
   ```

2. **`std::variant` 的底层存储**：
   ```c++
   // 使用 aligned_union 存储多种可能类型
   using storage_t = aligned_union_t<0, int, double, std::string>;
   storage_t buffer;
   // 通过 placement new 构造实际类型
   ```

3. **`std::any` 的小对象优化**：
   ```c++
   // std::any 内部针对小对象使用 SBO
   static constexpr size_t SBO_SIZE = sizeof(void*) * 4;
   aligned_storage_t<SBO_SIZE> _M_buffer;
   // 小对象直接存缓冲区，大对象存堆
   ```

### 与其他主题的关联

- **placement new**：对齐存储上构造对象的唯一合法方式
- **显式析构**：`ptr->~T()` 手动调用析构函数，编译器不会自动析构
- **类型擦除**：`std::function`、`std::any` 内部都使用了类似 aligned_storage 的技术
- **POD 类型**：`aligned_storage` 本身是 trivial 类型，可用于 memcpy

### 常见优化策略

- **C++23 用 `aligned_flat_storage`**：类型安全的替代方案
- **对齐值必须是 2 的幂**：否则编译错误
- **生命周期管理全手动**：不调用析构→资源泄漏
- **union 和 `aligned_storage` 的区别**：union 只能存一种类型（同时只能活跃一个），aligned_storage 可复用于不同场景
- **适合实现 variant/optional**：底层用 aligned_storage + unsigned char 表示状态

### `std::numeric_limits::has_denorm` 也被 C++23 弃用

`std::numeric_limits::has_denorm` 是 `std::numeric_limits` 类的一个静态成员常量，用于鉴别浮点类型所用的非正规风格。其值可以是：
- `std::denorm_absent`：表示该类型不支持非正规值
- `std::denorm_present`：表示该类型支持非正规值

标准特化中，对于大多数整数类型，`has_denorm` 的值为 `std::denorm_absent`；对于 `float`、`double` 和 `long double` 类型，通常为 `std::denorm_present`。

在 C++23 中，`std::aligned_storage`、`std::aligned_union`（提案 P1413R3）以及 `std::numeric_limits::has_denorm`（提案 P2614R2）都被列入了弃用名单。

## 五、源码解析和实践感悟（≥1000字）

### 1. aligned_storage 的底层实现

```c++
template<std::size_t Len, std::size_t Align = alignof(max_align_t)>
struct aligned_storage {
    alignas(Align) unsigned char data[Len];  // 裸字节数组 + 对齐约束
};
// 用途: 提供未初始化的对齐存储，配合 placement new 延迟构造
// C++23: 改为 aligned_flat_storage，更安全的接口
```

### 2. 延迟构造与显式析构

```c++
aligned_storage_t<sizeof(MyClass), alignof(MyClass)> storage;
MyClass* p = new (&storage) MyClass(42);  // placement new 构造
p->~MyClass();  // 必须显式析构！
// 编译器不会为 aligned_storage 自动管理生命周期
```

### 实践经验
1. **C++23 用 aligned_flat_storage**：类型安全替代
2. **对齐值必须是 2 的幂**：否则编译错误
3. **生命周期管理全手动**：不调用析构→资源泄漏
4. **union 和 aligned_storage 的区别**：union 只能存一种类型，aligned_storage 可复用
5. **适合实现 variant/optional**：底层用 aligned_storage + unsigned char 表示状态

## 六、面试准备

### Q&A（10题）

**Q1: aligned_storage 的用途？**
A: 提供原始对齐存储，允许在已分配内存上延迟构造对象

**Q2: aligned_storage 和 union 的区别？**
A: union 明确声明所有可能类型；aligned_storage 是未类型化的原始字节缓冲区

**Q3: 如何在对齐存储上构造对象？**
A: placement new: `new (&storage) T(args...)`

**Q4: 对齐存储中的对象如何销毁？**
A: 必须显式调用析构函数: `p->~T()`，编译器不会自动析构

**Q5: C++23 中 aligned_storage 被什么替代？**
A: `std::aligned_flat_storage`（更安全的类型化接口）

**Q6: aligned_storage 的第二个模板参数是什么？**
A: 对齐值，默认 `alignof(std::max_align_t)`

**Q7: 对齐不匹配会导致什么问题？**
A: UB——可能触发硬件异常或性能严重下降

**Q8: 哪些标准库类型内部使用 aligned_storage？**
A: std::optional、std::variant、std::any 内部都用了类似技术

**Q9: aligned_union 和 aligned_storage 的区别？**
A: aligned_union 自动计算满足多个类型中大者的 Len 和 Align

**Q10: aligned_storage 是 trivial 类型吗？**
A: 是（纯 char 数组），可用于 memcpy 等

### 陷阱与反问（5个）
1. **陷阱**：忘记调用析构→非平凡类型的资源泄漏
2. **反问**：为什么 C++23 要弃用 aligned_storage？→ 易导致 UB 且不直观
3. **陷阱**：访问 aligned_storage 前未 placement new→UB
4. **反问**：能否用 char 数组替代 aligned_storage？→ 不能保证对齐
5. **陷阱**：`reinterpret_cast<T*>(&storage)` 而非 placement new→UB

### 一句话答案（8个）
1. **aligned_storage**：裸字节对齐存储
2. **placement new**：对齐存储上构造对象
3. **显式析构**：`ptr->~T()` 手动调析构
4. **对齐模板参数**：默认 alignof(max_align_t)
5. **C++23 替代**：aligned_flat_storage
6. **内部使用**：optional/variant/any
7. **aligned_union**：自动选最大 Len/Align
8. **trivial**：是，可 memcpy
