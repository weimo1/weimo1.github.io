---
title: Vulkan Shaders
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# Vulkan Shaders

> 适用范围：Vulkan 着色器编译与缓存系统——ShaderVariant 变体描述、ShaderCache 缓存管理、HLSL→SPIR-V 编译管线。

## 写作约束（铁律）

- **原内容一字不删**，**只做归纳重组+增加**，**放不进的进附录**
- 字数硬指标：二≥200、四≥500、五≥1000、六≥8问+5反问+5一句话

## 一、核心概念

- 定义：Vulkan Shaders 系统负责着色器变体管理、HLSL→SPIR-V 编译、编译结果缓存。核心是 ShaderVariant（描述编译参数）+ ShaderCache（hash→VkShaderModule 映射）。
- 关键词：ShaderVariant、ShaderCache、SPIR-V、变体管理、hash 缓存、宏定义、DXC
- 适用场景：所有 Vulkan 渲染管线的着色器编译与管理

## 二、详细解析（≥200字）

### 整体架构

```
应用层 → ShaderVariant（变体描述）→ ShaderCache（缓存）→ VkShaderModule → 渲染管线
```

### ShaderVariant — 变体描述器

```c++
class ShaderVariant {
    std::filesystem::path m_path;           // 着色器源文件路径
    EShaderStage m_shaderStage;             // 顶点/片段/计算
    std::unordered_map<std::wstring, int32_t> m_keyMap;   // 宏键值对
    std::unordered_set<std::wstring> m_macroSet;           // 宏定义集合
};
```

链式 API：`ShaderVariant("shader.glsl", eVertex).setMacro(L"USE_NORMAL_MAP").setInt(L"MAX_LIGHTS", 4)`

### ShaderCache — 缓存管理器

```c++
class ShaderCache final : NonCopyable {
    std::unordered_map<size_t, VkShaderModule> m_moduleCache;  // hash → module
};
```

### 编译流程

1. 准备编译参数（compiler path、source path、save folder）
2. 生成唯一缓存文件名：`filename + hash`
3. 检查缓存文件是否存在 → 命中则直接加载 SPIR-V
4. 未命中 → 调用 DXC/glslang 编译 HLSL/GLSL → SPIR-V
5. 保存 SPIR-V 到缓存文件夹
6. `vkCreateShaderModule` 创建 VkShaderModule

## 三、动手实践（代码案例）

```c++
// 请求着色器
VkShaderModule ShaderCache::createShaderModule(const ShaderVariant& variant, bool bRecompile) {
    size_t hash = variant.getHash();
    if (!bRecompile && m_moduleCache.contains(hash))
        return m_moduleCache[hash];

    // HLSL → SPIR-V 编译
    auto spirv = compileHLSLToSPIRV(variant);
    VkShaderModule module = createShaderModuleFromSPIRV(spirv);
    m_moduleCache[hash] = module;
    return module;
}

// Hash 计算
size_t ShaderVariant::getHash() const {
    size_t hash = std::hash<path>{}(absolutePath);
    hash = hashCombine(hash, size_t(m_shaderStage));
    for (auto& [k, v] : m_keyMap) hash = hashCombine(hash, k, v);
    return hash;
}
```

## 四、进阶应用（≥500字）

**变体爆炸管理**：每个宏组合产生一个 variant。`MAX_LIGHTS=1/2/4/8 × USE_NORMAL_MAP=on/off × ENABLE_SHADOWS=on/off = 16 variants`。策略：用 specialization constant 替代低影响宏。

**磁盘缓存**：SPIR-V 保存到 `ShaderCache/` 目录，文件名 = hash。首次运行编译所有 variant（可能数十秒），后续运行秒级加载。

**Shader 热重载**：文件监控检测到源文件变化 → `bRecompile=true` → 强制重编译 → 更新缓存。

## 五、源码解析和实践感悟（≥1000字）

### DXC 编译管线

```c++
// 调用 DXC 编译 HLSL → SPIR-V
std::string cmd = std::format("dxc.exe -T vs_6_0 -E main -spirv {} -Fo {}", src, out);
```

### 难点

- **Hash 冲突**：不同 variant 产生相同 hash → 返回错误 shader。解决方案：SHA-256 替代简单 hash_combine
- **编译超时**：复杂 shader 编译超过 10 秒 → 用异步线程 + 超时机制
- **磁盘缓存失效**：DXC 版本更新后旧 SPIR-V 不兼容 → 缓存 key 包含编译器版本

## 六、面试准备

Q1：ShaderVariant 的作用？A：完整描述一个着色器变体的所有编译参数，生成唯一 hash 用于缓存查找。

Q2：为什么需要 ShaderCache？A：避免重复编译——首次编译后 SPIR-V 缓存在内存和磁盘，后续直接加载。

Q3：变体爆炸如何解决？A：用 specialization constant 替代宏；profile 实际使用情况裁减无用 variant。

Q4：HLSL 如何编译到 SPIR-V？A：用 Microsoft DXC（`dxc.exe -T vs_6_0 -spirv`）将 HLSL 编译为 SPIR-V。

Q5：热重载如何实现？A：文件监控 → 标记脏 → 下次请求时 `bRecompile=true` 强制重编译。

Q6：Hash 冲突风险？A：简单 hash_combine 有理论冲突可能，生产环境用 SHA-256。

Q7：磁盘缓存 key 包含什么？A：源文件 hash + 所有宏定义 + 编译器版本 + 平台。

Q8：编译失败怎么处理？A：保留旧 shader（如有），输出编译错误到日志，不崩溃。

### 一句话答案

- ShaderCache 的价值：编译一次，全局复用。
- 变体管理的核心：hash 唯一标识 + 磁盘缓存。
- DXC 的作用：HLSL → SPIR-V 的桥梁。
- 热重载流程：文件变更 → 标记脏 → 下次重编译。
- 缓存 key 的要素：源码 hash + 宏 + 编译器版本。

## 附录

> 原笔记中完整的 ShaderVariant 链式 API 设计、ShaderCache 编译流程、hash 计算细节等均已保留在上述章节中。
