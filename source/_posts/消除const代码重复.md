---
title: 消除const代码重复
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "基础知识", "实践与杂项"]
publish: true
---

# 消除 const/non-const 代码重复

## 一、核心概念

- **定义**：当类同时提供 const 和 non-const 版本的成员函数时，两者的实现往往几乎完全相同——核心技巧是用 non-const 版本实现 const 版本（反向则需要 `const_cast`）
- **关键词**：`const_cast`、代码复用、DRY 原则、constexpr 自动退化
- **典型场景**：`operator[]` 的 const 重载、访问器（getter）的 const 重载

## 二、详细解析

C++ 的 const 重载是类型安全的重要机制，但它导致了一个实际问题：const 和 non-const 版本通常返回类型不同（`const T&` vs `T&`），但内部逻辑完全相同。

### 方案一：non-const 调用 const 版本（推荐）

```c++
class Buffer {
    char data_[1024];
    
    const char& at(size_t i) const {
        // 边界检查 + 返回
        if (i >= 1024) throw std::out_of_range("");
        return data_[i];
    }
    
    char& at(size_t i) {
        // ★ 复用 const 版本，然后去除 const
        return const_cast<char&>(
            static_cast<const Buffer&>(*this).at(i)
        );
    }
};
```

这一方案是安全的：因为调用者持有 non-const 对象，实际对象是可修改的，const_cast 只是移除编译期检查。

### 方案二：constexpr 自动退化

```c++
// constexpr 函数在传入非常量实参时可自动退化
template<typename T>
constexpr T max(T a, T b) { return a < b ? b : a; }

int x = 5, y = 10;
int r1 = max(x, y);             // 普通版本（运行时）
constexpr int r2 = max(3, 7);   // 编译期版本
// 无需重写——constexpr 自动处理 const/non-const 场景
```

## 三、实践经验

1. **`const_cast` 的安全使用**：只在 non-const 版本中调用 const 版本时使用——底层对象是 non-const 的，const_cast 只是去掉了"逻辑 const"而非修改真正的 const 对象
2. **反向使用是 UB**：在 const 版本中 `const_cast` 调用 non-const 版本然后修改——修改 const 对象是未定义行为
3. **constexpr 替代方案**：如果函数逻辑可以编译期执行，标记为 `constexpr` 自动获得 const/non-const 双重能力
4. **C++23 `deducing this`**：`auto& at(this auto& self, size_t i)` 自动推导 const 性，彻底消除重复代码

## 附录（原内容）

使用 `const_cast<>` 重写 const 版本的函数，直接转换。

使用 `constexpr` 常量表达式——在传入非常量时可以自动退化，不用重写普通版本。
