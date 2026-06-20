---
title: std__invoke
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "现代C++特性"]
publish: true
---

# std::invoke

> 适用范围：C++17 std::invoke统一调用语法、INVOKE协议、函数对象调用、成员指针调用

## 一、核心概念

- **定义**：`std::invoke` 是 C++17 引入的统一调用机制，基于 INVOKE 协议。它能统一处理普通函数、成员函数指针、成员变量指针、函数对象(lambdas/functors)的调用，无需区分语法形式
- **关键词**：INVOKE协议、统一调用语法、成员指针调用、函数对象、ADL、名字查找
- **适用场景/边界**：
  - 泛型库中统一调用各种可调用对象（std::visit、std::thread内部使用）
  - 替代手写区分 `(obj.*pmf)(args...)` / `f(args...)` 的模板代码
  - 与 `std::is_invocable` 等类型萃取配合进行编译期检查

## 二、详细解析（≥200字）

### 2.1 函数调用的解析过程

一次 **C++ 函数调用**（含普通函数、成员函数、运算符重载、构造函数等）的大致流水线是：

1. **名字查找（name lookup）** ➜ 找到可能的候选（含**未限定查找**与 **ADL**）。
2. **构建候选集* ➜ 普通函数 + 模板函数 + 成员函数/隐式对象参数 + 内置运算符/用户自定义运算符。
3. **模板实参推导（TAD）/类模板推导（CTAD）** ➜ 形成具体候选。
4. **可行性检查** ➜ 形参与实参是否能匹配（含默认实参、可访问性、=delete、显式/隐式转换、cv/ref 限定等）。
5. **重载决议（overload resolution）** ➜ 以"转换序列优劣"与"部分特化/偏序"等规则选出**最佳可行函数**；否则二义性或无匹配报错。
6. **动态派发（若是虚函数）** ➜ 运行期根据动态类型选择最终版本。

### 2.2 std::invoke 的 INVOKE 协议

`std::invoke` 的 INVOKE 协议规定：
- `INVOKE(f, t1, t2, ..., tN)` ≡ `f(t1, t2, ..., tN)` — 普通函数/函数对象
- `INVOKE(pmf, t1, args...)` ≡ `(t1.*pmf)(args...)` — 成员函数指针
- `INVOKE(pmd, t1)` ≡ `t1.*pmd` — 成员变量指针

当 t1 是指针时用 `->*` 替代 `.*`。`std::invoke` 自动处理智能指针的解引用。

### 2.3 ADL（Argument-Dependent Lookup）

ADL是C++中的一种查找规则：当使用函数模板时，编译器会根据函数调用中的实参类型，从命名空间中查找与这些实参相关的函数模板。

ADL的查找规则如下：
1. 编译器首先在函数模板所在的命名空间中查找匹配的函数模板
2. 如果找不到，编译器会到函数调用所在的作用域中查找
3. 如果还找不到，编译器会到实参类型所对应的命名空间中查找
4. 如果最终找不到，编译器会报错

ADL的主要作用是允许函数模板在不同的命名空间中定义，而不需要使用全局命名空间或限定作用域。例如，STL中的算法函数模板就定义在std命名空间中，但可以在其他命名空间中使用，因为使用了ADL。

## C++ 函数调用的解析过程

一次 **C++ 函数调用**（含普通函数、成员函数、运算符重载、构造函数等）的大致流水线是：

1. **名字查找（name lookup）** ➜ 找到可能的候选（含**未限定查找**与 **ADL**）。
2. **构建候选集** ➜ 普通函数 + 模板函数 + 成员函数/隐式对象参数 + 内置运算符/用户自定义运算符。
3. **模板实参推导（TAD）/类模板推导（CTAD）** ➜ 形成具体候选。
4. **可行性检查** ➜ 形参与实参是否能匹配（含默认实参、可访问性、=delete、显式/隐式转换、cv/ref 限定等）。
5. **重载决议（overload resolution）** ➜ 以“转换序列优劣”与“部分特化/偏序”等规则选出**最佳可行函数**；否则二义性或无匹配报错。
6. **动态派发（若是虚函数）** ➜ 运行期根据动态类型选择最终版本。

[C++函数调用的解析过程 - \_Sylvan - 博客园](https://www.cnblogs.com/sprinining/p/19066316#c-%E5%87%BD%E6%95%B0%E8%B0%83%E7%94%A8%E7%9A%84%E8%A7%A3%E6%9E%90%E8%BF%87%E7%A8%8B)

ADL:<https://zhuanlan.zhihu.com/p/617189501>

[ADL](https://zhida.zhihu.com/search?content_id=225284260&content_type=Article&match_order=1&q=ADL&zhida_source=entity)（[Argument-dependent lookup](https://zhida.zhihu.com/search?content_id=225284260&content_type=Article&match_order=1&q=Argument-dependent+lookup&zhida_source=entity)，也称为[Koenig查找](https://zhida.zhihu.com/search?content_id=225284260&content_type=Article&match_order=1&q=Koenig%E6%9F%A5%E6%89%BE&zhida_source=entity)）是C++中的一种查找规则，用于在调用[函数模板](https://zhida.zhihu.com/search?content_id=225284260&content_type=Article&match_order=1&q=%E5%87%BD%E6%95%B0%E6%A8%A1%E6%9D%BF&zhida_source=entity)时确定模板参数的类型。当使用函数模板时，编译器会根据函数调用中的实参类型，从[命名空间](https://zhida.zhihu.com/search?content_id=225284260&content_type=Article&match_order=1&q=%E5%91%BD%E5%90%8D%E7%A9%BA%E9%97%B4&zhida_source=entity)中查找与这些实参相关的函数模板。

ADL的查找规则如下：

1. 编译器首先在函数模板所在的命名空间中查找匹配的函数模板。
2. 如果在函数模板所在的命名空间中找不到匹配的函数模板，则编译器会到函数调用所在的作用域中查找匹配的函数模板。
3. 如果在函数调用所在的作用域中也找不到匹配的函数模板，则编译器会到实参类型所对应的命名空间中查找匹配的函数模板。
4. 如果在实参类型所对应的命名空间中也找不到匹配的函数模板，则编译器会报错。

ADL的主要作用是允许函数模板在不同的命名空间中定义，而不需要使用全局命名空间或限定作用域。例如，STL中的算法函数模板就定义在std命名空间中，但可以在其他命名空间中使用，因为使用了ADL。

需要注意的是，ADL只适用于函数模板的名称查找，不适用于[类模板](https://zhida.zhihu.com/search?content_id=225284260&content_type=Article&match_order=1&q=%E7%B1%BB%E6%A8%A1%E6%9D%BF&zhida_source=entity)、[成员函数模板](https://zhida.zhihu.com/search?content_id=225284260&content_type=Article&match_order=1&q=%E6%88%90%E5%91%98%E5%87%BD%E6%95%B0%E6%A8%A1%E6%9D%BF&zhida_source=entity)或其他类型的模板。如果要使用其他类型的模板，需要使用限定作用域或全局命名空间。

当使用函数模板时，编译器需要在当前作用域和相关命名空间中查找匹配的函数模板，并根据实参类型推导出模板参数类型，这个过程就称为模板名称查找。如果找到了匹配的函数模板，则可以进行[模板实例化](https://zhida.zhihu.com/search?content_id=225284260&content_type=Article&match_order=1&q=%E6%A8%A1%E6%9D%BF%E5%AE%9E%E4%BE%8B%E5%8C%96&zhida_source=entity)并调用对应的函数。

`std::invoke` 是 [C++17](https://zhida.zhihu.com/search?content_id=228390243&content_type=Article&match_order=1&q=C%2B%2B17&zhida_source=entity)标准库中引入的一个[函数模板](https://zhida.zhihu.com/search?content_id=228390243&content_type=Article&match_order=1&q=%E5%87%BD%E6%95%B0%E6%A8%A1%E6%9D%BF&zhida_source=entity)，用于统一地调用[可调用对象](https://zhida.zhihu.com/search?content_id=228390243&content_type=Article&match_order=1&q=%E5%8F%AF%E8%B0%83%E7%94%A8%E5%AF%B9%E8%B1%A1&zhida_source=entity)（函数、函数指针、[成员函数指针](https://zhida.zhihu.com/search?content_id=228390243&content_type=Article&match_order=1&q=%E6%88%90%E5%91%98%E5%87%BD%E6%95%B0%E6%8C%87%E9%92%88&zhida_source=entity)、[仿函数](https://zhida.zhihu.com/search?content_id=228390243&content_type=Article&match_order=1&q=%E4%BB%BF%E5%87%BD%E6%95%B0&zhida_source=entity)等）。它解决了在 C++ 中调用可调用对象的一致性和灵活性问题。  
  
在之前的 C++ 版本中，要调用不同类型的可调用对象，需要使用不同的语法，例如使用函数调用运算符 () 来调用函数或函数指针，使用成员访问运算符 -> 或 . 来调用成员函数。这样的语法差异导致了代码的冗余和不一致，给编写和维护代码带来了困扰。  
  
`std::invoke` 的引入就是为了解决这个问题，它提供了一种统一的调用语法，无论是调用函数、函数指针、成员函数指针还是仿函数，都可以使用相同的方式进行调用。

`std::invoke` 的语法如下：

```
template <typename Fn, typename... Args>
decltype(auto) invoke(Fn&& fn, Args&&... args);
```

它接受一个可调用对象 fn 和相应的参数 args...，并返回调用结果。使用方法如下:

```
#include <iostream>
#include <functional>

struct Foo {
    int add(int a, int b) {
        return a + b;
    }
};

int multiply(int a, int b) {
    return a * b;
}

int main() {
    Foo foo;

    // 使用 std::invoke 调用成员函数
    int result1 = std::invoke(&Foo::add, foo, 3, 4);
    std::cout << "Result 1: " << result1 << std::endl;  // 输出: Result 1: 7

    // 使用 std::invoke 调用自由函数
    int result2 = std::invoke(multiply, 3, 4);
    std::cout << "Result 2: " << result2 << std::endl;  // 输出: Result 2: 12
    
    
    int result3=std::invoke([](int a,int b){ return a+b;},519,1);
    
    std::cout<<"result3: "<<result3<<'\n';
    return 0;
}
```

通过 `std::invoke`，我们可以在不关心可调用对象的具体类型的情况下进行调用，提高了代码的灵活性和可读性。它尤其适用于泛型编程中需要以统一方式调用各种可调用对象的场景，例如使用函数指针或成员函数指针作为模板参数的算法或容器等。  
  
另外，`std::invoke` 还考虑了完美转发的问题，可以正确地将参数转发给可调用对象，并返回适当的引用类型。  
  
所以这就是个语法糖，可以让你的代码看起来风格统一，更易于维护，但是真的是这样吗，也没有多易懂啊？不就是把调用方式统一了吗？当然没这么简单。他还支持多态：

```
#include <iostream>
#include <functional>

class Shape {
public:
    virtual void draw() const = 0;
};

class Circle : public Shape {
public:
    void draw() const override {
        std::cout << "Drawing a circle." << std::endl;
    }
};

class Square : public Shape {
public:
    void draw() const override {
        std::cout << "Drawing a square." << std::endl;
    }
};

int main() {
    Circle circle;
    Square square;

    Shape* shape1 = &circle;
    Shape* shape2 = &square;

    // 使用 std::invoke 多态调用 draw 函数
    std::invoke(&Shape::draw, shape1);  // 输出: Drawing a circle.
    std::invoke(&Shape::draw, shape2);  // 输出: Drawing a square.

    return 0;
}
```

我们定义了一个基类 `Shape`，并派生了两个子类 `Circle` 和 `Square`。这些类都实现了 `draw` 函数。然后，我们使用指针将 `circle` 和 `square` 对象转换为基类指针，并使用 `std::invoke` 多态调用了 `draw` 函数。通过 `std::invoke`，我们可以在运行时选择不同的子类对象，并以统一的方式调用其虚函数。在使用 `std::invoke` 进行多态调用时，需要确保函数指针或成员指针的类型与基类中的虚函数匹配，以正确调用派生类的函数。也就是多态实现的必要条件他会根据基类指针指向的实际类型去对应虚表里面找。

在网上找到一份源码：

```
template <typename F, typename T, typename... Args>
decltype(auto) invoke(F&& f, T&& t, Args&&... args) {
    if constexpr (std::is_member_function_pointer_v<std::remove_reference_t<F>>) {
        if constexpr (std::is_base_of_v<std::remove_reference_t<F>, std::remove_reference_t<T>>) {
            return (std::forward<T>(t).*f)(std::forward<Args>(args)...);
        } else {
            return ((*std::forward<T>(t)).*f)(std::forward<Args>(args)...);
        }
    } else if constexpr (std::is_member_object_pointer_v<std::remove_reference_t<F>>) {
        if constexpr (std::is_base_of_v<std::remove_reference_t<F>, std::remove_reference_t<T>>) {
            return std::forward<T>(t).*f;
        } else {
            return (*std::forward<T>(t)).*f;
        }
    } else {
        return std::forward<F>(f)(std::forward<T>(t), std::forward<Args>(args)...);
    }
}
```

还是挺复杂的，使用了很多[RTTI](https://zhida.zhihu.com/search?content_id=228390243&content_type=Article&match_order=1&q=RTTI&zhida_source=entity)特性，还有[条件编译](https://zhida.zhihu.com/search?content_id=228390243&content_type=Article&match_order=1&q=%E6%9D%A1%E4%BB%B6%E7%BC%96%E8%AF%91&zhida_source=entity)，都是新特性，用于判断传入的是什么类型，比如成员函数肯定得和普通函数分开，通过上面使用，毕竟参数都不一样，调用成员函数第二个参数是对象，但是发现没有？这货在进行判断的时候会区分两种对象

* `std::is_member_function_pointer_v<std::remove_reference_t<F>>`
* `std::is_member_object_pointer_v<std::remove_reference_t<F>>y` 、

一是成员函数指针，指向成员函数，然后判断是否基类，判断是否多态调用，二是成员对象指针，要知道成员函数和成员对象是不一样的（函数不占内存什么的）,也就是说，我们可以做这样的事：

```
#include <iostream>
#include <functional>

class MyClass {
public:
    int memberVariable = 10;
    void memberFunction() {
        std::cout << "Member function called!" << std::endl;
    }
};

int main() {
    MyClass obj;

    // 使用 std::invoke 调用成员函数指针
    void (MyClass::*funcPtr)() = &MyClass::memberFunction;
    std::invoke(funcPtr, obj);

    // 使用 std::invoke 访问成员对象指针
    int MyClass::*varPtr = &MyClass::memberVariable;
    int value = std::invoke(varPtr, obj);

    std::cout << "Value: " << value << std::endl;

    return 0;
}
```

## 三、动手实践（代码案例）

[C++函数调用的解析过程 - _Sylvan - 博客园](https://www.cnblogs.com/sprinining/p/19066316#c-%E5%87%BD%E6%95%B0%E8%B0%83%E7%94%A8%E7%9A%84%E8%A7%A3%E6%9E%90%E8%BF%87%E7%A8%8B)

ADL:<https://zhuanlan.zhihu.com/p/617189501>

上述各节和五中的代码示例已涵盖 std::invoke 的核心用法。INVOKE 协议支持：(1) `invoke(f, args...)` = `f(args...)`；(2) `invoke(pmf, obj, args...)` = `(obj.*pmf)(args...)`；(3) `invoke(pmd, obj)` = `obj.*pmd`。智能指针和引用包装器自动解引用。

## 四、进阶应用（≥500字）

### 4.1 std::invoke 在标准库中的应用

- **std::visit**：内部使用 INVOKE 协议调用访问器
- **std::thread**：构造函数使用 INVOKE 在新线程中调用可调用对象
- **std::function**：内部使用 INVOKE 协议实现类型擦除调用
- **std::bind**：绑定参数的 `operator()` 基于 INVOKE 协议

### 4.2 与其他主题的关联

- **std::is_invocable<T, Args...>** (C++17)：编译期检查类型是否可通过 INVOKE 协议调用
- **std::invoke_result<T, Args...>** (C++17)：获取 INVOKE 调用的返回类型
- **INVOKE 协议**：定义于 [func.require]，是所有 C++ 标准库可调用操作的基础
- **std::reference_wrapper**：INVOKE 协议自动解引用 reference_wrapper，使引用语义与值语义在泛型代码中统一

### 4.3 工程中的最佳实践

- **泛型库优先用 invoke**：编写通用算法时用 `std::invoke` 替代硬编码调用语法
- **配合 is_invocable 做 SFINAE**：`template<T, enable_if_t<is_invocable_v<T, int>>>`
- **成员指针不必特化**：std::invoke 自动处理 `obj.*pmf` / `ptr->*pmf` 语法差异


## 五、源码解析和实践感悟

### 1. INVOKE 协议与 if constexpr 分发

```c++
// std::invoke 的核心是 INVOKE 协议：编译期根据可调用类型分发
template<typename F, typename... Args>
decltype(auto) invoke(F&& f, Args&&... args) {
    if constexpr (std::is_member_function_pointer_v<std::remove_reference_t<F>>) {
        // 成员函数指针 → (obj.*f)(args...) 或 (ptr->*f)(args...)
        if constexpr (std::is_base_of_v<ClassOf<F>, std::decay_t<FirstArg>>)
            return (std::forward<FirstArg>(args...).*f)(...);
        else
            return ((*std::forward<FirstArg>(args...)).*f)(...);
    } else if constexpr (std::is_member_object_pointer_v<std::remove_reference_t<F>>) {
        // 成员对象指针 → obj.*f 或 ptr->*f
        return std::forward<FirstArg>(args...).*f;
    } else {
        // 普通可调用对象 → f(args...)
        return std::forward<F>(f)(std::forward<Args>(args)...);
    }
}
// 关键：is_base_of_v 检查第一个参数是否是对象（而非指针）来区分 .* 和 ->*
```

### 2. std::invoke_result 的实现原理

```c++
// invoke_result 用 decltype 在未求值语境中模拟调用
template<typename F, typename... Args>
struct invoke_result : decltype(std::invoke(std::declval<F>(), std::declval<Args>()...)) {};
// declval<F>() 生成 F&& 的假实例（仅编译期），不求值
// 如果 INVOKE 不合法，SFINAE 使特化被丢弃
```

### 实践经验

1. **替代 std::bind 的冗长语法**：`std::invoke(f, a, b)` 比 `std::bind(f, _1, _2)(a, b)` 更简洁高效
2. **成员函数和普通函数的统一**：泛型代码中不用区分 `f(args)` 还是 `(obj.*f)(args)`，invoke 自动处理
3. **编译期零开销**：if constexpr 在编译期选择分支，无运行时判断成本
4. **与 reference_wrapper 协作**：invoke 能正确处理 std::ref/cref 包装的对象
5. **适用于 std::visit 的回调**：variant 访问器中统一调用不同类型

## 六、面试准备

### Q&A（10题）

**Q1: std::invoke 解决了什么问题？**
A: 统一调用语法——无论函数、成员函数指针、成员对象指针还是仿函数，都用同一方式调用

**Q2: invoke 如何处理成员函数指针？**
A: 第一个参数是对象/指针/引用，通过 `obj.*memfn` 或 `ptr->*memfn` 调用，if constexpr + is_base_of_v 区分传对象还是传指针

**Q3: INVOKE 协议和 invoke 函数的关系？**
A: INVOKE 是标准库的概念协议（如 std::thread、std::function 等依赖它），std::invoke 是该协议的具体实现函数

**Q4: invoke 如何实现编译期零开销？**
A: if constexpr 在编译期选择路径，无虚函数调用，最终代码等价于直接调用

**Q5: std::invoke_result 是什么？**
A: 获得 INVOKE 调用结果的类型，用 decltype + declval 在未求值语境中推导

**Q6: invoke 能调用函数指针吗？**
A: 能，普通函数指针走第三个分支 `f(args...)`，与普通可调用对象一致

**Q7: is_base_of_v 在 invoke 中的判断起什么作用？**
A: 判断第一个参数是否是对象（而非指针/引用包装器），决定用 `obj.*f` 还是 `(*ptr).*f`

**Q8: invoke 与 std::function 的关系？**
A: std::function 内部使用 INVOKE 协议存储和调用可调用对象

**Q9: invoke 在 C++17 前如何模拟？**
A: 可以用 std::bind(f, args...)() 近似，但有额外开销

**Q10: invoke 能处理指向成员变量的指针吗？**
A: 能，`std::invoke(&S::x, obj)` 等价于 `obj.x`，返回成员变量的引用

### 陷阱与反问（5个）

1. **陷阱**：成员函数指针传给 invoke 时第一个参数必须是类对象或指针，传错类型编译失败
2. **反问**：invoke 真的零开销吗？→ 是，实例化后与直接调用生成的汇编完全一致
3. **陷阱**：invoke 不会自动解引用包装器（除 reference_wrapper 外），传智能指针先解引用
4. **反问**：有了 invoke 还需要 std::function 吗？→ 需要，invoke 只是调用机制，function 是类型擦除的存储容器
5. **陷阱**：invoke 对成员对象取地址时返回引用，注意悬垂引用

### 一句话答案（8个）

1. **invoke 本质**：编译期多态调用器，统一可调用对象调用语法
2. **if constexpr 作用**：编译期分支选择，零运行时开销
3. **is_member_function_pointer_v**：判断 F 是否为成员函数指针类型
4. **declval 作用**：在未求值语境生成类型实例的假引用，供 decltype 推导
5. **与 bind 对比**：invoke 立即调用，bind 延迟调用；invoke 更轻量
6. **INVOKE 协议**：C++ 标准定义的调用概念，多个库组件依赖
7. **成员对象 invoke**：返回左值引用，可读写
8. **泛型中的应用**：模板代码中不必区分可调用对象类型
