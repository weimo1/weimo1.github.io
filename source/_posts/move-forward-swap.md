---
title: move  forward  swap
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "现代C++特性"]
publish: true
---

# move  forward  swap

> 适用范围：C++11 std::move移动语义、std::forward完美转发、std::swap交换、引用折叠规则

## 一、核心概念

- **定义**：`std::move` 无条件将左值转为右值引用（触发移动语义）；`std::forward` 根据模板参数保持原值类别（左/右值）的转发；`std::swap` 高效交换两个对象的所有权
- **关键词**：移动语义(move semantics)、完美转发(perfect forwarding)、右值引用、引用折叠(reference collapsing)、万能引用(forwarding reference)
- **适用场景/边界**：
  - 避免不必要的深拷贝（unique_ptr转移所有权、大容器返回值优化）
  - 泛型编程中保持参数值类别传递（工厂模式、emplace_back）
  - 边界：move后对象处于有效但未指定状态；forward只能用于万能引用上下文(T&&)

## 二、详细解析（≥200字）

### 2.1 std::move 原理

`std::move` 的本质是静态_cast：`static_cast<std::remove_reference_t<T>&&>(t)`。它不做任何运行时操作，只是类型转换——将左值标记为"可移动"。真正的资源转移发生在移动构造函数/移动赋值运算符内部。

**关键误区**：`std::move` 不移动任何东西，它只是"允许"移动。如果目标类型没有移动构造函数，退化为拷贝。

### 2.2 std::forward 原理

`std::forward` 利用引用折叠规则：
- `T& &` → `T&`
- `T& &&` → `T&`
- `T&& &` → `T&`
- `T&& &&` → `T&&`

当 `T` 被推导为左值引用时，`T&&` 折叠为 `T&`（左值引用）。当 `T` 被推导为非引用类型时，`T&&` 保持为右值引用。`std::forward<T>(t)` 据此恢复参数原始值类别。

## 三、动手实践（代码案例）

## 1、std::move

std::move() 函数获得一个右值引用

```
/// since C++11, until C++14
template< class T >
typename std::remove_reference<T>::type&& move( T&& t ) noexcept;

/// since C++14
template< class T >
constexpr std::remove_reference_t<T>&& move( T&& t ) noexcept;
```

右值引用可以触发移动语义，使用资源交换而不是拷贝的方法完成赋值。例如下面的示例，（2）触发移动语义，调用完成，str 成为了空字符串，因为进行了资源交换。

```
#include <iostream>
#include <string>
#include <utility>
#include <vector>

int main() {
    std::string str = "Salut";
    std::vector<std::string> v;

    v.push_back(str); // (1)
    std::cout << "After copy, str is " << str << '\n';

    v.push_back(std::move(str)); // (2)
    std::cout << "After move, str is " << str << '\n';

    std::cout << "The contents of the vector are { ";
    for (auto& elm : v) {
        std::cout << elm << ' ';
    }
    std::cout << "}\n";
    return 0;
}
```

执行的输出为

```
After copy, str is Salut
After move, str is 
The contents of the vector are { Salut Salut }
```

std::move() 的实现非常简单

```
/// include/bits/move.h
template<typename _Tp>
_GLIBCXX_NODISCARD
constexpr typename std::remove_reference<_Tp>::type&&
move(_Tp&& __t) noexcept
{ return static_cast<typename std::remove_reference<_Tp>::type&&>(__t); }
```

理解 std::move() 需要明白如下两点

（1）引用折叠

* **间接创建**（只能间接，如类型别名或模板参数，语法不支持直接创建）引用的引用，这些引用会形成“折叠”
* T& &、T& &&、T&& & 都会折叠成左值引用 T&
* T&& && 折叠成右值引用 T&&

（2）模板右值引用参数

* 模板函数形参类型是 T&&，而实参是一个左值，推断出的模板实参类型将是 T&，且函数参数将被实例化一个普通的左值引用参数 T&
* 模板函数形参类型是 T&&，而实参是一个右值，推断出的模板实参类型将是 T，且函数参数将被实例化一个普通参数 T

（3）从一个左值 static\_cast 到一个右值引用是允许的

明白上述（1）（2）（3）三点就可以理解 std::move() 的原理了。

如果 std::move() 实参是右值，如下所示：

```
auto s2 = std::move(std::string("bye!"));
```

模板函数 move 函数将会被实例化为如下类型

```
std::string&& move(std::string&& t);
```

* 模板参数 Tp 被推断为 std::string 类型
* 形参类型右值引用 std::string&&
* std::remove\_reference 用 std::string 实例化
* std::remove\_reference<std::string> 的 type 成员是 std::string
* 返回类型是 std::string&&

如果 std::move() 实参是左值，如下所示：

```
std::string s1 = std::string("bye"); 
auto s2 = std::move(s1);
```

模板函数 move 将会被实例化为

```
std::string&& move(std::string& t);
```

* 模板参数 Tp 被推断为 std::string& 类型
* 形参类型是 std::string& &&，引用折叠为左值引用 std::string&
* std::remove\_reference 用 std::string& 实例化
* std::remove\_reference<std::string&> 的 type 成员是 std::string
* 返回类型是 std::string&&

## 2、std::swap()

通过移动类交换两个变量。它要求传入的变量是可以移动的（具有移动构造函数和重载移动赋值运算符）。宏定义 \_GLIBCXX\_MOVE 在 C++11 展开为 std::move()。

```
/// include/bits/move.h
template<typename _Tp>
_GLIBCXX20_CONSTEXPR
inline
#if __cplusplus >= 201103L
typename enable_if<__and_<__not_<__is_tuple_like<_Tp>>,
is_move_constructible<_Tp>,
is_move_assignable<_Tp>>::value>::type
#else
void
#endif
swap(_Tp& __a, _Tp& __b)
_GLIBCXX_NOEXCEPT_IF(__and_<is_nothrow_move_constructible<_Tp>,
is_nothrow_move_assignable<_Tp>>::value)
{
    #if __cplusplus < 201103L
    ///...
    #endif
    _Tp __tmp = _GLIBCXX_MOVE(__a);
    __a = _GLIBCXX_MOVE(__b);
    __b = _GLIBCXX_MOVE(__tmp);
}

template<typename _Tp, size_t _Nm>
_GLIBCXX20_CONSTEXPR
inline
#if __cplusplus >= 201103L
typename enable_if<__is_swappable<_Tp>::value>::type
#else
void
#endif
swap(_Tp (&__a)[_Nm], _Tp (&__b)[_Nm])
_GLIBCXX_NOEXCEPT_IF(__is_nothrow_swappable<_Tp>::value)
{
    for (size_t __n = 0; __n < _Nm; ++__n)
        swap(__a[__n], __b[__n]);
}
```

在移动的过程中，不会有资源的申请和释放。看下面的例子：

```
#define ADD_MOVE

class Test {
public:
explicit Test(size_t l): len_(l), data_(new unsigned char[l]) {
    printf("Test Ctor\n");
}
Test(const Test& other): len_(other.len_), data_(new unsigned char[len_]) {
    printf("Test Copy Ctor\n");
    memmove(data_, other.data_, len_);
}
Test& operator=(const Test& rhs) {
    printf("Test operator=\n");
    if(this != &rhs) {
        len_ = rhs.len_;
        data_ = new unsigned char[len_];
        memmove(data_, rhs.data_, len_);
        return *this;
    }
}
#ifdef ADD_MOVE
Test(Test&& other): len_(len_), data_(other.data_) {
    printf("Test Move Ctor\n");
    other.len_ = 0;
    other.data_ = nullptr;
}
Test& operator=(Test&& rhs) {
    printf("Test Move operator=\n");
    if(this != &rhs) {
        len_ = rhs.len_;
        data_ = rhs.data_;
        rhs.len_ = 0;
        rhs.data_ = nullptr;
    }
}
#endif
~Test() {
    printf("Test Dtor\n");
    delete[] data_;
}

private:
size_t len_;
unsigned char* data_;
};
```

我们重载 operator new() 和 operator delete() 输出分配或释放内存操作

```
void* operator new(size_t size) {
    printf("allocate memory\n");
    return malloc(size);
}

void operator delete(void* ptr) {
    printf("free memory\n");
    free(ptr);
}
```

进行交换测试

```
int main() {
  Test a(1), b(1);
  printf("===========Swap==========\n");
  std::swap(a, b);
  printf("===========Done==========\n");
  return 0;
}
```

在对象“无法”移送的时候（没有显式移动构造函数和移动赋值运算符），交换需要拷贝资源

```
+Allocate Memory
Test Ctor
+Allocate Memory
Test Ctor
===========Swap==========
+Allocate Memory
Test Copy Ctor
Test operator=
+Allocate Memory
Test operator=
+Allocate Memory
Test Dtor
-Free Memory
===========Done==========
Test Dtor
-Free Memory
Test Dtor
-Free Memory
```

当对象可以移动时，交换没有资源的拷贝

```
+Allocate Memory
Test Ctor
+Allocate Memory
Test Ctor
===========Swap==========
Test Move Ctor
Test Move operator=
Test Move operator=
Test Dtor
===========Done==========
Test Dtor
-Free Memory
Test Dtor

-Free Memory
```

## 3、std::forward()

std::forward() 是为了支持 C++11 转发。

某些函数需要将其一个或多个实参连同类型不变地转发给其他函数，在此情况下，我们需要保持被转发实参的所有性质，包括实参类型是否是 const 的以及实参是左值还是右值。

比如如下例子，Data 构造函数可以接受参数类型是 int&&, int&，模板函数 MakeData 可以接受左值和右值（和 std::move() 相同的原理）

```
#include <iostream>
#include <memory>
#include <utility>

struct Data {
Data(int&& n) { std::cout << "rvalue overload, n=" << n << '\n'; }
Data(int& n) { std::cout << "lvalue overload, n=" << n << '\n'; }
};

template <typename Tp>
std::unique_ptr<Data> MakeData(Tp&& value) {
    return std::unique_ptr<Data>(new Data(value));
}

int main() {
    auto data1 = MakeData(1); // rvalue
    int n = 2;
    auto data2 = MakeData(n); // lvalue

    return 0;
}
```

但是无论传递给 MakeData() 的是左值还是右值，都是调用参数类型为 int& 的构造函数。

```
lvalue overload, n=1
lvalue overload, n=2
```

如果使用 std::forward() 函数，则可以将 value 的类型完全转发。

```
#include <iostream>
#include <memory>
#include <utility>

struct Data {
Data(int&& n) { std::cout << "rvalue overload, n=" << n << '\n'; }
Data(int& n) { std::cout << "lvalue overload, n=" << n << '\n'; }
};

template <typename Tp>
std::unique_ptr<Data> MakeData(Tp&& value) {
    return std::unique_ptr<Data>(new Data(std::forward<Tp>(value)));
}

int main() {
    auto data1 = MakeData(1);
    int n = 2;
    auto data2 = MakeData(n);

    return 0;
}
```

传入右值可以调用到参数类型为 int&& 的构造函数。

```
rvalue overload, n=1
lvalue overload, n=2
```

需要注意的是，std::forward() 必须通过显式模板实参来调用。std::forward() 返回该显式实参类型的右值引用。通过其返回类型上的引用折叠，std::forward() 可以保持给定实参的左值/右值属性。

```
/// include/bits/move.h
template<typename _Tp>
_GLIBCXX_NODISCARD
constexpr _Tp&&
forward(typename std::remove_reference<_Tp>::type& __t) noexcept
{ return static_cast<_Tp&&>(__t); }

template<typename _Tp>
_GLIBCXX_NODISCARD
constexpr _Tp&&
forward(typename std::remove_reference<_Tp>::type&& __t) noexcept
{
    static_assert(!std::is_lvalue_reference<_Tp>::value,
    "std::forward must not be used to convert an rvalue to an lvalue");
    return static_cast<_Tp&&>(__t);
}
```

std::forward() 的需要结合右值引用模板函数，才能实现完美转发。如果 MakeData() 函数一样

```
template <typename Tp>
std::unique_ptr<Data> MakeData(Tp&& value) {
    return std::unique_ptr<Data>(new Data(std::forward<Tp>(value)));
}
```

* 如果 MakeData() 函数实参是左值，模板参数被推断为 Tp&，std::forward() 的返回值为 Tp& &&，引用折叠后是 Tp&，保持参数左值属性
* 如果 MakeData() 函数实参是右值，模板参数被推断为 Tp，std::forward() 的返回值为 Tp&&，保持参数右值属性

## 四、进阶应用（≥500字）

### 4.1 完美转发的工程应用

完美转发是泛型工厂模式的核心：
```c++
template<typename T, typename... Args>
std::unique_ptr<T> make_unique(Args&&... args) {
    return std::unique_ptr<T>(new T(std::forward<Args>(args)...));
}
```

`std::vector::emplace_back` 同样依赖完美转发——将构造参数无损传递给元素的构造函数。

### 4.2 引用折叠的完整规则

| 模板参数T | T&&（万能引用） | 结果 |
| --- | --- | --- |
| int& | int& && | int&（左值引用） |
| int&& | int&& && | int&&（右值引用） |
| int | int&& | int&&（右值引用） |

关键：只要T本身是左值引用，结果就是左值引用（T&优先级高于&&）。

### 4.3 std::move 的常见陷阱

- **move后不要使用原对象**（除非重新赋值）：移后对象处于"有效但未指定"状态
- **const对象不能移动**：对const对象move退化为拷贝（移动构造函数需要非const右值引用参数）
- **不要move返回值**：编译器自动优化（RVO/NRVO），手动move反而阻止优化

### 4.4 与其他主题的关联

- **引用折叠**：完美转发的底层机制，解释了为什么template + T&&是万能引用
- **移动语义**：move + 移动构造函数/移动赋值运算符实现零拷贝资源转移
- **emplace_back**：利用完美转发在原位构造元素
- **noexcept**：移动操作标记 noexcept 允许vector扩容时安全移动

### 4.5 工程中的最佳实践

- **forward用于万能引用**：`template<T> void f(T&& t)` 中用 `std::forward<T>(t)`
- **move用于所有权转移**：明确要放弃对象所有权时使用
- **返回局部变量不用move**：信任编译器RVO
- **swap实现用移动**：`using std::swap; swap(a, b);` ADL两阶段


## 五、源码解析和实践感悟

### 1. std::move 的实现本质

```c++
// move 只是类型转换，不生成任何运行时代码
template<typename T>
constexpr std::remove_reference_t<T>&& move(T&& t) noexcept {
    return static_cast<std::remove_reference_t<T>&&>(t);
}
// move 的本质: 无条件将参数转为右值引用
// 汇编: 完全被优化掉，零指令
```

### 2. std::forward 的条件转换

```c++
// forward 依赖引用折叠，保留参数的原始值类别
template<typename T>
constexpr T&& forward(std::remove_reference_t<T>& t) noexcept {
    return static_cast<T&&>(t);
}
// 调用: forward<Arg>(arg)
// Arg 推断为 int& → 返回 int& && → int& (左值)
// Arg 推断为 int  → 返回 int&&     → int&& (右值)

// 引用折叠规则: & + & = &; & + && = &; && + & = &; && + && = &&
```

### 3. swap 的编译期优化

```c++
// 标准 swap 用移动语义替代三次拷贝
template<typename T>
void swap(T& a, T& b) noexcept(is_nothrow_move_constructible_v<T>
                               && is_nothrow_move_assignable_v<T>) {
    T tmp = std::move(a);  // 移动构造
    a = std::move(b);      // 移动赋值
    b = std::move(tmp);    // 移动赋值
}
// vector 扩容时如果元素移动构造是 noexcept，用 memmove 替代逐元素拷贝
```

### 实践经验

1. **move 不移动，forward 不转发**：两者都是编译期类型转换，move 无条件转右值，forward 条件转右值
2. **右值引用本身是左值**：`void f(int&& x) { auto y = move(x); }` 必须有 move——x 有名字就是左值
3. **forward 的模板参数必须是 T**：`forward<T>(arg)` 中 T 必须是模板参数推导的原始类型，不能手动指定
4. **swap 的 noexcept 影响 vector 性能**：元素类型移动构造为 noexcept 时，vector 扩容用 memmove 而非逐元素
5. **在 return 语句中不需要 move**：编译器自动做 NRVO/RVO，加 move 反而禁用优化

## 六、面试准备

### Q&A（10题）

**Q1: std::move 做了什么？**
A: 无条件的类型转换——将参数转为其右值引用类型。不移动任何数据，只是一个 static_cast

**Q2: std::forward 和 std::move 的区别？**
A: move 无条件转右值；forward 保留参数的原始值类别（左值→左值，右值→右值）

**Q3: 什么是引用折叠？**
A: C++11 规则——两个引用组合时：只有 &&+&&→&&，其他组合→&。forward 依赖此规则

**Q4: 为什么右值引用变量本身是左值？**
A: 任何有名字的变量都是左值（可寻址）。要重新获得其右值属性需再 move

**Q5: 完美转发是什么意思？**
A: 将参数的值类别（左值/右值）原封不动传递给下一层调用，依赖万能引用 + forward

**Q6: swap 为什么需要 noexcept？**
A: 标准库容器在扩容时检测 swap/noexcept 移动构造来选择高效路径

**Q7: move 之后对象处于什么状态？**
A: 处于 valid-but-unspecified——可安全析构或赋新值，但不保证原值

**Q8: 万能引用和右值引用的语法区别？**
A: 语法相同 `T&&`，当 T 被推导且形如 `T&&` 时是万能引用；`int&&` 或 `std::vector<T>&&` 不是

**Q9: forward 的参数能否省略模板参数？**
A: 不能，forward 需要模板参数来区分左值/右值版本，`forward(arg)` 无法编译

**Q10: RVO/NRVO 和 move 的关系？**
A: RVO 直接在调用方栈帧构造对象（零拷贝），比 move 更优。return move(x) 会禁用 RVO

### 陷阱与反问（5个）

1. **陷阱**：`return std::move(local_var)`→禁用 NRVO，反而多一次移动构造
2. **反问**：move 后对象能读吗？→ 能（valid-but-unspecified），但不应依赖其值
3. **陷阱**：const 对象 move→不会调用移动构造（移动构造需要非 const 右值引用）
4. **反问**：有万能引用还需重载吗？→ 万能引用是贪婪的，可能劫持拷贝/移动构造，通常需要 SFINAE 约束
5. **陷阱**：`auto&& x = expr` 中 x 是万能引用，expr 是右值时 x 是右值引用，左值时 x 是左值引用

### 一句话答案（8个）

1. **move 本质**：`static_cast<T&&>`，编译期类型转换
2. **forward 本质**：`static_cast<T&&>` + 引用折叠保留值类别
3. **引用折叠**：T& &/T& &&/T&& & → T&；T&& && → T&&
4. **完美转发语法**：`template<class T> void f(T&& x) { g(forward<T>(x)); }`
5. **swap 三步骤**：移动构造 tmp、移动赋值 a、移动赋值 b
6. **NRVO 条件**：返回局部变量且类型匹配，不加 move
7. **const T& 也能绑定右值**：但会延长临时对象生命周期
8. **移动操作后状态**：valid-but-unspecified
