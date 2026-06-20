---
title: std__expected
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "现代C++特性"]
publish: true
---

# std::expected

> 适用范围：C++23 `std::expected`——类型安全的错误处理替代异常机制。

## 一、核心概念

- **定义**：`std::expected` 是 C++23 标准库中的一个模板类，定义于头文件 `<expected>` 中。它提供了一种方式来表示两个值之一：类型 `T` 的期望值，或类型 `E` 的非期望值。`std::expected` 永远不会是无值的。
- **关键词**：`std::expected`、`std::unexpected`、`and_then`、`or_else`、`transform`、错误处理、monadic 操作
- **适用场景/边界**：
  - 替代异常进行可恢复错误处理
  - 函数返回值既可能是成功结果也可能是错误信息
  - 不适合不可恢复的致命错误（仍应用异常/assert）

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：基本工作原理**

众所周知，C++23以前的异常处理是比较麻烦的，尤其是自己要在可能抛出异常的地方，需要自己去捕获它，比如除数为0的异常、使用std::stoi函数将字符串转换成int整型数据、处理文件读写的异常等等，不然很容易造成程序终止。`std::expected` 为函数返回结果的处理提供了一种更加优雅、类型安全的解决方案。

**第二层：关键步骤详解**

```c++
template< class T, class E >
class expected;
// (since C++23)
template< class T, class E >
    requires std::is_void_v<T>
class expected<T, E>;
```

类模板 std::expected 提供了一种表示两种值的方式：类型为 T 的预期值或类型为 E 的意外值。预期值永远不会是无值的。

1. 主模板。在其自身的存储空间中包含预期值或意外值，该存储空间嵌套在预期对象中。
2. void 部分特化。表示预期 void 值或包含意外值。如果包含意外值，则嵌套在预期对象中。

**第三层：底层机制**

模板参数：
- T - 预期值的类型。该类型必须是（可能为 cv 限定的）`void`，或者满足 Destructible 即可析构性要求（特别是，不允许使用数组和引用类型）。
- E - 意外值的类型。该类型必须满足 Destructible 要求，并且必须是 std::unexpected 的有效模板参数（特别是，不允许使用数组、非对象类型和 cv 限定的类型）。

- **关键数据结构**：union-like 存储（T 或 E 二选一）+ bool 标志位
- **关键公式**：`expected<T,E>` = `variant<T,E>` 语义 + monadic 操作链

## 三、动手实践（代码案例）

## 四、进阶应用（≥500字）

# C++23中的std::expected:异常处理

众所周知，C++23以前的异常处理是比较麻烦的，尤其是自己要在可能抛出异常的地方，需要自己去捕获它，比如除数为0的异常、使用std::stoi函数将字符串转换成int整型数据、处理文件读写的异常等等，不然很容易造成程序终止。

关于C++23中引入的[std::expected](https://en.cppreference.com/w/cpp/utility/expected.html)，这一全新的词汇表类型，它为函数返回结果的处理提供了一种更加优雅、类型安全的解决方案。

`std::expected`是C++23标准库中的一个模板类，定义于头文件`<expected>`中。它提供了一种方式来表示两个值之一：类型`T`的期望值，或类型`E`的非期望值。`std::expected`永远不会是无值的。

```
template< class T, class E >
class expected;
(1)	(since C++23)
template< class T, class E >
    requires std::is_void_v<T>
class expected<T, E>;
```

类模板 std::expected 提供了一种表示两种值的方式：类型为 T 的预期值或类型为 E 的意外值。预期值永远不会是无值的。

1. 主模板。在其自身的存储空间中包含预期值或意外值，该存储空间嵌套在预期对象中。
2. void 部分特化。表示预期 void 值或包含意外值。如果包含意外值，则嵌套在预期对象中。  
   如果程序使用引用类型、函数类型或 std::unexpected 的特化来实例化预期值，则程序格式错误。此外，T 不能是 std::in\_place\_t 或 std::unexpect\_t。

模板参数

T - 预期值的类型。该类型必须是（可能为 cv 限定的）`void`，或者满足[Destructible](https://en.cppreference.com/w/cpp/named_req/Destructible.html)即可析构性要求（特别是，不允许使用数组和引用类型）。

E - 意外值的类型。该类型必须满足`Destructible`要求，并且必须是 std::unexpected 的有效模板参数（特别是，不允许使用数组、非对象类型和 cv 限定的类型）。

通过`has_value()`方法检查`std::expected`对象是否包含期望值，并根据结果进行相应的处理。

**优势分析**：

•[**链式调用**](https://zhida.zhihu.com/search?content_id=255204675&content_type=Article&match_order=1&q=%E9%93%BE%E5%BC%8F%E8%B0%83%E7%94%A8&zhida_source=entity)：通过`and_then`串联操作，逻辑清晰，代码更具声明式风格。

•**性能高效**：避免了异常抛出的运行时开销，错误处理在编译时优化。

•**类型安全**：成功值和错误信息统一封装在`std::expected`中，调用者处理更直观。

### 底层原理

#### Expected的ABI布局优化

`std::expected<T, E>`的内存布局经过精心设计，以最小化空间开销。它通常采用tagged union的形式，仅在必要时存储错误信息。根据GCC 13.2的实现，`std::expected<int, std::string>`的内存占用为16字节（4字节int + 8字节std::string + 4字节tag），而`std::variant<int, std::string>`为24字节（因padding增加额外空间）。通过`sizeof`运算符测量，这一优化节省了约33%的内存，特别适合资源受限的嵌入式环境。

#### [零开销抽象](https://zhida.zhihu.com/search?content_id=255204675&content_type=Article&match_order=1&q=%E9%9B%B6%E5%BC%80%E9%94%80%E6%8A%BD%E8%B1%A1&zhida_source=entity)：编译器如何消除`and_then`的运行时开销

`std::expected`的`and_then`方法利用模板和内联展开，实现了零开销抽象。以如下代码为例：

![](../../资源/图片/yuque_785a7511dc57.png)

编译器在实例化时将其展开为：

![](../../资源/图片/yuque_6b383e3d7d70.png)

这种展开消除了函数调用和运行时多态的开销。使用Clang 15.0和`std::chrono`高精度计时测试，`and_then`链式调用的延迟仅为纳秒级，与手写的if-else分支性能相当。这一特性在高性能场景中尤为关键。

```
#include <cmath>
#include <expected>
#include <iomanip>
#include <iostream>
#include <string_view>
 
enum class parse_error
{
    invalid_input,
    overflow
};
 
auto parse_number(std::string_view& str) -> std::expected<double, parse_error>
{
    const char* begin = str.data();
    char* end;
    double retval = std::strtod(begin, &end);
 
    if (begin == end)
        return std::unexpected(parse_error::invalid_input);
    else if (std::isinf(retval))
        return std::unexpected(parse_error::overflow);
 
    str.remove_prefix(end - begin);
    return retval;
}
 
int main()
{
    auto process = [](std::string_view str)
    {
        std::cout << "str: " << std::quoted(str) << ", ";
        if (const auto num = parse_number(str); num.has_value())
            std::cout << "value: " << *num << '\n';
            // If num did not have a value, dereferencing num
            // would cause an undefined behavior, and
            // num.value() would throw std::bad_expected_access.
            // num.value_or(123) uses specified default value 123.
        else if (num.error() == parse_error::invalid_input)
            std::cout << "error: invalid input\n";
        else if (num.error() == parse_error::overflow)
            std::cout << "error: overflow\n";
        else
            std::cout << "unexpected!\n"; // or invoke std::unreachable();
    };
 
    for (auto src : {"42", "42abc", "meow", "inf"})
        process(src);
}
```

## 五、源码解析和实践感悟

### 1. expected 的 tagged union 实现

```c++
template<typename T, typename E>
class expected {
    union { T m_value; E m_error; };  // 互斥存储
    bool m_has_value;                  // 标志位
public:
    bool has_value() const { return m_has_value; }
    T& value() { if (!m_has_value) throw bad_expected_access(m_error); return m_value; }
    E& error() { return m_error; }
    // and_then/or_else: monadic 操作链式处理
};
```

### 实践经验
1. **expected<T,E> vs 异常**：expected 适合可预期的失败（文件不存在），异常适合意外失败
2. **monadic 操作**：and_then/or_else/transform 实现链式错误处理
3. **性能**：无异常抛出路径零开销，等价于返回 variant
4. **C++23 标准**：之前用 tl::expected 等第三方库
5. **void 偏特化**：`expected<void, E>` 只关心成功/失败

## 六、面试准备

### Q&A（10题）

**Q1: expected 和 optional 的区别？**
A: optional 只有有值/无值二态；expected 有值/错误二态，错误带信息

**Q2: expected 替代异常有什么优势？**
A: 错误处理显式化（函数签名体现）、无异常栈展开开销、适合禁用异常环境

**Q3: and_then 和 transform 的区别？**
A: and_then 返回 expected（可失败），transform 返回 T（总成功）

**Q4: expected 的内存布局？**
A: tagged union——值/错误共用存储 + bool 标志位

**Q5: C++23 前如何获取 expected？**
A: tl::expected、boost::outcome、自定义实现

**Q6: expected<void,E> 有什么用？**
A: 只表示操作成功或失败（类似 Result<(), Error>）

**Q7: value() 和 operator* 的区别？**
A: value() 无值时抛 bad_expected_access，operator* 无值时 UB

**Q8: expected 和 Rust Result 的关系？**
A: 直接灵感来源——C++ expected = Rust Result<T,E>

**Q9: 如何从 expected 中提取值并提供默认？**
A: `exp.value_or(default_val)` 无值时返回默认值

**Q10: expected 能被用在构造函数中吗？**
A: 不能直接——构造函数要么成功构造要么抛异常，可用工厂函数返回 expected

### 陷阱与反问（5个）
1. **陷阱**：`*exp` 不检查值是否存在→UB
2. **反问**：expected 会取代异常吗？→ 不会，互补——expected 预知失败，异常处理意外
3. **陷阱**：expected 的错误类型不支持继承层次→无法分类捕获
4. **反问**：函数返回值用 expected 还是抛异常？→ 可恢复错误用 expected，不可恢复用异常
5. **陷阱**：在 expected 的 transform 中抛异常→异常传播而非转为错误

### 一句话答案（8个）
1. **expected**：值或错误二态容器
2. **monadic**：and_then/or_else/transform 链式操作
3. **value_or**：带默认值的提取
4. **tagged union**：值/错误共用内存
5. **bad_expected_access**：无值时抛的异常类型
6. **C++23**：正式纳入标准库
7. **Result 模式**：Rust 风格的错误处理
8. **void 特化**：只表示成功/失败
