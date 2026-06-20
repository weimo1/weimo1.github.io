---
title: C++单元测试gtest-gmock
date: 2026-06-20
categories:
  - ["项目学习", "基础库与工具"]
publish: true
---

# C++ 单元测试：Google Test & Google Mock

> 适用范围：C++ 单元测试框架——gtest 断言与测试固件、gmock 模拟对象、TDD 流程、可测试性设计与覆盖率。

## 写作约束（铁律）

- **原内容一字不删**：所有原有文字、代码、注释、图片必须全部保留，禁止删除任何原内容。
- **只做归纳重组+增加**：在原有内容基础上调整结构、归类，新增内容以"补充"标记。新增量须让最终篇幅 ≥ 原版。
- **放不进的进附录**：六大段模板容纳不下的原内容，移入最后的「附录」章节，不得丢弃。
- **动笔前先搜索**：做相关知识准备。
- **字数硬指标**：详细解析(二)≥200字、进阶应用(四)≥500字、源码解析与实践感悟(五)≥1000字、面试准备(六)高频问法≥8个且带回答，反问点和一句话答案各≥5个。
- **代码块必须标注语言**：CMake 用 `cmake`，C++ 用 `c++`，禁止无语言标注的裸代码块。

## 一、核心概念

- **定义**：Google Test（gtest）是 C++ 主流单元测试框架，Google Mock（gmock）是其扩展，用于创建模拟对象来替代真实依赖。两者配合实现隔离测试和可测试性设计。
- **关键词**：单元测试、gtest、gmock、Mock、测试固件、断言、EXPECT/ASSERT、代码覆盖率、TDD
- **适用场景/边界**：
  - 任何 C++ 项目的单元测试（跨平台：Linux/Windows/Mac）
  - 通过 Mock 隔离外部依赖（网络、数据库、文件系统）
  - 不适合：集成测试（需用其他框架）、UI 测试

> 来源: [可测试性实践：C++单元测试 gtest & gmock - 腾讯云](https://cloud.tencent.com/developer/article/2532013)

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：测试金字塔**

```
        ┌──────────────┐
        │   UI Tests   │  最慢、成本最高
        ├──────────────┤
        │ Integration  │  集成/端到端测试
        ├──────────────┤
        │  Unit Tests  │  最快、成本最低、覆盖率应最高
        └──────────────┘
```

越接近底层代码的测试，速度越快，成本越低。单元测试位于金字塔底部，应该有最高的覆盖率。引入单元测试有两大目标：
- 提升测试速度和降低测试成本
- 提升代码可测试性

**最终目的只有一个：提升质量。**

**第二层：gtest 核心机制——断言与测试固件**

gtest 提供两类断言：
| 类型 | 失败行为 | 适用场景 |
|------|---------|---------|
| `ASSERT_*` | 立即终止当前测试用例 | 后续代码依赖断言结果（如指针非空后再解引用） |
| `EXPECT_*` | 继续执行，记录失败 | 希望看到所有断言的结果（推荐优先使用） |

测试固件（Test Fixture）：通过 `TEST_F` 宏和继承 `::testing::Test` 共享测试环境和数据。

**第三层：gmock 模拟原理**

Mock 对象通过继承接口并覆盖虚函数，模拟真实对象的行为。gmock 使用 `MOCK_METHOD` 宏生成 Mock 类，`EXPECT_CALL` 设置期望行为和返回值。

为什么引入 Mock：
- 解决环境依赖（网络、数据库等）
- 更早实现接口逻辑（后端未就绪时先行开发）
- 通过模拟驱动更好的代码设计（面向接口编程）

## 三、动手实践（代码案例）

### 3.1 基础 gtest 示例

```c++
#include <gtest/gtest.h>

TEST(HelloTest, BasicAssertions) {
    // Expect two strings not to be equal.
    EXPECT_STRNE("hello", "world");
    // Expect equality.
    EXPECT_EQ(7 * 6, 42);
}
```

- `TEST` 宏定义了一个测试用例
- `HelloTest` 是测试套件名称，可包含多个测试用例
- `BasicAssertions` 是测试用例名称
- `EXPECT_STRNE` 断言两个字符串不相等
- `EXPECT_EQ` 断言两个数值相等

### 3.2 gmock 模拟示例

```c++
#include <gtest/gtest.h>
#include <gmock/gmock.h>

// 定义一个接口
class MyInterface {
public:
    virtual ~MyInterface() = default;
    virtual int Foo(int x) = 0;
};

// 使用 gmock 生成 Mock 类
class MockMyInterface : public MyInterface {
public:
    MOCK_METHOD(int, Foo, (int x), (override));
};

TEST(MockTestSuite, MockTestCase) {
    MockMyInterface mock;
    EXPECT_CALL(mock, Foo(5)).Times(1).WillOnce(testing::Return(10));

    ASSERT_EQ(mock.Foo(5), 10);
}
```

- `MOCK_METHOD` 宏生成 Mock 类，参数依次为：返回类型、函数名、参数列表、修饰符
- `EXPECT_CALL` 设置期望：`Foo(5)` 被调用 1 次，返回 10
- `ASSERT_EQ` 验证返回值

### 3.3 CMake 集成配置

```cmake
cmake_minimum_required(VERSION 3.14)
project(UnitTestProj)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
FetchContent_Declare(
    googletest
    URL https://github.com/google/googletest/archive/03597a01ee50ed33e9dfd640b249b4be3799d395.zip
)
# For Windows: Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

enable_testing()
include_directories(${CMAKE_SOURCE_DIR}/src)
include_directories(${gtest_SOURCE_DIR}/include ${gmock_SOURCE_DIR}/include)

add_executable(unit_test_demo src/hello_test.cpp src/test_mock.cpp)
target_link_libraries(unit_test_demo gtest gmock gtest_main)

include(GoogleTest)
gtest_discover_tests(unit_test_demo)
```

### 3.4 gmock 常用功能速查

**设置调用次数**：
```c++
Times(n)                       // 期望调用 n 次
Times(testing::AtLeast(n))     // 至少 n 次
Times(testing::AtMost(n))      // 至多 n 次
```

**设置返回值**：
```c++
WillOnce(testing::Return(value))           // 一次调用返回 value
WillRepeatedly(testing::Return(value))     // 多次调用返回 value
```

**参数匹配器**：
```c++
testing::Eq(val)    // 等于
testing::Ne(val)    // 不等于
testing::Lt(val)    // 小于
testing::Gt(val)    // 大于
testing::StrEq(str) // 字符串相等
```

**动作（Actions）**：
```c++
WillOnce(testing::Invoke(func))           // 一次调用执行 func
WillRepeatedly(testing::Invoke(func))     // 多次调用执行 func
```

## 四、进阶应用（≥500字）

### 测试覆盖率实践

引入单元测试后，使用以下指标衡量成果：

1. **代码覆盖率**：使用 gcov/lcov 生成覆盖率报告，目标 ≥80% 行覆盖和分支覆盖
2. **缺陷检测率**：统计单元测试发现的缺陷数，目标单测发现 70% 以上缺陷
3. **测试执行时间**：确保单测套件在 5 分钟内完成
4. **测试通过率**：目标 ≥95%
5. **测试维护成本**：定期评估代码变更时的测试修改量
6. **覆盖功能模块**：确保所有关键功能有对应单测

```bash
# gcov 覆盖率统计
cmake -DCMAKE_BUILD_TYPE=Debug -DENABLE_COVERAGE=ON ..
make
./unit_test_demo
gcov src/*.cpp
lcov --capture --directory . --output-file coverage.info
genhtml coverage.info --output-directory coverage_report
```

> 来源: [可测试性实践：C++ 单元测试 & 代码覆盖率统计 - 知乎](https://zhuanlan.zhihu.com/p/719450407)

### TDD（测试驱动开发）流程

```
RED → GREEN → REFACTOR 循环：

1. RED：   先写一个失败的测试（描述期望行为）
2. GREEN： 写最小代码让测试通过
3. REFACTOR：在测试保护下重构代码结构
```

TDD 的优势：
- 从调用者角度设计 API（接口更合理）
- 保证每一行生产代码都有对应测试
- 让重构有安全网

### 可测试性设计原则

1. **依赖注入**：通过构造函数/Setter 注入依赖，而非硬编码
2. **面向接口编程**：依赖抽象接口，方便替换为 Mock
3. **单一职责**：类功能单一，测试容易覆盖
4. **避免静态方法和全局状态**：静态方法难以 Mock，需通过 virtual 接口包装
5. **Seam 模式**：在代码中预留可替换的"接缝"，测试时替换依赖

## 五、源码解析和实践感悟（≥1000字）

### gtest 测试发现机制

`gtest_discover_tests` 会在构建后运行测试可执行文件，通过 `--gtest_list_tests` 参数获取所有测试用例列表，然后为每个测试用例生成独立的 CTest 测试。这允许并行执行和分别报告失败。

### gmock EXPECT_CALL 实现思路

`EXPECT_CALL` 宏的核心机制：
1. 创建一个 Expectation 对象
2. 注册到 Mock 对象的内部表
3. 当 Mock 方法被调用时，检查是否有匹配的 Expectation
4. 匹配则执行动作，不匹配则记录失败
5. Mock 对象析构时，检查所有 Expectation 是否被满足

### 难点与易错点

1. **ASSERT 误用导致测试不完整**

在 `ASSERT` 后的代码不会被执行的测试模块使用 `EXPECT`：

```c++
// ❌ 错误：如果指针为空，后面的 EXPECT_EQ 永远不会执行
void TestFoo() {
    auto* p = GetPointer();
    ASSERT_NE(p, nullptr);
    EXPECT_EQ(p->value, 42);  // ASSERT 失败后这行不执行
}

// ✅ 正确：用 EXPECT 让所有断言都执行
void TestFoo() {
    auto* p = GetPointer();
    EXPECT_NE(p, nullptr);
    if (p) {  // 手动检查避免崩溃
        EXPECT_EQ(p->value, 42);
    }
}
```

2. **接口设计不支持 Mock**

没有虚函数或接口类，gmock 无法生成 Mock 对象。解决方案：为关键类提取纯虚接口，或使用模板+编译期 Mock。

```c++
// ❌ 无法 Mock 的具体类
class Database {
public:
    bool Query(const std::string& sql) { /* 直接访问数据库 */ }
};

// ✅ 可 Mock 的接口设计
class IDatabase {
public:
    virtual ~IDatabase() = default;
    virtual bool Query(const std::string& sql) = 0;
};

class MockDatabase : public IDatabase {
public:
    MOCK_METHOD(bool, Query, (const std::string& sql), (override));
};
```

3. **测试之间状态污染**

不同测试用例可能共享全局状态，导致测试顺序敏感。解决方法：在 TearDown 中清理状态，每个测试使用独立的测试固件。

```c++
class MyTest : public ::testing::Test {
protected:
    void SetUp() override {
        // 每个测试前初始化
        obj_ = new MyClass();
    }
    void TearDown() override {
        // 每个测试后清理
        delete obj_;
        obj_ = nullptr;
    }
    MyClass* obj_;
};

TEST_F(MyTest, Test1) { /* 使用 obj_ */ }
TEST_F(MyTest, Test2) { /* 使用 obj_，不受 Test1 影响 */ }
```

4. **覆盖率 100% 的陷阱**

行覆盖率 100% ≠ 分支覆盖率 100% ≠ 无 Bug。常见遗漏：
- 异常路径未测试
- 边界条件遗漏（空输入、最大值、负值）
- 并发场景未覆盖

### 经验总结（补充）

- **先写测试再写代码（TDD）** 虽然初期成本高，但长期显著减少 Bug 数量和修复成本。国内团队做不好 TDD 的原因：工期压力、缺乏自上而下的支持、认为单测浪费时间的认知。
- **至少对核心逻辑加测试**：不要求 100% 覆盖率，但对公司核心业务逻辑（支付、鉴权、数据一致性）必须有单测保护。
- **区分单元测试和集成测试**：单测不访问真实数据库/网络，集成测试需要。混淆会导致单测慢且脆弱。
- **测试代码也是代码**：好的测试是活文档，描述模块的期望行为。测试命名要清晰（`MethodName_Scenario_ExpectedBehavior`）。

## 六、面试准备（高频问法≥10个，反问点/一句话答案≥5个，均带回答）

### 6.1 高频问法（≥10个）

**基础理解**：

Q1：什么是单元测试？为什么需要它？

A：单元测试是对最小可测试单元（通常是一个函数或类）的自动化验证。作用：1) 尽早发现 Bug，降低修复成本；2) 作为活文档，描述代码行为；3) 支持安全重构，提供回归保护网；4) 改善代码设计（迫使代码模块化）。

Q2：EXPECT 和 ASSERT 的区别？什么时候用哪个？

A：EXPECT 失败后测试继续执行，ASSERT 失败后立即终止。优先用 EXPECT（可以看到更多失败点），只有当后续代码依赖断言成功时才用 ASSERT（如检查指针非空后再解引用）。

Q3：什么是 Mock？为什么需要 Mock？

A：Mock 是模拟对象，替代真实依赖（数据库、网络服务等）。作用：1) 隔离被测代码与外部依赖；2) 让测试快速、稳定、可重复；3) 模拟异常场景（网络超时、返回错误）；4) 面向接口编程的驱动力。

**原理深入**：

Q4：gmock 的 MOCK_METHOD 宏是如何工作的？

A：MOCK_METHOD 为指定函数生成内部存根（stub），记录每次调用参数，并在 EXPECT_CALL 设置的期望满足时执行指定动作。gmock 在对象析构时自动验证所有期望是否被满足。

Q5：测试覆盖率 100% 意味着代码没有 Bug 吗？

A：不。覆盖率只说明代码被执行过，不说明逻辑正确性。遗漏的场景：1) 边界条件未覆盖；2) 异常路径未测试；3) 并发竞态条件；4) 时序依赖问题。高覆盖率是必要条件，不是充分条件。

Q6：什么是测试固件（Test Fixture）？什么时候用 TEST_F 而非 TEST？

A：测试固件是多个测试用例共享的测试环境（初始化 + 清理）。当多个测试需要相同的初始化逻辑或共享数据时，使用 `TEST_F` + 继承 `::testing::Test` 并重写 `SetUp()`/`TearDown()`。

**实践应用**：

Q7：TDD 的红-绿-重构循环是什么？

A：1) RED：先写失败的测试（描述期望行为）；2) GREEN：写最小实现让测试通过；3) REFACTOR：在测试保护下重构代码。核心是先思考"代码应该做什么"再思考"怎么实现"。

Q8：如何让 C++ 代码具备可测试性？

A：1) 依赖注入（通过构造函数传入依赖）；2) 面向接口编程（依赖抽象接口）；3) 避免全局状态和静态方法；4) 保持类功能单一；5) 为关键模块提取纯虚接口以支持 Mock。

Q9：如何统计 C++ 项目的代码覆盖率？

A：使用 gcov + lcov 工具链：编译时加 `--coverage` 标志 → 运行测试生成 .gcda 文件 → gcov 解析生成覆盖信息 → lcov 汇总并生成 HTML 报告。

Q10：在 C++ 项目中，哪些代码应该优先写单元测试？

A：1) 核心业务逻辑（支付、计算）；2) 易出错的复杂算法；3) 频繁变动的模块；4) 边界条件和错误处理路径；5) 公开 API 接口。不优先：简单的 getter/setter、UI 渲染代码、第三方库的薄封装层。

### 6.2 反问点/陷阱点（≥5个）

常见的陷阱问题：

- **陷阱问题1**：为了一段代码方便测试而把它改成 virtual 值得吗？ → 值得。可测试性是代码质量的重要维度。为关键依赖提取接口虽然增加了一层间接，但带来了可测试、可替换、可扩展的好处。如果担心性能，可以在 Release 构建中去虚化（LTO/WPO）。

- **陷阱问题2**：单元测试应该 mock 所有依赖吗？ → 不。只 mock 外部依赖（网络、数据库、文件系统）和难以构造的对象。值对象（std::string、自定义数据结构）和简单的工具函数不需要 mock，直接用真实对象更简单可靠。

- **陷阱问题3**：测试写完了但覆盖率只有 30%，怎么办？ → 不是盲目补测试。先分析未覆盖代码：1) 是不是死代码（直接删除）；2) 是不是集成测试覆盖更合适（不强制单测覆盖）；3) 是不是防御性代码（如不可能发生的 else 分支）。聚焦在核心逻辑的覆盖率上。

- **陷阱问题4**：gmock 的死亡测试是什么？ → 死亡测试（Death Test）验证代码在特定条件下会按预期终止（如 abort、_exit）。用于测试 assert 行为、CHECK 宏。用 `EXPECT_DEATH(statement, regex)` 包装。需要独立子进程运行，速度较慢，不宜滥用。

- **陷阱问题5**：为什么有些团队单元测试做不起来？ → 根本原因：1) 管理层不认可 ROI（短期成本增加）；2) 代码架构不支持测试（紧耦合、无接口）；3) 缺乏测试文化（开发 = 写完功能就行）；4) 测试代码质量差（脆弱、难维护）。解决方案：从核心模块开始，用可测试性倒逼架构改进。

### 6.3 一句话答案（≥5个）

快速记忆要点：

- 单元测试的核心价值是**快速反馈 + 回归保护 + 活文档**
- gmock 的核心是**接口 + 期望 + 动作**三段式
- ASSERT 失败终止，EXPECT 失败继续，优先用 EXPECT
- TDD 的核心循环是**RED → GREEN → REFACTOR**
- 测试覆盖率 ≠ 测试质量，关键是**核心逻辑的路径覆盖**

情景模拟答案：

- 当被问到"你们团队怎么做单元测试"时，回答："我们使用 Google Test + GMock 框架，要求核心模块有 80% 以上覆盖率。CI 流程中自动运行测试套件，不通过不能合并。Mock 外部依赖（MySQL、Redis）确保单测在 3 分钟内跑完。"

- 当被问到"什么时候不写单元测试"时，回答："对于生命周期短的原型代码、一次性脚本、UI 层代码不强制单测。但对于涉及金钱计算、用户鉴权、数据一致性的核心逻辑，单测是必须的。"

- 当被问到"你觉得测试应该占开发时间的多少"时，回答："初期 TDD 可能占 50% 以上时间，熟练后约 30%。但长期看，测试节省的 Debug 和重构时间远超写测试的投入。'Write tests, not bugs.'"

## 附录（模板外原内容收纳）

### 参考链接

- [可测试性实践：C++单元测试 gtest & gmock - 腾讯云开发者社区](https://cloud.tencent.com/developer/article/2532013)
- [可测试性实践：C++ 单元测试 & 代码覆盖率统计 - 知乎](https://zhuanlan.zhihu.com/p/719450407)
- [Google Test & GMock 详细使用指南 - CSDN](https://blog.csdn.net/bandaoyu/article/details/124374057)
- [C++ 雾中风景番外篇：Gtest 与 Gmock - 博客园](https://www.cnblogs.com/happenlee/p/9888900.html)
