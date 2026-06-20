---
title: 多态内存资源(PMR)
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "内存模型"]
publish: true
---

# 多态内存资源(PMR)

> 适用范围：C++17 PMR（Polymorphic Memory Resource）——运行时多态内存分配、STL 容器与自定义内存策略集成、monotonic/pool_resource 的使用与原理

参考链接：

- <https://zhuanlan.zhihu.com/p/703967014>
- <https://zhuanlan.zhihu.com/p/527327054>

## 一、核心概念

- **定义**：PMR 是 C++17 引入的多态内存资源系统，核心是 `std::pmr::memory_resource` 抽象基类 + `std::pmr::polymorphic_allocator` 类型擦除分配器。它用虚函数实现运行时多态的内存策略，解决了传统 allocator 模板参数导致的容器类型膨胀问题。
- **关键词**：PMR、memory_resource、polymorphic_allocator、monotonic_buffer_resource、synchronized_pool_resource、类型擦除、upstream 链式组合
- **适用场景/边界**：适用需要运行时切换内存策略的场景（原型验证、A/B 测试不同分配器）、STL 容器需使用自定义内存池的场景；不适用纳秒级延迟要求（虚函数开销 ~5ns/次）或百万次/帧的小分配场景。

## 二、详细解析（≥200字）

### 第一层：传统 allocator 的三大痛点

C++98 起，标准容器通过模板参数 `Allocator` 支持自定义分配器，但存在三个固有问题：
1. **类型膨胀**：`vector<int, A1>` 和 `vector<int, A2>` 是不同的类型——不同分配器产生不同的函数实例化，编译速度和二进制体积受影响
2. **编译期绑定**：分配策略在编译期确定，无法运行时切换
3. **样板代码多**：手写一个合规的 STL allocator 需要数十行模板代码

### 第二层：PMR 的类型擦除架构

PMR 的核心创新是用虚函数替代模板参数：
- `memory_resource`：定义 `do_allocate()`/`do_deallocate()`/`do_is_equal()` 三个纯虚函数
- `polymorphic_allocator<T>`：仅持有一个 `memory_resource*` 指针，通过虚函数调用代理所有分配操作
- 结果：所有 `pmr::vector<int>` 类型相同——资源在运行时通过构造函数注入

标准库的主要结构：

![](../../资源/图片/yuque_751387c650e7.png)

memory_resource 为分配释放内存的管理类，allocator 和类型相关，向 memory_resource 索取内存，因此构造 allocator 时需传入 upstream（即 memory_resource 的指针）。

### 第三层：五种内置资源

| 组件名称 | 类型 | 核心特性 | 关键用途 |
| --- | --- | --- | --- |
| `memory_resource` | 抽象基类 | 定义内存分配/释放的纯虚接口 | 所有内存资源的基类 |
| `polymorphic_allocator` | 模板分配器类 | 通过 memory_resource 代理内存操作，支持运行时多态 | 将 STL 容器与特定内存资源绑定 |
| `synchronized_pool_resource` | 预置内存资源 | 线程安全的通用内存池，多尺寸块管理，自动碎片合并 | 多线程环境的长期内存管理 |
| `unsynchronized_pool_resource` | 预置内存资源 | 单线程内存池，零同步开销，更快分配速度 | 单线程高性能场景 |
| `monotonic_buffer_resource` | 预置内存资源 | 高性能单向分配器，不支持单独释放，零内存碎片 | 短生命周期对象的批量分配 |

其实内存池的主要原理和策略就是这几个：块预分配（一次性分配大块）、固定尺寸桶（不同大小请求路由到独立子池）、延迟释放（空闲块缓存在池中复用）、块合并（相邻空闲块自动合并）。

`monotonic_buffer_resource` 性能很高，适合一次性操作（函数内使用，返回时内存即释放），类似 protobuf/leveldb 中的 Arena。`synchronized_pool_resource` 和 `unsynchronized_pool_resource` 都是开箱即用的内存池，内置先进的内存整理算法防止碎片，前者线程安全用于多线程环境，后者适用于单线程环境。

![](../../资源/图片/yuque_f82143112db8.webp)

## 三、动手实践（代码案例）

### 使用 monotonic_buffer_resource

```c++
#include <memory_resource>
#include <vector>
#include <string>

// 在栈上创建 1KB 的 monotonic buffer
char buffer[1024];
std::pmr::monotonic_buffer_resource pool(buffer, sizeof(buffer));

// pmr::vector 直接使用该资源
std::pmr::vector<int> vec(&pool);
vec.push_back(42);
vec.push_back(100);  // 所有分配都从 buffer 中来

// pmr::string 也可以绑定同一资源
std::pmr::string str("hello pmr", &pool);
```

### upstream 链式组合

```c++
// pool 作为第一级缓存，monotonic 作为第二级
std::pmr::monotonic_buffer_resource upstream(1024 * 1024);  // 1MB
std::pmr::unsynchronized_pool_resource pool(&upstream);

// 分配流程：先查 pool 的 free list → 没有则向 monotonic 索取
std::pmr::vector<int> vec(&pool);
```

## 四、进阶应用（≥500字）

### 4.1 polymorphic_allocator 的类型擦除机制

传统 allocator 作为模板参数导致类型爆炸——一个函数接收 `vector<int, Alloc>` 时，不同分配器产生不同的函数实例化。PMR 用虚函数开销换类型统一，对编译速度和二进制体积有显著改善。

C++17 引入 PMR 的目的：
1. 池化内存分配，减少频繁系统调用分配或释放内存带来的性能损失
2. 与已有 std 中的 allocator、container 结合，方便使用者自定义相关的内存分配策略类
3. 特殊使用场景：内存分配效率敏感、需要禁用内存分配。如因功能安全需要，自动驾驶代码禁止动态内存分配

### 4.2 内置资源的选型指南

| 场景 | 推荐资源 | 理由 |
|------|---------|------|
| HTTP 请求处理 | monotonic | 请求内所有临时对象统一释放，零碎片 |
| 游戏引擎主循环 | unsynchronized_pool | 单线程，追求极致分配速度 |
| 服务器后台线程池 | synchronized_pool | 多线程共享，需要线程安全 |
| 编译器 AST 构建 | monotonic | 源文件解析完统一回收所有节点 |
| 原型验证阶段 | PMR 任意资源 | 快速切换策略对比性能，无需改容器类型 |

### 4.3 自定义 memory_resource

继承 `std::pmr::memory_resource`，实现三个虚函数：`do_allocate`、`do_deallocate`、`do_is_equal`。`do_is_equal` 用于判断两个资源是否可互换内存（如释放时验证归属）。

### 4.4 关键注意事项

1. **虚函数开销**：每次 `allocate/deallocate` 多一次虚函数调用（~5ns），频繁小分配场景可能占比 10-20%
2. **资源生命周期**：`polymorphic_allocator` 不拥有资源——资源必须比所有使用它的容器活得久
3. **monotonic 的释放语义**：`deallocate` 是空操作！不报错也不释放——设计如此（整体释放优于单次释放）
4. **线程安全**：基类不提供同步保证。`synchronized_pool_resource` 是线程安全的，`unsynchronized_pool_resource` 和 `monotonic_buffer_resource` 不是

![](../../资源/图片/yuque_9dce41c9c4dd.webp)

## 五、源码解析和实践感悟

### polymorphic_allocator 的类型擦除机制

```c++
// simplified polymorphic_allocator implementation
template<typename T>
class polymorphic_allocator {
    memory_resource* resource_;  // 只有一个指针！
public:
    polymorphic_allocator(memory_resource* r) noexcept : resource_(r) {}
    
    T* allocate(size_t n) {
        return static_cast<T*>(
            resource_->allocate(n * sizeof(T), alignof(T))
        );
    }
    
    void deallocate(T* p, size_t n) noexcept {
        resource_->deallocate(p, n * sizeof(T), alignof(T));
    }
};

// 关键：所有 pmr::vector<int> 类型相同，资源在运行时绑定
pmr::monotonic_buffer_resource pool(1024);
pmr::vector<int> vec1(&pool);  // 类型: pmr::vector<int>
pmr::vector<int> vec2(&pool);  // 类型: pmr::vector<int> (相同!)
// 传统 allocator: vector<int,A1> 和 vector<int,A2> 是不同的类型
```

为什么这很重要：传统 allocator 作为模板参数导致类型爆炸——一个函数接收 `vector<int, Alloc>` 时，不同分配器产生不同的函数实例化。PMR 用虚函数开销换类型统一，对编译速度和二进制体积有显著改善。

### monotonic_buffer_resource 的 bump pointer 实现

```c++
// 极简实现——核心是"指针加法"
class monotonic_buffer_resource : public memory_resource {
    char* current_;
    char* end_;
    void* do_allocate(size_t bytes, size_t alignment) override {
        // 对齐当前指针
        uintptr_t aligned = (reinterpret_cast<uintptr_t>(current_) + alignment - 1) 
                           & ~(alignment - 1);
        if (aligned + bytes > reinterpret_cast<uintptr_t>(end_)) {
            return allocate_new_chunk(bytes);  // 分配新块
        }
        current_ = reinterpret_cast<char*>(aligned + bytes);
        return reinterpret_cast<void*>(aligned);
    }
    void do_deallocate(void*, size_t, size_t) override {
        // 什么也不做——单向增长，整体释放
    }
};
```

### synchronized_pool_resource 的锁粒度设计

```c++
// 每个 size class 有独立的池和锁——减少竞争
class synchronized_pool_resource : public memory_resource {
    struct pool {
        mutex mtx;
        list<void*> free_list;
    };
    array<pool, 16> pools_;  // 按大小分 16 个桶
    
    void* do_allocate(size_t bytes, size_t alignment) override {
        size_t idx = size_to_index(bytes);
        lock_guard<mutex> lock(pools_[idx].mtx);  // 仅锁当前桶！
        if (auto p = pools_[idx].try_pop())
            return p;
        return upstream_->allocate(bytes, alignment);
    }
};
```

### 经验总结

1. **monotonic ≈ Arena + 标准接口**：和自定义 Arena 分配器完全同构，但 PMR 版可以通过 `std::pmr::vector` 等标准容器直接使用——无需写任何自定义分配器代码。
2. **什么时候选 PMR 而非手写内存池**：①需要与 STL 容器集成时（`std::pmr::vector/map/string`）；②原型阶段快速验证内存策略；③团队不熟悉内存分配器细节。手写内存池在极致性能要求（如 `alignas` 特殊处理、slab 缓存亲和性）时仍有优势。
3. **memory_resource 不是线程安全的**：基类不提供同步保证。`synchronized_pool_resource` 是线程安全的，`unsynchronized_pool_resource` 和 `monotonic_buffer_resource` 不是。后者必须单线程使用。
4. **do_allocate 的 noexcept 约定**：内存资源的虚函数不抛异常（返回 nullptr 表示失败），顶层 `polymorphic_allocator::allocate` 负责抛 `bad_alloc`。这让内核级别的分配器可以在无异常环境中使用。
5. **upstream 链式组合**：`pool_resource(upstream)` 形成资源链——如果池中没有可用块，向 upstream 索取。这允许嵌套策略：`monotonic(256MB) → pool(monotonic)` → 请求的容器先用池，池空时从 monotonic 拿。
6. **PMR 和 std::pmr::string 的实际案例**：Web 服务器中每个 HTTP 请求创建一个 `monotonic_buffer_resource`（如 64KB），请求内所有字符串操作（路径解析、header 拼接）用 `pmr::string` 绑定这个资源——请求结束时一次性释放所有字符串，碎片为零。

## 相关笔记

- [内存池](/posts/内存池/) — 内存池设计与实现
- [内存分配器](/posts/内存分配器/) — STL allocator 机制
- [内存管理](/posts/内存管理/) — 内存管理全景

## 六、面试准备

### 6.1 高频问法（≥10个）

Q1：PMR 是什么？为什么 C++17 引入它？
A：PMR（Polymorphic Memory Resource）是 C++17 的多态内存资源系统。解决传统 allocator 的三大痛点：①模板参数导致容器类型膨胀（`vector<int,A1>` ≠ `vector<int,A2>`）；②编译期绑定无法运行时切换策略；③手写 allocator 样板代码多。PMR 通过虚函数 `memory_resource` + `polymorphic_allocator` 实现类型擦除和运行时多态。

Q2：polymorphic_allocator 和 std::allocator 的本质区别？
A：`std::allocator` 是编译期多态（模板参数，不同类型不同分配器生成不同容器类型），`polymorphic_allocator` 是运行时多态（虚函数，不同资源但对容器类型无影响）。前者零运行时开销，后者有虚函数开销但类型统一。

Q3：monotonic_buffer_resource 适合什么场景？
A：短生命周期批量分配——例如编译器解析一个源文件期间的 AST 节点、一个 HTTP 请求处理期间的临时数据。优势：极快（bump pointer）、零碎片。限制：不支持单独释放（只能整体销毁）。

Q4：synchronized vs unsynchronized pool_resource 选哪个？
A：多线程访问用 `synchronized_pool_resource`（内部加锁），单线程用 `unsynchronized_pool_resource`（零锁开销，快 2-3x）。如果确定只有一个线程使用该内存池，选 unsynchronized。

Q5：upstream memory_resource 的设计模式？
A：资源链模式（Chain of Responsibility）——每个资源有一个 upstream。当自己无法满足分配时（如池空），向 upstream 请求。`pool_resource(monotonic_resource(256MB))` 表示：先查池缓存 → 池空时从 monotonic 拿 → monotonic 空时抛异常。

Q6：PMR 的性能开销？何时不应使用？
A：每次 `allocate/deallocate` 多一次虚函数调用（~5ns），对于频繁小分配的场景可能占比 10-20%。不应使用的场景：①nanosecond 级要求；②大量 `allocate/deallocate` 对（如百万次/帧）；③内存资源已在编译期确定且不需要运行时切换。这类场景仍用手写 allocator。

Q7：如何自定义 memory_resource？
A：继承 `std::pmr::memory_resource`，实现三个虚函数：`do_allocate`、`do_deallocate`、`do_is_equal`。`do_is_equal` 用于判断两个资源是否可互换内存（如释放时验证归属）。

Q8：std::string 如何用 PMR？
A：`std::pmr::string` 是 `std::basic_string<char, traits, polymorphic_allocator<char>>` 的别名。构造时传入 `memory_resource*`：`pmr::string s("hello", &my_resource)`。

Q9：monotonic_buffer_resource 用完后内存还能复用吗？
A：`release()` 方法重置内部指针到起始位置，之后可重新使用——类似于 Arena 的 reset。内存不归还给 upstream 也不释放给 OS，只是标记为空。

Q10：PMR 和传统内存池（如自写的 ObjectPool）的区别？
A：PMR 是 C++ 标准的一部分——与 STL 容器原生集成（`pmr::vector`、`pmr::string`），接口标准化。自写内存池更灵活（可定制对齐策略、hook 统计、针对特定对象大小优化），但不具备标准库互操作性。

Q11：C++23 对 PMR 有什么增强？
A：①`std::pmr::stacktrace_resource`——记录分配时的调用栈用于调试泄漏；②`std::pmr::buffer_resource`——直接在已有 buffer 上分配（无 extra heap 分配）；③更好的 zero-copy 支持。

### 6.2 反问点/陷阱点（≥5个）

1. **monotonic 的释放错觉**："调了 `do_deallocate` 为什么不释放内存？"——monotonic 的 `deallocate` 是空操作！不代表泄漏——设计如此（整体释放优于单次释放）。
2. **polymorphic_allocator 的传播**："`pmr::vector` 的拷贝——资源会传播吗？"——`polymorphic_allocator` 默认 `propagate_on_container_copy_assignment`，拷贝赋值时资源会传播（两个 vector 共享同一资源）。若不想共享，用 `pmr::vector` 构造时传入不同资源。
3. **winking-out 问题**："容器析构后资源还活着吗？"——`polymorphic_allocator` 不拥有资源（只有继承指针），资源生命周期必须由用户管理。容器析构后资源仍存活（除非你主动销毁它）。
4. **synchronized_pool 的锁粒度**："多线程大量分配——为什么性能还是不好？"——虽然每个 size class 有独立锁，但 upstream 是共享的。大量分配穿透池缓存时，都会竞争 upstream 资源。用 `monotonic` 作为 upstream 可缓解。
5. **不同 memory_resource 之间的 reallocate**："从 pool A 分配的内存，用 pool B 的 deallocate 释放——可以吗？"——`do_is_equal` 返回 false 时，`polymorphic_allocator` 应拒绝这种操作。但程序调用者需自己保证 resource 一致性。
6. **线程安全 ≠ 可重入**："在 signal handler 中调用 PMR 分配内存——安全吗？"——`synchronized_pool_resource::allocate` 在用 mutex，在 signal handler 中可能死锁（如果 signal 中断了持有同一 mutex 的代码）。signal handler 中应使用 `monotonic` 或预分配 buffer。

### 6.3 一句话答案（≥5个）

- PMR = 运行时多态的 allocator：虚函数 `memory_resource` + 类型擦除 = 容器类型统一。
- monotonic = bump pointer + 整体释放：比 malloc 快 20x，零碎片，不支持单对象释放。
- pool_resource = 分级内存池 + 碎片合并：synchronized（多线程） vs unsynchronized（单线程）。
- upstream 链式设计 = CoR 模式：自己满足不了 → 向 upstream 索取。
- PMR 的核心价值 = STL 容器可以用运行时指定的内存策略，而无需改变容器类型。
- 虚函数开销 ~5ns/次——仅在百万次/帧的小分配中显式影响性能。
- `pmr::string` = `basic_string<char, polymorphic_allocator<char>>`，构造时传 `memory_resource*`。
- `do_is_equal` = 判断两个资源的分配/释放是否可互换——多态释放的关键。

## 附录（模板外原内容收纳）

> 本文原有 PMR 组件介绍、内存池原理等内容已在各节中整合覆盖。
