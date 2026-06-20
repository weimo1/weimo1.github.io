---
title: String View
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "现代C++特性"]
publish: true
---

# String View

> 适用范围：C++17 std::string_view 非拥有型字符串视图、零拷贝子字符串、高效只读字符串参数传递

## 一、核心概念

- **定义**：`std::string_view` 是 C++17 引入的非拥有型只读字符串视图，仅持有指向外部字符序列的指针和长度（sizeof = 16字节，64位），不分配堆内存
- **关键词**：非拥有型(non-owning)、零拷贝、substr O(1)、悬空引用、from_chars、sv字面量
- **适用场景/边界**：
  - 只读字符串参数传递（替代 `const std::string&`）
  - 子字符串解析与处理（零拷贝切片）
  - 字符串字面量传参（避免临时 string 构造的堆分配）
  - 边界：不能用于需要修改字符串、需要空字符终止（C API）、需要持有所有权的场景

## 二、详细解析（≥200字）

### 2.1 基本工作原理（三层递进）

**第一层：视图模式**。`string_view` 不拥有底层字符数据，只是"观察"外部已存在的字符序列。内部仅存储 `const CharT* data_` 和 `size_t size_` 两个成员，sizeof = 16字节（64位），值传递成本与传引用相当。

**第二层：零拷贝操作**。`string_view::substr(pos, count)` 仅创建新的 `string_view` 对象，将内部指针偏移 `pos`、缩小长度到 `count`，完全不涉及内存分配或数据复制。这与 `string::substr` 的 O(n) 分配+复制形成本质区别。

**第三层：生命周期陷阱**。正因为不拥有数据，`string_view` 的生命周期必须严格短于被引用对象。`string_view sv = string("hello") + " world";` 是典型的未定义行为：临时 `string` 在表达式结束后析构，sv 内部指针变为悬空。

### 2.2 核心特点

和`std::string`相比，`std::string_view`对象有以下特点：

* 底层的字符序列是只读的。没有操作可以修改底层的字符。你只能赋予一个新值、 交换值、把视图缩小为字符序列的子序列。
* 字符序列不保证有空字符终止。因此，字符串视图并不是一个 *空字符终止的字节流(NTBS)* 。
* `data()`返回的值可能是`nullptr`。例如，当用默认构造函数初始化一个 字符串视图之后，调用`data()`将返回`nullptr`。
* 没有分配器支持。

因为可能返回`nullptr`，并且可能不以空字符结尾， 所以在使用`operator[]`或`data()`之前应该 总是使用`size()`获取长度 （除非你已经知道了长度）。

## 三、动手实践（代码案例）

[C++17 字符串视图(String Views)](https://zhuanlan.zhihu.com/p/535124502)

[C++17剖析：string_view的实现，以及性能](https://zhuanlan.zhihu.com/p/166359481)

### 3.1 字符串视图概述

在C++17中，C++标准库引入了一个特殊的字符串类：`std::string_view`， 它能让我们像处理字符串一样处理字符序列，而不需要为它们分配内存空间。 也就是说，`std::string_view`类型的对象只是引用一个外部的字符序列， 而不需要持有它们。因此，一个字符串视图对象可以被看作字符串序列的 *引用* 。

![](../../资源/图片/yuque_f167c5cb931c.png)

使用字符串视图的开销很小，速度却很快（以值传递一个`string_view`的开销总是很小）。 然而，它也有一些潜在的危险，就和原生指针一样，在使用`string_view`时也必须 由程序员自己来保证引用的字符串序列是有效的。  
  
和`std::string`相比，`std::string_view`对象有以下特点：

* 底层的字符序列是只读的。没有操作可以修改底层的字符。你只能赋予一个新值、 交换值、把视图缩小为字符序列的子序列。
* 字符序列不保证有空字符终止。因此，字符串视图并不是一个 *空字符终止的字节流(NTBS)* 。
* `data()`返回的值可能是`nullptr`。例如，当用默认构造函数初始化一个 字符串视图之后，调用`data()`将返回`nullptr`。
* 没有分配器支持。

因为可能返回`nullptr`，并且可能不以空字符结尾， 所以在使用`operator[]`或`data()`之前应该 总是使用`size()`获取长度 （除非你已经知道了长度）。

### 3.2 使用字符串视图作为参数

下面是使用字符串视图作为只读字符串的第一个例子， 这个例子定义了一个函数将传入的字符串视图作为前缀，之后打印一个集合中的元素：

```
#include <string_view>

template<typename T>
void printElems(const T& coll, std::string_view prefix = {})
{
    for (const auto& elem : coll) {
        if (prefix.data()) {    // 排除nullptr
            std::cout << prefix << ' ';
        }
        std::cout << elem << '\n';
    }
}
```

这里，把函数参数声明为`std::string_view`，与声明为`std::string`比较起来， 可能会减少一次分配堆内存的调用。具体的情况依赖于是否传递的是短字符串和是否使用了短字符串优化(SSO)。 例如，如果我们像下面这么声明：

```
template<typename T>
void printElems(const T& coll, const std::string& prefix = {});
```

然后传递了一个字符串字面量，那么这个调用会创建一个临时的string，这将会在堆上分配一次内存， 除非使用了短字符串优化。 通过使用字符串视图，将不会分配内存，因为字符串视图只 *指向* 字符串字面量。

注意在使用值未知的字符串视图前应该检查`data()`来排除`nullptr`。 这里为了避免写入额外的空格分隔符，必须检查`nullptr`。 值为`nullptr`的字符串视图写入到输出流时不应该写入任何字符。

另一个例子是使用字符串视图作为只读的字符串来改进`std::optional<>`章节的`asInt()`示例， 改进的方法就是把参数声明为字符串视图：

```
#include <optional>
#include <string_view>
#include <charconv> // for from_chars()
#include <iostream>

// 尝试将string转换为int：
std::optional<int> asInt(std::string_view sv)
{
    int val;
    // 把字符序列读入int：
    auto [ptr, ec] = std::from_chars(sv.data(), sv.data() + sv.size(), val);
    // 如果有错误码，就返回空值：
    if (ec != std::errc{}) {
        return std::nullopt;
    }
    return val;
}

int main()
{
    for (auto s : {"42", "  077", "hello", "0x33"}) {
        // 尝试把s转换为int，并打印结果：
        std::optional<int> oi = asInt(s);
        if (oi) {
            std::cout << "convert '" << s << "' to int: " << *oi << "\n";
        }
        else {
            std::cout << "can't convert '" << s << "' to int\n";
        }
    }
}
```

![](../../资源/图片/yuque_48323a1cac32.png)

将`asInt()`的参数改为字符串视图之后需要进行很多修改。 首先，没有必要再使用`std::stoi()`来转换为整数，因为`stoi()`的参数是string， 而根据string view创建string的开销相对较高。

作为代替，我们向新的标准库函数`std::from_chars()`传递了字符范围。 这个函数需要两个字符指针为参数，分别代表字符序列的起点和终点，并进行转换。 注意这意味着我们可以避免单独处理空字符串视图，这种情况下`data()`返回`nullptr`， `size()`返回0，因为从`nullptr`到`nullptr+0`是一个有效的空范围 （任何指针类型都支持与0相加，并且不会有任何效果）。

`std::from_chars()`返回一个`std::from_chars_result`类型的结构体， 它有两个成员：一个指针`ptr`指向未被处理的第一个字符， 另一个成员`ec`的类型是`std:errc`，`std::errc{}`代表没有错误。 因此，使用返回值中的`ec`成员初始化`ec`之后（使用了结构化绑定）， 下面的检查将在转换失败时返回`nullopt`：

```
if (ec != std::errc{}) {
    return std::nullopt;
}
```

使用字符串视图还可以显著提升子字符串排序的性能。

### 3.3 安全使用字符串视图的总结

总结起来就是 **小心地使用**`std::string_view` ， 也就是说你应该按下面这样调整你的编码风格：

* 不要在那些会把参数传递给string的API中使用string view。
* 不要用string view形参来初始化string成员。
* 不要把string设为string view调用链的终点。
* 不要返回string view。
* 除非它只是转发输入的参数，或者你可以标记它很危险，例如，通过命名来体现危险性。
* **函数模板** 永远不应该返回泛型参数的类型 **T** 。
* 作为替代，返回`auto`类型。
* 永远不要用返回值来初始化string view。
* **不要** 把返回泛型类型的函数模板的返回值赋给 `auto` 。
* 这意味着AAA( *总是auto(Almost Always Auto)* )原则不适用于string view。

如果因为这些规则太过复杂或者太困难而不能遵守，那就完全不要 使用`std::string_view`（除非你知道自己在做什么）。

## 四、进阶应用（≥500字）

### 4.1 性能优势深度分析

**零分配构造**：传递字符串字面量时，`string_view` 仅存储指针+长度（O(1)从字面量），而 `const string&` 需构造临时 `string` 对象（至少一次堆分配，除非 SSO 命中）。在频繁调用场景下差异显著。

**子字符串排序**：`string_view::substr` 零拷贝特性使得子字符串排序完全避免内存分配。例如对 1GB 文本的百万级子串切片排序，`string_view` 解决方案内存占用恒定（仅视图数组），而 `string` 方案会指数级复制数据。

### 4.2 string_view 安全使用规则

* 不要在那些会把参数传递给string的API中使用string view
* 不要用string view形参来初始化string成员
* 不要把string设为string view调用链的终点
* 不要返回string view（除非只是转发输入参数，或通过命名体现危险性）
* **函数模板** 永远不应该返回泛型参数的类型 **T** ，作为替代返回`auto`类型
* 永远不要用返回值来初始化string view
* **不要** 把返回泛型类型的函数模板的返回值赋给 `auto`
* 这意味着AAA( *总是auto(Almost Always Auto)* )原则不适用于string view

如果因为这些规则太过复杂或者太困难而不能遵守，那就完全不要 使用`std::string_view`（除非你知道自己在做什么）。

### 4.3 与其他主题的关联

- **span (C++20)**：`std::span<T>` 是 `string_view` 的泛化版本，适用于任意连续内存范围的只读/可读写视图
- **from_chars (C++17)**：`std::from_chars(sv.data(), sv.data() + sv.size(), val)` 是 C++17 最高效的字符串转数字 API，与 string_view 天然搭配
- **SSO (短字符串优化)**：短字符串（通常 ≤15 字符）在 `std::string` 内部栈缓冲中存储，不触发堆分配，此时 string_view 的免分配优势不明显
- **string_view_literals**：`using namespace std::string_view_literals;` 后可用 `"hello"sv` 在编译期确定长度，避免运行时 strlen 的 O(n) 开销

### 4.4 工程中的最佳实践

- **只读参数首选**：`void f(std::string_view sv)` 统一接收 `const char*`、`string`、`string_view`、字面量
- **避免作为成员**：类成员不要用 `string_view`——对象生命周期难以保证长于被引用源
- **配合 from_chars**：解析数字/日期等场景，string_view + from_chars 是无分配方案
- **优先 sv 字面量**：`"hello"sv` 而非 `"hello"` 构造 string_view，避免不必要的 strlen 调用


## 五、源码解析和实践感悟

### 5.1 源码解析

#### std::string_view 的底层结构

`string_view` 本质上是一个**非拥有型字符串引用**，仅包含两个成员：

```c++
template<class CharT, class Traits = std::char_traits<CharT>>
class basic_string_view {
public:
    using const_pointer   = const CharT*;
    using size_type       = std::size_t;

private:
    const_pointer data_;   // 指向外部字符序列（不拥有）
    size_type     size_;   // 序列长度
};
```

**关键设计**：sizeof(string_view) = 16 字节（64位），只存一个指针 + 一个长度，无堆分配、无引用计数。值传递成本极低（复制 16 字节），与传递 `const string&` 等价。

#### substr 的零拷贝实现

```c++
constexpr basic_string_view substr(size_type pos = 0, size_type count = npos) const {
    return basic_string_view(data_ + pos, std::min(count, size_ - pos));
}
```

与 `std::string::substr`（需要分配新内存并复制）不同，`string_view::substr` 只是偏移指针、缩小长度，**零拷贝、零分配**。这就是子字符串排序等场景性能大幅提升的根源。

#### 字符串字面量构造路径

```c++
// 从 const char* 构造
constexpr basic_string_view(const CharT* s) 
    : data_(s), size_(Traits::length(s)) {}  // 调 strlen，O(n)
```

注意：从 `const char*` 构造会调用 `strlen` 确定长度（O(n)），但从 `const string&` 或一对指针构造则是 O(1)。如果已经知道长度，优先使用 `string_view(ptr, len)` 或直接从 `string` 构造。

### 5.2 实践经验

1. **首选参数类型**：只读字符串参数优先用 `string_view` 替代 `const string&`——避免不必要的 `string` 临时对象构造和堆分配，尤其是传递字符串字面量时
2. **NULL 终止不是保证**：`string_view::data()` 不保证末尾有 `'\0'`，传给 C API（如 `printf`）前必须手动追加或转成 `string`
3. **生命周期陷阱**：`string_view` 不拥有数据，引用临时 `string` 时极容易悬空：`string_view sv = string("hello") + " world";` 是未定义行为
4. **substr 链式优化**：多次 `substr` 只在原始视图上不断缩小窗口，不会产生内存碎片
5. **与 from_chars 配合**：`std::from_chars(sv.data(), sv.data() + sv.size(), val)` 是 C++17 最高效的字符串转数字方式
6. **不在 API 边界返回**：作为函数返回值返回 `string_view` 极易导致悬空引用，除非明确是转发输入参数

## 六、面试准备

### 6.1 面试高频问答

**Q1：`std::string_view` 和 `std::string` 的关系是什么？**

A：`string_view` 是 `string` 的**非拥有型视图**（类似 `span` 之于数组）。`string` 拥有并管理字符缓冲区，`string_view` 只持有指向外部字符序列的指针和长度。`string` 可以隐式转换为 `string_view`，反之需要显式构造。

**Q2：为什么 `string_view::data()` 不保证末尾有空字符？**

A：因为 `string_view` 可以指向任意字符序列的子区间（通过 `substr`），原始序列末尾的空字符可能不在视图范围内。如果保证末尾空字符，就需要复制一份数据，违背了零开销的设计目标。

**Q3：`string_view::substr` 为什么是 O(1)？**

A：它只是返回一个指向同一缓冲区的新 `string_view`，调整起始指针偏移和长度，不涉及任何内存分配或数据复制。与 `string::substr` 的 O(n)（分配+复制）形成鲜明对比。

**Q4：什么场景下不能用 `string_view`？**

A：(1) 需要修改字符串内容时（只读视图）；(2) 需要将字符串传递给需要空字符结尾的 C API 时；(3) 需要存储字符串所有权时（如类成员）；(4) 作为函数返回值返回局部字符串的视图（悬空风险）。

**Q5：`string_view` 作为函数参数有什么优势？**

A：统一接口——一个参数可接收 `const char*`、`string`、`string_view`、字符串字面量等，避免为每种类型写重载，且无需在传递字面量时构造临时 `string`（免堆分配）。

**Q6：如何安全地从 `string_view` 获取 C 风格字符串？**

A：先构造 `std::string(sv)`（会复制并追加 `'\0'`），然后调用 `.c_str()`。不能直接使用 `sv.data()` 作为 C 字符串。

**Q7：`string_view` 的 sizeof 是多少？为什么？**

A：通常 16 字节（64位系统）：一个指针（8字节）+ 一个 size_t（8字节）。只有两个成员，且没有虚函数、没有分配器。

**Q8：写出一个 `string_view` 悬空的典型错误示例。**

A：
```c++
std::string_view sv = std::string("hello") + " world";  // 临时 string 被析构
std::cout << sv;  // 未定义行为！
```
临时 `string` 在表达式结束即析构，`sv` 内部指针变为悬空。

### 6.2 陷阱与反问

**陷阱1**：`string_view sv = "hello"` 调用 `strlen` 确定长度（O(n)），在热路径中可用编译期确定长度的 `"hello"sv`（C++17 字面量）

**陷阱2**：`sv.data()[sv.size()]` 访问越界——`size()` 返回的是长度，最后一个有效字符在 `data()[size()-1]`

**陷阱3**：作为类成员时，必须保证引用源的生命周期长于对象本身——这是最常见的 `string_view` bug

**陷阱4**：`auto x = "hello"` 推导为 `const char*`，不是 `string_view`；需要 `using namespace std::string_view_literals` 并用 `"hello"sv`

**陷阱5**：`for (auto c : sv)` 遍历的是字符值，不是引用——如果期望修改，需要使用 `string`

**反问**：`string_view` 的设计为什么不能替代 `const string&` 的所有使用场景？

*答案要点：因为 `string_view` 不保证空字符终止（C API 不兼容）、不拥有数据（不能作为返回值或长期存储）、不能作为 `string` 的"终极替换"——它只是视图，需要被引用对象存活。*

### 6.3 一句话答案

1. **string_view**：C++17 非拥有型只读字符串视图，存指针+长度，16字节
2. **substr**：O(1) 零拷贝子串视图，只偏移指针不复制数据
3. **data() vs c_str()**：`data()` 不保证空字符终止，`c_str()` 保证（只有 `string` 有）
4. **生命周期**：`string_view` 不拥有数据，引用源销毁后悬空
5. **构造开销**：从 `const char*` 构造 O(n)（需 strlen），从 string 或 (ptr,len) 构造 O(1)
6. **from_chars**：C++17 高效字符串转数字，与 `string_view` 天然配合
7. **字面量后缀 sv**：`"hello"sv` 在编译期确定长度，避免运行时 strlen
