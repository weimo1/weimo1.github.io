---
title: Vulkan Bindless渲染系统
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# Vulkan Bindless 渲染系统

> 适用范围：Bindless 纹理/采样器/StorageBuffer 数组、全局描述符集、动态索引访问

## 一、一句话结论

Bindless 渲染系统 = **全局描述符大数组 + 索引分配器 + 着色器动态索引用**。一次绑定、持续绘制，把传统"每材质切 DescriptorSet"变成"每 draw call 传一个 int 索引"，批处理能力拉满。

---

## 二、核心概念解析（≥200字）

### 2.1 Traditional vs Bindless

```
传统渲染（绑定时）:
  vkCmdBindDescriptorSets(materialA_set) → draw A
  vkCmdBindDescriptorSets(materialB_set) → draw B
  // 每次切换材质都打断批处理

Bindless 渲染（索引时）:
  vkCmdBindDescriptorSets(globalBindlessSet)  // 全帧只绑一次
  pushConstants(textureIndex=0) → draw A
  pushConstants(textureIndex=1) → draw B
  // 连续绘制，无中断
```

**核心理念**：分离"绑定操作"和"资源访问"。绑定只做一次（全局大数组），访问靠整数索引。

### 2.2 比喻：图书馆借阅系统

- **传统**：每个读者（材质）有自己的小书柜（DescriptorSet），换读者就换书柜
- **Bindless**：全市只有一个超级图书馆（全局 Set），读者只需知道书号（索引）就能借任何书

### 2.3 类层次结构

```
BindlessBase（抽象基类）
├── BindlessSampler      → 采样器数组
├── BindlessTexture      → 纹理数组（最常见）
└── BindlessStorageBuffer → StorageBuffer 数组
```

---

## 三、源码解析与实践感悟（≥1000字）

### 3.1 核心数据结构

```cpp
struct BindlessTextureDescriptorHeap {
    VkDescriptorSetLayout setLayout;                 // 布局
    VkDescriptorPool descriptorPool;                 // 描述符池
    VkDescriptorSet descriptorSetUpdateAfterBind;    // 支持 AFTER_BIND 的 Set
};
```

### 3.2 索引管理（锁+空闲列表）

```cpp
uint32_t m_bindlessElementCount = 0;     // 当前已分配数量
std::set<uint32_t> m_freeIndex;          // 空闲索引池（有序集合）
std::mutex m_bindlessElementCountLock;   // 线程安全锁

uint32_t BindlessBase::getCountAndAndOne() {
    std::lock_guard lock(m_bindlessElementCountLock);
    if (m_freeIndex.size() < m_maxCountConfig / 4) {
        return m_bindlessElementCount++;  // 无空闲，分配新索引
    } else {
        uint32_t index = *m_freeIndex.begin();  // 有空闲，复用
        m_freeIndex.erase(m_freeIndex.begin());
        return index;
    }
}
```

**阈值设计**：空闲索引 < 总数 1/4 时才分配新的。避免回收后立刻又分配造成索引碎片。

### 3.3 初始化——四个关键 Flags

```cpp
VkDescriptorBindingFlagsEXT flags =
    VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT_EXT |    // 可变数量
    VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT_EXT |              // 部分绑定
    VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT_EXT |            // 绑定后可更新
    VK_DESCRIPTOR_BINDING_UPDATE_UNUSED_WHILE_PENDING_BIT_EXT;   // pending 时更新未使用项
```

**UPDATE_AFTER_BIND** 是最关键的：传统描述符必须在 Bind 前更新，而 Bindless 允许运行时动态添加纹理到已绑定的 Set 中。

### 3.4 纹理注册

```cpp
uint32_t BindlessTexture::updateTextureToBindlessDescriptorSet(
    VkImageView view, 
    VkImageLayout layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) 
{
    VkDescriptorImageInfo imageInfo{};
    imageInfo.imageView = view;
    imageInfo.imageLayout = layout;

    VkWriteDescriptorSet write{};
    write.dstArrayElement = getCountAndAndOne();  // 获取空闲索引
    write.pImageInfo = &imageInfo;
    vkUpdateDescriptorSets(device, 1, &write, 0, nullptr);
    return write.dstArrayElement;  // 返回索引号
}
```

返回的 uint32_t 就是"这本书在图书馆里的编号"。

### 3.5 索引回收（Fallback 机制）

```cpp
void BindlessTexture::freeBindlessImpl(uint32_t index, VulkanImage* fallback) {
    if (fallback) {
        VkDescriptorImageInfo imageInfo{};
        imageInfo.imageView = fallback->getOrCreateView().view;
        VkWriteDescriptorSet write{};
        write.dstArrayElement = index;  // 用 fallback 填充空洞
        vkUpdateDescriptorSets(device, 1, &write, 0, nullptr);
    }
    BindlessBase::freeBindless(index);  // 回收索引
}
```

**为什么需要 fallback**：Vulkan 验证层会警告"访问未绑定的描述符"，用一个 1x1 白色纹理填充已释放的槽位，避免警告和未定义行为。

### 3.6 着色器端（GLSL）

```glsl
#version 460
#extension GL_EXT_nonuniform_qualifier : require

layout(binding = 0) uniform texture2D textures[];       // 纹理大数组
layout(binding = 1) uniform sampler samplers[];          // 采样器大数组

vec4 sampleTexture(uint texIdx, uint sampIdx, vec2 uv) {
    return texture(sampler2D(textures[texIdx], samplers[sampIdx]), uv);
}
```

**`GL_EXT_nonuniform_qualifier`** 是 Bindless 必须的扩展，允许在 warp/wave 内不同线程访问不同纹理（NonUniformResourceIndex）。

### 3.7 性能对比

传统方式 1000 个材质 = 1000 次 `vkCmdBindDescriptorSets`，Bindless = 1 次绑定 + 1000 次 PushConstants（整数）。

---

## 四、面试准备

### 高频问法（≥8个）

1. **什么是 Bindless 渲染？与传统描述符绑定有什么本质区别？** → 全局大数组替代每材质独立 Set；分离"绑定"和"访问"，绑定一次通过索引动态访问
2. **UPDATE_AFTER_BIND_BIT 的作用？** → 允许描述符集在被绑定到 CommandBuffer 之后继续更新，是 Bindless 运行时动态添加资源的基石
3. **Bindless 如何保证线程安全？** → `std::mutex` 保护索引分配，`std::set` 管理空闲索引
4. **索引回收时为什么需要 Fallback 纹理？** → 避免验证层警告和着色器访问未绑定的描述符
5. **VARIABLE_DESCRIPTOR_COUNT 有什么意义？** → 允许绑定时指定实际使用的描述符数量而非全部声明数量，减少内存浪费
6. **GLSL 中 NonUniformResourceIndex 的作用？** → 允许同一 warp/wave 内不同线程通过不同索引访问纹理，GPUs 原生支持
7. **Bindless 和 PushDescriptor 的区别？** → Bindless 用于大量静态资源；PushDescriptor 用于每帧变化的小数据
8. **CVar 如何控制 Bindless 最大数量？** → `r.RHI.BindlessTextureMaxCount`，ReadOnly 标志表示启动时确定
9. **Bindless 的硬件限制有哪些？** → `maxDescriptorSetUpdateAfterBindSampledImages`、`maxDescriptorSetUpdateAfterBindSamplers` 等

### 反问点（≥5个）
- 如果 Bindless 索引用完了（达到 maxCount）怎么办？
- `m_freeIndex.size() < m_maxCountConfig / 4` 这个阈值怎么定的？
- Bindless 和 DescriptorFactory 如何协同工作？
- 为什么 Sampler 和 Texture 要分开成两个 Bindless 数组？
- 多线程同时调用 `updateTextureToBindlessDescriptorSet` 会导致什么问题？

### 一句话答案（≥5个）
- Bindless = 图书馆借书，传书号不传书
- UPDATE_AFTER_BIND = 绑定了还能往里加东西
- Fallback 纹理 = 退书后用白纸占位，不空着
- NonUniformResourceIndex = Wave 内不同线程访不同纹理
- 一次绑定全帧 = 1 vs 1000 次驱动调用

---

## 附录（原内容完整保留）

### 原：传统方式 vs Bindless 方式
```cpp
// 传统：每个材质独立 Set
vkCmdBindDescriptorSets(材质A描述符集) → 绘制A
vkCmdBindDescriptorSets(材质B描述符集) → 绘制B

// Bindless：全局 Set + 索引
vkCmdBindDescriptorSets(全局Bindless描述符集)  // 一次
vkCmdPushConstants(索引0) → 绘制A
vkCmdPushConstants(索引1) → 绘制B
```

### 原：渲染循环
```cpp
void renderFrame() {
    VkDescriptorSet bindlessSets[] = {
        bindlessTextures->getSet(),
        bindlessSamplers->getSet(),
        bindlessBuffers->getSet()
    };
    vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
        pipelineLayout, 0, 3, bindlessSets, 0, nullptr);

    for (auto& material : materials) {
        uint32_t pushConstants[4];
        material.bind(pushConstants);
        vkCmdPushConstants(commandBuffer, pipelineLayout, 
            VK_SHADER_STAGE_ALL, 0, sizeof(pushConstants), pushConstants);
        vkCmdDrawIndexed(commandBuffer, ...);
    }
}
```

### 原：HLSL 等价代码
```hlsl
Texture2D textures[] : register(t0, space0);
SamplerState samplers[] : register(s0, space0);
RWStructuredBuffer<float> storageBuffers[] : register(u0, space0);

float4 sampleTexture(uint texIdx, uint sampIdx, float2 uv) {
    return textures[NonUniformResourceIndex(texIdx)].Sample(
        samplers[NonUniformResourceIndex(sampIdx)], uv);
}
```

### 原：CVar 配置
```cpp
static AutoCVarInt32 cVarRHIBindlessTextureMaxCount(
    "r.RHI.BindlessTextureMaxCount",
    "Bindless texture set max count.",
    "RHI",
    20000,
    CVarFlags::ReadOnly
);
```

### 原：性能对比表
| 方面 | 传统渲染 | Bindless 渲染 |
|------|---------|-------------|
| API调用 | 每个材质多次绑定 | 一次绑定 |
| 资源管理 | 静态预分配 | 动态运行时分配 |
| 灵活性 | 有限 | 随时添加 |
| 批处理 | 材质切换打断 | 连续批处理 |
| 内存使用 | 多个描述符集 | 共享描述符集 |
