---
title: 闭包：仿函数operator() && 绑定器bind && 包装器function && lambda表达式&& 函数指针
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "现代C++特性"]
publish: true
---

# 闭包：仿函数operator() && 绑定器bind && 包装器function && lambda表达式&& 函数指针

> 适用范围：C++ 闭包——仿函数、`std::bind`、`std::function`、lambda 表达式、函数指针的统一理解。

参考：<https://cloud.tencent.com/developer/article/2513972>

## 一、核心概念

- **定义**：闭包有很多种定义，一种说法是，闭包是带有上下文的函数。说白了，就是有状态的函数，就是有自己的变量。更直接一些，**就是一个类换了个名字而已**。一个函数，带上了一个状态，就变成了闭包了。意思是这个闭包有属于自己的变量，这些变量的值是创建闭包的时候设置的，并在调用闭包的时候可以访问这些变量。
- **关键词**：闭包（Closure）、仿函数（Functor）、`std::bind`、`std::function`、lambda 表达式、函数指针
- **适用场景/边界**：
  - 回调函数管理
  - 状态与函数绑定的场景
  - 五种实现方式：仿函数、bind、function、lambda、函数指针

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：基本工作原理**

函数是代码，状态是一组变量，将代码和一组变量捆绑（`bind`），就形成了闭包。闭包的状态捆绑，必须发生在运行时。

**第二层：关键步骤详解**

- **仿函数（Functor）**：重载 `operator()` 的类，可将状态存储为成员变量
- **`std::bind`**：将函数与参数绑定，返回可调用对象
- **`std::function`**：类型擦除的多态函数包装器
- **lambda 表达式**：编译器自动生成的匿名仿函数
- **函数指针**：最简单的可调用对象形式

**第三层：底层机制**

`std::function` 对象最大的用处就是在实现函数回调。使用者需要注意，虽然它不能被用来检查相等或者不相等，但是可以与 `NULL` 或者 `nullptr` 进行比较。`std::function` 填补了函数指针的灵活性，但会对调用性能有一定损耗——经测试发现，在调用次数达10亿次时，函数指针比直接调用要慢 2 秒左右，而 `std::function` 要比函数指针慢 2 秒左右，这么少的损耗如果是对于调用次数并不高的函数，替换成 `std::function` 绝对是划得来的。

- **关键数据结构**：`std::function` 内部的类型擦除虚表
- **关键公式**：闭包 = 代码（函数） + 状态（变量） + 运行时绑定

## 三、动手实践（代码案例）

## 四、进阶应用（≥500字）

### 什么是闭包

**闭包有很多种定义， 一种说法是， 闭包是带有上下文的函数。** 说白了， 就是有状态的函数，就是有自己的变量。更直接一些， **就是一个类** 换了个名字而已。

**一个函数， 带上了一个状态， 就变成了闭包了**。 那什么叫 **“带上状态”** 呢？ 意思是这个**闭包有属于自己的变量， 这些个变量的值是创建闭包的时候设置的， 并在调用闭包的时候， 可以访问这些变量。**

**函数是代码， 状态是一组变量， 将代码和一组变量捆绑 (**`bind`**) ， 就形成了闭包。闭包的状态捆绑， 必须发生在运行时。**

##### std::function包装器

`std::function` **对象最大的用处就是在实现函数回调，使用者需要注意，虽然它不能被用来检查相等或者不相等，但是可以与** `NULL` **或者** `nullptr` **进行比较。**

💥💥💥当然，任何东西都会有优缺点，`std::function` 填补了函数指针的灵活性，但会对调用性能有一定损耗，经测试发现，在调用次数达10亿次时，函数指针比直接调用要慢 `2` 秒左右，而 `std::function` 要比函数指针慢 `2` 秒左右，这么少的损耗如果是对于调用次数并不高的函数，替换成 `std::function` 绝对是划得来的。

`function` **包装器就是用来实现对函数指针、仿函数、**`lambda`**表达式等进行统一的表示**

```
#include <iostream>
#include <functional>
using namespace std;

template<class F, class T>
T useF(F f, T x)
{
	static int count = 0;
	cout << "count:" << ++count << endl;
	cout << "count:" << &count << endl;
	return f(x);
}
// 普通函数
double f(double i)
{
	return i / 2;
}
// 仿函数
struct Functor 
{
	double operator()(double d)
	{
		return d / 3;
	}
};

int main()
{
	// 函数名
	cout << useF(f, 11.11) << endl;
	// 函数对象
	cout << useF(Functor(), 11.11) << endl;
	// lambda表达式
	cout << useF([](double d)->double { return d / 4; }, 11.11) << endl;
	return 0;
}

// 运行结果：
count:1
count:00007FF607272574
5.555
count:1
count:00007FF607272578
3.70333
count:1
count:00007FF60727257C
2.7775
   
int main()
{
	// 函数名
	cout << useF(f, 11.11) << endl;
	// 函数对象
	cout << useF(Functor(), 11.11) << endl;
	// lamber表达式
	cout << useF([](double d)->double { return d / 4; }, 11.11) << endl;
	cout << "################################################################################" << endl;

	// 函数名
	function<double(double)> func1 = f;
	cout << useF(func1, 11.11) << endl;
    // cout << useF(function<double(double)>(f), 11.11) << endl;  // 也可以写成这样子
    
	// 函数对象
	function<double(double)> func2 = Functor();
	cout << useF(func2, 11.11) << endl;
    
	// lamber表达式
	function<double(double)> func3 = [](double d)->double { return d / 4; };
	cout << useF(func3, 11.11) << endl;
	return 0;
}

// 运行结果：
count:1
count:00007FF607272574
5.555
count:1
count:00007FF607272578
3.70333
count:1
count:00007FF60727257C
2.7775
################################################################################
count:1
count:00007FF607272580
5.555
count:2
count:00007FF607272580
3.70333
count:3
count:00007FF607272580
2.7775
```

`useF` **函数模板被实例化为了三份不同的函数，这其实就导致了没必要的内存开销等等！**

那么这个问题我们就可以通过包装器 `function` 来解决，**包装器就是为了统一我们调用这些函数的类型**，也就是说，如果我们用 `function` 去包装我们调用的函数，那么 `useF` 函数模板怎么识别都是只有一个类型也就是 `function` 类型，那么这样子就只会实例化一份函数，大大的减少了开销！

##### std::bind

`bind` 函数看作是一个通用的函数适配器，它接受一个可调用对象，生成一个新的可调用对象来 “适应” 原对象的参数列表。

调用 `bind` 的一般形式：`auto newCallable = bind(callable, arg_list);`

其中，`newCallable` 本身是一个可调用对象，`arg_list` 是一个逗号分隔的参数列表，对应给定的 `callable` 的参数。**当我们调用**`newCallable`**时，**`newCallable`**会调用**`callable`**,****并传给它**`arg_list`**中的参数**。

`arg_list` 中的参数可能包含形如 `_n` 的名字，其中 `n` 是一个整数，这些参数是 **“占位符”**，表示 `newCallable` 的参数，它们占据了传递给 `newCallable` 的参数的“位置”。数值 `n` 表示生成的可调用对象中参数的位置：`_1` **为** `newCallable` **的第一个参数，**`_2` **为第二个参数，以此类推……**

##### std::bind 和 std::function 的配合使用

`std::function` 可以指向类成员函数和函数签名不一样的函数，其实，这两种函数都是一样的，因为类成员函数都有一个默认的参数：`this`，作为第一个参数，这就**导致了类成员函数不能直接赋值给** `std::function`，这时候我们就需要 `std::bind` 了！

简言之，`std::bind` **的作用就是转换函数签名，将缺少的参数补上，将多了的参数去掉，甚至还可以交换原来函数参数的位置**！

## 五、源码解析和实践感悟

### 1. 仿函数（Functor）的编译期优化

```c++
// 仿函数 = 重载 operator() 的类
struct Adder { int v; int operator()(int x) const { return x+v; } };
// 调用: Adder{5}(3) → 编译器可完全内联，零开销
// vs 函数指针: 间接调用，无法内联
```

### 2. std::bind 的内部实现

```c++
// bind 返回一个匿名仿函数对象，存储绑定的参数
auto f = std::bind(print, _1, 42);
// 内部: struct __bind_print { tuple<Args...> args; auto operator()(int x) { ... } };
// C++14 起推荐 lambda 替代 bind:
auto f = [](int x) { print(x, 42); };  // 更清晰、更高效
```

### 实践经验
1. **lambda 优于 bind**：lambda 更可读、更易优化、参数更明确
2. **仿函数比函数指针快**：可内联，函数指针无法内联（除非全程序优化）
3. **bind 的占位符陷阱**：`_1` 等是 `std::placeholders::_1`
4. **函数指针不能存状态**：lambda/仿函数/bind 都可以
5. **闭包捕获注意生命周期**：引用捕获超出作用域即悬垂

## 六、面试准备

### Q&A（10题）

**Q1: 仿函数和函数指针的本质区别？**
A: 仿函数是类对象（有状态、可内联），函数指针是地址（无状态、间接调用）

**Q2: lambda 表达式被编译器转换为什么？**
A: 匿名仿函数类——每个 lambda 生成唯一的类类型，捕获变量成为成员

**Q3: std::bind 和 lambda 如何选择？**
A: C++14 起优先 lambda——更清晰、编译更快、没有占位符混乱

**Q4: 函数指针、仿函数、lambda 的性能排序？**
A: lambda ≈ 仿函数 > 函数指针（因为可内联 vs 不可内联）

**Q5: lambda 的 mutable 关键字是什么意思？**
A: 允许修改按值捕获的变量（默认 operator() 是 const）

**Q6: 泛型 lambda (C++14) 的本质？**
A: `auto f = [](auto x){ return x*2; };` → operator() 是模板函数

**Q7: bind 的嵌套调用的陷阱？**
A: `bind(f, bind(g, _1))` → 内层 bind 返回值传给外层的 _1 参数，非常难读

**Q8: 函数对象如何存储和传递？**
A: 模板（编译期）、std::function（运行期类型擦除）、auto（推导）

**Q9: operator() 可以重载吗？**
A: 可以，不同参数列表可以重载 operator()，仿函数可有多个调用形式

**Q10: 函数指针能指向成员函数吗？**
A: 不能直接用，需要成员函数指针（`void (C::*)()`）和对象/指针

### 陷阱与反问（5个）
1. **陷阱**：lambda 按引用捕获→引用源对象销毁后成为悬垂引用
2. **反问**：仿函数有存在必要吗（既然有 lambda）？→ 需要重载多个 operator() 或命名类型时需要
3. **陷阱**：`std::bind` 返回的对象传递给 `std::function` 时类型擦除掉
4. **反问**：C++ 闭包和 JS/Python 闭包最大的不同？→ C++ 需要显式指定捕获方式
5. **陷阱**：lambda 的 init capture `[x=move(y)]` 是 C++14 特性

### 一句话答案（8个）
1. **仿函数**：重载 operator() 的类对象
2. **lambda**：编译期生成的匿名仿函数
3. **bind**：参数绑定生成可调用对象
4. **函数指针**：存代码地址，无状态
5. **闭包**：lambda 捕获外部变量形成闭包
6. **mutable**：允许修改按值捕获的副本
7. **泛型 lambda**：C++14 auto 参数的 lambda
8. **function 包装**：运行期类型擦除存储
