---
title: std__declval
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "模板与泛型"]
publish: true
---

# std::declval

> 适用范围：C++11 `std::declval`——编译期伪实例，用于在不构造对象的情况下获取类型信息。

## 一、核心概念

- **定义**：`std::declval` 是一个工具类型操作函数，定义在 `<utility>` 头文件中。它与 `std::move` 和 `std::forward` 等函数属于同一类别。其作用非常简单：为其类型模板参数添加右值引用。说白了，就是给定任何类型，返回其右值引用（会运用引用折叠规则），比如：
  - 输入 `int` 得到 `int &&`
  - 输入 `int &` 得到 `int &`
  - 输入 `int &&` 得到 `int &&`
- **关键词**：`std::declval`、未求值上下文（unevaluated context）、伪实例、`decltype`、引用折叠、SFINAE
- **适用场景/边界**：
  - 配合 `decltype` 推导成员函数返回类型
  - 类型萃取中检测成员是否存在（SFINAE）
  - `noexcept` 推导成员函数是否抛异常
  - 仅用于 `decltype`、`sizeof`、`typeid`、`noexcept` 四个未求值上下文；不可运行时调用

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：基本工作原理**

该函数的声明如下：

```c++
template<class T>
typename std::add_rvalue_reference<T>::type declval() noexcept;
```

该函数没有定义，因此无法直接调用。它只能用于未求值上下文（decltype、sizeof、typeid 和 noexcept）。这些是仅在编译期处理的上下文，不会在运行时求值。**std::declval 的目的是辅助类型推导，适用于没有默认构造函数，或存在默认构造函数但因其为私有或受保护而无法访问的类型**。

**第二层：关键步骤详解**

主要有两个作用：
- 将任意一个类型转换成右值引用类型
- **不必经过构造函数就能使用该类型的成员函数**

说人话就是在编译期中，需要一个值对象，但并不希望这个值对象被编译为一个二进制实体，那就用 declval 虚拟地构造一个，从而彷佛获得了一个临时对象，可以在该对象上施加操作，例如调用成员函数什么的，但既然是虚拟的，就不会真的存在这么个临时对象，所以称之为伪实例。

**我们常常并不真的直接需要 declval 求值求得的伪实例，更多的是需要借助于这个伪实例来求取到相应的类型描述，也就是 T。所以一般情况下 declval 之外往往包围着 decltype 计算，设法拿到 T 才是我们的真实目的。**

**第三层：底层机制**

关键设计：declval 只有声明无定义，调用时不会产生任何指令。编译器在未求值上下文（decltype/sizeof/noexcept）中只做类型推导，不会链接符号。

```c++
// add_rvalue_reference 的引用折叠逻辑
template<typename _Tp>
struct add_rvalue_reference {
    using type = _Tp&&;  // 一般类型返回右值引用
};
template<typename _Tp>
struct add_rvalue_reference<_Tp&> {
    using type = _Tp&;   // 左值引用输入 → 左值引用输出（折叠规则：T& && → T&）
};
template<typename _Tp>
struct add_rvalue_reference<_Tp&&> {
    using type = _Tp&&;  // 右值引用输入 → 右值引用输出
};
```

- **关键数据结构**：`add_rvalue_reference<T>::type`（引用折叠）
- **关键公式**：`decltype(std::declval<T>().method())` = 不构造 T 的情况下获取 method() 返回类型

## 三、动手实践（代码案例）

### 3.1 基本用法：推导返回类型

```c++
#include <iostream>

namespace {
  struct base_t { virtual ~base_t(){} };

  template<class T>
    struct Base : public base_t {
      virtual T t() = 0;
    };

  template<class T>
    struct A : public Base<T> {
      ~A(){}
      virtual T t() override { std::cout << "A" << '\n'; return T{}; }
    };
}

int main() {
  decltype(std::declval<A<int>>().t()) a{}; // = int a;
  decltype(std::declval<Base<int>>().t()) b{}; // = int b;
  std::cout << a << ',' << b << '\n';
}
```

**可以看到，`A<int>` 的伪实例能够"调用" A 的成员函数 t()，然后借助于 decltype 我们就可以拿到 t() 的返回类型，并用来声明一个具体的变量 a。因为 t() 的返回类型为 T，所以 main() 函数中的这条变量声明语句实际上等价于 `int a{};`。**

### 3.2 无默认构造函数的类型

```c++
class A{
public:
    double func() {}
};

using T = decltype(std::declval<A>()); // T的类型为A &&
using T = decltype(std::declval<A>().func()); // T的类型为double
```

正常情况下，要获得成员函数 `func` 的返回值类型，可以用 `decltype(A().func())`，即创建一个临时对象A，然后访问其成员变量，有两点不好：

1. **需要有构造函数和析构函数**。如果把构造函数delete掉，即 `A() = delete`，那上述表达式就会报错。如果析构函数为private，也会报错。
2. **需要知道构造函数的参数**。如果A的构造函数带有参数，那构造临时对象A时就需要传入参数。

### 3.3 SFINAE 检测成员函数

```c++
// 用 declval 检测类型是否有 size() 方法
template<typename T, typename = void>
struct has_size : std::false_type {};

template<typename T>
struct has_size<T, std::void_t<decltype(std::declval<T>().size())>> 
    : std::true_type {};
```

### 3.4 汇编验证：无运行时开销

```c++
struct NoDefault {
    NoDefault() = delete;
    int value() const { return 42; }
};

// decltype(std::declval<NoDefault>().value()) x = 0;
// 编译结果：mov DWORD [rbp-4], 0   （没有构造 NoDefault 的任何指令）
```

## 四、进阶应用（≥500字）

### 其他注意事项

`decltype(func(args...))`：int类型，即myfunc()函数的返回类型；`decltype(func)`：int (\*)(int,int)类型，显然这是一个函数指针类型。**可变参数 `...` 应该放在哪？** `...` 出现的几种场景：

1. template
2. auto TestFuncRtn(F func, Args... args)
3. std::declval()(std::declval()...)
4. decltype(func(args...))
5. sizeof...(Args)

可以简单理解为，后面都将重复 `...` 前面的内容，比如：`std::declval()(std::declval()...)` 可以理解为 `std::declval()(std::declval(), std::declval())`。

### 与其他主题的关联

- **decltype**：declval 几乎总是配合 decltype 使用，单独无意义
- **SFINAE/void_t**：配合检测成员函数/成员类型是否存在
- **引用折叠**：declval 通过 `add_rvalue_reference` 实现引用折叠规则
- **noexcept 推导**：`noexcept(std::declval<T>().foo())` 可在编译期检测成员函数是否抛异常
- **变参模板展开**：`std::declval<Args>()...` 在折叠表达式和参数包展开中充当类型占位

### 常见陷阱

- **普通表达式中使用 declval**：编译通过但链接失败（undefined reference）
- **decltype(declval<T>().foo()) 当 foo 返回引用时**：推导出引用类型，需用 remove_reference 剥离
- **decltype(declval<const T>().foo())**：T 的 const 版本 foo 可能不存在，SFINAE 需双版本测试

## 五、源码解析和实践感悟（≥1000字）

### 1. declval 的标准实现

```c++
// C++11 标准库实现（只有声明，没有定义）
template<typename _Tp>
typename std::add_rvalue_reference<_Tp>::type declval() noexcept;

// add_rvalue_reference 的引用折叠逻辑
template<typename _Tp>
struct add_rvalue_reference {
    using type = _Tp&&;  // 一般类型返回右值引用
};
template<typename _Tp>
struct add_rvalue_reference<_Tp&> {
    using type = _Tp&;   // 左值引用输入 → 左值引用输出（折叠规则：T& && → T&）
};
template<typename _Tp>
struct add_rvalue_reference<_Tp&&> {
    using type = _Tp&&;  // 右值引用输入 → 右值引用输出
};
```

关键设计：declval 只有声明无定义，调用时不会产生任何指令。编译器在未求值上下文（decltype/sizeof/noexcept）中只做类型推导，不会链接符号。

### 2. 伪实例机制的实际汇编验证

```c++
struct NoDefault {
    NoDefault() = delete;
    int value() const { return 42; }
};

// decltype(std::declval<NoDefault>().value()) x = 0;
// 编译结果：mov DWORD [rbp-4], 0   （没有构造 NoDefault 的任何指令）
```

`std::declval<NoDefault>()` 只是编译期占位符——它让编译器"假装"有一个 NoDefault 对象，从而能推断 `.value()` 的返回类型，但运行时不会有任何构造函数调用。

### 3. 与 SFINAE 的经典配合

```c++
// 用 declval 检测类型是否有 size() 方法
template<typename T, typename = void>
struct has_size : std::false_type {};

template<typename T>
struct has_size<T, std::void_t<decltype(std::declval<T>().size())>> 
    : std::true_type {};

// declval 在这里"虚拟"调用了 T::size()，仅用于推导返回类型
```

### 实践经验

1. **不可实例化类型**：有 deleted 构造函数或纯虚函数的类，只能用 declval 在编译期获取其成员类型
2. **与 decltype 强绑定**：declval 几乎总是配合 decltype 使用，单独无意义
3. **noexcept 推导**：`noexcept(std::declval<T>().foo())` 可在编译期检测成员函数是否抛异常
4. **变参模板展开**：`std::declval<Args>()...` 在折叠表达式和参数包展开中充当类型占位
5. **注意**：declval 返回引用，对于返回引用的成员函数 `decltype(declval<T>().ref_func())` 得到左值引用
6. **替代方案**：`decltype(T{})` 可用但需要完整类型和可访问构造函数，declval 更通用

## 六、面试准备

### Q&A（8题）

**Q1: std::declval 是什么？**
A: 一个无定义的模板函数，返回类型的右值引用，只能用于未求值上下文（decltype/sizeof/noexcept）

**Q2: 为什么 declval 只有声明没有定义？**
A: 它只是编译期的类型工具，运行时不应该被调用。没有定义意味着链接阶段会报错，防止误用

**Q3: declval 和 decltype(T{}) 的区别？**
A: declval<T>() 返回 T&&，不需要构造函数；T{} 需要可访问的默认构造函数，且返回 T 而非引用

**Q4: declval 如何支持"没有默认构造函数的类型"？**
A: declval 不实际构造对象，只是告诉编译器"假设有这样一个值，它的类型是什么"

**Q5: decltype(declval<T>().foo()) 与 decltype(T().foo()) 的区别？**
A: 前者不调构造/析构，后者语义上需要构造临时对象，若构造被 delete 则编译失败

**Q6: add_rvalue_reference 引用折叠规则？**
A: T → T&&，T& → T&（T& && 折叠为 T&），T&& → T&&

**Q7: declval 可以用于运行时吗？**
A: 不可以。它是未求值操作数，只能在编译期使用；若尝试链接会报 undefined reference

**Q8: declval 在 SFINAE 中的角色？**
A: 配合 decltype 和 void_t，在模板推导阶段检测成员函数/成员类型是否存在，不存在则 SFINAE 移除候选

### 陷阱与反问（5个）

1. **陷阱**：在普通表达式中使用 declval — 编译通过但链接失败（undefined reference）
2. **反问**：declval 和 move 有什么本质区别？→ move 是运行时操作返回右值引用，declval 纯粹是编译期类型工具
3. **陷阱**：`decltype(declval<T>().foo())` 当 foo 返回引用时推导出引用类型 — 需用 remove_reference 剥离
4. **反问**：能否用 declval 替代真实对象做函数参数？→ 不能，只能用于 decltype/sizeof/noexcept 四个上下文
5. **陷阱**：`decltype(declval<const T>().foo())` — T 的 const 版本 foo 可能不存在，SFINAE 需双版本测试

### 一句话答案（5个）

1. **declval 本质**：编译期伪实例，用于在不构造对象的情况下获取类型信息
2. **核心用途**：配合 decltype 推导成员函数返回类型
3. **为什么不能调用**：没有函数体，链接阶段会报 undefined reference
4. **与 T{} 的区别**：declval 不要求构造函数、不生成任何运行时代码
5. **适用场景**：模板元编程、SFINAE、类型萃取、noexcept 推导
