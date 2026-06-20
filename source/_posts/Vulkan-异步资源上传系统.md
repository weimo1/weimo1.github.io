---
title: Vulkan 异步资源上传系统
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# Vulkan 异步资源上传系统

> 适用范围：CPU→GPU 纹理/模型上传、Staging Buffer 管理、异步命令提交

## 一、一句话结论

异步上传系统 = **生产者-消费者模型 + 静态/动态双通道 + 专用传输队列**。小资源批量静态上传器处理、大资源按需动态上传器处理，通过 Fence 非阻塞同步，主线程零卡顿。

---

## 二、核心概念解析（≥200字）

### 2.1 生产者-消费者架构

```
主线程（生产者）          上传器线程（消费者）
    ↓                         ↑
创建 AssetLoadTask → 塞入任务队列 → 取出任务
    ↓                         ↓
继续游戏逻辑            创建 Staging Buffer
    ↓                         ↓
                        记录 vkCmdCopy 命令
    ↓                         ↓
tick() 检查 fence  ← 提交到传输队列 → GPU 执行
    ↓                         ↓
调用 finishCallback()    重置 fence，回收 Buffer
```

### 2.2 静态 vs 动态上传器

| 特性 | StaticAsyncUploader | DynamicAsyncUploader |
|------|---------------------|----------------------|
| 缓冲区策略 | 固定 64MB 大缓冲，永不释放 | 按需分配，用完释放 |
| 适用场景 | 小纹理、字体、UI | 大纹理、模型、环境贴图 |
| 任务大小 | < dynamicUploaderMinSize（如 8MB） | ≥ 8MB |
| 批处理 | 多个小任务累积后一起提交 | 单个任务独立提交 |

---

## 三、源码解析与实践感悟（≥1000字）

### 3.1 AssetLoadTask（策略模式基类）

```cpp
struct AssetLoadTask {
    virtual void finishCallback() = 0;       // GPU 完成后回调
    virtual uint32_t uploadSize() const = 0; // 数据大小
    virtual void uploadFunction(...) = 0;    // 实际的上传逻辑
};
```

**纹理上传示例**：
```cpp
class TextureUploadTask : public AssetLoadTask {
    std::vector<uint8_t> m_pixels;
    Texture* m_targetTexture;

    void uploadFunction(...) override {
        memcpy(bufferPtr + offset, m_pixels.data(), m_pixels.size());
        VkBufferImageCopy region{};
        vkCmdCopyBufferToImage(cmd, stageBuffer, image, layout, 1, &region);
    }

    void finishCallback() override {
        m_targetTexture->setState(TextureState::Ready);
    }
};
```

### 3.2 动态上传器的智能缓冲区复用

```cpp
const bool bShouldRecreate =
    (m_stageBuffer == nullptr)                    // 未创建
    || (m_stageBuffer->getSize() < requireSize)   // 太小
    || (m_stageBuffer->getSize() > 2 * requireSize);  // 太大（浪费）

if (bShouldRecreate) {
    m_stageBuffer = std::make_unique<VulkanBuffer>(...);
}
```

**设计精妙之处**：
- 太小当然要重建
- **太大也要重建**（> 2×）：比如之前加载 200MB 模型分配了 200MB staging buffer，接下来只需要传 1MB 小纹理，继续用 200MB 的缓冲太浪费
- 在 (1×, 2×] 区间内继续复用：既有余量又不至于太浪费

### 3.3 内存对齐

```cpp
static const uint32_t kBufferOffsetRoundUpSize = 128;
static inline uint32_t getUploadSizeQuantity(AssetLoadTask* task) {
    return kBufferOffsetRoundUpSize * 
        divideRoundingUp(task->uploadSize(), kBufferOffsetRoundUpSize);
}
```

**128 字节对齐**：GPU 传输的最小粒度。对齐后 GPU DMA 引擎效率最高，且避免不同任务数据跨 cache line。

### 3.4 专用传输队列

```cpp
poolInfo.queueFamilyIndex = getContext()->getCopyFamily();
```

**为什么用独立 Copy Queue**：Vulkan 允许图形队列和传输队列并行执行。上传纹理时图形队列继续渲染，互不阻塞——这是 DX11 做不到的。

### 3.5 Fence 非阻塞同步

```cpp
// 提交时关联 fence
VkSubmitInfo submitInfo{};
submitInfo.pCommandBuffers = &obj->getCommandBuffer();
vkQueueSubmit(queue, 1, &submitInfo, obj->getFence());

// 主线程检查（非阻塞）
if (vkGetFenceStatus(device, obj->getFence()) == VK_SUCCESS) {
    obj->onFinished();   // 调用 finishCallback
    obj->resetFence();   // 重置 fence
}
```

**关键**：`vkGetFenceStatus` 是非阻塞的，不会卡主线程。GPU 还没完成就跳过，下次 tick 再检查。

### 3.6 条件变量唤醒

```cpp
void DynamicAsyncUploader::threadFunction() {
    if (!m_manager.dynamicLoadAssetTaskEmpty() && !working()) {
        loadTick();  // 有任务，处理
    } else {
        std::unique_lock lock(m_manager.getDynamicMutex());
        m_manager.getDynamicCondition().wait(lock);  // 没任务，休眠
    }
}
```

**零 CPU 空转**：没任务时线程挂起，主线程 `addTask` 后 `notify_all` 唤醒——标准的生产者-消费者模型。

### 3.7 多队列轮询提交

```cpp
void AsyncUploaderManager::submitObjects() {
    for (auto* obj : m_submitObjects) {
        vkQueueSubmit(..., obj->getCommandBuffer(), ..., obj->getFence());
    }
    m_submitObjects.clear();
}
```

**轮询多个传输队列**：现代 GPU 有多个 Copy Queue，轮询提交能充分利用硬件并行能力。

---

## 四、面试准备

### 高频问法（≥8个）

1. **异步上传系统的整体架构？** → 生产者-消费者：主线程创建任务→塞队列→上传线程消费→GPU 执行→Fence 通知→回调
2. **静态和动态上传器有什么区别？** → 静态：固定大缓冲，小任务批量处理；动态：按需分配，大任务独立处理
3. **为什么用专用传输队列而不是主图形队列？** → 图形队列继续渲染不阻塞，传输和渲染并行
4. **Fence 如何实现非阻塞同步？** → `vkGetFenceStatus` 非阻塞查询，完成则回调+重置，未完则下次 tick 再查
5. **动态上传器缓冲区"太大也重建"的设计思路？** → 前一个 200MB 任务分配的缓冲用于后续 1MB 任务太浪费，重建小缓冲省内存
6. **128 字节对齐的原因？** → GPU DMA 引擎最小传输粒度，对齐后效率最高
7. **条件变量在异步上传中怎么用？** → 上传线程无任务时 `wait` 休眠，主线程 `addTask` 后 `notify_all` 唤醒
8. **`uploadFunction` 回调里具体做了什么？** → memcpy 数据到 staging buffer → 记录 `vkCmdCopyBufferToImage` 命令
9. **如果上传任务过多，静态队列满了怎么办？** → 会阻塞主线程的 `addTask`，形成背压（backpressure）

### 反问点（≥5个）
- Staging Buffer 为什么要用 `HOST_COHERENT` 而不是手动 flush？
- 如果 GPU 不支持独立 Copy Queue 怎么办？
- `finishCallback` 里做了哪些事？能在回调里创建新的 Vulkan 资源吗？
- 动态上传器缓冲区的 2× 阈值为什么是这个数？
- 多个上传线程同时在 CopyQueue 提交命令会不会有竞争？

### 一句话答案（≥5个）
- 异步上传 = 主线程塞任务、子线程传数据、GPU 干了通知 CPU
- 静态/动态分流 = 小件批量、大件专车
- Fence = GPU 完成信号灯
- 128 对齐 = DMA 友好的地板
- 条件变量 = 有活就干、没活睡觉

---

## 附录（原内容完整保留）

### 原：系统概览
```
主线程（生产者）
    ↓
添加 AssetLoadTask → 根据大小分发 静态/动态 队列
    ↓
上传器线程（消费者）
    ↓
从队列获取任务 → 创建暂存缓冲区 → 记录传输命令 → 提交到 GPU
```

### 原：Task 示例
```cpp
class TextureUploadTask : public AssetLoadTask {
    uint32_t uploadSize() const override { return m_pixels.size(); }
    void uploadFunction(...) override {
        memcpy(bufferPtr + offset, m_pixels.data(), m_pixels.size());
        vkCmdCopyBufferToImage(cmd, stageBuffer, image, layout, 1, &region);
    }
    void finishCallback() override {
        m_targetTexture->setState(TextureState::Ready);
    }
};
```

### 原：静态上传器
- 缓冲区策略：一次性分配固定大小（如 64MB），永不释放
- 示例配置：4个静态上传器，每个 64MB
- 工作流程：获取队列小任务 → 累积填满 64MB → 一次记录所有拷贝 → 批量提交 → 统一回调

### 原：动态上传器
- 缓冲区策略：按需分配，用完后释放
- 示例配置：2个动态上传器
- 工作流程：获取大任务 → 按需分配缓冲 → 记录单个拷贝 → 提交 → 回调并释放

### 原：多队列轮询提交
```cpp
void submitObjects() {
    for (auto* obj : m_submitObjects) {
        vkQueueSubmit(..., obj->getCommandBuffer(), ..., obj->getFence());
    }
    m_submitObjects.clear();
}
```

### 原：Fence 同步
```cpp
VkFenceCreateInfo fenceInfo{};
vkCreateFence(device, &fenceInfo, nullptr, &m_fence);
// 提交时关联
vkQueueSubmit(queue, 1, &submitInfo, obj->getFence());
// 非阻塞检查
if (vkGetFenceStatus(device, obj->getFence()) == VK_SUCCESS) {
    obj->onFinished();
    obj->resetFence();
}
```
