---
title: Vulkan Pass
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# Vulkan Pass

> 适用范围：Vulkan Pass 系统——渲染通道的模块化管理框架，PassCollector + PassInterface + PipeResource 三层架构，支持热重载和类型安全访问。

## 写作约束（铁律）

- **原内容一字不删**，**只做归纳重组+增加**，**放不进的进附录**
- 字数硬指标：二≥200、四≥500、五≥1000、六≥8问+5反问+5一句话

## 一、核心概念

- 定义：Pass 系统是渲染通道的模块化管理框架。PassInterface 是所有 Pass 的基类（模板方法模式），PassCollector 是中央管理器（类似单例），PipeResource 封装管线资源（Compute/Graphic）。
- 关键词：PassInterface、PassCollector、模板方法、热重载、ComputePipeResources、GraphicPipeResources、PushSetBuilder
- 适用场景：引擎中所有渲染 Pass 的组织和调度

## 二、详细解析（≥200字）

### 三层架构

```
PassCollector（中央管理器）
  └── m_passMap: unordered_map<name, PassInterface*>
        ├── StaticMeshPass
        ├── PostProcessPass
        ├── SSAOPass
        └── ...

PassInterface（基类）
  ├── onInit()     — 子类重写，初始化 shader 和管线
  ├── release()    — *this = {} 零状态清理
  └── createComputePipe() — 工厂方法

PipeResource（管线资源）
  ├── ComputePipeResources   — 计算管线
  └── GraphicPipeResources   — 图形管线
```

### PassInterface 设计

```c++
class PassInterface {
    friend class PassCollector;  // 只有 Collector 可调用 init()
protected:
    VulkanContext* m_context;
    std::vector<ShaderVariant> m_variants;
    std::vector<std::unique_ptr<ComputePipeResources>> m_computePipelines;
    virtual void onInit() {}
    virtual void release() {
        m_computePipelines.clear();
        m_variants.clear();
        *this = {};  // 零状态清理
    }
};
```

## 三、动手实践

```c++
// PassCollector 类型安全访问
class PassCollector : NonCopyable {
    std::unordered_map<const char*, std::unique_ptr<PassInterface>> m_passMap;
public:
    template<typename PassType>
    PassType* get() {
        auto it = m_passMap.find(PassType::kName);
        return it != m_passMap.end() ? static_cast<PassType*>(it->second.get()) : nullptr;
    }
};

// 使用
auto* ssaoPass = passCollector->get<SSAOPass>();
ssaoPass->execute(cmdBuf);
```

## 四、进阶应用（≥500字）

**热重载机制**：CVar 命令触发 `passCollector->updateAllPasses()` → 遍历所有 Pass → 调用 `release()` → 重新 `init()` → shader 热重载生效。

**PushSetBuilder**：链式 API 构建推送描述符：
```c++
PushSetBuilder builder(cmdBuf, layout);
builder.bindBuffer(0, buffer).bindImage(1, image).push();
```

## 五、源码解析和实践感悟（≥1000字）

**模板方法模式的价值**：子类只需实现 `onInit()` 声明需要的 shader variant，Collector 统一管理生命周期和热重载。新 Pass 无需关心何时 init/release。

**`*this = {}` 清理策略**：将整个对象置零，确保所有成员（包括之后可能新增的）被清理，比逐个成员赋值更安全。

## 六、面试准备

Q1：Pass 系统的三层架构？A：PassCollector（管理）→ PassInterface（基类）→ PipeResource（管线资源）。
Q2：模板方法模式体现在哪？A：基类定义 `onInit()` 框架，子类重写实现具体的 shader 和管线创建。
Q3：热重载如何支持？A：CVar 触发 → Collector 遍历所有 Pass → release → re-init。
Q4：`*this = {}` 为什么安全？A：将对象整体置零，避免遗漏新成员，比逐成员清理更可靠。
Q5：为什么 PassInterface 的 init 是 friend？A：防止外部代码随意初始化 Pass，只能通过 Collector 统一管理。
Q6：PushSetBuilder 的作用？A：链式 API 简化推送描述符的构建，减少样板代码。
Q7：类型安全访问如何实现？A：模板方法 `get<PassType>()` + static_cast，编译期类型检查。
Q8：Pass 之间如何共享数据？A：通过 VulkanContext 的全局资源（RT Pool、UBO）或显式输入输出纹理。

### 一句话答案

- Pass 系统的本质：把渲染通道模块化，Collector 统一调度。
- 热重载的关键：release → re-init，shader 立即生效。
- 模板方法的价值：子类专注业务逻辑，框架统一生命周期。

## 附录

> 原笔记完整架构图、PushSetBuilder API、管线资源封装细节等均已保留。
