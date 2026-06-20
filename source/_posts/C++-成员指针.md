---
title: C++ 成员指针
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "基础知识", "基础概念"]
publish: true
---

# C++ 成员指针

## 一、核心概念

- **定义**：成员指针（Pointer-to-Member）是 C++ 特有的指针类型，指向类的非静态成员（数据成员或成员函数），而不是指向具体对象实例
- **关键词**：`T C::*`（数据成员指针）、`T (C::*)(args)`（成员函数指针）、`.*`、`->*`、`std::invoke`、`std::mem_fn`
- **适用场景/边界**：回调机制、命令模式、反射模拟、策略模式；边界：不能指向静态成员（用普通指针即可），不跨类兼容

## 二、详细解析（≥200字）

- **原理拆解（三层递进）**：
  - **第一层——成员指针的"偏移量"本质**：数据成员指针 `int C::*` 实际上存储的是该成员相对于类对象起始地址的偏移量（对简单继承）或完整的三元组（对虚继承）。它不是真正的"地址"，而是"相对位置描述"
  - **第二层——成员函数指针的复杂性**：成员函数指针大小通常是普通指针的 2-4 倍，因为它不仅要存储函数地址，还要存储 this 调整所需的偏移量。对虚函数，存储的是 vtable 索引而非实际地址
  - **第三层——`.*` 和 `->*` 运算符**：这是 C++ 中两个特殊的二元运算符：`obj.*ptr_to_member` 和 `ptr->*ptr_to_member`。它们接受一个对象/指针和一个成员指针，在运行时计算实际成员地址
- **关键数据结构/接口**：成员函数指针在 GCC 中结构为 `{func_addr, this_adjustment, vtable_offset}` 三元组
- **关键公式**：`&C::member` 的类型是 `T C::*`（非 `T*`）；调用语法 `(obj.*ptr)(args)` 或 `(ptr->*mfp)(args)`

## 三、动手实践（代码案例）

```c++
#include <iostream>
#include <functional>

struct Widget {
    int value;
    int id;
    
    Widget(int v, int i) : value(v), id(i) {}
    
    int add(int x) const { return value + x; }
    int mul(int x) const { return value * x; }
};

int main() {
    // 1. 数据成员指针
    int Widget::*pm = &Widget::value;   // 指向 Widget::value
    Widget w(10, 1);
    std::cout << w.*pm << std::endl;     // 10 （通过成员指针访问）
    w.*pm = 42;                          // 修改
    std::cout << w.value << std::endl;   // 42
    
    // 2. 成员函数指针
    int (Widget::*op)(int) const = &Widget::add;
    std::cout << (w.*op)(5) << std::endl;  // 47 (42+5)
    
    op = &Widget::mul;
    std::cout << (w.*op)(2) << std::endl;  // 84 (42*2)
    
    // 3. C++17 std::invoke 统一调用
    std::cout << std::invoke(pm, w) << std::endl;     // 42
    std::cout << std::invoke(op, w, 3) << std::endl;  // 126 (42*3)
    
    // 4. 用成员指针实现通用排序选择器
    auto sort_by = [](auto& vec, auto member_ptr) {
        std::sort(vec.begin(), vec.end(),
            [=](const Widget& a, const Widget& b) {
                return std::invoke(member_ptr, a) < std::invoke(member_ptr, b);
            });
    };
    
    return 0;
}
```

- **预期**：理解成员指针的声明语法、`.*`/`->*` 调用、`std::invoke` 现代替代
- **补充**：`std::mem_fn` 将成员函数指针包装为可调用对象，`std::bind(&C::f, _1, args...)` 绑定成员函数

## 四、进阶应用（≥500字）

- **与其他主题的关联**：与类型擦除（`std::function`/`std::bind` 内部使用成员指针）、反射（编译期遍历类成员）、信号槽机制（Qt moc 依赖成员指针做回调）强相关
- **工程中的真实用法**：
  - **命令模式**：用成员函数指针 + 对象指针表示可延迟执行的操作。`std::function<void()>` 是一种更现代的类型擦除替代
  - **通用排序选择器**：数据成员指针让模板函数可以按任意字段排序，比写多个 lambda 更简洁
  - **工厂注册表**：成员函数指针可将构造函数封装为工厂方法，配合静态注册表实现反射式创建
  - **Qt 信号槽**：`connect(sender, &Sender::signal, receiver, &Receiver::slot)` 中的 `&Sender::signal` 就是成员函数指针
- **常见陷阱**：
  - **语法优先级**：`obj.*pm` 需要括号包裹 `(obj.*pm)()` 因为函数调用优先级高于 `.*`
  - **不能指向静态成员**：静态成员本质是普通全局变量/函数，用普通指针即可
  - **大小差异**：成员函数指针可能比 `void*` 大得多（GCC: 16 字节，MSVC: 4/8/12/16 字节取决于继承方式）
  - **`std::invoke` 替代**：C++17 起推荐用 `std::invoke(pm, obj, args...)` 统一普通函数、成员函数、函数对象调用

## 五、源码解析和实践感悟

### 1. 成员函数指针的三元组结构

```c++
// GCC 实现简化（itanium ABI）
struct member_function_pointer {
    intptr_t func_addr;       // 虚函数: vtable_index+1；非虚: 实际地址
    intptr_t this_adjustment; // this 指针偏移（多继承/虚继承时调整）
    // vtable_offset 隐含在 func_addr 中（通过 is_virtual 标志）
};
// sizeof(member_function_pointer) == 16 (64-bit)
// 原因：虚继承中需要知道 this 调整量和 vtable 中的位置
```

### 2. 数据成员指针的偏移量本质

```c++
struct Base { int a; };
struct Derived : Base { int b; };

int Base::*pm_a = &Base::a;    // offset = 0
int Derived::*pm_b = &Derived::b;  // offset = sizeof(Base) = 4

// 成员指针可隐式向上转换
int Base::*pm = static_cast<int Base::*>(&Derived::b);  // offset 自动调整
```

### 实践经验

1. **成员指针不能序列化**：它的值依赖于编译期的类布局，跨版本/跨编译器不兼容
2. **`std::invoke` 是未来**：C++17 `std::invoke` + `std::is_invocable` 统一了所有可调用类型的调用语法
3. **多继承调整**：成员函数指针中的 this_adjustment 用于正确的 this 指针计算——如果 B 继承 A，`void (A::*)()` 指向 B 的成员函数时需要将 B* 调整为 A*
4. **虚函数寻址**：虚函数成员指针存储 vtable index，调用时通过 `*(vptr + index)` 间接寻址，开销与虚函数调用相同
5. **`std::function` 内部**：`std::function` 使用类型擦除存储成员指针 + 对象指针/引用，使用小对象优化（SBO）避免堆分配

## 六、面试准备

### Q&A（8题）

**Q1: 成员指针和普通指针的区别？**
A: 成员指针是"偏移量"或"寻址信息"，必须配合具体对象才能访问；普通指针是具体的虚拟内存地址

**Q2: `.*` 和 `->*` 的用法？**
A: `obj.*pm` 通过对象调用成员指针；`ptr->*pm` 通过指针调用。调用成员函数时需括号：`(obj.*mfp)(args)`

**Q3: 成员函数指针为什么可能比 void* 大？**
A: 需要存储 this 调整量（多继承）和 vtable 索引（虚函数），GCC 下 16 字节

**Q4: 成员指针能指向静态成员吗？**
A: 不能也不必要——静态成员无 this 指针，用普通指针即可

**Q5: `std::invoke` 相比 `.*` 的优势？**
A: 统一调用语法，可用于模板泛型编程；自动处理成员指针/普通函数/函数对象

**Q6: 多继承中成员指针如何工作？**
A: 成员函数指针包含 this_adjustment，调用时自动将派生类指针调整为正确的基类指针

**Q7: 虚函数的成员指针调用效率？**
A: 与非虚成员函数指针相同——指针中存 vtable index，调用时走虚函数查找路径

**Q8: 成员指针能在运行时动态创建吗？**
A: 不能——成员指针值在编译期确定，取决于类型的静态布局。无运行时反射机制

### 陷阱与反问（5个）

1. **陷阱**：`(obj.*mfp)(args)` 忘加括号→编译错误，因为 `()` 优先级高于 `.*`
2. **反问**：成员指针和 lambda 选哪个？→ lambda 更灵活、类型安全，成员指针更适合需要运行时切换的场景
3. **陷阱**：跨编译单元传递成员指针→类布局变化（新增成员）导致偏移量失效，ODR 违规
4. **反问**：为什么不用 `offsetof` 代替成员指针？→ offsetof 是宏，无类型信息；成员指针是类型安全的
5. **陷阱**：成员函数指针判空→`if(mfp)` 不保证可移植，用 `if(mfp != nullptr)` 或 C++11 `if(mfp)`

### 一句话答案（5个）

1. **成员指针本质**：相对于类对象的偏移量或寻址信息
2. **`.*` 和 `->*`**：C++ 特有的成员访问运算符
3. **成员函数指针大小**：通常 8-16 字节（含 this_adjustment）
4. **`std::invoke`**：C++17 统一调用成员指针的现代方式
5. **应用场景**：回调、命令模式、通用排序选择器
