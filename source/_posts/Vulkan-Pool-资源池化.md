---
title: Vulkan Pool 资源池化
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# Vulkan Pool（资源池化）

> 适用范围：RenderTexturePool（临时纹理复用）、BufferParameterPool（环形 Uniform/Storage 缓冲池）

## 一、一句话结论

GPU 资源池化 = **哈希匹配复用 + 延迟释放 + 环形缓冲 + RAII 自动归还**。RenderTexturePool 管临时纹理、BufferParameterPool 管 Uniform/Storage 缓冲，两者通过不同的"安全复用窗口"策略解决 CPU-GPU 同步问题。

---

## 二、核心概念解析（≥200字）

### 2.1 两大池的分工

| 维度 | RenderTexturePool | BufferParameterPool |
|------|-------------------|---------------------|
| 管理对象 | 临时纹理（后处理中间图） | Uniform/Storage 缓冲 |
| 复用关键 | `VkImageCreateInfo` 哈希 | `BufferIdentifier` 哈希 |
| 安全窗口 | 交换链 backbuffer 数 | backbuffer + 1 帧 |
| 生命周期 | `PoolImageSharedRef` RAII | 环形槽位自动推进 |
| 清理策略 | 每 5 帧检查超时空闲 | 每帧清空当前槽位 |

### 2.2 为什么 GPU 资源需要池化

GPU 资源（`VkImage`/`VkBuffer`）的创建/销毁涉及：
1. `vkCreateImage` → 驱动内部内存分配
2. `vkAllocateMemory` → 物理设备内存分配
3. `vkBindImageMemory` → 绑定

频繁创建/销毁 = 大量驱动调用 + 内存碎片。池化让相同规格的资源"换名不换身"。

---

## 三、源码解析与实践感悟（≥1000字）

### 3.1 RenderTexturePool：三级嵌套结构

```
PoolImageStorage（强引用纹理 + 状态）
    ↓ 被管理
PoolImage（状态记录器，weak_ptr 观察纹理）
    ↓ 被包装
PoolImageRef（RAII 智能句柄，析构自动归还）
```

**层级设计精妙之处**：
- `PoolImageStorage`：池内部持有 `shared_ptr<VulkanImage>`，真正所有权
- `PoolImage`：只记录哈希 ID、释放时间戳，通过 `weak_ptr` 观察，不阻止纹理销毁
- `PoolImageRef`：给用户用，`NonCopyable` + 析构自动归还

### 3.2 哈希匹配

```cpp
const uint32_t createInfoHash = crc::crc32((const char*)&info, sizeof(info));

if (m_freeImages[createInfoHash].size() <= 0) {
    storage.image = std::make_shared<VulkanImage>(...);  // 新建
} else {
    storage = m_freeImages[createInfoHash].back();  // 复用
    m_freeImages[createInfoHash].pop_back();
}
```

**CRC32 直接对 `VkImageCreateInfo` 做**：确保相同 format/尺寸/mip/usage 的纹理可以互换。

### 3.3 延迟释放窗口

```cpp
bool shouldRelease(uint64_t freeCounter) {
    return m_innerCounter > freeCounter + getContext()->getSwapchain().getBackbufferCount();
}
```

**逻辑**：纹理释放后不会立即销毁，而是在空闲池保留 N 帧（N = 交换链 backbuffer 数）。如果 N 帧内又被请求同规格纹理，直接复用，避免"乒乓式"创建/销毁。

### 3.4 BufferParameterPool：环形缓冲核心公式

```cpp
// 安全重用数量 = 交换链 backbuffer 数 + 1
size_t getSafeReusedNum() {
    return getContext()->getSwapchain().getBackbufferCount() + 1;
}

// 总槽位数 = 安全重用数 × 2
size_t getExistNum() {
    return getSafeReusedNum() * 2;
}
```

**为什么 backbuffer + 1**：
```
假设 backbuffer = 3：
帧0: GPU 用 bufferA → CPU 不能重用（GPU 还在用）
帧1: GPU 用 bufferB → CPU 不能重用 bufferA
帧2: GPU 用 bufferC → CPU 不能重用 bufferA
帧3: GPU 用 bufferA → 现在可以安全重用帧0的 bufferA
需要等 backbuffer+1 = 4 帧
```

**为什么 ×2**：保留 2 倍历史，给 Debug 和统计留余地，也避免边界条件问题。

### 3.5 重用 ID 计算

```cpp
const size_t reuseIdAdd = m_index + getSafeReusedNum();
const size_t reuseId = reuseIdAdd % getExistNum();
```

以 backbuffer=3 为例（safeNum=4, existNum=8）：
```
帧0: reuseId = (0+4)%8 = 4 → 重用槽位4
帧1: reuseId = (1+4)%8 = 5
...
帧4: reuseId = (4+4)%8 = 0 → 重用槽位0（4帧前的数据）
```

### 3.6 Tick 清理

```cpp
void BufferParameterPool::tick() {
    m_index++;
    if (m_index >= getExistNum()) m_index = 0;
    m_ownPtr[m_index].clear();       // 清空当前槽位
    m_hashBufferPtr[m_index].clear();
}
```

每帧只清理一个槽位，被清理的数据在 N 帧后才会被重用，确保 GPU 已完成。

### 3.7 便捷方法封装

```cpp
BufferParameterHandle getStaticStorage(const char* name, size_t size, void* data = nullptr);
BufferParameterHandle getStaticStorageGPUOnly(const char* name, size_t size);
BufferParameterHandle getIndirectStorage(const char* name, size_t size, void* data);
BufferParameterHandle getStaticUniform(const char* name, size_t size, void* data = nullptr);
```

**`Static` vs `GPUOnly`**：Static 使用 `HOST_VISIBLE` 内存（可 CPU 写入），GPUOnly 使用 `DEVICE_LOCAL`（更快但 CPU 不可见）。

---

## 四、面试准备

### 高频问法（≥8个）

1. **RenderTexturePool 如何决定一个纹理是否可以复用？** → CRC32 哈希 `VkImageCreateInfo`，相同 format/尺寸/mip/usage 即可复用
2. **BufferParameterPool 为什么需要延迟 N+1 帧才能重用缓冲？** → GPU 可能在 backbuffer 数帧内仍在处理之前的命令，必须等 GPU 完成后才能安全覆盖
3. **空闲纹理为什么不立即销毁？** → 保留 backbuffer 帧数内可能被再次请求相同规格纹理，避免创建/销毁抖动
4. **PoolImageRef 继承 NonCopyable 的原因？** → 防止浅拷贝导致同一纹理被多次归还或 double-free
5. **环形槽位数为什么是 `(backbuffer+1) × 2`？** → +1 是安全窗口，×2 是保留 2 倍历史提供缓冲
6. **BufferParameterPool 的哈希碰撞怎么处理？** → 用 CRC32，参数结构体包含 size/usage/type/vmaUsage 四元组，碰撞概率极低；且正确性不受影响（同规格缓冲区可互换）
7. **`getStaticStorage` 和 `getStaticStorageGPUOnly` 的使用场景区别？** → 需要 CPU 上传数据用前者（HOST_VISIBLE），纯 GPU 计算中间结果用后者（DEVICE_LOCAL 更快）
8. **tick 为什么要每 5 帧才清理一次空闲纹理？** → 减少 CPU 开销，避免每帧都遍历哈希表
9. **为什么用 `weak_ptr` 观察实际纹理？** → PoolImage 不应该延长纹理生命周期——如果外部已不再引用，说明纹理可安全销毁

### 反问点（≥5个）
- CRC32 会不会对不同的 `VkImageCreateInfo` 产生相同哈希？
- 如果后处理需要 100 个临时纹理，但是池只有 3 个匹配的空闲纹理怎么办？
- `VK_SHARING_MODE_CONCURRENT` 的纹理可以跨池复用吗？
- Ring Buffer 和 Object Pool 两种池化方式的优缺点？
- 为什么 Texture Pool 用 unordered_map 而 Buffer Pool 用 vector？

### 一句话答案（≥5个）
- 池化 = "同款纹理换名不换身"
- 延迟 N 帧 = GPU 安全窗口
- PoolImageRef = 自动还书卡
- 哈希匹配 = 用参数指纹找同款
- Ring Buffer = 固定槽位轮转，O(1) 复用

---

## 附录（原内容完整保留）

### 原：整体架构
```
GPU 资源池化系统
├── RenderTexturePool
│   ├── 管理临时渲染目标
│   ├── 支持纹理复用
│   └── 自动释放超时资源
└── BufferParameterPool
    ├── 管理 Uniform/Storage 缓冲区
    ├── 支持多帧缓冲区重用
    └── 自动数据更新
```

### 原：RenderTexturePool 核心
```cpp
class RenderTexturePool {
    std::unordered_map<uint32_t, std::vector<PoolImageStorage>> m_freeImages;
    std::unordered_map<uint32_t, std::vector<PoolImageStorage>> m_busyImages;
};
```

### 原：PoolImageRef RAII
```cpp
class PoolImageRef : NonCopyable {
private:
    PoolImage m_image;
public:
    ~PoolImageRef() { m_image.release(); }
};
```

### 原：BufferParameter 结构
```cpp
class BufferParameter {
    std::unique_ptr<VulkanBuffer> m_buffer;
    size_t m_bufferSize;
    VkDescriptorType m_type;
    VkDescriptorBufferInfo m_bufferInfo;
};
```

### 原：BufferParameterPool 哈希匹配
```cpp
struct BufferIdentifier {
    uint32_t bufferSize;
    uint32_t bufferUsage;
    uint32_t type;
    uint32_t vmaUsage;
};
uint32_t requireHash = crc::crc32(&hash, sizeof(hash));
```

### 原：Bloom 使用示例
```cpp
PoolImageSharedRef engine::renderBloom(...) {
    auto* rtPool = &getContext()->getRenderTargetPools();
    auto blurX = rtPool->createPoolImage("blurX", workWidth, workHeight, 
        hdrSceneColor.getFormat(), 
        VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT);
    blurX->getImage().transitionLayout(cmd, VK_IMAGE_LAYOUT_GENERAL, ...);
    return blurX;
}
```

### 原：Uniform 复用
```cpp
void renderFrame() {
    auto* bufferPool = &getContext()->getBufferParameterPools();
    auto perFrameData = bufferPool->getStaticUniform(
        "PerFrameData", sizeof(PerFrameUBO), &frameData);
    VkDescriptorBufferInfo bufferInfo = perFrameData->getBufferInfo();
}
```
