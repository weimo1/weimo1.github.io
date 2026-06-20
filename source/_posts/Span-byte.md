---
title: Span   byte
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "现代C++特性"]
publish: true
---

# Span   byte

> 适用范围：C++20 std::span 非拥有型连续内存视图、std::byte 类型安全字节操作

## 一、核心概念

- **定义**：`std::span<T>` 是 C++20 引入的非拥有型连续内存视图，仅持有数据指针和长度（类似 string_view 的泛化版本）。`std::byte` 是 C++17 引入的类型安全字节类型，替代 `char`/`unsigned char` 进行原始内存操作
- **关键词**：非拥有型视图、连续内存、边界安全、类型安全字节、静态/动态长度
- **适用场景/边界**：
  - 统一API接口：一个函数接收数组/C数组/vector/array等所有连续容器
  - 子范围传递：无需指针+长度的不安全组合
  - 边界：span不拥有数据（生命周期必须长于span）；不能用于非连续容器（list/map）

## 二、详细解析（≥200字）

### 2.1 span 的核心设计

**第一层：非拥有视图**。`std::span` 不负责数据生命周期，sizeof通常为 16字节（指针+长度，动态extent）或 8字节（指针，静态extent）。这是与 vector 最根本的区别。

**第二层：统一API**。C++20之前需要为数组/C数组/vector/array 分别写重载；span 提供了一致的接口，自动处理类型转换。

**第三层：边界安全**。span知道数据大小，可执行边界检查。与裸指针+长度相比，span在API层面是不可分割的整体，避免指针和长度不匹配的错误。

### 2.2 std::byte 的设计

`std::byte` 的引入解决 `char`/`unsigned char` 作为"字节容器"时的歧义问题：
- char 有符号/无符号不确定（编译器定义）
- char 允许算术运算（导致意外行为）
- std::byte 仅支持位运算（<<, >>, |, &, ^, ~），禁止算术运算

## 三、动手实践（代码案例）

# std::Span的使用

C++中，我们经常需要传递数组或容器的一部分给函数进行处理。通常的做法是使用指针和长度来表示数组的一部分，但这可能导致越界和难以维护的代码。C++ 20中新引入的std::span，则提供了一种更安全、更直观的方式来处理这种情况。

实际上，std::span是一个非常实用的容器适配器，用于表示连续的内存区域。它并不直接拥有数据，而是提供了一种访问现有数组或容器元素的方式，增强了代码的灵活性和泛型性。std::span可以看作是对指针和长度对的一个类型安全、范围安全的封装，特别适合用于算法和接口设计中，以提高代码的可重用性和安全性。  
  
std::span<T>是一个模板类，其中T是元素的类型，它可以通过数组、标准库容器或其他任何提供迭代器的对象来构造。std::span有两个关键属性：一个是指向连续数据元素的指针，另一个表示元素数量的size\_t值。这使得它可以安全地访问并操作数据范围内的元素，而不需要知道数据的具体存储方式。std::span提供了类似数组的接口，允许我们通过索引访问元素，并提供了size()、empty()、begin()、end()等成员函数来获取关于数据的信息。

我们可以说，std::span 之于 std::vector 和 array 数组类型，就像 std::string\_view 之于 std::string 一样。

类模板 std::span 可在头文件 <span> 中找到。

std::span的主要特点如下。

1、非拥有性。std::span不拥有它所引用的数据，它只是一个视图。

2、类型安全。std::span知道它所引用的数据的类型。

3、边界检查。由于std::span知道数据的大小，因此可以在访问时执行边界检查。

4、灵活性。std::span可以与数组、std::vector、std::array等容器一起使用。

1. **非拥有 (Non-owning)**：这是与 `std::vector` 最根本的区别。`std::span`**不负责**其所指向内存的生命周期。它只是一个观察者或“视图”。当 `std::span` 本身被销毁时，它指向的数据**不会**被销毁。这使得 `std::span` 非常轻量，其大小通常就是两个指针的大小，创建和复制的开销极低
2. [**连续内存**](https://zhida.zhihu.com/search?content_id=261790820&content_type=Article&match_order=1&q=%E8%BF%9E%E7%BB%AD%E5%86%85%E5%AD%98&zhida_source=entity) **(Contiguous)**：`std::span` 只能用于操作内存地址连续的数据结构，例如 C 风格数组、`std::array`、`std::vector` 以及手动分配的内存块。它不能用于 `std::list` 或 `std::map`

**痛点一：**[**API 接口**](https://zhida.zhihu.com/search?content_id=261790820&content_type=Article&match_order=1&q=API+%E6%8E%A5%E5%8F%A3&zhida_source=entity)**不统一**

在 C++20 之前，如果想编写一个可以处理任何连续数据序列的函数，通常需要提供多个重载：

```
// Before C++20
void process_data(const std::vector<int>& data);
void process_data(const std::array<int, 10>& data);
void process_data(const int* data, std::size_t size); // C-style
```

这种方式非常繁琐且容易出错

`std::span` 的解决方案：统一接口

```
#include <span>
#include <vector>
#include <array>

// With C++20 std::span
void process_data(std::span<const int> data) { // 一个函数，接受所有！
    for (int val : data) {
        // ... process val
    }
}

void test() {
    std::vector<int> v = {1, 2, 3};
    std::array<int, 4> a = {4, 5, 6, 7};
    int c_array[] = {8, 9, 10};

    process_data(v);
    process_data(a);
    process_data(c_array); // 隐式转换为 span
}
```

`std::span` 提供了一个通用的词汇类型来表示“一个连续的数据序列”，极大地简化了API设计

**痛点二：C风格接口的安全性差**

`void process_data(const int* data, std::size_t size)` 这种接口非常危险。`data` 和 `size` 是两个独立的参数，很容易传错：

1. 传入的 `size` 大于 `data` 指向的实际内存大小，导致[缓冲区溢出](https://zhida.zhihu.com/search?content_id=261790820&content_type=Article&match_order=1&q=%E7%BC%93%E5%86%B2%E5%8C%BA%E6%BA%A2%E5%87%BA&zhida_source=entity)
2. 忘记传递 `size` 或者传了 `nullptr`

`std::span` 的解决方案：绑定指针和大小

`std::span` 将指针和大小封装在**一个对象**中，让它们始终保持同步

**痛点三：不必要的性能开销**

有时只是想传递数据的一部分给一个函数。使用 `std::vector` 可能需要创建一个新的、只包含子集的 `vector`，这会涉及到昂贵的内存分配和数据拷贝

`std::span` 的解决方案：零开销的切片

`std::span` 的 `subspan()` 成员函数可以创建一个指向原始数据子集的视图，这个操作**没有**任何内存分配和拷贝，仅仅是创建了一个新的、包含不同指针和长度的 `span` 对象

创建 `std::span`

```
#include <span>
#include <vector>
#include <array>

int c_array[] = {1, 2, 3, 4, 5};
std::vector<int> vec = {1, 2, 3, 4, 5};
std::array<int, 5> arr = {1, 2, 3, 4, 5};

// 1. 从 C 数组创建
std::span<int> s1(c_array); // 自动推导大小

// 2. 从 std::vector 创建
std::span<int> s2(vec);

// 3. 从 std::array 创建
std::span<int> s3(arr);

// 4. 从指针和长度创建 (与 C API 交互时常用)
std::span<int> s4(c_array, 3); // 指向 c_array 的前 3 个元素

// 5. 从迭代器创建
std::span<int> s5(vec.begin() + 1, vec.begin() + 4); // 指向 vec 的 [1, 2, 3]
```

**核心操作**

`std::span` 的接口和常见的容器很像：

```
void inspect_span(std::span<const int> data) {
    if (data.empty()) return;

    // 访问大小
    std::cout << "Size: " << data.size() << std::endl;
    std::cout << "Size in bytes: " << data.size_bytes() << std::endl;

    // 访问元素
    std::cout << "First element: " << data.front() << std::endl;
    std::cout << "Last element: " << data.back() << std::endl;
    std::cout << "Element at index 1: " << data[1] << std::endl; // 不进行边界检查

    // 获取底层指针 (与 C API 交互)
    const int* p_data = data.data();

    // 迭代
    for(int val : data) { /* ... */ }
}
```

## **切片 (Slicing)**

这是 `std::span` 的一个强大功能，通过 `subspan()` 实现

```
// 假设 network_packet 是一个包含头部和载荷的缓冲区
std::vector<std::byte> network_packet = get_packet();
std::span<const std::byte> packet_view(network_packet);

// 假设头部是 8 字节
constexpr size_t header_size = 8;
std::span<const std::byte> header = packet_view.subspan(0, header_size);
std::span<const std::byte> payload = packet_view.subspan(header_size); // 从第8字节到末尾

// process_header 和 process_payload 函数可以安全地处理各自的数据视图
process_header(header);
process_payload(payload);
```

**静态大小 和 动态大小 (Fixed vs. Dynamic Extent)**

`std::span` 有一个模板参数 `Extent`，用于在编译期指定大小。

* `std::dynamic_extent`：默认值，表示 `span` 的大小在运行时确定。
* `<N>`：一个具体的整数，表示 `span` 的大小是编译期常量

```
// 动态大小 (最常用)
void process(std::span<int> s);

// 静态大小 (编译期固定为3)
void process_3d_vector(std::span<float, 3> xyz) {
    // 编译器知道大小是3，可以进行优化，比如循环展开
    // xyz.size() 是一个编译期常量
}

float c_pos[] = {1.0, 2.0, 3.0, 4.0};
// process_3d_vector(c_pos); // 编译错误！c_pos 大小是4，不匹配
std::span<float, 4> s_pos(c_pos);
// process_3d_vector(s_pos); // 编译错误！大小不匹配

std::array<float, 3> arr_pos = {1.0, 2.0, 3.0};
process_3d_vector(arr_pos); // OK
```

## span “胖指针”

假如你手一滑，或者老板需求改变，把 buf 缓冲区少留了两个字节：

```
char buf[30];
read(fd, buf, 32);
```

但你 read 的参数依然是 32，就产生了数组越界，又未定义行为了。

我们采用封装精神，把相关的 buf 和 size 封装成一个参数：

```
struct Span {
    char *data;
    size_t size;
};

ssize_t read(FileHandle fd, Span buf);
```

read(fd, Span{buf, 32});

注意：Span 不需要以引用形式传入函数！

```
void read(std::string &buf);  // 如果是 string 类型，参数需要为引用，才能让 read 能够修改 buf 字符串
void read(Span buf);          // Span 不需要，因为 Span 并不是独占资源的类，Span 本身就是个轻量级的引用
```

vector 和 string 这种具有“拷贝构造函数”的 RAII 封装类才需要传入引用 `string &buf`，如果直接传入会发生深拷贝，导致 read 内部修改的是 string 的一份拷贝，无法影响到外界原来的 string。 如果是 Span 参数就不需要 `Span &buf` 引用了，Span 并不是 RAII 封装类，并不持有生命周期，并没有“拷贝构造函数”，他只是个对外部已有 vector、string、或 char[] 的引用。或者说 Span 本身就是一个对原缓冲区的引用，直接传入 read 内部一样可以修改你的缓冲区。

用 Span 结构体虽然看起来更明确了，但是依然不解决用户可能手滑写错缓冲区长度的问题：

```
char buf[30];
read(fd, Span{buf, 32});
```

为此，我们在 Span 里加入一个隐式构造函数：

```
struct Span {
char *data;
size_t size;

template <size_t N>
Span(char (&buf)[N]) : data(buf), size(N) {}
};
```

这将允许 char [N] 隐式转换为 Span，且长度自动就是 N 的值。

此处如果写 `Span(char buf[N])`，会被 C 语言的某条沙雕规则，函数签名会等价于 `Span(char *buf)`，从而只能获取起始地址，而推导不了长度。使用数组引用作为参数 `Span(char (&buf)[N])` 就不会被 C 语言自动退化成起始地址指针了。

用户只需要：

```
char buf[30];
read(fd, Span{buf});
```

等价于 `Span{buf, 30}`，数组长度自动推导，非常方便。

由于我们是隐式构造函数，还可以省略 Span 不写：

```
char buf[30];
read(fd, buf);  // 自动转换成 Span{buf, 30}
```

加入更多类型的支持：

```
struct Span {
char *data;
size_t size;

template <size_t N>
Span(char (&buf)[N]) : data(buf), size(N) {}

template <size_t N>
Span(std::array<char, N> &arr) : data(arr.data()), size(N) {}

Span(std::vector<charN> &vec) : data(vec.data()), size(vec.size()) {}

// 如果有需要，也可以显式写出 Span(buf, 30) 从首地址和长度构造出一个 Span 来
explicit Span(char *data, size_t size) : data(data), size(size) {}
};
```

现在 C 数组、array、vector、都可以隐式转换为 Span 了：

```
char buf1[30];
Span span1 = buf1;

std::array<char, 30> buf2;
Span span2 = buf2;

std::vector<char> buf(30);
Span span3 = buf3;

const char *str = "hello";
Span span4 = Span(str, strlen(str));
```

运用模板元编程，自动支持任何具有 data 和 size 成员的各种标准库容器，包括第三方的，只要他提供 data 和 size 函数。

```
template <class Arr>
concept has_data_size = requires (Arr arr) {
{ arr.data() } -> std::convertible_to<char *>;
{ arr.size() } -> std::same_as<size_t>;
};

struct Span {
char *data;
size_t size;

template <size_t N>
Span(char (&buf)[N]) : data(buf), size(N) {}

template <has_data_size Arr>
Span(Arr &&arr) : data(arr.data()), size(arr.size()) {}
// 满足 has_data_size 的任何类型都可以构造出 Span
// 而标准库的 vector、string、array 容器都含有 .data() 和 .size() 成员函数
};
```

---

如果用户确实有修改长度的需要，可以通过 subspan 成员函数实现：

```
char buf[32];
read(fd, Span(buf).subspan(0, 10));  // 只读取前 10 个字节！
```

subspan 内部实现原理：

```
struct Span {
char *data;
size_t size;

Span subspan(size_t start, size_t length = (size_t)-1) const {
    if (start > size)  // 如果起始位置超出范围，则抛出异常
        throw std::out_of_range("subspan start out of range");
    auto restSize = size - start;
    if (length > restSize) // 如果长度超过上限，则自动截断
        length = restSize;
    return Span(data + start, restSize + length);
}
};
```

可以把 Span 变成模板类，支持任意类型的数组，比如 `Span<int>`。

```
template <class Arr, class T>
concept has_data_size = requires (Arr arr) {
{ std::data(arr) } -> std::convertible_to<T *>;
{ std::size(arr) } -> std::same_as<size_t>;
// 使用 std::data 而不是 .data() 的好处：
// std::data 对于 char (&buf)[N] 这种数组类型也有重载！
// 例如 std::size(buf) 会得到 int buf[N] 的正确长度 N
// 而 sizeof buf 会得到 N * sizeof(int)
// 类似于 sizeof(buf) / sizeof(buf[0]) 的效果
// 不过如果 buf 是普通 int * 指针，会重载失败，直接报错，没有安全隐患
};

template <class T>
struct Span {
T *data;
size_t size;

template <has_data_size<T> Arr>
Span(Arr &&arr) : data(std::data(arr)), size(std::size(arr)) {}
// 👆 同时囊括了 vector、string、array、原始数组
};

template <has_data_size Arr>
Span(Arr &&t) -> Span<std::remove_pointer_t<decltype(std::data(std::declval<Arr &&>()))>>;
```

---

`Span<T>` 表示可读写的数组。 对于只读的数组，用 `Span<const T>` 就可以。

```
ssize_t read(FileHandle fd, Span<char> buf);         // buf 可读写！
ssize_t write(FileHandle fd, Span<const char> buf);  // buf 只读！
```

---

好消息！这东西在 C++20 已经实装，那就是 std::span。 没有 C++20 开发环境的同学，也可以用 GSL 库的 gsl::span，或者 ABSL 库的 absl::Span 来体验。

C++17 还有专门针对字符串的区间类 std::string\_view，可以从 std::string 隐式构造，用法类似，不过切片函数是 substr，还支持 find、find\_first\_of 等 std::string 有的字符串专属函数。

* `std::span<T>` - 任意类型 T 的可读可写数组
* `std::span<const T>` - 任意类型 T 的只读数组
* `std::string_view` - 任意字符串

在 read 函数内部，可以用 .data() 和 .size() 重新取出独立的首地址指针和缓冲区长度，用于伺候 C 语言的老函数：

```
ssize_t read(FileHandle fd, std::span<char> buf) {
    memset(buf.data(), 0, buf.size());  // 课后作业，用所学知识，优化 C 语言的 memset 函数吧！
    ...
        }
```

也可以用 range-based for 循环来遍历：

```
ssize_t read(FileHandle fd, std::span<char> buf) {
    for (auto & c : buf) {  // 注意这里一定要用 auto & 哦！否则无法修改 buf 内容
        c = 'c';
        ...
    }
}
```

# std::mdspan的使用

<https://zhuanlan.zhihu.com/p/1963293221128995391>

`std::mdspan`是 C++23 引入的核心组件（[C++26](https://zhida.zhihu.com/search?content_id=264525488&content_type=Article&match_order=1&q=C%2B%2B26&zhida_source=entity)进一步扩展），全称 **Multidimensional Span**（多维视图）。它是一个轻量级、非拥有（non-owning）的多维数组视图，类似于一维的`std::span`，但支持任意维度。主要设计目标是高性能科学计算（如线性代数、数值模拟）和硬件友好型数据访问。

核心特性如下：

1. 非拥有视图。不管理内存生命周期，仅引用现有数据，零开销抽象（但其实不完全零成本，详见：[Is C++23 std::mdspan a Zero-overhead Abstraction?](https://link.zhihu.com/?target=https%3A//www.youtube.com/watch%3Fv%3D9fRnSQkpNGg)）
2. 多维支持。支持任意维度。
3. 可定制行为。通过布局策略（[Layout Policy](https://zhida.zhihu.com/search?content_id=264525488&content_type=Article&match_order=1&q=Layout+Policy&zhida_source=entity)）控制内存排列方式，通过访问器（[Accessor Policy](https://zhida.zhihu.com/search?content_id=264525488&content_type=Article&match_order=1&q=Accessor+Policy&zhida_source=entity)）控制元素访问方式。

![](../../资源/图片/yuque_9e02e7774759.jpeg)

## 基础操作

`std::mdspan`在头文件 `<mdspan>`中定义：

```
template<
    class T,
    class Extents,
    class LayoutPolicy = std::layout_right,
    class AccessorPolicy = std::default_accessor<T>
> class mdspan;
```

其中：

* `T`指定了底层的数据类型，和`std::span`的第一个参数一样。
* `Extents`指定了维度的信息。
* `LayoutPolicy`指定内存布局方式。
* `AccessorPolicy`指定元素访问的方式。

`std::mdspan`遵循了 `std::span`的模式，我们使用动态或静态维度来创建`std::mdspan`。当然，不同于`std::span`，我们可以指定多个维度，而不仅仅是一个。其声明还通过 `LayoutPolicy`和 `AccessorPolicy`提供了更多定制选项。

### 静态维度

```
#include <mdspan>
#include <vector>
#include <print>

int main() {
	std::vector<int> vec = { 1, 2, 3, 2, 4, 5, 3, 5, 6 };
	std::mdspan<int, std::extents<size_t, 2, 3>> mat{ vec.data() };
	std::print("sizeof: {}, rank: {}, ext 0: {}, ext 1: {}\n", sizeof(mat), mat.rank(), mat.extent(0), mat.extent(1));
}
```

程序输出如下：

sizeof: 8, rank: 2, ext 0: 2, ext 1: 3

我们通过指定`std::mdspan`的第二个模板参数`Extents`为`std::extents<size_t, 2, 3>`，来表示引用一个大小为  的二维矩阵（下标类型为`size_t`）。`std::mdspan`的第一个参数指定了数据的来源，在这段代码里使用了`vec`中的数据。

可以看到静态维度的`std::mdspan`只占用了8字节内存（保存了一个指针指向数据），它的大小是编译期常量不需要占用内存。静态维度的`std::mdspan`通常比动态维度的`std::mdspan`占用更小的内存，而且下标访问速度也更快（乘常数可以被优化成位移运算）。

成员函数`rank`返回这个`std::mdspan`的维数，`extent(i)`返回第i维的长度。

### 动态维度

```
#include <mdspan>
#include <vector>
#include <print>

int main() {
	std::vector<int> vec = { 1, 2, 3, 2, 4, 5, 3, 5, 6 };
	std::mdspan<int, std::dextents<size_t, 2>> mat{ vec.data(), 2, 3 };
	std::print("sizeof: {}, rank: {}, ext 0: {}, ext 1: {}\n", sizeof(mat), mat.rank(), mat.extent(0), mat.extent(1));
}
```

程序输出如下：

sizeof: 24, rank: 2, ext 0: 2, ext 1: 3

我们通过指定`std::mdspan`的第二个模板参数`Extents`为`std::dextents<size_t, 2>`，来让`std::mdspan`引用一个动态大小的二维矩阵。具体地，这个矩阵的长度和宽度可以不是编译期常量，我们通过运行时参数来传递（此处传递了2,3）。

此时`std::mdspan`的大小变成了24字节，内存布局大致如下：

```
struct mdspan {
    int* data; //指向数据的指针
    size_t size[2]; //每一个维度的长度都要保存下来
};
```

`std::dextents<size_t, 2>`其实是`std::extents<size_t, std::dynamic_extents, std::dynamic_extents>`的简写，从C++26开始，可以进一步简写为`std::dims<2>`。 `std::dims<N>`表示一个动态大小的N维张量。

### 混合维度

```
#include <mdspan>
#include <vector>
#include <print>

int main() {
	std::vector<int> vec = { 1, 2, 3, 2, 4, 5, 3, 5, 6 };
	std::mdspan<int, std::extents<size_t, 2, std::dynamic_extent>> mat{ vec.data(), 3 };
	std::print("sizeof: {}, rank: {}, ext 0: {}, ext 1: {}\n", sizeof(mat), mat.rank(), mat.extent(0), mat.extent(1));
}
```

程序输出如下：

sizeof: 16, rank: 2, ext 0: 2, ext 1: 3

上述代码中`std::mdspan`的第一维是编译时确定的（长度为2），第二维是运行时指定的（在模板参数中指定`std::dynamic_extent`，然后再在构造函数中传递实际大小）。

`std::mdspan`具有指定某个维度是动态还是静态的能力，这给了`std::mdspan`非常大的灵活性，也赋予了`std::mdspan`能把编译期优化做到极致的能力。

## 构造函数

### 默认构造

```
constexpr mdspan();
```

样例：

```
#include <mdspan>
#include <vector>
#include <print>

int main() {
	std::mdspan<int, std::dextents<size_t, 2>> empty_span;
	std::println("is empty {}", empty_span.empty());
}
```

### 可变参数构造

```
template< class... OtherIndexTypes >
constexpr explicit mdspan( data_handle_type p, OtherIndexTypes... exts );
```

样例：

```
#include <mdspan>
#include <vector>
#include <print>

int main() {
	int arr[12]{ 0 };
	std::mdspan<int, std::extents<size_t, 3, 4>> span(arr);
	std::println("w: {}, h: {}", span.extent(0), span.extent(1));
	auto ex = span.extents();
	std::println("{}, {}", ex.rank(), ex.static_extent(1));

	std::mdspan<int, std::dextents<size_t, 2>> dspan(arr, 3, 4);
	std::println("w: {}, h: {}", dspan.extent(0), dspan.extent(1));
	auto ex2 = dspan.extents();
	std::println("{}, {}", ex2.rank(), ex2.static_extent(1));
}
```

程序输出如下：

w: 3, h: 4

### 通过std::array构造

```
template< class OtherIndexType, std::size_t N >
constexpr explicit(N != rank_dynamic()) mdspan( data_handle_type p, const std::array<OtherIndexType, N>& exts );
```

样例：

```
#include <mdspan>
#include <vector>
#include <print>

int main() {
	int arr[12]{ 0 };
	std::mdspan span(arr, std::array{ 3, 4 });
}
```

此时可以通过`std::mdspan`的CTAD直接推断出它的模板参数，此处推断出的类型为`std::mdspan<int, std::dims<2>>`。

## 布局策略

由于我们处理的是多维数据，访问元素的方式有多种。为此，我们引入了"布局"策略类来表示不同的选择。

以下是 C++23 标准提供的三种基础布局：

* **layout\_right**：C/C++ 风格的row-major布局，最右侧索引对应内存的连续访问（跨度为1）；
* **layout\_left**：Fortran/Matlab 风格的column-major布局，最左侧索引对应内存的连续访问（跨度为1）；
* **layout\_stride**：上述两种布局的通用形式，可为每个维度单独存储步长（步长值不一定为1）。

此外，C++26 标准还引入了两种新的布局策略：

* **layout\_left\_padded**：row-major布局，最左侧的维度可以有填充；
* **layout\_right\_padded**：column-major布局，最右侧的维度可以有填充。

### **layout\_right** 和 **layout\_left**

`layout_right`和`layout_left`比较容易理解，下面看一个简单的样例：

```
#include <mdspan>
#include <vector>
#include <print>

template <typename layout>
void printMat(std::mdspan<int, std::dims<2>, layout> mat) {
    for (size_t i = 0; i < mat.extent(0); ++i) {
        for (size_t j = 0; j < mat.extent(1); ++j)
            std::print("{} ", mat[i, j]);
        std::println();
    }
}

int main() {
    std::vector<int> vec = { 0, 1, 2, 3, 4, 5 };

    std::mdspan<int, std::dims<2>, std::layout_right> mat{ vec.data(), 2, 3 };
    std::println("right:");
    printMat(mat);

    std::mdspan<int, std::dims<2>, std::layout_left> mat_left{ vec.data(), 2, 3 };
    std::println("left:");
    printMat(mat_left);
}
```

程序输出如下：

right:  
0 1 2  
3 4 5  
left:  
0 2 4  
1 3 5

### layout\_left\_padded 和 layout\_right\_padded

`layout_left_padded`和`layout_right_padded`功能类似，下面只介绍`layout_right_padded`。

`layout_right_padded`为最右边的维度设置了一个最小步长（即填充值）。这个步长可以大于该维度的实际长度，即`extent(rank()-1)`。同样，`PaddingExtent`可以是静态或动态的。 在`layout_right_padded<PaddingStride>`下，这个最小步长被设置为`max(cols, PaddingStride)`。

下面看一段示例代码：

```
#include <mdspan>
#include <vector>
#include <print>

template <typename layout>
void printMat(std::mdspan<int, std::dims<2>, layout> mat) {
    for (size_t i = 0; i < mat.extent(0); ++i) {
        for (size_t j = 0; j < mat.extent(1); ++j)
            std::print("{} ", mat[i, j]);
        std::println();
    }
}

int main() {
    std::vector<int> vec = { 0, 1, 2, 3, 4, 5, 6, 7 };

    using PaddedRight = std::layout_right_padded<std::dynamic_extent>;
    PaddedRight::mapping mapping(std::extents{2, 3}, 4);

    std::mdspan mat{ vec.data(), mapping };
    std::println("right:");
    printMat(mat);
}
```

程序输出如下：

right:  
0 1 2  
4 5 6

如果最小步长是编译时常量，那么直接传递给`layout_right_padded`即可，比如`using PaddedRight = std::layout_right<4>`。

### layout\_stride

`layout_stride`是最具灵活性的布局了，上面的所有4种布局都可以看作是`layout_stride`的特例。`layout_stride`为每一个维度独立指定一个步长（stride）。这个步长定义了在该维度上索引增加 1 时，在内存中的线性偏移量需要增加多少。

`layout_stride::mapping`对象内部存储了两个关键信息：

1. **extents**：描述多维索引空间的大小（每个维度有多少个元素）。
2. **strides**： 一个数组，其大小与 `extents`的秩（rank）相同。`strides[r]`指定了在第 `r`维上索引增加 1 时，在一维内存空间中的地址偏移量。

对于一个多维索引  ，`layout_stride`将其映射到一维偏移量的公式是：

前面的`layout_right_padded`逻辑上等价于下面的代码：

```
#include <mdspan>
#include <vector>
#include <print>

template <typename layout>
void printMat(std::mdspan<int, std::dims<2>, layout> mat) {
    for (size_t i = 0; i < mat.extent(0); ++i) {
        for (size_t j = 0; j < mat.extent(1); ++j)
            std::print("{} ", mat[i, j]);
        std::println();
    }
}

int main() {
    std::vector<int> vec = { 0, 1, 2, 3, 4, 5, 6, 7 };

    std::layout_stride::mapping mapping(std::extents{2, 3}, std::array{4, 1});

    std::mdspan mat{ vec.data(), mapping };
    std::println("right:");
    printMat(mat);
}
```

注意，标准要求步长必须是正数：

![](../../资源/图片/yuque_400f5027a18f.png)

**这里不是很理解为什么要加这个限制，因为步长为负数也是有用的（比如可以实现一个反向索引的span），有人知道原因的话可以在评论区说一下~**

## 访问策略

C++23只提供了最基本的默认访问策略`std::default_accessor`，C++26进一步引入了`std::aligned_accessor`用了提供明确的对齐要求，在未来标准还有可能引入`std::atomic_accessor`来保证元素的访问是原子的。

访问策略用的相对较少，此处就不展开介绍了。

## std::submdspan

`std::submdspan`是一个普通函数。它的第一个参数是一个 `std::mdspan`对象 `x`，其余 `x.rank()`个参数是切片说明符，每个维度一个。这些切片说明符描述了范围 `[0, x.extent(d))`中的哪些元素属于返回的 `std::mdspan`的多维索引空间。

函数签名如下：

```
template<class T, class E, class L, class A,
         class ... SliceArgs)
auto submdspan(mdspan<T,E,L,A> x, SliceArgs ... args);
```

其中`E.rank()`必须等于`sizeof...(SliceArgs)`。

`std::submdspan`支持的4种切片说明符如下：

1. 单个整数值。对于传递给 `std::submdspan`的每个整数值，返回的 `std::mdspan`的秩（rank）将比输入 `mdspan`的秩减少一，因为这个维度只有这一个索引被选取了，这个维度也将不再存在。
2. 任何可转换为 `std::tuple<std::mdspan::index_type, std::mdspan::index_type>`的类型。这个`std::tuple`表示一个左闭右开的索引区间。
3. 标签类 `std::full_extent_t`的实例。这表示在返回的子视图中包含该维度上的全部元素
4. `std::strided_slice`的实例。这个类似于python的切片语法`A[begin:end:step]`，但是又有一些不同。具体地，`std::strided_slice`通过起始位置（begin）、范围长度（extent）及步长（step size）来定义切片，而非python中的起始位置、结束位置与步长组合。这种方法具有一项根本优势：能够将运行时的起始值与编译时确定的范围长度相结合，从而直接为子视图生成静态维度（static extent）。注意，`std::strided_slice`结构采用具名字段而非元组形式，以避免三个参数顺序可能带来的混淆。

样例如下：

```
#include <vector>
#include <print>
#include <mdspan>

void printMat(auto mat) {
    for (size_t i = 0; i < mat.extent(0); ++i) {
        std::print("{} ", mat[i]);
    }
    std::println();
}

int main() {
    std::vector<int> vec = { 0, 1, 2, 3, 4, 5, 6, 7 };

    std::mdspan<int, std::extents<size_t, 2, 4>> mat{ vec.data() };

    printMat(std::submdspan(mat, 1, std::full_extent));
    printMat(std::submdspan(mat, 1, std::tuple{1, 2}));
    printMat(std::submdspan(mat, 1, std::strided_slice{0, 4, 2}));
}
```

程序输出如下：

4 5 6 7  
5  
4 6

可以通过`std::integral_constant`来实现常量切片（得到的`std::mdspan`具有静态维度），代码如下：

```
int main() {
    std::vector<int> vec = { 0, 1, 2, 3, 4, 5, 6, 7 };

    std::mdspan<int, std::extents<size_t, 2, 4>> mat{ vec.data() };

    std::println("{}", sizeof(std::submdspan(mat, 1, std::tuple{1, 2})));
    std::println("{}", sizeof(std::submdspan(mat, 1, std::tuple{std::integral_constant<size_t, 1>{}, std::integral_constant<size_t, 2>{}})));
}
```

程序输出如下：

16  
8

## 总结

`std::mdspan`是 C++23 引入的一个非拥有、引用语义的多维数组视图。它将一个原始指针与一个多维索引空间（由`extents`描述）绑定，并通过可定制的布局策略`LayoutPolicy`和访问策略`AccessorPolicy`来定义元素的内存布局和访问方式。其核心价值在于为零开销的多维数据操作提供了类型安全、灵活且高性能的抽象，是科学计算、机器学习和高性能计算库的理想基础组件，同时也为 C++ 带来了现代、高效且强大的多维数组处理能力。

# std::byte的使用

首先要了解char、signed char、unsigned char在C++中的三重职责：

1. [字节寻址](https://zhida.zhihu.com/search?content_id=715726330&content_type=Answer&match_order=1&q=%E5%AD%97%E8%8A%82%E5%AF%BB%E5%9D%80&zhida_source=entity)：被用于表示内存中的字节，是内存操作的基本单位。
2. 算术类型：可以参与算术运算，如加法、减法等。
3. 字符类型：特别是`char`和`signed char`，它们还被用来表示字符数据，用于处理文本。

这种多重角色很容易导致程序员在处理应当作为原始数据字节的情况下，一不小心就进行了算术运算或字符处理，从而引发错误和混淆。

而`std::byte`的引入正是为了解决这一问题，可以避免多重职责导致的混淆，在C++中，char、signed char和unsigned char承担了多重职责，既用于字节寻址，又用作算术类型和字符类型。这种设计容易导致程序员错误地对字节值进行算术运算，引入std::byte可以避免这种混淆，通过提供一个专门用于字节数据的类型，这样可以清晰地区分字节操作和字符/数值操作，增强程序的[类型安全性](https://zhida.zhihu.com/search?content_id=715726330&content_type=Answer&match_order=1&q=%E7%B1%BB%E5%9E%8B%E5%AE%89%E5%85%A8%E6%80%A7&zhida_source=entity)和表达清晰度。

### 它的作用

1. 提供明确的类型用于实现C++语言定义中的字节概念：`std::byte`它作为一个明确的类型，用于表示内存中的一个字节，而不是通过`char`、`signed char`或`unsigned char`来间接表示。
2. 增强类型安全性：通过引入一个独立的字节类型，`std::byte`有助于区分以字节为单位访问内存与以字符或整数值访问内存的操作，从而提高程序的类型安全性。
3. 提高代码可读性和意图清晰度：使用`std::byte`可以使代码的意图更加明确，即在处理内存中的原始数据，而不是字符或数值，这有助于提高代码的可读性和便于其他程序员或工具理解代码。
4. 便于[位操作](https://zhida.zhihu.com/search?content_id=715726330&content_type=Answer&match_order=1&q=%E4%BD%8D%E6%93%8D%E4%BD%9C&zhida_source=entity)：尽管`std::byte`不是整数类型，但它提供了一系列的位操作函数，可以对字节进行位操作变得更加方便和安全。

c++ 17引入了 一种std::byte类型，它表示内存元素的“nature”类型字节。与char或int类型的关键区别在于，它不是字符类型且非算术类型,它唯一支持的“计算”操作是[位操作符](https://zhida.zhihu.com/search?content_id=476470122&content_type=Answer&match_order=1&q=%E4%BD%8D%E6%93%8D%E4%BD%9C%E7%AC%A6&zhida_source=entity)。

补充知识：

1）一个byte(字节)为八位[二进制](https://zhida.zhihu.com/search?content_id=476470122&content_type=Answer&match_order=1&q=%E4%BA%8C%E8%BF%9B%E5%88%B6&zhida_source=entity)，可以存储十进制数值0-255

2）0x为[十六进制](https://zhida.zhihu.com/search?content_id=476470122&content_type=Answer&match_order=1&q=%E5%8D%81%E5%85%AD%E8%BF%9B%E5%88%B6&zhida_source=entity)，0b为二进制

3）位运算：

```
#include <cstddef> // for std::byte

std::byte b1{0x3F};//
std::byte b2{0b1111'0000};
std::byte b4[4] {b1, b2, std::byte{1}}; // 4 bytes (last is 0)

if (b1 == b4[0]) 
{
    b1 <<= 1;
}

std::cout << std::to_integer<int>(b1) << '\n'; // outputs: \T{126}

//列表初始化(使用大括号)是直接初始化std::byte对象的单个值的唯一方法。
std::byte b1{42}; // OK (as for all enums with fixed underlying type since C++17)
std::byte b2(42); // ERROR
std::byte b3 = 42; // ERROR
std::byte b4 = {42}; // ERROR
```

初始化及相关用法如下：

```
//须用显式转换的整数文字初始化字节数组
std::byte b5[] {1}; // ERROR
std::byte b5[] {std::byte{1}}; // OK

//如果不进行任何初始化，std::byte的值将为堆栈上的对象未定义
std::byte b; // undefined value

//可以强制初始化，所有的位都设置为零，并使用列表初始化
std::byte b{}; // same as bf0g

//std::byte作为布尔值也需要这样的转换
if (b2) ... // ERROR
    if (b2 != std::byte{0}) ... // OK
        if (to_integer<bool>(b2)) ... // ERROR (ADL doesn’t work here)
            if (std::to_integer<bool>(b2)) ... // OK
```

1.std::byte的操作

![](../../资源/图片/yuque_84bd702ffae2.webp)

```
#include <iostream>
#include <string>
#include <cstddef>
#include <bitset>
#include <limits>

int main()
{
    std::byte b1{ 0x3F };
    std::byte b2{ 0b1111'0000 };
    std::byte b4[4]{ b1, b2, std::byte{1} }; // 4 bytes (last is 0)
    std::byte b5[]{ std::byte{1} };
    std::byte b6{};



    if (b2 == std::byte{ 0b1111'0000 })
    {
        std::cout << std::to_integer<int>(b2) << std::endl;
    }

    using ByteBitset = std::bitset<std::numeric_limits<unsigned char>::digits>;
    std::cout << ByteBitset{ std::to_integer<unsigned char>(b1) } << std::endl;

    std::string s = ByteBitset{ std::to_integer<unsigned char>(b2) }.to_string();
    std::cout << s << std::endl;

    return 0;
}
```

## 四、进阶应用（≥500字）

### 4.1 span 的动态extent vs 静态extent

```c++
std::span<int> dynamic_span(arr);         // extent = dynamic_extent, sizeof = 16
std::span<int, 5> static_span(arr);       // extent = 5 (编译期常量), sizeof = 8
```

静态extent允许编译器做更激进的优化（如循环展开），但数组大小必须在编译期确定。

### 4.2 span 的安全边界检查

span提供 `operator[]` 和 `.front()/.back()` 等带边界检查的访问。但在性能关键路径上，这些检查可由编译器的优化消除。与裸指针相比，span在API层面消除了"指针和长度不一致"的风险。

### 4.3 与其他主题的关联

- **string_view**：span 的字符串特化版本，C++17引入
- **mdspan** (C++23)：多维版本，支持矩阵等数据结构
- **指针+长度模式**：span是"指针+长度"对的类型安全替代
- **迭代器**：span提供begin()/end()，可无缝配合标准算法

### 4.4 工程中的最佳实践

- **统一API**：用span替代 (T* ptr, size_t len) 参数组合
- **只读参数用 `span<const T>`**：明确只读意图
- **注意生命周期**：span不拥有数据，被引用数据必须长于span


## 五、源码解析和实践感悟

### 5.1 std::span 的内部实现（简化）

```c++
// libstdc++ 中 std::span 的核心骨架
template<typename T, size_t Extent = dynamic_extent>
class span {
public:
    using element_type = T;
    using pointer = T*;
    using size_type = size_t;

    // 关键：只有两个成员——指针和大小
    pointer data_;
    size_type size_;  // 当 Extent != dynamic_extent 时编译器可优化掉

    // 从连续容器构造
    template<contiguous_range R>
    constexpr explicit span(R&& range)
        : data_(std::data(range)), size_(std::size(range)) {}

    // 从指针+大小构造
    constexpr span(pointer p, size_type n) : data_(p), size_(n) {}

    // 子区间：零拷贝切片
    constexpr span subspan(size_type offset, size_type count) const {
        return span(data_ + offset, count);
    }

    // 访问
    constexpr T& operator[](size_type idx) const { return data_[idx]; }
    constexpr T& front() const { return data_[0]; }
    constexpr T& back() const { return data_[size_ - 1]; }
    constexpr pointer data() const { return data_; }
    constexpr size_type size() const { return size_; }
    constexpr size_type size_bytes() const { return size_ * sizeof(T); }
    constexpr bool empty() const { return size_ == 0; }

    // 迭代器支持 range-based for
    constexpr T* begin() const { return data_; }
    constexpr T* end() const { return data_ + size_; }
};
```

核心设计要点：
- **胖指针**：`{T*, size_t}` 结构，64位下固定 16 字节。与 `string_view` 同构。
- **静态 Extent**：编译期已知大小时 `size_` 被优化掉，sizeof 降为 8 字节，下标访问用位移替代乘法。
- **subspan 零开销**：只做指针偏移，不分配内存、不拷贝数据。返回新的 span 对象（两个寄存器值）。

### 5.2 span 为什么不需要引用传递？

```c++
// span 是 trivial 类型，无 RAII 语义
// 传值 = 复制两个寄存器（指针+长度），和传指针一样快
void process(span<int> s);   // 推荐：值传递，16 字节
void process(span<int>& s);  // 多余：引用传递也是 8 字节，但多了一次解引用

// 对比 vector：传值会触发深拷贝
void process(vector<int> v);      // 慢！拷贝所有元素
void process(const vector<int>& v); // 正确：引用传递
```

本质区别：span 是"视图"（view），不拥有数据。vector 是"容器"，拥有数据。视图传值，容器传引用——这是 C++ 的惯用法。

### 5.3 mdspan 的 layout 策略在内存中的映射

```c++
// 2x3 矩阵，原始内存：{0,1,2,3,4,5}
int data[] = {0, 1, 2, 3, 4, 5};

// layout_right (C/C++ row-major): mat[i][j] = data[i * cols + j]
// mapping: offset(i,j) = i * 3 + j
// mat[0] = {0,1,2}, mat[1] = {3,4,5}
mdspan<int, dims<2>, layout_right> mat_right(data, 2, 3);

// layout_left (Fortran column-major): mat[i][j] = data[i + j * rows]
// mapping: offset(i,j) = i + j * 2
// mat[0] = {0,2,4}, mat[1] = {1,3,5}
mdspan<int, dims<2>, layout_left> mat_left(data, 2, 3);

// layout_stride: 自定义步长
// stride[0] = 4: 行间跳跃 4 个元素
// stride[1] = 1: 列间跳跃 1 个元素
// mat[0] = {0,1,2}, mat[1] = {4,5,6}（跳过了 data[3]）
layout_stride::mapping mapping(extents{2,3}, array{4,1});
```

layout_right_padded 的应用场景：SIMD 对齐。例如 AVX-512 一次处理 16 个 int，用 `layout_right_padded<16>` 确保每行末尾有 padding 对齐到 64 字节边界，避免跨 cache line 的 SIMD 加载。

### 5.4 std::byte 的类型安全设计

```c++
// std::byte 在 libstdc++ 中的定义
enum class byte : unsigned char {};

// 只支持位运算，禁止算术运算
constexpr byte operator|(byte l, byte r) noexcept {
    return byte(static_cast<unsigned char>(
        static_cast<unsigned char>(l) | static_cast<unsigned char>(r)));
}
// 类似定义 & ^ ~ << >> 共六个位运算符

// to_integer 是唯一"逃逸"方式
template<typename IntType>
constexpr IntType to_integer(byte b) noexcept {
    return static_cast<IntType>(b);
}
```

为什么 `byte b2(42)` 编译失败？`enum class` 禁止隐式整数转换，必须用 `byte{42}` 列表初始化。这是刻意的安全设计——防止 `int x = 5; byte b = x;` 这种无意的类型混淆。

### 感悟

1. **span 是 C++ 从"拥有语义"到"视图语义"的关键一步**：类似 Rust 的 `&[T]` 切片。C++20 span 终于补上了这块拼图，配合 ranges 让代码风格更接近函数式。
2. **胖指针模式是跨语言共识**：Go 的 slice（`{ptr, len, cap}`）、Rust 的 `&[T]`（`{ptr, len}`）、C++ 的 span（`{ptr, len}`）都是同构设计。理解一个就能理解全部。
3. **mdspan 的真正价值在 HPC**：科学计算中矩阵乘法、卷积等操作严重依赖内存布局（row-major vs column-major）。mdspan 让 C++ 不必依赖 Fortran 或手写索引计算就能安全表达多维数据。
4. **std::byte 是类型系统进化的缩影**：从 `char` 的三重职责到 `byte` 的单一职责，是 C++ 从"能编译就行"到"类型安全"的持续演进。`enum class` + 位运算重载是零开销的类型安全。
5. **subspan/submdspan 的零开销切片是设计精华**：Python 的切片会拷贝（除非用 memoryview），C++ 的 subspan 就是指针偏移。网络协议解析、文件格式解析中极其实用。
6. **静态 Extent 的优化价值被低估**：`span<int, 4>` 8 字节 vs `span<int>` 16 字节，差异在寄存器压力而非内存。函数参数超过 4-6 个时多出的 8 字节可能导致栈溢出（spill），影响热路径性能。

## 六、面试准备

### 6.1 高频面试题 Q&A

**Q1: std::span 是什么？解决什么问题？**
A: std::span (C++20) 是对连续内存的非拥有视图，封装了 `{T*, size_t}` 胖指针。解决三个痛点：(1) 统一 API——一个函数接受 vector/array/C数组；(2) 安全——绑定指针和大小，避免越界；(3) 零开销切片——subspan 只做指针偏移。

**Q2: span 和 string_view 的关系？**
A: 同构设计——都是 `{指针, 长度}` 的胖指针。`string_view` 是 `span<const char>` 的字符串特化版，多了 find/substr/compare 等字符串操作。span 是通用版，支持任意类型。

**Q3: span 传值还是传引用？为什么？**
A: 传值。span 是 trivial 类型（不管理资源），复制只拷贝 16 字节（两个寄存器），没有深拷贝。传引用反而多一次解引用。容器（vector/string）才需要传引用，因为它们有 RAII 和深拷贝语义。

**Q4: span 的静态 Extent 有什么好处？**
A: `span<int, 4>` 大小在编译期已知：(1) sizeof 从 16 降到 8（长度不存）；(2) 编译器可做循环展开、边界检查消除；(3) 与固定大小 API（如 `span<float,3>` 表示 3D 向量）类型匹配。

**Q5: std::mdspan 是什么？与 span 的关系？**
A: mdspan (C++23) 是多维 span。span 是一维数组视图，mdspan 是 N 维矩阵/张量视图。核心扩展：(1) 多维 extents；(2) 可定制 layout（row-major/column-major/stride）；(3) submdspan 多维切片。

**Q6: layout_right 和 layout_left 的区别？**
A: layout_right = C/C++ 行主序：`mat[i][j] = data[i*cols + j]`，右索引连续。layout_left = Fortran 列主序：`mat[i][j] = data[i + j*rows]`，左索引连续。默认是 layout_right。跨语言互操作时（如 BLAS/LAPACK 通常用列主序）必须匹配。

**Q7: std::byte 和 unsigned char 的区别？**
A: std::byte 是 `enum class`，只支持位运算（`| & ^ ~ << >>`），不支持算术运算和隐式整数转换。unsigned char 可以做算术，也会被隐式转换为 int。byte 用类型系统强制"这就是原始字节，不是数字也不是字符"。

**Q8: 为什么 `std::byte b = 42` 编译失败？**
A: `enum class` 禁止隐式整数转换。必须用列表初始化 `std::byte{42}`。这是安全设计——防止无意的 `int x = 5; byte b = x;` 混淆字节和整数。

**Q9: span 能替代 const vector<T>& 做函数参数吗？**
A: 大多数情况下可以，且有优势：(1) 调用方不用持有 vector，裸数组也能传；(2) 调用方可以只传子区间（subspan）；(3) 语义更清晰——"我需要连续的一段 T"比"我需要一个 vector"更精确。例外：如果函数需要 vector 特有的操作（push_back, resize），则不能用 span。

**Q10: subspan 的边界检查是怎样的？**
A: `subspan(offset, count)` 要求 `offset + count <= size()`，否则未定义行为（类似 `operator[]` 不检查）。标准库实现可选在 debug 模式下做断言。`first(n)` / `last(n)` 同理。

**Q11: mdspan 的 layout_stride 有什么实际用途？**
A: (1) 表达非连续矩阵（如卷积中的 im2col 展开）；(2) 反向索引（Python `[::-1]`，虽然标准要求 stride 为正）；(3) 子矩阵视图（取矩阵的隔行隔列）；(4) 与外部库（如 Eigen、LAPACK）的步长参数对接。

### 6.2 陷阱和反问

| # | 陷阱/反问 | 要点 |
|---|----------|------|
| 1 | span 指向的 vector 扩容后继续用 span 安全吗？ | 不安全。span 持有原始指针，vector 扩容后指针失效（reallocate），span 变成悬空指针。span 不拥有数据，不跟踪生命周期。 |
| 2 | `span<const int>` 能绑定到 `vector<int>` 吗？ | 能。const span 表示只读视图，不要求底层数据是 const 的。类似 `const int*` 可指向非 const int。 |
| 3 | span 能指向 std::deque 吗？ | 不能。deque 内存不连续（分块存储）。span 要求连续内存，只能用于 vector/array/C数组/unique_ptr<T[]>。 |
| 4 | 为什么 `std::byte` 可以用 `<<` 但不能用 `+`？ | `<<` 是位运算（移位），`+` 是算术运算。byte 的设计哲学：字节操作 = 位操作，禁止算数运算来避免语义混淆。 |
| 5 | 反问：span 和 gsl::span 的区别？ | gsl::span 是 C++ Core Guidelines 的实现，比 std::span 早出现。std::span 吸取了 gsl::span 的经验，API 略有不同（如构造方式）。两者核心概念一致。 |
| 6 | 反问：mdspan 的零开销是真的零开销吗？ | 静态 Extents 的 mdspan 确实 sizeof 只有 8 字节（仅存指针），下标访问编译期展开为零偏移计算。动态 Extents 的 sizeof 为 `8 + rank * 8`，每次访问需要查表，仍有轻微开销。 |

### 6.3 一句话答案

- **span 本质**：`{T*, size_t}` 胖指针，连续内存的非拥有视图
- **span vs vector 参数**：span 传值（16 字节拷贝），vector 传 const&（避免深拷贝）
- **静态 Extent 优势**：sizeof 缩半、编译器可循环展开、消除边界检查
- **mdspan 核心**：多维 span + 可定制 layout（row/column-major/stride）
- **std::byte 设计目的**：`enum class` 禁止算术，只留位运算，类型安全表达"原始字节"
- **subspan 零开销**：指针偏移 + 返回新 span，不拷贝数据
- **span 最大坑**：不拥有数据，底层容器释放后 span 悬空
- **layout_right vs left**：C 行主序 vs Fortran 列主序，跨语言互操作必须匹配
