---
title: GPU资产管理
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# GPU 资产管理

> 适用范围：GPUImageAsset、GPUStaticMeshAsset、回退机制、异步加载与 Bindless 集成

## 一、一句话结论

GPU 资产系统 = **异步上传 + 回退 Fallback + Bindless 自动注册 + LRU 缓存淘汰**。纹理和网格资产加载期间使用 Fallback（白纹理/内置盒子），加载完成后自动切换到真实资产，渲染无卡顿。

---

## 二、核心概念解析（≥200字）

### 2.1 两类 GPU 资源

```
GPU 资源
├── 临时资源（池化系统）
│   ├── 后处理中间纹理 → RenderTexturePool
│   └── Uniform/Storage 缓冲 → BufferParameterPool
│
└── 持久资产（资产系统）
    ├── 材质纹理 → GPUImageAsset + BindlessTexture
    └── 静态网格 → GPUStaticMeshAsset + BLAS
```

### 2.2 回退模式（Fallback Pattern）

```cpp
class UploadAssetInterface {
    std::atomic<bool> m_bAsyncLoading = true;
    UploadAssetInterface* m_fallback = nullptr;
};

template<typename T>
T* getReadyAsset() {
    if (isAssetLoading()) return dynamic_cast<T*>(m_fallback);  // 还在加载，用回退
    return dynamic_cast<T*>(this);  // 加载完成，用真实资产
}
```

**回退链**：纹理加载中 → 用白色像素纹理填充；模型加载中 → 用内置立方体盒子占位。渲染永不停。

---

## 三、源码解析与实践感悟（≥1000字）

### 3.1 GPUImageAsset：从创建到采样

```cpp
GPUImageAsset::GPUImageAsset(GPUImageAsset* fallback, VkFormat format,
    const std::string& name, uint32_t mipmapCount, math::uvec3 dimension) 
{
    // 创建 VulkanImage + 设置 mipmap
}
```

**上传流程**：
```cpp
void prepareToUpload(RHICommandBufferBase& cmd, VkImageSubresourceRange range) {
    m_image->transitionLayout(cmd, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, range);
}

void finishUpload(RHICommandBufferBase& cmd, VkImageSubresourceRange range) {
    m_image->transitionLayout(cmd, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, range);
}
```

**获取 Bindless 索引**：
```cpp
uint32_t getBindlessIndex(VkImageSubresourceRange range) {
    auto* asset = getReadyAsset<GPUImageAsset>();  // 用 Fallback 策略
    return asset->m_image->getOrCreateView(range, imageViewType).srvBindless;
}
```

### 3.2 GPUStaticMeshAsset：组件化缓冲管理

```cpp
struct ComponentBuffer {
    std::unique_ptr<VulkanBuffer> buffer = nullptr;
    uint32_t bindless = ~0U;  // Bindless SSBO 索引
    VkDeviceSize stripeSize = ~0U;
    uint32_t num = ~0U;
};
```

**网格组件**：indices / positions / normals / uv0s / tangents——每个组件都是独立的 GPU Buffer，都注册到 Bindless SSBO。

### 3.3 光线追踪支持

```cpp
VkBufferUsageFlags bufferFlagBasic = VK_BUFFER_USAGE_TRANSFER_DST_BIT | 
    VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
if (getContext()->getGraphicsState().bSupportRaytrace) {
    bufferFlagBasic |= 
        VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR |
        VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
}
```

BLAS 按需构建：
```cpp
BLASBuilder& getOrBuilddBLAS() {
    if (!m_blasBuilder.isInit()) {
        m_blasBuilder.build(allBlas, 
            VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR |
            VK_BUILD_ACCELERATION_STRUCTURE_ALLOW_COMPACTION_BIT_KHR);
    }
    return m_blasBuilder;
}
```

### 3.4 资产注册

```cpp
getContext()->insertBuiltinAsset(uuid, newAsset);   // 内置资产（引擎启动时加载）
getContext()->insertLRUAsset(uuid, newAsset);       // LRU 资产（运行时按需加载，支持淘汰）
```

### 3.5 析构安全释放

```cpp
GPUStaticMeshAsset::~GPUStaticMeshAsset() {
    const bool bReleasing = (Engine::get()->getModuleState() == Engine::EModuleState::Releasing);
    GPUStaticMeshAsset* fallback = nullptr;
    if (!bReleasing) {
        fallback = getContext()->getBuiltinStaticMeshBox().get();  // 用内置盒子做 Fallback
    }
    freeComponent(&m_indices, bReleasing ? nullptr : fallback->getIndices().buffer.get());
}
```

**关键**：引擎关闭时 fallback=nullptr 完全释放；正常运行时用内置盒子占位，避免引用悬空。

---

## 四、面试准备

### 高频问法（≥8个）

1. **Fallback 机制解决了什么问题？** → 资产加载期间渲染暂停的问题；加载中用默认资产占位，加载完自动切换
2. **GPUImageAsset 从创建到可采样经过几个步骤？** → 创建→prepareToUpload(TRANSFER_DST)→上传数据→finishUpload(SHADER_READ_ONLY)→可采样
3. **`getReadyAsset<T>()` 模板的作用？** → 根据 `m_bAsyncLoading` 返回真实资产或 fallback，调用方无感切换
4. **为什么网格的每个顶点组件独立成 ComponentBuffer？** → 光线追踪中只需要 Position 和 Index 构建 BLAS，不需要 UV/Tangent，分离节省带宽
5. **BLAS 何时构建？** → 按需构建（`getOrBuilddBLAS`），只在需要光追时
6. **内置资产和 LRU 资产的区别？** → 内置=引擎启动加载永不释放；LRU=按需加载，支持缓存淘汰
7. **析构时 fallback 的处理逻辑？** → 引擎关闭时传 nullptr 完全释放；正常运行时传内置盒子防止引用悬空
8. **Bindless SSBO 索引在网格资产中怎么用？** → 每个 ComponentBuffer 创建时自动 `updateBufferToBindlessDescriptorSet`
9. **Assimp 导入用了哪些后处理？** → `aiProcessPreset_TargetRealtime_Fast | aiProcess_FlipUVs | aiProcess_GenBoundingBoxes`

### 反问点（≥5个）
- `m_bAsyncLoading` 用 `std::atomic<bool>` 而不是普通 bool 的原因？
- 如果 Fallback 资产也正在加载，会怎样？
- LRU 淘汰策略是什么？基于什么指标？
- 网格的多组件分开上传如何保证原子性？
- `getRuntimeUniqueGPUAssetName` 为什么用递增 ID？

### 一句话答案（≥5个）
- Fallback = 加载中的占位符，渲染不停
- getReadyAsset = 透明切换真实/回退资产
- 组件分离 = 光追省带宽
- BLAS 按需构建 = 不追光不浪费
- 析构安全 = 关引擎清空，运行时占位

---

## 附录（原内容完整保留）

### 原：资源分类
```
├── 临时资源（池化系统管理）
│   ├── 后处理中间纹理
│   ├── Uniform/Storage缓冲区
│   └── 计算着色器临时缓冲区
└── 持久资产（资产系统管理）
    ├── 材质纹理
    ├── 静态网格
    └── 天空盒、环境贴图
```

### 原：回退模式
```cpp
template<typename T>
T* getReadyAsset() {
    if (isAssetLoading()) {
        CHECK(m_fallback && "Loading asset must exist one fallback.");
        return dynamic_cast<T*>(m_fallback);
    }
    return dynamic_cast<T*>(this);
}
```

### 原：纹理加载多格式工厂
```cpp
static std::shared_ptr<RawAssetTextureLoadTask> buildFlatTexture(...);
static std::shared_ptr<RawAssetTextureLoadTask> buildTexture(...);
static std::shared_ptr<RawAssetTextureLoadTask> buildExrTexture(...);
```

### 原：静态网格上传
```cpp
void AssetRawStaticMeshLoadTask::uploadFunction(...) {
    memcpy(bufferPtr + offset, cacheIndices.data(), cacheIndices.size());
    vkCmdCopyBuffer(cmd, stageBuffer, meshAssetGPU->getIndices().buffer, 1, &regionIndex);
    // ... 其他组件
}
```

### 原：Buildless 自动注册
```cpp
void GPUStaticMeshAsset::makeComponent(...) {
    in->bindless = getContext()->getBindlessSSBOs().updateBufferToBindlessDescriptorSet(
        in->buffer->getVkBuffer(), 0, size);
}
```
