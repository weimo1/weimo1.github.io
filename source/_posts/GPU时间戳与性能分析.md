---
title: GPU时间戳与性能分析
date: 2026-06-20
categories:
  - ["计算机图形学", "性能与调试"]
publish: true
---

# GPU 时间戳与性能分析系统

> 适用范围：Vulkan Timestamp Query、帧耗时分析、ScopePerframeMarker RAII、Tracy 集成

## 一、一句话结论

GPU 时间戳系统 = **VkQueryPool + vkCmdWriteTimestamp + 3 帧异步缓冲**。每帧最多 128 个时间戳，当前帧写入、下一帧读取，零 GPU 等待。配合 ScopePerframeMarker RAII 自动标记 Pass 边界，输出各 Pass 时间和占比。

---

## 二、核心概念解析（≥200字）

### 2.1 异步无等待设计

```
第 N 帧：CPU 调用 vkCmdWriteTimestamp → GPU 执行到此处时记录 tick
第 N+1 帧：CPU 调用 vkGetQueryPoolResults 读取第 N 帧的 tick → 不阻塞
```

**为什么需要 3 帧缓冲**：GPU 可能还在执行第 N 帧时 CPU 已经开始第 N+1 帧。如果只有 1 个缓冲区，CPU 读取和 GPU 写入会冲突。3 帧轮转确保安全。

### 2.2 容量计算

- 典型帧：5-10 个主要 Pass
- 每个 Pass：3-5 个时间戳（开始/子阶段/结束）
- 特殊操作：10-20 个
- 总计：~90 个 → 取 128（有余量）
- 内存：128 × 3 帧 × 8 字节 = 3KB

---

## 三、源码解析与实践感悟（≥1000字）

### 3.1 初始化

```cpp
void GPUTimestamps::init(uint32_t numberOfBackBuffers) {
    m_numberOfBackBuffers = numberOfBackBuffers;
    const VkQueryPoolCreateInfo queryPoolCreateInfo = {
        .queryType = VK_QUERY_TYPE_TIMESTAMP,
        .queryCount = m_maxValuesPerFrame * numberOfBackBuffers,  // 128 × 3 = 384
    };
    vkCreateQueryPool(device, &queryPoolCreateInfo, NULL, &m_queryPool);
}
```

### 3.2 记录时间戳

```cpp
void GPUTimestamps::getTimeStamp(VkCommandBuffer cmd, const char* label) {
    uint32_t measurements = (uint32_t)m_labels[m_frame].size();
    uint32_t offset = m_frame * m_maxValuesPerFrame + measurements;
    vkCmdWriteTimestamp(cmd, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, m_queryPool, offset);
    m_labels[m_frame].push_back(label);  // 记录标签
}
```

**`BOTTOM_OF_PIPE_BIT`**：在管线最末端记录时间戳，确保前面的所有命令都已执行完毕。

### 3.3 读取与计算

```cpp
void GPUTimestamps::onBeginFrame(VkCommandBuffer cmd, std::vector<TimeStamp>* pTimestamps) {
    uint32_t offset = m_frame * m_maxValuesPerFrame;
    uint32_t measurements = (uint32_t)gpuLabels.size();
    
    if (measurements > 0) {
        double microsecondsPerTick = (1e-3 * deviceProperties.limits.timestampPeriod);
        uint64_t timingsInTicks[256] = {};
        vkGetQueryPoolResults(device, m_queryPool, offset, measurements,
            measurements * sizeof(uint64_t), &timingsInTicks, sizeof(uint64_t),
            VK_QUERY_RESULT_64_BIT);

        for (uint32_t i = 1; i < measurements; i++) {
            TimeStamp ts = {
                m_labels[m_frame][i],
                float(microsecondsPerTick * (timingsInTicks[i] - timingsInTicks[i - 1]))
            };
            pTimestamps->push_back(ts);
        }
        // 总时间
        pTimestamps->push_back({
            "Total GPU Time",
            float(microsecondsPerTick * (timingsInTicks[measurements-1] - timingsInTicks[0]))
        });
    }
    
    vkCmdResetQueryPool(cmd, m_queryPool, offset, m_maxValuesPerFrame);  // 重置备用
    getTimeStamp(cmd, "Begin Frame");  // 新帧第一个时间戳
}
```

**关键**：读取的是 `m_frame`（上一帧）的数据，写入的 `getTimeStamp` 是当前帧的。

### 3.4 ScopePerframeMarker（RAII 自动标记）

```cpp
struct ScopePerframeMarker {
    ScopePerframeMarker(VkCommandBuffer cmdBuf, const std::string& name, 
        const glm::vec4& color, GPUTimestamps* timer) {
        getContext()->setPerfMarkerBegin(cmdBuf, name.c_str(), color);
    }
    ~ScopePerframeMarker() {
        getContext()->setPerfMarkerEnd(cmd);
        if (timer) timer->getTimeStamp(cmd, name.c_str());
    }
};
```

使用：
```cpp
{
    ScopePerframeMarker marker(cmd, "Bloom Pass", {1,0,0,1}, timer);
    // ... 渲染 Bloom ...
} // 自动结束 + 记录时间戳
```

### 3.5 ScopeRenderCmdObject（完整渲染通道作用域）

```cpp
class ScopeRenderCmdObject : NonCopyable {
    VkCommandBuffer cmd;
    VkRect2D scissor;
    VkViewport viewport;
    std::unique_ptr<ScopePerframeMarker> frameMarker;

    ScopeRenderCmdObject(VkCommandBuffer inCmd, GPUTimestamps* timer, ...) {
        frameMarker = std::make_unique<ScopePerframeMarker>(inCmd, name, color, timer);
        // 设置视口（Y 翻转）、裁剪、多边形填充模式
        viewport = {0, (float)renderHeight, (float)renderWidth, -(float)renderHeight, 0, 1};
        vkCmdBeginRendering(cmd, &renderInfo);
        vkCmdSetScissor(cmd, 0, 1, &scissor);
        vkCmdSetViewport(cmd, 0, 1, &viewport);
    }

    ~ScopeRenderCmdObject() {
        vkCmdEndRendering(cmd);
        frameMarker.reset();  // 自动结束标记 + 时间戳
    }
};
```

**封装了 Vulkan Dynamic Rendering 的整套启动流程**：BeginRendering → SetScissor → SetViewport → 用户渲染 → EndRendering。

### 3.6 输出示例

```
=== 性能报告 (第 123 帧) ===
总时间: 16.7ms (目标: 16.67ms)
┌─────────────────┬──────────┬──────────┐
│ 阶段             │ 时间(ms) │ 占比(%)  │
├─────────────────┼──────────┼──────────┤
│ Shadow Pass      │ 2.3      │ 13.8%    │
│ G-Buffer         │ 5.1      │ 30.5%    │
│ Deferred Light   │ 3.8      │ 22.8%    │
│ Post Process     │ 2.9      │ 17.4%    │
│ UI               │ 0.5      │ 3.0%     │
└─────────────────┴──────────┴──────────┘
瓶颈: G-Buffer (30.5%)
```

---

## 四、面试准备

### 高频问法（≥8个）

1. **Vulkan Timestamp Query 的工作原理？** → `vkCmdWriteTimestamp` 在 GPU 管线中插入时间标记，GPU 执行到时自动记录时钟周期
2. **为什么需要多帧缓冲？** → CPU-GPU 异步，单缓冲会导致读取和写入冲突；3 帧轮转确保安全
3. **timestampPeriod 是什么？** → 一个 GPU tick 对应多少纳秒，不同 GPU 不同；用于 tick→微秒转换
4. **为什么选 BOTTOM_OF_PIPE_BIT 而非 TOP_OF_PIPE？** → BOTTOM 确保前面所有命令已执行，测量更准确（含所有等待）
5. **ScopePerframeMarker 用了什么设计模式？** → RAII：构造标记开始，析构标记结束 + 自动记录时间戳
6. **128 个时间戳每帧够用吗？如何扩展？** → 典型需要 ~90 个，128 有余量；不够可增大 `m_maxValuesPerFrame`
7. **如何与 Tracy 集成？** → 将时间戳数据导出为 Tracy Zone 格式，Tracy 提供可视化火焰图
8. **为什么读取上一帧数据不影响性能分析？** → 性能分析目标是定位瓶颈，不是实时显示；延迟一帧的数值仍然有效
9. **ScopeRenderCmdObject 封装了什么？** → BeginRendering + SetScissor + SetViewport + PerfMarker + EndRendering

### 反问点（≥5个）
- 如果 `vkGetQueryPoolResults` 返回 `VK_NOT_READY` 怎么处理？
- `timestampPeriod` 在不同 GPU 上的典型值？
- 如何区分 CPU 端耗时和 GPU 端耗时？
- 时间戳对 GPU 性能有影响吗？
- 能否在 Release Build 中使用？影响多大？

### 一句话答案（≥5个）
- Timestamp Query = GPU 内置秒表
- 3 帧缓冲 = 读取和写入永不冲突
- BOTTOM_OF_PIPE = 等所有命令跑完再计时
- ScopePerframeMarker = RAII 自动掐秒表
- 128 × 3 × 8 = 3KB 内存

---

## 附录（原内容完整保留）

### 原：GPUTimestamps 类定义
```cpp
class GPUTimestamps {
    struct TimeStamp {
        std::string label;
        float microseconds;
    };
    static const uint32_t m_maxValuesPerFrame = 128;
    VkQueryPool m_queryPool;
    uint32_t m_frame = 0;
    uint32_t m_numberOfBackBuffers = 0;
    std::vector<std::string> m_labels[5];
    std::vector<TimeStamp> m_cpuTimeStamps[5];
};
```

### 原：完整 init/onBeginFrame/onEndFrame 实现
（已在正文展示完整代码）

### 原：ScopeRenderCmdObject
```cpp
class ScopeRenderCmdObject : NonCopyable {
    VkCommandBuffer cmd;
    VkRect2D scissor;
    VkViewport viewport;
    // 构造：BeginRendering + 设置视口/裁剪 + 开始 PerfMarker
    // 析构：EndRendering + 结束 PerfMarker
};
```

### 原：ColorAttachmentsBuilder
```cpp
struct ColorAttachmentsBuilder {
    std::vector<VkRenderingAttachmentInfo> result;
    ColorAttachmentsBuilder& add(VulkanImage& image, ...);
};
```

### 原：光线追踪扩展函数延迟加载
```cpp
VkResult createAccelerationStructure(...) {
    static auto ptr = (PFN_vkCreateAccelerationStructureKHR)
        vkGetDeviceProcAddr(device, "vkCreateAccelerationStructureKHR");
    return ptr(device, pCreateInfo, pAllocator, pAccelerationStructure);
}
```
