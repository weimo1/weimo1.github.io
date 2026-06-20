---
title: new    malloc
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "内存模型"]
publish: true
---

# new / malloc

> 适用范围：C++ 中 `new`/`delete` 与 `malloc`/`free` 的对比——分配位置、类型安全、构造函数调用、重载机制、POD 与非 POD 类型混用的可行性

## 一、核心概念

- **定义**：`new`/`delete` 是 C++ 运算符，在自由存储区（free store）分配/释放内存并调用构造/析构函数；`malloc`/`free` 是 C 标准库函数，在堆（heap）上分配/释放原始内存，不调用构造/析构函数。
- **关键词**：new、delete、malloc、free、operator new、placement new、自由存储区、堆、POD、内存泄漏
- **适用场景/边界**：C++ 代码默认使用 `new`/`delete`（类型安全+构造保证）；与 C 交互、跨语言内存管理、需要 `realloc` 时使用 `malloc`/`free`；POD 类型理论上可混用但不推荐。

## 二、详细解析（≥200字）

### 第一层：new 表达式的两步操作

`new` 表达式做了两件事：①调用 `operator new` 分配原始内存（等价于 `malloc`）；②在分配的内存上调用构造函数。同理，`delete` 表达式先调用析构函数，再调用 `operator delete` 释放内存。这种分离是 C++ 内存模型的根本哲学——分配内存和构造对象是两个独立操作。

### 第二层：POD 与非 POD 类型混用的可行性

- **POD 类型**（Plain Old Data，平凡构造+平凡析构+标准布局）：`malloc`/`free` 和 `new`/`delete` 可以混用——因为无构造/析构函数需要调用
- **非 POD 类型**（有自定义构造/析构函数、虚函数、非平凡成员）：必须配套使用——`new` 分配的对象必须用 `delete` 释放（否则析构函数不执行），`malloc` 分配的对象必须用 `free` 释放（否则 `delete` 会调用不存在的虚表指针导致未定义行为）

### 第三层：全局变量与局部变量的回收

全局变量操作系统会自己回收（进程退出时），也不会出现内存泄漏，提前回收也可以。但局部变量（栈上对象）必须自己回收——离开作用域时自动析构。堆上分配的对象（`new`/`malloc`）无论全局还是局部，都必须手动回收——除非使用智能指针。

### 核心对比表

| 特征 | new/delete | malloc/free |
|------|-----------|-------------|
| 分配内存的位置 | 自由存储区 | 堆 |
| 返回类型安全性 | 完整类型指针 | void* |
| 内存分配失败返回值 | 默认抛出异常 | 返回 NULL |
| 分配内存的大小 | 由编译器根据类型计算得出 | 必须显式指定字节数 |
| 处理数组 | 有处理数组的 new 版本 new[] | 需要用户计算数组的大小后进行内存分配 |
| 已分配内存的扩充 | 无法直观地处理 | 使用 realloc 简单完成 |
| 是否相互调用 | 可以，看具体的 operator new/delete 实现 | 不可调用 new |
| 分配内存时内存不足 | 无法通过用户代码进行处理 | 能够使用 realloc 函数或重新制定分配器 |
| 函数重载 | 允许 | 不允许 |
| 构造函数与析构函数 | 调用 | 不调用 |

## 三、动手实践（代码案例）

### 基础用法对比

```c++
#include <iostream>

class MyClass {
public:
    MyClass(int value) : myValue(value) {}
    int getValue() const { return myValue; }
private:
    int myValue;
};

// new/delete 用法
MyClass* pObj = new MyClass(10);
std::cout << pObj->getValue() << '\n';
delete pObj;  // 调用析构函数 + 释放内存

// malloc/free 用法
void* raw = malloc(sizeof(MyClass));
MyClass* obj = new(raw) MyClass(20);  // placement new 手动构造
obj->~MyClass();                        // 手动析构
free(raw);                              // 释放内存
```

### POD 类型混用的实验验证

```c++
// POD 类型：可混用 new/delete 和 malloc/free（不推荐但可行）
struct POD {
    int x;
    double y;
};

POD* p1 = static_cast<POD*>(malloc(sizeof(POD)));
p1->x = 42;
free(p1);  // OK：POD 无析构函数

// 非 POD 类型：必须配套使用
struct NonPOD {
    std::string name;
    NonPOD(const char* n) : name(n) {}
    ~NonPOD() { std::cout << "~NonPOD\n"; }
};

NonPOD* p2 = new NonPOD("test");
delete p2;  // OK：调用析构函数
// free(p2);  // 错误！析构函数不执行，string 内存泄漏
```

## 四、进阶应用（≥500字）

### 4.1 为什么 operator new 可被重载而 malloc 不能

`operator new` 是 C++ 的可替换函数——用户可以在全局或类级别提供自定义实现（如集成内存池、添加调试日志）。`malloc` 是 C 标准库函数——可通过 `LD_PRELOAD` 全局替换（如 jemalloc/tcmalloc），但不能做类型级别定制。

### 4.2 自由存储区 vs 堆

标准从概念上区分自由存储区（free store，`new` 分配）和堆（heap，`malloc` 分配），但实际实现中两者通常是同一物理内存区域。关键在于：`operator new` 的实现**可以**不通过 `malloc`——如果用户重载了 `operator new`，它可以从任何地方获取内存（静态 buffer、mmap 映射、GPU 显存等）。

### 4.3 new 的三种形式

- **普通 new**：分配 + 构造，失败抛 `std::bad_alloc`
- **nothrow new**：`new (std::nothrow) T`——失败返回 nullptr
- **placement new**：`new (addr) T`——在已有地址构造，不分配内存

### 4.4 混用的风险与建议

虽然实验验证 POD 类型可混用 `new`/`delete` 和 `malloc`/`free`，但为了代码的可维护性，建议配套使用。混用的问题在于：
1. `new` 分配的地址可能不是 `malloc` 分配的地址（自定义 `operator new` 时）
2. `delete` 和 `free` 的内部实现可能不兼容（不同的内存管理数据结构）
3. 代码阅读者预期 `new` 配 `delete`——混用降低可维护性

### 4.5 内存泄漏检测

全局变量操作系统会自己回收，也不会出现内存泄漏，提前回收也可以。但是局部变量（堆上分配）必须要自己回收。使用工具检测：Valgrind（`--leak-check=full`）、AddressSanitizer（`-fsanitize=address`）、Visual Studio 的 CRT 调试堆（`_CrtDumpMemoryLeaks`）。

## 五、源码解析和实践感悟（≥1000字）

### 5.1 operator new 的默认实现

```c++
// operator new 对 malloc 的封装
void* operator new(std::size_t size) {
    if (size == 0) size = 1;  // 禁止零大小分配
    void* p;
    while ((p = std::malloc(size)) == nullptr) {
        std::new_handler handler = std::get_new_handler();
        if (handler)
            handler();  // 用户可以设置 new_handler 尝试释放内存
        else
            throw std::bad_alloc();
    }
    return p;
}

void operator delete(void* p) noexcept {
    std::free(p);
}
```

### 5.2 new 和 malloc 在多线程下的差异

`new` 在 C++11 起保证 `operator new` 的线程安全性（即使自定义版本也应线程安全）。`malloc` 在 POSIX 标准中也要求线程安全（内部有锁）。但在高竞争场景下，两者的锁实现可能不同——自定义 `operator new` 可以优化锁粒度（如 thread-local cache）。

### 5.3 难点与易错点

1. **new[] 必须配 delete[]**：`new int[10]` 配 `delete p`（而非 `delete[] p`）是未定义行为——可能只释放第一个元素
2. **malloc 后忘记调用构造函数**：`malloc` 返回的原始内存中对象处于未初始化状态——访问其成员是未定义行为
3. **free 前忘记调用析构函数**：非 POD 对象的资源（文件句柄、锁、动态成员）泄漏
4. **自定义 operator new 未配 operator delete**：如果用特殊方式分配（如 `mmap`），必须用对应方式释放——否则崩溃或泄漏

### 经验总结

1. **在 C++ 中默认使用 new/delete**：类型安全 + RAII 兼容 + 异常安全
2. **只在必要场景使用 malloc**：跨语言内存共享（C 库回调）、需要 `realloc`、直接操作原始字节
3. **POD 可混用但不推荐**：为代码一致性，始终配套使用
4. **用智能指针替代裸 new/delete**：`std::make_unique`/`std::make_shared` 是 C++14/11 的最佳实践

## 六、面试准备

### 6.1 高频问法（≥10个）

**Q1：new 和 malloc 的区别？**
A：①new 是运算符，malloc 是函数；②new 返回类型指针，malloc 返回 void*；③new 调用构造函数，malloc 不调用；④new 失败抛异常，malloc 返回 NULL；⑤new 自动计算大小，malloc 需手动指定字节数；⑥new 可重载，malloc 不可重载。

**Q2：new 表达式做了哪两步操作？**
A：①调用 `operator new` 分配原始内存（底层通常调用 malloc）；②在分配的内存上调用构造函数。`delete` 反之：先析构，再 `operator delete`。

**Q3：POD 类型可以混用 new/delete 和 malloc/free 吗？**
A：技术上可以（因为无构造/析构函数），但不推荐——降低代码可维护性。非 POD 类型必须配套使用（否则析构函数不执行或虚表指针错误）。

**Q4：operator new 可以被重载吗？有哪些形式？**
A：可以。全局重载（影响所有 new）、类特定重载（仅影响该类）、placement new（在已有地址构造）。还可以重载 `operator new[]` 和 `operator delete`。

**Q5：malloc(0) 会发生什么？**
A：结果是实现定义的——可能返回 NULL（C 标准允许），也可能返回可安全传递给 `free` 的非 NULL 指针但不可解引用。不要依赖此行为。

**Q6：为什么 C++ 引入 new 而不直接用 malloc？**
A：malloc 不调用构造函数——无法初始化非平凡对象（虚表指针、成员对象等）。new 的类特定重载支持内存池、调试跟踪等高级功能。

**Q7：全局变量 new 分配的内存需要手动 delete 吗？**
A：严格说需要——虽然 OS 在进程退出时会回收所有内存，但如果析构函数有重要的副作用（如 flush 日志、关闭网络连接），不 delete 会导致这些副作用不执行。局部变量必须自己回收。

**Q8：new[] 和 delete[] 的实现原理？**
A：`new T[n]` 分配 `n * sizeof(T) + overhead` 的内存——overhead 存储元素个数（通常放在返回指针之前），`delete[]` 从中读取元素个数依次调用析构函数。`delete`（不带 []）不会读取这个 overhead——因此对数组用 `delete` 是未定义行为。

**Q9：placement new 需要配套 placement delete 吗？**
A：placement new 不分配内存（只在已有地址上构造），因此通常不需要 delete。但若构造函数抛异常，编译器会调用匹配的 placement delete 释放内存。这是 C++ 异常安全的微妙之处。

**Q10：malloc 和 operator new 在多线程环境下的区别？**
A：两者都线程安全（C++11 起保证 operator new 线程安全）。但自定义 operator new 可以优化锁粒度（如 thread-local pool），而 malloc 的内部实现不可干预。此外 operator new 支持 `std::new_handler` 回调，malloc 无等价物。

**Q11：什么时候应该用 malloc 而不是 new？**
A：①与 C 代码交互（跨语言边界）；②需要 `realloc` 调整已分配内存大小；③直接操作原始字节块（如协议解析 buffer）；④配合自定义内存分配器（如 jemalloc）时使用 `malloc` + placement new。

### 6.2 反问点/陷阱点（≥5个）

1. **new 和 malloc 分配的内存是否在同一个区域？**——通常在同一物理内存区域，但标准未规定。如果重载了 `operator new`，它可能从完全不同的来源分配（共享内存、显存）。
2. **delete 非 new 分配的内存会怎样？**——未定义行为！`operator delete` 假设传入的指针来自 `operator new`，内部数据结构可能不兼容，导致 heap corruption。
3. **malloc 后 placement new 再 free 安全吗？**——POD 类型安全；非 POD 不安全——`free` 不调用析构函数，资源泄漏。必须显式析构后再 free。
4. **为什么有 `new (std::nothrow)` 还要普通 new？**——异常是 C++ 的错误处理机制——`new` 失败通常无法恢复，抛异常让上层决定如何降级（返回 nullptr 需要每层都检查，代码膨胀且易遗漏）。
5. **`operator new` 和 `new` 表达式的关系？**——`new` 表达式是一个语法构造，它调用 `operator new` 分配内存然后构造对象。`operator new` 只负责分配原始内存，可以被重载。
6. **`realloc` 可以作用于 `new` 分配的内存吗？**——绝对不行！`realloc` 要求传入 `malloc`/`calloc`/`realloc` 返回的指针。`new` 分配的内存内部结构不同，`realloc` 会导致 heap corruption。

### 6.3 一句话答案（≥5个）

- new = operator new（分配） + 构造函数：**分配和构造是两步，delete 反之**。
- malloc 返回 void* 不调构造函数：**C 的原始内存分配，C++ 应优先用 new**。
- POD 可混用但不推荐：**代码一致性 > 理论可行性**。
- operator new 可重载：**全局或类级别自定义内存策略**。
- new[] 配 delete[]：**delete 不读取元素个数 overhead，行为未定义**。
- placement new = 不分配内存只构造：**在已有地址上构造对象，需手动析构**。
- malloc 场景：**C 交互、realloc 需求、字节级操作**。

## 附录（原内容收纳）

> 本文原有 new/malloc 对比表、代码示例等内容已在各节中整合覆盖。

![](../../资源/图片/yuque_b2ec59a9bf34.png)
![](D:\桌面\C++\EffectiveModernCppChinese-master\EffectiveModernCppChinese-master\4.SmartPointers\base14.png)
