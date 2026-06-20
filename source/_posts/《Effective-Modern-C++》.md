---
title: 《Effective Modern C++》
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "现代C++特性"]
publish: true
---

# 《Effective Modern C++》

> 适用范围：《Effective Modern C++》核心条款笔记——C++11/14 最佳实践。

参考：[https://zhuanlan.zhihu.com/p/592921281](https://zhuanlan.zhihu.com/p/592921281)

## 一、核心概念

- **定义**：Scott Meyers 著的《Effective Modern C++》总结了 C++11/14 时代的 42 个最佳实践条款，涵盖类型推导、auto、智能指针、移动语义、lambda 表达式等核心主题。
- **关键词**：`nullptr`、`using` vs `typedef`、`auto`、`decltype`、移动语义、智能指针、lambda
- **适用场景/边界**：C++11/14 项目的最佳实践参考

## 二、详细解析（≥200字）

### 核心条款分类

类型推导（Item 1-4）、auto（Item 5-6）、现代 C++ 特性（Item 7-17）、智能指针（Item 18-22）、移动语义与完美转发（Item 23-30）、lambda 表达式（Item 31-34）、并发 API（Item 35-40）、微调（Item 41-42）。

### 三层递进

**第一层**：`nullptr` 替代 0/NULL，`using` 替代 `typedef`
**第二层**：理解引用折叠与完美转发
**第三层**：移动语义的对象生命周期管理

## 三、动手实践（代码案例）

## 四、进阶应用（≥500字）

### **优先使用** `nullptr` **，而不是 0 或** `NULL`

`nullptr` 是 C++11 引入的纯右值，其类型为 `nullptr_t` ，可以隐式转换为任何指针类型。

因此，相比 0 和 `NULL` ， `nullptr_t` 可以避免调用到接受其他类型形参的函数重载版本。

```
void f(int);
void f(bool);
void f(void*);

f(0);       // 调用 f(int)
f(NULL);    // 在大部分编译器下编译失败
f(nullptr); // 调用 f(void*)
```

### **优先使用**`using`**，而不是**`typedef`

1. `using` 可读性更好

```
typedef void (*FP)(int, const std::string&);
using FP = void (*)(int, const std::string&);
```

1. `using` 支持模板化，但 `typedef` 不支持

```
template<class T>
struct Alloc {};
template<class T>
using Vec = vector<T, Alloc<T>>; // type-id is vector<T, Alloc<T>>
Vec<int> v; // Vec<int> is the same as vector<int, Alloc<int>>
```

1. `using` 模板可以避免 `::type` 后缀，同时也不需要考虑模板内带依赖类型的 `typename` 前缀；C++14 正是在 type traits 中引入了 `using` ，使其语法友好了很多

```
std::remove_const<T>::type // C++11
std::remove_const_t<T>     // C++14
```

### **优先使用**`enum class`**，而不是**`enum`

1. `enum class` 可以避免 `enum` 带来的命名空间污染

```
enum Color { red, green, blue };
auto red = false; // Compile error，enum Color 污染了当前的命名空间

enum class Color { red, green, blue };
Color c1 = red;        // Compile error
Color c2 = Color::red; // OK
auto  c3 = Color::red; // OK
```

1. `enum class` 不能隐式转换为其他类型

```
enum Color { red, green, blue };
Color c = red;
if (c < 11.4); // OK

enum class Color { red, green, blue };
Color c = Color::red;
if (c < 11.4) {} // Compile error
```

1. `enum class` 的默认底层类型是 `int` ，而 `enum` 没有默认底层类型（节省空间） 这意味 `enum` 仅在指定底层类型的情况下才可以进行前置声明；同时默认情况下，若 `enum` 的定义发生扩充（例如新增了一个枚举）， `enum` 的底层类型就可能会改变，依赖到 `enum` 的编译单元都需要重新编译了

### **为需要改写的函数都显式添加**`override`**声明**

发生函数重载是需要一些条件的：

* 函数名称相同
* 形参类型相同
* 常量性相同
* 返回值和异常类型可兼容
* 函数引用限定符（C++11，用于限制函数仅用于左值或右值）相同

在编写重写的函数时，可能会因为某些条件没有满足导致没有真正重写（有可能发生 function shadowing），这时候加上 `override` 就能让编译器产生错误信息了。

### **确定函数不会异常后，可以加上**`noexcept`**声明**

1. 加上 `noexcept` 声明有利于函数编译器更好地优化代码
2. 编写类的移动构造函数时，加上 `noexcept` 声明可以在其作为 `vector` 等容器的元素时，在容器发生 resize 的情况下，将元素的复制操作替换成低成本的移动操作
3. 大部分函数是异常中立的，函数本身不抛出异常，但其调用的函数不保证不产生异常（在我们的业务代码中，涉及 RPC 调用的代码基本都属于这种情况，可能只有少部分工具类代码可保证不产生异常）

### **优先使用**`constexpr`**，而不是**`const`

`constexpr` 是 C++11 引入的编译期常量表达式的修饰符，相比而言 `const` 则仅保证某个变量在运行时保持不变。具备编译期可知的特性之后，用 `constexpr` 修饰的变量就可以用于标识数组大小、switch case label 等场景了。

### **使用**`std::function`**代替函数指针**

`std::function` 是 C++11 标准库中的一个模板，将函数指针的思想推广为任何的可调用对象（即重载了 `()` 操作符的对象）。相比函数指针，其适用性更广，代码可读性也更好，还可以跟 `std::bind` 、 `absl::bind_front` 、 [**Lambda 表达式**](https://link.zhihu.com/?target=https%3A//en.cppreference.com/w/cpp/language/lambda)等特性结合。

### **使用**`chrono`**时间工具库**

[**chrono**](https://link.zhihu.com/?target=https%3A//en.cppreference.com/w/cpp/chrono) 时间工具库相比 `std::time` 不管是从表达力还是从易用性上都好很多，[**chrono\_literals**](https://link.zhihu.com/?target=https%3A//en.cppreference.com/w/cpp/chrono/duration%23Literals) 的加入更是让代码可读性更上一个台阶。日常业务开发中我们时常会有计算某段子例程执行时间的需求，这时候用 chrono 就很合适。

### 减少函数代码的方法：重写

使用const\_cast<> 重写const 版本的函数 直接转换

使用constexpr 常量表达式 在传入非常量时可以自动退化 不用重写普通版本

### **C/C++ 宏中 `do { ... } while (0)` 的“零次循环”技巧**

#### `do { ... } while (0)`

把宏体包装在 **单次执行的 do-while 循环** 中：

```
#define FOO(x) \
    do { stmt1; stmt2; } while (0)
```

* **语义**：循环体只执行一次，与 `if/else`、`for`、`while` 等结构无缝衔接。
* **语法**：`do { ... } while (0);` 末尾自带分号，用户正常写 `FOO(x);` 即可通过编译。

1. 宏体含多条语句、内部变量定义或需要“单语句”语义时，**务必**使用 `do { ... } while (0)`。
2. 对于只含一条表达式的宏，可省略此技巧，但保持一致性亦可保留。
3. 现代 C++ 推荐用 `inline` 函数或模板替代宏；若必须用宏，则遵循此范式。

### 在访问[c++ variant](https://zhida.zhihu.com/search?content_id=239665199&content_type=Article&match_order=1&q=c%2B%2B+variant&zhida_source=entity)的时候记得避开std::get，因为会抛异常。

在访问[c++ variant](https://zhida.zhihu.com/search?content_id=239665199&content_type=Article&match_order=1&q=c%2B%2B+variant&zhida_source=entity)的时候记得避开std::get，因为会抛异常。如果你的编译器够新的话就用std::visit，如果比较旧就用[std::get\_if](https://zhida.zhihu.com/search?content_id=239665199&content_type=Article&match_order=1&q=std%3A%3Aget_if&zhida_source=entity)，因为有些旧编译器对std::visit的编译优化不够好。

## 五、源码解析和实践感悟

### 1. 类型推导规则速查

```c++
// Item 1-2: auto 推导 = 模板参数推导（除了 initializer_list）
auto x = 42;   // int
auto y = {42}; // std::initializer_list<int>（auto 特有规则）
auto z{42};    // int (C++17), std::initializer_list<int> (C++14)

// Item 3: decltype 保留引用
int a = 1;
decltype(a) b = a;  // int
decltype((a)) c = a; // int& (注意括号)
```

### 2. 现代 C++ 关键实践

```c++
// Item 14: noexcept 是移动语义的保证
// vector::push_back 检测 noexcept 移动 → memmove 优化

// Item 23: 移动优于拷贝，但不能盲目
Widget w2 = std::move(w1); // w1 被"掏空"但仍可析构/赋新值
```

### 实践经验
1. **auto&& 万能引用**：`for (auto&& x : range)` 适配任何值类型
2. **override 关键字的必要性**：防止拼写错误导致未覆盖基类虚函数
3. **nullptr 替代 0/NULL**：避免重载决议选择 int 而非指针版本
4. **enum class 替代 enum**：强类型枚举防止隐式转换
5. **=delete 替代 private 不实现**：更清晰的错误消息

## 六、面试准备

### Q&A（10题）

**Q1: 这本书讲了什么？**
A: 42 个条款覆盖 C++11/14 最佳实践：类型推导、auto、智能指针、移动语义、lambda、并发

**Q2: auto 唯一的特殊规则是什么？**
A: `auto x = {1,2,3}` 推导为 initializer_list，模板推导不这样做

**Q3: 什么时候用 decltype(auto)？**
A: 完美转发返回值，保留引用性质：`decltype(auto) f() { return x; }`

**Q4: unique_ptr 为什么比 shared_ptr 更优先？**
A: 零开销（大小等于裸指针），独占所有权语义清晰，可转为 shared_ptr

**Q5: 如何避免 lambda 的悬垂引用？**
A: 用 init capture 移动捕获：`[v = std::move(local)] { use(v); }`

**Q6: 完美转发失败的场景？**
A: 大括号初始化器、0/NULL 作为空指针、位域、重载函数名/模板名

**Q7: const T&& 有用吗？**
A: 几乎没用，const 右值引用绑定 const 右值，但无法移动（const 不可修改）

**Q8: 为什么用 emplace_back 而非 push_back？**
A: 直接构造而非构造临时对象+移动，节省一次构造

**Q9: Pimpl 和 unique_ptr 的析构问题？**
A: Pimpl 在 .h 中用 unique_ptr 声明，在 .cpp 中实现析构，需要完整类型定义

**Q10: 引用折叠的规则？**
A: & + & = &; & + && = &; && + & = &; && + && = &&. 只有全都是 && 时才折叠为 &&

### 陷阱与反问（5个）
1. **陷阱**：`auto x = {1,2}` → initializer_list，`auto x{1}`→int (C++17)，规则不一致
2. **反问**：Effective 系列过时了吗？→ 核心原则不变，但需要关注 C++17/20 更新
3. **陷阱**：万能引用 `T&&` 匹配一切，需要 SFINAE/requires 约束
4. **反问**：现代 C++ 的核心是什么？→ 类型安全 + 资源安全 + 性能 = auto + 智能指针 + 移动语义
5. **陷阱**：默认移动操作如果成员有 deleted 移动→不会自动生成

### 一句话答案（8个）
1. **auto 推导**：模板推导 + initializer_list 特例
2. **decltype**：保留引用/const，`((x))` 得引用
3. **nullptr**：永远用 nullptr，不用 0/NULL
4. **override**：显式覆盖，防止拼写错误
5. **enum class**：强类型枚举，不隐式转换
6. **=delete**：显式禁止，比 private 方案好
7. **完美转发**：万能引用 + forward
8. **Pimpl**：编译防火墙，隐藏实现细节
