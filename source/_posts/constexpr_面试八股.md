---
title: constexpr_面试八股
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "现代C++特性"]
publish: true
---

# constexpr

> 适用范围：C++11/14/17/20 constexpr编译期计算、constexpr函数/变量/构造函数、编译期常量、if constexpr、consteval

## 一、核心概念

- **定义**：`constexpr` 是 C++11 引入的关键字，指示编译器该变量或函数的值/结果可以在编译期求值。C++14 放宽了 constexpr 函数的限制（允许多语句、循环），C++17 引入 `if constexpr`，C++20 引入 `consteval` 和 `constinit`
- **关键词**：编译期计算、constexpr函数、constexpr变量、if constexpr、consteval、constinit、编译期常量
- **适用场景/边界**：
  - 编译期计算数学常量（阶乘、斐波那契、π）
  - 编译期验证数组大小、模板参数合法性
  - 替代宏定义的类型安全常量
  - 边界：C++11 constexpr函数只能含单return语句；不能有副作用（I/O、动态内存分配在C++20前）

## 二、详细解析（≥200字）

### 2.1 基本工作原理（三层递进）

**第一层：编译期常量**。`constexpr int MAX = 100;` 保证 MAX 在编译期已知，可用于数组大小、模板参数等必须编译期常量的上下文。

**第二层：constexpr函数**。编译器尝试在编译期执行 constexpr 函数——如果所有参数都是编译期常量且函数体可编译期求值，结果直接嵌入二进制。否则退化为普通运行时函数。

**第三层：标准演进**。C++11→14（放宽函数体）、C++17（if constexpr 编译期分支）、C++20（consteval 强制编译期、constexpr new/vector/string）。`if constexpr` 与普通 `if` 的本质区别：前者在编译期丢弃未选中分支的代码生成，后者仍需编译所有分支。

### 2.2 constexpr 的核心作用

在 C++ 中，`constexpr` 的核心价值是 **将计算从运行时转移到编译时**，虽然其语法要求严格（如函数体必须简单、不能有副作用），但它能显著提升性能、增强安全性，并简化代码逻辑。以下是 `constexpr` 的核心作用和实际价值，以及为何值得"麻烦"：

#### 1. 编译时计算：消除运行时开销

* **场景**：计算常量值（如数学常量、配置参数）。
* 示例：编译时计算斐波那契数列，结果直接硬编码到二进制中。cpp复制

```
constexpr int fibonacci(int n) {
    return (n <= 1) ? n : fibonacci(n-1) + fibonacci(n-2);
}
constexpr int fib10 = fibonacci(10);  // 编译时计算，运行时直接使用 55
```

#### **2. 编译时验证：提前捕获错误**

* **场景**：确保常量值合法（如数组大小、配置约束）。
* 示例：编译时检查数组大小是否合法。cpp复制

```
constexpr int MAX_SIZE = 100;
int arr[MAX_SIZE];  // 合法
// int arr[fibonacci(20)];  // 编译时计算大小，若结果溢出则直接报错
```

#### **3. 替代宏：类型安全与作用域控制**

* **场景**：定义类型安全的常量，替代 `#define`。
* 示例：cpp复制

```
constexpr double PI = 3.1415926;  // 替代 #define PI 3.1415926
```

#### **4. 元编程：生成编译时数据结构**

* **场景**：编译时生成查找表、类型列表等。
* 示例：编译时生成素数表。cpp复制

```
constexpr std::array<int, 10> generate_primes() { /* ... */ }
constexpr auto primes = generate_primes();  // 编译时生成并嵌入二进制
```

---

### **二、为何值得“麻烦”？**

#### **1. 性能提升**

* **零运行时开销**：编译时计算的结果直接硬编码到程序中，无需运行时计算。
* 适用场景：

+ 高频调用的数学函数（如哈希、加密算法）。
+ 游戏引擎中的常量计算（如物理引擎参数）。

#### **2. 代码安全性**

- 编译时错误检查：若constexpr函数或变量的值不合法，直接编译失败。

```
constexpr int safe_div(int a, int b) {
    return (b == 0) ? throw "除零错误" : a / b;  // 编译时检查 b 是否为 0
}
// constexpr int val = safe_div(10, 0);  // 直接编译错误！
```

#### **3. 简化复杂逻辑**

- 示例：编译时字符串哈希（替代运行时计算）。

```
constexpr uint32_t hash(const char* str) {
    uint32_t hash = 0;
    for (; *str; ++str) {
        hash = (hash * 131) + *str;
    }
    return hash;
}
constexpr uint32_t hash_val = hash("hello");  // 编译时计算哈希值
```

#### **4. 与模板结合**

-场景：在模板元编程中生成编译时条件分支。

```
template <int N>
struct Factorial {
    static constexpr int value = N * Factorial<N-1>::value;
};
template <>
struct Factorial<0> {
    static constexpr int value = 1;
};
int result = Factorial<5>::value;  // 编译时计算 120
```

---

### **三、**`constexpr` **的演进与简化**

#### **1. C++11 → C++14 → C++17 → C++20**

- C++11 ：限制严格，函数体只能包含一条return语句。

```
constexpr int add(int a, int b) { return a + b; }  // C++11 合法
```

- C++14：放宽限制，支持局部变量、循环等。

```
constexpr int factorial(int n) {
    int result = 1;
    for (int i = 1; i <= n; ++i) {
        result *= i;
    }
    return result;  // C++14 起支持
}
```

- C++17 ：支持if constexpr，编译时条件分支。

```
template <typename T>
auto get_value(T t) {
    if constexpr (std::is_pointer_v<T>) {
        return *t;  // 编译时选择分支
    } else {
        return t;
    }
}
```

* **C++20**：支持 `consteval`（强制编译时求值）、`constinit`（强制编译时初始化）。

#### **2. 工具支持**

* **编译器优化**：现代编译器（如 GCC、Clang）能自动内联 `constexpr` 函数。
* **调试支持**：在调试模式下保留编译时计算逻辑，便于跟踪。

---

### **四、何时使用** `constexpr`**？**

|  |  |
| --- | --- |
| **场景** | **示例** |
| **编译时已知的常量** | 数学常数（π）、配置参数（缓冲区大小） |
| **高频调用的简单函数** | 哈希函数、加密算法、数学运算（如 `pow`） |
| **类型安全的常量替代宏** | 替代 `#define` 定义的常量 |
| **模板元编程** | 生成编译时数据结构（如查找表）、实现编译时条件逻辑 |

---

### **总结**

`constexpr` 的“麻烦”源于其严格的编译时约束，但这些约束正是其价值的体现：

* **性能**：将计算从运行时转移到编译时，消除开销。
* **安全**：编译时检查错误，避免运行时崩溃。
* **清晰**：明确表达“此值/函数应在编译时确定”，增强代码可读性。

## 条款十五：尽可能的使用`constexpr`

**Item 15: Use** `constexpr` **whenever possible**

如果要给C++11颁一个“最令人困惑新词”奖，`constexpr`十有八九会折桂。当用于对象上面，它本质上就是`const`的加强形式，但是当它用于函数上，意思就大不相同了。有必要消除困惑，因为你绝对会用它的，特别是当你发现`constexpr` “正合吾意”的时候。

从概念上来说，`constexpr`表明一个值不仅仅是常量，还是编译期可知的。这个表述并不全面，因为当`constexpr`被用于函数的时候，事情就有一些细微差别了。为了避免我毁了结局带来的surprise，我现在只想说，你不能假设`constexpr`函数的结果是`const`，也不能保证它们的（译注：返回）值是在编译期可知的。最有意思的是，这些是**特性**。关于`constexpr`函数返回的结果不需要是`const`，也不需要编译期可知这一点是**良好的**行为！

不过我们还是先从`constexpr`对象开始说起。这些对象，实际上，和`const`一样，它们是编译期可知的。（技术上来讲，它们的值在翻译期（translation）决议，所谓翻译不仅仅包含是编译（compilation）也包含链接（linking），除非你准备写C++的编译器和链接器，否则这些对你不会造成影响，所以你编程时无需担心，把这些`constexpr`对象值看做编译期决议也无妨的。）

编译期可知的值“享有特权”，它们可能被存放到只读存储空间中。对于那些嵌入式系统的开发者，这个特性是相当重要的。更广泛的应用是“其值编译期可知”的常量整数会出现在需要“整型常量表达式（**integral constant expression**）的上下文中，这类上下文包括数组大小，整数模板参数（包括`std::array`对象的长度），枚举名的值，对齐修饰符（译注：`alignas(val)`），等等。如果你想在这些上下文中使用变量，你一定会希望将它们声明为`constexpr`，因为编译器会确保它们是编译期可知的：

```
int sz;                             //non-constexpr变量
…
constexpr auto arraySize1 = sz;     //错误！sz的值在
                                    //编译期不可知
std::array<int, sz> data1;          //错误！一样的问题
constexpr auto arraySize2 = 10;     //没问题，10是
                                    //编译期可知常量
std::array<int, arraySize2> data2;  //没问题, arraySize2是constexpr
```

注意`const`不提供`constexpr`所能保证之事，因为`const`对象不需要在编译期初始化它的值。

```
int sz;                            //和之前一样
…
const auto arraySize = sz;         //没问题，arraySize是sz的const复制
std::array<int, arraySize> data;   //错误，arraySize值在编译期不可知
```

简而言之，所有`constexpr`对象都是`const`，但不是所有`const`对象都是`constexpr`。如果你想编译器保证一个变量有一个值，这个值可以放到那些需要编译期常量（compile-time constants）的上下文的地方，你需要的工具是`constexpr`而不是`const`。

涉及到`constexpr`函数时，`constexpr`对象的使用情况就更有趣了。如果实参是编译期常量，这些函数将产出编译期常量；如果实参是运行时才能知道的值，它们就将产出运行时值。这听起来就像你不知道它们要做什么一样，那么想是错误的，请这么看：

* `constexpr`函数可以用于需求编译期常量的上下文。如果你传给`constexpr`函数的实参在编译期可知，那么结果将在编译期计算。如果实参的值在编译期不知道，你的代码就会被拒绝。
* 当一个`constexpr`函数被一个或者多个编译期不可知值调用时，它就像普通函数一样，运行时计算它的结果。这意味着你不需要两个函数，一个用于编译期计算，一个用于运行时计算。`constexpr`全做了。

假设我们需要一个数据结构来存储一个实验的结果，而这个实验可能以各种方式进行。实验期间风扇转速，温度等等都可能导致亮度值改变，亮度值可以是高，低，或者无。如果有**n**个实验相关的环境条件，它们每一个都有三个状态，最终可以得到的组合有3n个。储存所有实验结果的所有组合需要足够存放3n个值的数据结构。假设每个结果都是`int`并且**n**是编译期已知的（或者可以被计算出的），一个`std::array`是一个合理的选择。我们需要一个方法在编译期计算3n。C++标准库提供了`std::pow`，它的数学功能正是我们所需要的，但是，对我们来说，这里还有两个问题。第一，`std::pow`是为浮点类型设计的，我们需要整型结果。第二，`std::pow`不是`constexpr`（即，不保证使用编译期可知值调用而得到编译期可知的结果），所以我们不能用它作为`std::array`的大小。

幸运的是，我们可以应需写个`pow`。我将展示怎么快速完成它，不过现在让我们先看看它应该怎么被声明和使用：

```
constexpr                                   //pow是绝不抛异常的
int pow(int base, int exp) noexcept         //constexpr函数
{
 …                                          //实现在下面
}
constexpr auto numConds = 5;                //（上面例子中）条件的个数
std::array<int, pow(3, numConds)> results;  //结果有3^numConds个元素
```

回忆下`pow`前面的`constexpr`不表明`pow`返回一个`const`值，它只说了如果`base`和`exp`是编译期常量，`pow`的值可以被当成编译期常量使用。如果`base`和/或`exp`不是编译期常量，`pow`结果将会在运行时计算。这意味着`pow`不止可以用于像`std::array`的大小这种需要编译期常量的地方，它也可以用于运行时环境：

```
auto base = readFromDB("base");     //运行时获取这些值
auto exp = readFromDB("exponent"); 
auto baseToExp = pow(base, exp);    //运行时调用pow函数
```

因为`constexpr`函数必须能在编译期值调用的时候返回编译期结果，就必须对它的实现施加一些限制。这些限制在C++11和C++14标准间有所出入。

C++11中，`constexpr`函数的代码不超过一行语句：一个`return`。听起来很受限，但实际上有两个技巧可以扩展`constexpr`函数的表达能力。第一，使用三元运算符“`?:`”来代替`if`-`else`语句，第二，使用递归代替循环。因此`pow`可以像这样实现：

```
constexpr int pow(int base, int exp) noexcept
{
    return (exp == 0 ? 1 : base * pow(base, exp - 1));
}
```

这样没问题，但是很难想象除了使用函数式语言的程序员外会觉得这样硬核的编程方式更好。在C++14中，`constexpr`函数的限制变得非常宽松了，所以下面的函数实现成为了可能：

```
constexpr int pow(int base, int exp) noexcept   //C++14
{
    auto result = 1;
    for (int i = 0; i < exp; ++i) result *= base;
    
    return result;
}
```

`constexpr`函数限制为只能获取和返回**字面值类型**，这基本上意味着那些有了值的类型能在编译期决定。在C++11中，除了`void`外的所有内置类型，以及一些用户定义类型都可以是字面值类型，因为构造函数和其他成员函数可能是`constexpr`：

```
class Point {
public:
    constexpr Point(double xVal = 0, double yVal = 0) noexcept
    : x(xVal), y(yVal)
    {}

    constexpr double xValue() const noexcept { return x; } 
    constexpr double yValue() const noexcept { return y; }

    void setX(double newX) noexcept { x = newX; }
    void setY(double newY) noexcept { y = newY; }

private:
    double x, y;
};
```

`Point`的构造函数可被声明为`constexpr`，因为如果传入的参数在编译期可知，`Point`的数据成员也能在编译器可知。因此这样初始化的`Point`就能为`constexpr`：

```
constexpr Point p1(9.4, 27.7);  //没问题，constexpr构造函数
                                //会在编译期“运行”
constexpr Point p2(28.8, 5.3);  //也没问题
```

类似的，`xValue`和`yValue`的*getter*（取值器）函数也能是`constexpr`，因为如果对一个编译期已知的`Point`对象（如一个`constexpr` `Point`对象）调用*getter*，数据成员`x`和`y`的值也能在编译期知道。这使得我们可以写一个`constexpr`函数，里面调用`Point`的*getter*并初始化`constexpr`的对象：

```
constexpr
Point midpoint(const Point& p1, const Point& p2) noexcept
{
    return { (p1.xValue() + p2.xValue()) / 2,   //调用constexpr
             (p1.yValue() + p2.yValue()) / 2 }; //成员函数
}
constexpr auto mid = midpoint(p1, p2);      //使用constexpr函数的结果
                                            //初始化constexpr对象
```

这太令人激动了。它意味着`mid`对象通过调用构造函数，*getter*和非成员函数来进行初始化过程就能在只读内存中被创建出来！它也意味着你可以在模板实参或者需要枚举名的值的表达式里面使用像`mid.xValue() * 10`的表达式！（因为`Point::xValue`返回`double`，`mid.xValue() * 10`也是个`double`。浮点数类型不可被用于实例化模板或者说明枚举名的值，但是它们可以被用来作为产生整数值的大表达式的一部分。比如，`static_cast<int>(mid.xValue() * 10)`可以被用来实例化模板或者说明枚举名的值。）它也意味着以前相对严格的编译期完成的工作和运行时完成的工作的界限变得模糊，一些传统上在运行时的计算过程能并入编译时。越多这样的代码并入，你的程序就越快。（然而，编译会花费更长时间）

在C++11中，有两个限制使得`Point`的成员函数`setX`和`setY`不能声明为`constexpr`。第一，它们修改它们操作的对象的状态， 并且在C++11中，`constexpr`成员函数是隐式的`const`。第二，它们有`void`返回类型，`void`类型不是C++11中的字面值类型。这两个限制在C++14中放开了，所以C++14中`Point`的*setter*（赋值器）也能声明为`constexpr`：

```
class Point {
public:
    …
    constexpr void setX(double newX) noexcept { x = newX; } //C++14
    constexpr void setY(double newY) noexcept { y = newY; } //C++14
    …
};
```

现在也能写这样的函数：

```
//返回p相对于原点的镜像
constexpr Point reflection(const Point& p) noexcept
{
    Point result;                   //创建non-const Point
    result.setX(-p.xValue());       //设定它的x和y值
    result.setY(-p.yValue());
    return result;                  //返回它的副本
}
```

客户端代码可以这样写：

```
constexpr Point p1(9.4, 27.7);          //和之前一样
constexpr Point p2(28.8, 5.3);
constexpr auto mid = midpoint(p1, p2);

constexpr auto reflectedMid =         //reflectedMid的值
    reflection(mid);                  //(-19.1, -16.5)在编译期可知
```

本条款的建议是尽可能的使用`constexpr`，现在我希望大家已经明白缘由：`constexpr`对象和`constexpr`函数可以使用的范围比non-`constexpr`对象和函数大得多。使用`constexpr`关键字可以最大化你的对象和函数可以使用的场景。

还有个重要的需要注意的是`constexpr`是对象和函数接口的一部分。加上`constexpr`相当于宣称“我能被用在C++要求常量表达式的地方”。如果你声明一个对象或者函数是`constexpr`，客户端程序员就可能会在那些场景中使用它。如果你后面认为使用`constexpr`是一个错误并想移除它，你可能造成大量客户端代码不能编译。（为了debug或者性能优化而添加I/O到一个函数中这样简单的动作可能就导致这样的问题，因为I/O语句一般不被允许出现在`constexpr`函数里）“尽可能”的使用`constexpr`表示你需要长期坚持对某个对象或者函数施加这种限制。

**请记住：**

* `constexpr`对象是`const`，它被在编译期可知的值初始化
* 当传递编译期可知的值时，`constexpr`函数可以产出编译期可知的结果
* `constexpr`对象和函数可以使用的范围比non-`constexpr`对象和函数要大

## 三、动手实践（代码案例）

constexpr 代码示例已在上述各节中详述（编译期斐波那契、数组大小验证、阶乘等），此处不重复。核心要点：(1) constexpr函数需用编译期常量参数调用才能在编译期求值；(2) C++14起函数体可含循环/条件；(3) C++17起可用 if constexpr 做编译期分支；(4) C++20起支持 constexpr new/vector/string。

## 四、进阶应用（≥500字）

### 4.1 if constexpr 的编译器实现

`if constexpr(condition)` 的核心机制是编译期分支——当 condition 为编译期常量且为 false 时，未选中分支的代码不会被实例化。这与普通 `if` 的根本区别：
- 普通 `if`：两个分支都必须语法正确且可编译
- `if constexpr`：未选中分支完全不参与编译（仅做语法检查），允许依赖模板参数的分支在特定实例化时失效

典型应用：替代标签分发(tag dispatch)、SFINAE重载、std::enable_if。

### 4.2 consteval 与 constinit（C++20）

- **consteval**：立即函数(immediate function)，只能在编译期调用，不在运行时生成代码。比 constexpr 更严格：constexpr 函数可在运行时调用，consteval 必须编译期
- **constinit**：变量初始化必须在编译期完成，但变量本身非 const（可修改）。与 constexpr 变量的区别：constexpr 隐含 const，constinit 不隐含

```c++
consteval int compile_only(int n) { return n * n; }
constexpr int runtime_or_compile(int n) { return n * n; }
int x = compile_only(5);      // ✓ 编译期
int y = compile_only(x);      // ✗ x非编译期常量
int z = runtime_or_compile(5);// ✓
int w = runtime_or_compile(x);// ✓ 退化为运行时
```

### 4.3 与其他主题的关联

- **模板元编程**：constexpr 函数逐步替代传统模板递归（可读性更好）
- **static_assert**：与 constexpr 天然配合——`static_assert(constexpr_fn(x), "error")`
- **编译期反射**：C++26的反射提案依赖 constexpr 基础设施
- **std::is_constant_evaluated()** (C++20)：在 constexpr 函数内判断当前是否在编译期上下文

### 4.4 工程中的最佳实践

- **迁移宏常量**：用 `constexpr` 替代 `#define N 100`
- **编译期断言**：`static_assert(sizeof(T) == expected)` 在编译期捕获错误
- **轻量级函数**：数学常量计算/参数验证优先标记 constexpr
- **避免滥用**：非性能敏感代码不必强行 constexpr，保持代码可读性优先


## 五、源码解析和实践感悟

### 5.1 constexpr 函数的编译期求值机制

编译器用 AST 解释器在编译期执行 constexpr 函数：

```c++
// 编译器内部模拟：constexpr 求值器
struct ConstexprEvaluator {
    Value visit(const BinaryOpExpr* e) {
        auto lhs = visit(e->lhs);
        auto rhs = visit(e->rhs);
        switch (e->op) {
            case Add: return lhs + rhs;
            case Mul: return lhs * rhs;
            // ...
        }
    }
    Value visit(const IntegerLiteral* l) { return l->value; }
};
// 编译器在编译期用此求值器计算 constexpr 函数的结果
```

### 5.2 constexpr 与模板的协同

```c++
template<int N>
constexpr int factorial() {
    if constexpr (N > 1) return N * factorial<N-1>();
    else return 1;
}
// factorial<5>() 编译期完全展开为 120
// 二进制中直接嵌入常量 120，零运行时开销
```

### 5.3 constexpr vector 的实现要点

C++20 constexpr 支持 new/delete，但必须在同一 constexpr 上下文中配对释放：

```c++
constexpr int sum_to_n(int n) {
    std::vector<int> v(n);          // C++20 OK
    std::iota(v.begin(), v.end(), 1);
    return std::accumulate(v.begin(), v.end(), 0);
}  // v 的析构函数在编译期释放，若漏释放 → 编译错误

constexpr int result = sum_to_n(100);  // 编译期计算 5050
```

### 5.4 consteval 与 constinit 的区别

- **consteval**：强制编译期求值，否则编译错误。适用于必须编译期计算的函数（如反射信息）。
- **constinit**：确保静态/线程局部变量在编译期初始化，但不要求变量是 const。防止 static init order fiasco。

```c++
consteval int square(int n) { return n * n; }
auto a = square(5);   // OK，编译期
int x = 5;
auto b = square(x);   // 错误！x 不是常量表达式

constinit int g_value = square(10);  // 编译期初始化的全局变量
```

### 5.5 实践经验

1. **标记所有可能 constexpr 的函数**：数学运算、字符串哈希、查找表生成。后期移除 constexpr 是破坏性 API 变更。
2. **constexpr 不是 inline 的替代**：constexpr 函数隐式 inline，但分离编译时需在头文件中定义。
3. **调试 constexpr**：在 constexpr 函数中可加入 `if (!std::is_constant_evaluated())` 分支插入 printf 调试。
4. **编译时间换运行时**：大计算量的 constexpr 可能显著拖慢编译；用 `__builtin_is_constant_evaluated()` 做双路径。
5. **使用 if constexpr 消除运行时分支**：替代运行时 SFINAE，代码更清晰。
6. **constexpr 构造函数**：使得用户自定义类型也可做编译期常量，与模板元编程深度结合。


## 六、面试准备

### Q&A（11题）

**Q1: constexpr 和 const 的区别？**
A: const 表示运行时常量（不可修改）；constexpr 强调编译期可知，所有 constexpr 都是 const，反之不然。

**Q2: constexpr 函数何时运行期/编译期执行？**
A: 参数全是编译期常量时编译期执行，否则退化为普通函数运行期执行（C++11后）。

**Q3: if constexpr 和普通 if 的区别？**
A: if constexpr 在编译期求值条件，不满足的分支不被实例化（模板中分支即使语法错误也不报错）。

**Q4: consteval 和 constexpr 的区别？**
A: consteval 强制编译期求值（立即函数），constexpr 允许运行期回退。consteval 函数内可调用 constexpr 函数。

**Q5: constinit 解决什么问题？**
A: 保证静态存储期变量编译期初始化，避免 static init order fiasco（跨翻译单元的全局变量未定义初始化顺序）。

**Q6: C++20 constexpr 有哪些突破？**
A: 支持 new/delete（同一上下文中配对）、虚函数、try-catch（未被捕获时编译错误）、std::vector/std::string。

**Q7: constexpr 函数的限制？**
A: 参数和返回值必须是字面类型；不能调用非 constexpr 函数；C++11 限制单 return 语句。

**Q8: 字面类型 LiteralType 是什么？**
A: 标量类型、引用、字面类型数组、有 constexpr 构造函数的类（所有非静态成员都是字面类型）。

**Q9: constexpr lambda 的要点？**
A: C++17 起 lambda 默认 constexpr（如果可以）。捕获的变量必须是 constexpr，函数体满足 constexpr 限制。

**Q10: std::is_constant_evaluated() 的作用？**
A: 在 constexpr 函数中判断当前是否在编译期求值上下文。用于双路径优化或调试输出。

**Q11: constexpr 与模板元编程的关系？**
A: constexpr 是现代替代 TMP 的方式：用普通函数 + constexpr 代替递归模板实例化，代码更直白。

### 陷阱与反问（5个）

1. **陷阱**：constexpr 函数不一定在编译期执行。**反问**："如何确保某个调用一定是编译期求值？"（答：用 consteval 或赋值给 constexpr 变量）
2. **陷阱**：if constexpr 中某个分支语法错误，只有当条件触发时才报错。
3. **陷阱**：constexpr 函数分离声明和定义会报错——constexpr 函数必须定义在调用者的翻译单元中。
4. **陷阱**：consteval 函数中调用运行期函数编译失败。
5. **陷阱**：C++17 constexpr lambda 可以隐式用，但 C++11/14 需显式标记。

### 一句话答案（8个）

1. constexpr = 编译期常量 + 编译期函数（可选运行期回退）。
2. consteval = 强制编译期，立即函数。
3. constinit = 编译期初始化的非 const 变量，防 init order fiasco。
4. if constexpr = 编译期条件分支，死分支不实例化。
5. constexpr 隐式 inline，必须定义在头文件。
6. C++20 constexpr 支持 new/delete、vec、string。
7. std::is_constant_evaluated() 区分编译/运行期上下文。
8. constexpr 替代模板递归，可读性更好。

* `constexpr`是对象和函数接口的一部分

![](../../../资源/图片/yuque_01adfb735427.png)

## 附录（模板外原内容收纳）

> 以下为原笔记中额外内容，原样保留于此。

### Effective Modern C++ 参考图片

![](D:\桌面\C++\EffectiveModernCppChinese-master\EffectiveModernCppChinese-master\3.MovingToModernCpp\item15.png "null")
