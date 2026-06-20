---
title: const char与string实现
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "基础知识", "基础概念"]
publish: true
---

# const char* 与 string 实现

## 一、核心概念

- **定义**：`const char*` 是 C 风格字符串的底层类型——指向常量字符的指针，以 `\0` 结尾；`std::string` 是 C++ RAII 封装的动态字符串类，内部管理堆内存分配和 SSO（短字符串优化）
- **关键词**：`const char*` vs `char*`、字符串字面量、SSO、`c_str()`、自定义 string 实现、字符数组模板推导
- **适用场景/边界**：const char* 适合 C API 交互和性能关键路径；std::string 适合日常开发；自定义 string 适合学习内存管理和理解 SSO 原理

## 二、详细解析（≥200字）

- **原理拆解（三层递进）**：
  - **第一层——const char* 三种形式**：`const char* p`（指向常量，指针可改）、`char const* p`（同上）、`char* const p`（指针常量，内容可改）。C++ 中字符串字面量类型是 `const char[N]`（不可修改），C 中是 `char[N]`（可修改，但修改是 UB）
  - **第二层——std::string 的核心设计**：内部维护 `char* data_` + `size_t size_` + `size_t capacity_`。SSO 优化下短字符串（GCC≤15字节）直接存储在对象内部 union 缓冲中无需堆分配。`c_str()` 返回内部缓冲区的 const 指针（保证 `\0` 结尾）
  - **第三层——自定义 string 的最小实现**：需要三个特殊函数（拷贝构造 `memcpy`、移动构造 `swap` 指针、析构 `delete[]`）+ `reserve`（扩容策略）+ `append`（拼接含扩容检测）
- **关键数据结构/接口**：GCC `sizeof(string) = 32`（data 指针 + size + capacity + 16字节本地缓冲）；`std::strlen` 计算 C 字符串长度
- **关键公式**：扩容策略 `new_cap = std::max(old_cap * 2, size + len)`；最小容量 `s_min_capacity = 15`

## 三、动手实践（代码案例）

```c++
#include <iostream>
#include <cstring>

// 自定义最小 string 实现
class string {
    static const size_t s_min_capacity = 15;
    char* data_;
    size_t size_;
    size_t capacity_;
    
    void realloc_data(size_t new_cap) {
        new_cap = std::max(new_cap, s_min_capacity);
        char* new_data = new char[new_cap + 1];
        if (data_) {
            std::memcpy(new_data, data_, size_ + 1);  // +1 拷贝 \0
            delete[] data_;
        }
        data_ = new_data;
        capacity_ = new_cap;
    }
    
public:
    string() : data_(new char[s_min_capacity + 1]), size_(0), capacity_(s_min_capacity) {
        data_[0] = '\0';
    }
    
    string(const char* str) : string() {
        if (!str) throw std::invalid_argument("null pointer");
        size_ = std::strlen(str);
        if (size_ > capacity_) reserve(size_);
        std::memcpy(data_, str, size_ + 1);
    }
    
    // 拷贝构造
    string(const string& other) : data_(new char[other.capacity_ + 1]),
        size_(other.size_), capacity_(other.capacity_) {
        std::memcpy(data_, other.data_, size_ + 1);
    }
    
    // 移动构造（noexcept 重要！）
    string(string&& other) noexcept : data_(other.data_),
        size_(other.size_), capacity_(other.capacity_) {
        other.data_ = nullptr;
        other.size_ = other.capacity_ = 0;
    }
    
    ~string() { delete[] data_; }
    
    void reserve(size_t new_cap) {
        if (new_cap > capacity_) realloc_data(new_cap);
    }
    
    string& append(const char* str) {
        size_t len = std::strlen(str);
        if (size_ + len > capacity_) reserve((size_ + len) * 2);
        std::memcpy(data_ + size_, str, len);
        size_ += len;
        data_[size_] = '\0';
        return *this;
    }
    
    const char* c_str() const { return data_; }
    size_t size() const { return size_; }
};

int main() {
    string s("hello");
    s.append(" world");
    std::cout << s.c_str() << std::endl;  // hello world
    return 0;
}
```

- **预期**：理解 string 的内存管理（扩容/拷贝/移动）、const char* 的三种形式
- **补充**：生产代码用 `std::string`，自定义版本仅用于学习内存管理机制

## 四、进阶应用（≥500字）

- **与其他主题的关联**：与内存管理（RAII、三/五法则）、移动语义（noexcept 移动构造）、SSO 优化（union 复用空间）、模板元编程（字符数组模板推导）强相关
- **工程中的真实用法**：
  - **const char* 陷阱**：字符串字面量不可修改——`char* s = "hello"; s[0] = 'H'` 是 UB（段错误）。C++ 中字面量类型是 `const char[N]`，必须用 `const char*` 接收
  - **`c_str()` 生命周期**：返回的指针在 string 对象被修改或析构后失效——不要存储 `c_str()` 返回值跨函数使用
  - **字符数组模板推导**：`template<size_t N> void f(const char (&s)[N])` 可推导出编译期字符串长度，用于编译期字符串处理
  - **零拷贝优化**：C++17 `std::string_view` 取代 `const char*`，提供安全访问（带边界检查）且不拥有内存

## 五、源码解析和实践感悟

### 1. 字符数组模板推导

```c++
template <size_t T>
void f(const char (*s)[T]) {  // 指向长度为 T 的字符数组的指针
    std::cout << T << std::endl;  // 编译期知道数组长度
}
f(&"\x116789abcdef");  // T = 15（含 \0 和 \x 转义序列）
```

### 2. 移动构造的 noexcept 关键性

```c++
string(string&& other) noexcept : data_(other.data_), ... {
    other.data_ = nullptr;  // 将源对象置为安全空状态
}
// noexcept 保证 vector<string> 扩容时走 move 而非 copy
```

### 实践经验

1. **C++ 中必须用 `const char*`**：`char* s = "hello"` 在 C++ 是弃用的（deprecated），字面量不可修改
2. **`std::string_view` 替代 `const char*`**：C++17 起，传递只读字符串优先用 string_view——安全且零拷贝
3. **SSO 阈值**：GCC 15 字节、Clang 22 字节、MSVC 15 字节。短字符串完全在栈上
4. **扩容策略**：2x 增长（摊销 O(1)），配合 `reserve()` 预分配避免频繁扩容
5. **`c_str()` 与 `data()`**：C++11 起两者等价（都保证 `\0` 结尾），C++17 起 `data()` 返回 `char*` 可写

## 六、面试准备

### Q&A（8题）

**Q1: `const char*` 和 `char* const` 的区别？**
A: 前者指向常量（内容不可改），后者指针常量（不可指向别处）。读法：从右向左——`const char*` = pointer to const char

**Q2: 为什么 C++ 字符串字面量是 `const char[]`？**
A: 编译器通常将字面量放在只读数据段（.rodata），修改会段错误。const 阻止意外修改

**Q3: `c_str()` 返回的指针什么时候失效？**
A: string 对象被修改（非 const 操作）、移动、析构后。不可存储该指针跨函数使用

**Q4: 自定义 string 的扩容策略？**
A: 通常 2x 增长（保证摊销 O(1) 插入）。reserve 预分配避免多次扩容

**Q5: 移动构造为什么必须标记 noexcept？**
A: 保证 vector 扩容时使用移动而非拷贝——如果移动不 noexcept，vector 退化为拷贝以保证异常安全

**Q6: SSO 的阈值各编译器是多少？**
A: GCC 15 字节（含 \0 共 16）、Clang 22 字节、MSVC 15 字节

**Q7: `std::string_view` 相比 `const char*` 的优势？**
A: 有长度信息（免 strlen）、支持子串操作（O(1)）、带边界检查、不拥有内存

**Q8: 如何在模板中推导字符串字面量长度？**
A: `template<size_t N> void f(const char (&)[N])` 或 `template<size_t N> void f(const char (*)[N])`

### 陷阱与反问（5个）

1. **陷阱**：`char* s = "hello"` 在 C++ 中已弃用——应使用 `const char*`
2. **反问**：为什么需要 `c_str()` 和 `data()` 两个方法？→ C++17 前 data() 不保证 \0 结尾，现已统一
3. **陷阱**：`c_str()` 后修改 string —— 返回的指针可能指向已释放或移位的内存
4. **反问**：都用 `std::string_view` 可以吗？→ string_view 不拥有内存，不能返回 string_view 指向局部 string
5. **陷阱**：自定义 string 的拷贝构造忘掉 +1 拷贝 \0 —— c_str() 返回非零结尾字符串

### 一句话答案（5个）

1. **`const char*`**：指向只读 C 风格字符串的指针
2. **`c_str()`**：返回内部缓冲区的 const char*，保证 \0 结尾
3. **SSO**：短字符串内嵌对象存储，免堆分配
4. **扩容策略**：2x 增长，摊销 O(1)
5. **noexcept 移动**：保证 vector 扩容走 move 而非 copy
