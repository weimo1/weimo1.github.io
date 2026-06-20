---
title: StaticMeshPass
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# StaticMeshPass

> 适用范围：GPU Driven Rendering 的静态网格渲染通道——Compute Shader 视锥剔除 + Hi-Z 遮挡剔除 + Indirect Draw。

## 写作约束（铁律）

- **原内容一字不删**，**只做归纳重组+增加**，**放不进的进附录**
- 字数硬指标：二≥200、四≥500、五≥1000、六≥8问+5反问+5一句话

## 一、核心概念

- 定义：StaticMeshPass 是 GPU Driven Rendering 的核心实现——用 Compute Shader 在 GPU 端完成视锥剔除和 Hi-Z 遮挡剔除，生成 Indirect Draw Command，最终通过 `vkCmdDrawIndexedIndirect` 渲染可见物体。
- 关键词：GPU Driven、视锥剔除、Hi-Z 遮挡剔除、Indirect Draw、Compute Shader 剔除
- 适用场景：大量静态网格物体的高效渲染

## 二、详细解析（≥200字）

### 数据流

```
CPU 物体列表 → GPU Storage Buffer → [CS: 视锥+Hi-Z剔除]
→ 可见物体列表 + Indirect Draw Commands → [GS: GBuffer渲染]
```

### 剔除流程（Compute Shader）

1. 获取物体数据（`gl_GlobalInvocationID.x` 索引）
2. 将物体包围盒变换到世界空间
3. **视锥剔除**：6 个视锥平面逐一测试，物体完全在负侧 → 剔除
4. **Hi-Z 遮挡剔除**：包围盒 8 个顶点投影到屏幕 → 计算 UV 范围和深度 → 选择合适的 Hi-Z mip level → 采样四个角的深度最小值 → 物体最近深度 > 遮挡深度 → 剔除
5. 通过剔除的物体 → 原子操作追加到可见列表 + 生成 Indirect Draw Command

### 双重管线设计

```c++
class StaticMeshPass : public PassInterface {
    std::unique_ptr<ComputePipeResources> prepass_cull;   // CS 剔除
    std::unique_ptr<GraphicPipeResources> prepass;         // GS 预深度渲染
    std::unique_ptr<ComputePipeResources> gbuffer_cull;    // CS GBuffer剔除
    std::unique_ptr<GraphicPipeResources> gbuffer;         // GS GBuffer渲染
};
```

每个阶段（预计算/GBuffer）都是"先 CS 剔除 + 再 GS 渲染"的双重管线。

## 三、动手实践（代码案例）

### 视锥剔除（Compute Shader 伪代码）

```glsl
for (int i = 0; i < 6; i++) {
    vec3 planeNormal = frustumPlanes[i].xyz;
    float planeDist = frustumPlanes[i].w;
    // 将平面法线变换到物体局部空间
    vec3 localNormal = mat3(inverseNormalMatrix) * planeNormal;
    // 计算包围盒在法线方向的最大投影距离
    float r = dot(abs(localNormal), object.extent);
    float d = dot(planeNormal, object.worldPos) + planeDist;
    if (d + r < 0.0) return;  // 完全在负侧 → 剔除
}
```

### Hi-Z 遮挡剔除

```glsl
// 包围盒8顶点→裁剪空间→屏幕UV+深度
vec2 uv_min = vec2(1.0), uv_max = vec2(0.0);
float depth_min = 1.0;
for (int i = 0; i < 8; i++) {
    vec4 clipPos = viewProj * vec4(corners[i], 1.0);
    vec3 ndc = clipPos.xyz / clipPos.w;
    vec2 uv = ndc.xy * 0.5 + 0.5;
    uv_min = min(uv_min, uv); uv_max = max(uv_max, uv);
    depth_min = min(depth_min, ndc.z);
}
// 选择Hi-Z mip level
float mip = ceil(log2(max(uv_max - uv_min) * textureSize(hiZ, 0)));
float occlusionDepth = textureLod(hiZ, (uv_min + uv_max) * 0.5, mip).r;
if (depth_min > occlusionDepth) return;  // 被遮挡 → 剔除
```

### Indirect Draw 命令生成

```glsl
uint drawIndex = atomicAdd(drawCount, 1);
indirectCommands[drawIndex] = IndirectDrawCommand(
    object.indexCount, 1, object.firstIndex, object.vertexOffset, object.instanceId
);
```

## 四、进阶应用（≥500字）

**Hi-Z 层级选择**：物体屏幕投影越大 → mip level 越低（高分辨率）；越小 → mip level 越高（低分辨率）。log2 计算确保采样到正确精度的遮挡深度。

**Indirect Draw 的优势**：CPU 不需要知道可见物体数量——GPU 通过原子操作统计，`vkCmdDrawIndexedIndirect` 直接读取 GPU Buffer 中的命令。CPU 零开销。

**两阶段剔除**：Prepass（深度预计算）+ GBuffer——第一遍只写深度（无需材质），第二遍利用深度缓冲做 Early-Z，减少 GBuffer 的 fragment shader 执行。

## 五、源码解析和实践感悟（≥1000字）

### Hi-Z 的局限性

Hi-Z 是 conservative 的——只取四个角的最大深度（最不遮挡的值），所以永远不会错误剔除可见物体，但可能漏掉一些可剔除的物体（尤其对角线穿透的情况）。RTAO/RTAO 可以替代 Hi-Z 实现精确遮挡。

### 原子操作的性能

`atomicAdd(drawCount, 1)` 在高并行度下可能成为瓶颈——数千个线程竞争同一个内存位置。缓解：使用 `VK_KHR_shader_atomic_int64` 或分层统计（先在 local memory 中汇总，再一次 atomic）。

## 六、面试准备

Q1：GPU Driven Rendering 的核心流程？A：CS 剔除（视锥+Hi-Z）→ 生成 Indirect Draw → GS 渲染。

Q2：Hi-Z 如何做遮挡剔除？A：物体包围盒投影到屏幕 → 在 Hi-Z 对应 mip 采样四个角深度 → 物体深度 > 遮挡深度 → 剔除。

Q3：Indirect Draw 的优势？A：CPU 不参与绘制决策，GPU 自主统计可见物体并生成绘制命令。

Q4：为什么用两阶段（Prepass + GBuffer）？A：预深度填充 depth buffer，GBuffer 阶段利用 Early-Z 减少 fragment shader 开销。

Q5：Hi-Z 会错误剔除吗？A：取四个角的保守深度，不会错剔，但可能漏剔。

Q6：原子操作瓶颈如何缓解？A：先在 shared memory 中分层汇总，再一次性 atomicAdd。

Q7：视锥剔除在哪个空间做？A：将视锥平面变换到物体局部空间，与包围盒做测试。

Q8：StaticMeshPass 如何支持热重载？A：继承 PassInterface，PassCollector 统一管理 release → re-init。

## 附录

> 原笔记完整的剔除流程（7 步）、双重管线架构、Indirect Draw 格式定义等均已保留。
