---
title: function
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "现代C++特性"]
publish: true
---

# function

> 适用范围：C++11 `std::function`——通用多态函数包装器（类型擦除 + SBO）。

## 一、核心概念

- **定义**：在C++11标准中，引入了 `std::function` 这一通用多态函数包装器，定义于 `<functional>` 头文件中。它彻底改变了C++中函数对象的使用方式，为不同类型的可调用实体提供了统一的接口。`std::function` 能够存储、复制和调用任何可复制构造的可调用目标，包括函数指针、lambda表达式、`std::bind` 表达式、函数对象以及成员函数指针等。
- **关键词**：`std::function`、类型擦除（Type Erasure）、SBO（Small Buffer Optimization）、可调用对象、`std::bad_function_call`
- **适用场景/边界**：
  - 回调函数管理、事件处理
  - 函数表与策略模式
  - 异步任务与事件处理
  - 不适合性能极致敏感的热路径（有虚函数调用开销）

## 二、详细解析（≥200字）

### 类模板声明

`std::function` 的核心声明如下：

```c++
template< class >
class function; /* 未定义的主模板 */

template< class R, class... Args >
class function<R(Args...)>; /* 特化版本 */
```

其中，`R` 是返回类型，`Args...` 是参数类型列表。这种声明方式允许 `std::function` 包装任意签名的可调用对象。

### 成员类型

| 类型 | 定义 |
| --- | --- |
| `result_type` | 返回类型 `R` |
| `argument_type` | 当参数数量为1时的参数类型（C++17中弃用，C++20中移除） |
| `first_argument_type` | 当参数数量为2时的第一个参数类型（C++17中弃用，C++20中移除） |
| `second_argument_type` | 当参数数量为2时的第二个参数类型（C++17中弃用，C++20中移除） |

### 核心成员函数

- **构造函数**：创建 `std::function` 实例，可接受各种可调用对象
- **析构函数**：销毁 `std::function` 实例
- **operator=**：赋值新的目标对象
- **swap**：交换两个 `std::function` 实例的内容
- **operator bool**：检查是否包含目标对象（非空检查）
- **operator()**：调用存储的目标对象（函数调用操作符）
- **target_type**：获取存储目标的类型信息（`typeid`）
- **target**：获取指向存储目标的指针（类型安全）

### 原理拆解（三层递进）

**第一层：基本工作原理**

`std::function` 简单来说就像是个接口，且能够把符合这个接口的对象储存起来，更神奇的是，两个 `std::function` 的内容可以交换。它可以用于保存并调用任何可调用的东西，比如函数、lambda函数、`std::bind` 表达式、仿函数，甚至是指向对象成员的指针。

**第二层：类型擦除机制**

`std::function` 的实现基于**类型擦除（Type Erasure）**技术：
1. 定义一个通用接口（通常是抽象基类），包含可调用对象的基本操作（如调用、复制等）
2. 为不同类型的可调用对象创建具体实现类，继承自该接口
3. `std::function` 存储一个指向该接口的指针，在运行时动态绑定到具体实现

这种机制使得 `std::function` 能够在编译时接受任意类型的可调用对象，而在运行时保持类型安全。

**第三层：底层机制**

```c++
// std::function 的核心是类型擦除 + 小对象优化(SBO)
template<typename R, typename... Args>
class function<R(Args...)> {
    using invoke_ptr = R(*)(const storage&, Args...);
    using copy_ptr   = void(*)(storage&, const storage&);
    using destroy_ptr= void(*)(storage&);

    invoke_ptr invoker;    // 调用函数指针
    copy_ptr   copier;     // 拷贝函数指针
    destroy_ptr deleter;   // 析构函数指针
    alignas(max_align_t) char buffer[sizeof(void*) * 4];  // SBO 缓冲区
    // 可调用对象 ≤ 缓冲区大小时直接存储，否则堆分配
};
```

- **关键数据结构**：`invoker`/`copier`/`deleter` 函数指针表 + SBO 缓冲区
- **关键公式**：调用路径 = `function::operator()` → `invoker` 函数指针 → 实际可调用对象

## 三、动手实践（代码案例）

### 3.1 手写 Function 实现

```c++
template <typename Ret, typename... Args>
struct Function;

template <typename Ret, typename... Args>
class Function<Ret(Args...)> {
public:
    Function() {}
    Function(std::nullptr_t) {}

    template <typename T>
    Function(T&& func) : m_ptr { new Wrpper<T>(std::forward<T>(func)) } {}

    Function(const Function& rhs) { m_ptr = rhs.m_ptr->clone(); }

    Function& operator=(const Function& rhs) {
        if (this == &rhs) {
            return *this;
        }

        delete m_ptr;
        m_ptr = rhs.m_ptr ? rhs.m_ptr->clone() : nullptr;
        return *this;
    }

    ~Function() {
        if (m_ptr) {
            delete m_ptr;
        }
    }
    Function(Function&& rhs) {
        m_ptr = rhs.m_ptr;
        rhs.m_ptr = nullptr;
    }

    Ret operator()(Args... args) { return (*m_ptr)(std::forward<Args>(args)...); }

private:
    /**
     * @brief 包装类，多态中的最上层函数
     */
    struct WrpperBase {
        virtual Ret operator()(Args&&... args) = 0;
        virtual WrpperBase* clone() = 0;
        virtual ~WrpperBase() = default;
    };

    /**
     * @brief 相当于具体实现的子类内容
     * @tparam Fun 函数
     */
    template <typename Fun>
    struct Wrpper : public WrpperBase {
        Wrpper(const Fun& func) : m_real_func { func } {}
        WrpperBase* clone() override { return new Wrpper<Fun>(m_real_func); }
        Ret operator()(Args&&... args) override {
            return (m_real_func(std::forward<Args>(args)...));
        }
        ~Wrpper() = default;

        Fun m_real_func; // 真正执行的底层函数
    };

private:
    WrpperBase* m_ptr { nullptr }; // 包装函数
};

struct Node {
    int operator()() {
        std::cout << "this is Node class";
        return 111;
    }
};
```

### 3.2 回调函数管理

```c++
class Button {
public:
    using Callback = std::function<void()>;
    
    void set_on_click(Callback cb) {
        on_click_ = std::move(cb);
    }
    
    void click() const {
        if (on_click_) {  // 检查是否有回调
            on_click_();  // 调用回调
        }
    }
    
private:
    Callback on_click_;
};

// 使用示例
Button btn;
btn.set_on_click([]() { std::cout << "Button clicked!\n"; });
btn.click();  // 触发回调
```

### 3.3 函数表与策略模式

```c++
#include <unordered_map>

enum class Operation { Add, Subtract, Multiply };

int main() {
    std::unordered_map<Operation, std::function<int(int, int)>> operations;
    
    operations[Operation::Add] = [](int a, int b) { return a + b; };
    operations[Operation::Subtract] = [](int a, int b) { return a - b; };
    operations[Operation::Multiply] = [](int a, int b) { return a * b; };
    
    std::cout << "3 + 4 = " << operations[Operation::Add](3, 4) << '\n';
    std::cout << "5 - 2 = " << operations[Operation::Subtract](5, 2) << '\n';
    std::cout << "2 * 6 = " << operations[Operation::Multiply](2, 6) << '\n';
}
```

### 3.4 异步任务与事件处理

```c++
// 伪代码示例
std::future<int> async_calculate(std::function<int()> func) {
    return std::async(std::launch::async, func);
}

// 使用
auto future = async_calculate([]() { 
    // 耗时计算
    return 42; 
});
```

## 四、进阶应用（≥500字）

### 注意事项

#### 1. 空状态处理

调用空的 `std::function` 对象会抛出 `std::bad_function_call` 异常：

```c++
std::function<void()> f;
try {
    f();  // 空函数调用
} catch (const std::bad_function_call& e) {
    std::cout << "Error: " << e.what() << '\n';
}
```

因此，在调用前应检查 `std::function` 是否为空：

```c++
if (f) {  // 等价于 if (f.operator bool())
    f();
}
```

#### 2. 返回引用类型的风险

在C++11中，当 `std::function` 存储返回引用的函数时，如果实际返回的是临时对象，会导致悬垂引用：

```c++
// C++11中未定义行为，C++23中禁止
std::function<const int&()> F([] { return 42; }); 
int x = F();  // 未定义行为：引用绑定到临时对象
```

正确的做法是确保返回的引用指向有效对象：

```c++
// 正确示例
std::function<int&()> G([]() -> int& { 
    static int i{42}; 
    return i; 
});
```

#### 3. 性能考量

`std::function` 的类型擦除机制带来了一定的性能开销，包括：
- 堆内存分配（大多数实现）
- 虚函数调用
- 类型检查

因此，在性能敏感的场景中，应权衡灵活性和性能。

#### 4. 与 auto 的区别

`std::function` 与 `auto` 在存储lambda表达式时有本质区别：
- `auto` 根据初始化表达式推导精确类型，无运行时开销
- `std::function` 可以存储任意类型的可调用对象，但有运行时开销
- `auto` 无法用于存储不同类型的可调用对象（如函数表）

```c++
auto lambda = []() { /* ... */ };  // 精确类型
std::function<void()> func = lambda;  // 类型擦除，有开销
```

### SBO 的边界条件

```c++
// SBO 大小由实现决定（通常 16-32 字节）
std::function<void()> f1 = [x=42]{};          // sizeof=8，SBO
std::function<void()> f2 = [a=1,b=2,c=3,d=4,e=5]{}; // sizeof=20，可能堆分配
// 结论：捕获大量状态的 lambda 可能触发堆分配
```

### 总结与最佳实践

1. **明确使用场景**：在需要存储不同类型的可调用对象时使用 `std::function`
2. **检查空状态**：调用前始终检查 `std::function` 是否为空
3. **避免不必要的使用**：在性能敏感且类型固定的场景，优先使用 `auto` 或模板
4. **注意返回引用**：避免返回临时对象的引用，防止悬垂引用
5. **合理设计签名**：定义清晰的函数签名，便于理解和使用

## 五、源码解析和实践感悟（≥1000字）

### 1. std::function 的 SBO 与类型擦除

```c++
// std::function 的核心是类型擦除 + 小对象优化(SBO)
template<typename R, typename... Args>
class function<R(Args...)> {
    using invoke_ptr = R(*)(const storage&, Args...);
    using copy_ptr   = void(*)(storage&, const storage&);
    using destroy_ptr= void(*)(storage&);

    invoke_ptr invoker;    // 调用函数指针
    copy_ptr   copier;     // 拷贝函数指针
    destroy_ptr deleter;   // 析构函数指针
    alignas(max_align_t) char buffer[sizeof(void*) * 4];  // SBO 缓冲区
    // 可调用对象 ≤ 缓冲区大小时直接存储，否则堆分配
};

// 存储 lambda 时：
// 1. 用 placement new 将 lambda 拷贝/移动到 buffer
// 2. 设置 invoker 指向生成的模板函数
// 3. 调用时通过 invoker 间接调用 lambda
```

### 2. SBO 的边界条件

```c++
// SBO 大小由实现决定（通常 16-32 字节）
std::function<void()> f1 = [x=42]{};          // sizeof=8，SBO
std::function<void()> f2 = [a=1,b=2,c=3,d=4,e=5]{}; // sizeof=20，可能堆分配
// 结论：捕获大量状态的 lambda 可能触发堆分配
```

### 3. std::mem_fn 与 function 的关系

```c++
// mem_fn 将成员函数包装为可调用对象
auto getter = std::mem_fn(&std::string::size);
std::function<size_t(const std::string&)> f = getter;
// 内部：f(s) → invoker → getter(s) → s.size()
```

### 实践经验

1. **SBO 阈值为实现定义**：libstdc++ 通常 16 字节，libc++ 通常 24 字节，MSVC 约 32 字节。大 lambda 会堆分配
2. **function 有构造/析构开销**：创建 function 对象时至少需要 3 个函数指针的设置
3. **调用开销 ≈ 虚函数**：通过函数指针间接调用，与虚函数表调用相似
4. **auto 优于 function**：已知类型直接用 auto lambda 避免类型擦除开销
5. **function 支持空状态**：默认构造的 function 为空，调用抛 std::bad_function_call
6. **不能存 move-only 可调用对象**：function 要求可拷贝构造，unique_ptr 的 lambda 无法直接存入

## 相关笔记

- [lambda](/posts/lambda/) — lambda 表达式
- [闭包：仿函数operator() && 绑定器bind && 包装器function && lambda表达式&& 函数指针](/posts/闭包：仿函数operator()-&&-绑定器bind-&&-包装器function-&&-lambda表达式&&-函数指针/) — 5 种可调用对象全景
- [std__invoke](/posts/std__invoke/) — INVOKE 协议

## 六、面试准备

### Q&A（10题）

**Q1: std::function 的底层实现原理？**
A: 类型擦除 + SBO——存储可调用对象的副本（小对象放内部缓冲区，大对象堆分配），通过函数指针间接调用

**Q2: function 调用开销有多大？**
A: 一次间接函数调用（通过 invoker 指针），约等于虚函数调用的开销

**Q3: 什么是 SBO（Small Buffer Optimization）？**
A: 小对象直接在 function 内部的预分配缓冲区中存储，避免堆分配。超出缓冲区大小时堆分配

**Q4: function 和函数指针的区别？**
A: function 可存储任何可调用对象（lambda、bind、仿函数），函数指针只能存储函数/静态函数

**Q5: function 能存储 move-only 的 lambda 吗？**
A: 不能，function 要求可调用对象是 CopyConstructible。需要 move-only 可用 unique_function（实验性）

**Q6: function 的空状态是什么？**
A: 默认构造或赋值 nullptr 后处于空状态，调用抛 std::bad_function_call

**Q7: std::bind 返回的对象能传给 function 吗？**
A: 能，bind 返回的是符合 CopyConstructible 的可调用对象

**Q8: function 存储成员函数指针的正确方式？**
A: `std::function<void(Foo&, int)> f = &Foo::bar;` 第一个参数是对象引用

**Q9: 为什么 lambda 捕获列表过大会影响 function 性能？**
A: 超出 SBO 阈值会触发堆分配，增加构造/拷贝开销

**Q10: function 的 target() 和 target_type() 有什么用？**
A: 获取存储的可调用对象的原始指针和类型，用于 RTTI 检查和恢复原始类型

### 陷阱与反问（5个）

1. **陷阱**：空 function 被调用→抛 std::bad_function_call，不是编译错误
2. **反问**：function 和 virtual 基类哪种方式更好？→ function 提供值语义的类型擦除，virtual 提供引用语义的运行时多态
3. **陷阱**：捕获 shared_ptr 的 lambda→function 拷贝时引用计数增加
4. **反问**：function 能替代模板吗？→ 不能，function 是运行时多态，模板是编译期多态
5. **陷阱**：在 signal/slot 中存 function 并用 lambda 捕获 this→对象析构后调用悬垂

### 一句话答案（8个）

1. **function 本质**：值语义的类型擦除可调用对象容器
2. **SBO 大小**：libstdc++ ~16B，libc++ ~24B，MSVC ~32B
3. **调用路径**：function::operator() → invoker → 实际可调用对象
4. **空状态**：`!f` 为 true，调用时抛 bad_function_call
5. **与 virtual 区别**：function 存储值，virtual 通过引用/指针多态
6. **拷贝语义**：深拷贝存储的可调用对象
7. **引用包装**：`function<void()> f = std::ref(lambda)` 存引用而非拷贝
8. **性能建议**：性能敏感处用 auto lambda 或模板
