---
title: Vulkan光线追踪加速结构
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# Vulkan 光线追踪加速结构（BLAS/TLAS）

> 适用范围：Vulkan KHR Ray Tracing、BLAS 构建/压缩/更新、TLAS 实例管理

## 一、一句话结论

光线追踪加速结构分两层：**BLAS（底层，存几何体） + TLAS（顶层，存实例变换）**。BLAS 支持压缩和更新，TLAS 支持动态重建。构建流程：计算 Size → 分配 Scratch Buffer → 执行 vkCmdBuildAccelerationStructures → 压缩（可选）→ Barrier 后即可用于 TraceRay。

---

## 二、核心概念解析（≥200字）

### 2.1 双层加速结构

```
TLAS (Top-Level)
├── Instance[0]: BLAS_A @ Transform[0]  (customIndex=0)
├── Instance[1]: BLAS_A @ Transform[1]  (同一个 BLAS，不同位置)
└── Instance[2]: BLAS_B @ Transform[2]
         ↓
BLAS_A (Bottom-Level): 三角形数据、AABB
BLAS_B (Bottom-Level): 三角形数据、AABB
```

- **BLAS**：一个静态几何体（网格）一份 BLAS。支持构建、压缩、更新
- **TLAS**：引用 BLAS + 变换矩阵 + 实例自定义索引。支持动态重建（物体移动）

### 2.2 需要 4 个扩展

```cpp
VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME
VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME
VK_KHR_RAY_QUERY_EXTENSION_NAME
VK_KHR_RAY_TRACING_PIPELINE_EXTENSION_NAME
```

---

## 三、源码解析与实践感悟（≥1000字）

### 3.1 AccelKHR 封装

```cpp
struct AccelKHR {
    VkAccelerationStructureCreateInfoKHR createInfo{};
    VkAccelerationStructureKHR accel = VK_NULL_HANDLE;
    std::shared_ptr<VulkanBuffer> buffer = nullptr;

    void release();
    void create(VkAccelerationStructureCreateInfoKHR& accelInfo);
};
```

`shared_ptr<VulkanBuffer>` 是关键——加速结构本质上是一块 GPU Buffer，Vulkan 用 `VkAccelerationStructureKHR` 句柄关联。

### 3.2 BLAS 构建流程

```cpp
void BLASBuilder::build(const std::vector<BlasInput>& input, ...) {
    // 1. 计算每个 BLAS 的构建大小
    for (每个BLAS) {
        getAccelerationStructureBuildSizesKHR(...);
        asTotalSize += sizeInfo.accelerationStructureSize;
        maxScratchSize = std::max(maxScratchSize, sizeInfo.buildScratchSize);
    }

    // 2. 创建查询池（用于压缩）
    VkQueryPoolCreateInfo qpci{};
    qpci.queryType = VK_QUERY_TYPE_ACCELERATION_STRUCTURE_COMPACTED_SIZE_KHR;
    vkCreateQueryPool(device, &qpci, nullptr, &queryPool);

    // 3. 分批构建（每批 ≤ 256MB）
    VkDeviceSize batchLimit { 256 * 1024 * 1024 };
    for (每个BLAS) {
        if (batchSize >= batchLimit) {
            cmdCreateBlas(cmd, indices, buildAs, scratchAddress, queryPool);
            cmdCompactBlas(cmd, indices, buildAs, queryPool);  // 压缩
            destroyNonCompacted(indices, buildAs);  // 销毁未压缩版
        }
    }
}
```

**256MB 批次限制**：单次构建加速结构占用大量显存，分批避免 OOM。

### 3.3 压缩机制

```cpp
void BLASBuilder::cmdCompactBlas(...) {
    // 1. 查询压缩后大小
    vkGetQueryPoolResults(device, queryPool, ..., compactSizes.data(), ...);

    for (每个BLAS) {
        // 2. 创建压缩版加速结构
        VkAccelerationStructureCreateInfoKHR asCreateInfo{};
        asCreateInfo.size = compactSizes[idx];

        // 3. 复制到压缩版
        VkCopyAccelerationStructureInfoKHR copyInfo{};
        copyInfo.mode = VK_COPY_ACCELERATION_STRUCTURE_MODE_COMPACT_KHR;
        cmdCopyAccelerationStructure(cmdBuf, &copyInfo);
    }
}
```

**压缩效果**：通常能省 30%-50% 内存，对于大型场景效果显著。

### 3.4 TLAS 构建流程

```cpp
void TLASBuilder::buildTlas(VkCommandBuffer cmdBuf,
    const std::vector<VkAccelerationStructureInstanceKHR>& instances,
    bool update, VkBuildAccelerationStructureFlagsKHR flags) 
{
    // 1. 上传 Instance 数组到 GPU Buffer
    // 2. 获取设备地址
    VkAccelerationStructureGeometryInstancesDataKHR instancesVk{};
    instancesVk.data.deviceAddress = instBufferAddr;

    VkAccelerationStructureGeometryKHR topASGeometry{};
    topASGeometry.geometryType = VK_GEOMETRY_TYPE_INSTANCES_KHR;

    // 3. 计算构建大小
    getAccelerationStructureBuildSizesKHR(...);

    // 4. 创建/更新 TLAS
    cmdBuildAccelerationStructures(cmdBuf, 1, &buildInfo, &pBuildOffsetInfo);
}
```

**TLAS 的几何类型是 `INSTANCES`**，不是三角形——每个 instance 引用一个 BLAS + 变换矩阵。

### 3.5 内存屏障

```cpp
// 构建前：确保输入数据就绪
VkMemoryBarrier barrier{};
barrier.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT | VK_ACCESS_MEMORY_READ_BIT;
barrier.dstAccessMask = VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
vkCmdPipelineBarrier(...);

// 构建后：确保 AS 可被光线追踪读取
barrier.srcAccessMask = VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
barrier.dstAccessMask = VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR;
vkCmdPipelineBarrier(...);
```

### 3.6 更新机制

```cpp
void BLASBuilder::update(VkCommandBuffer cmd, ...) {
    // VK_BUILD_ACCELERATION_STRUCTURE_MODE_UPDATE_KHR
    // 几何体变形（如骨骼动画）无需重建 BLAS，只需更新
}
```

**更新 vs 重建**：更新保留原 AS 的内存布局，只修改内部数据，比重建快得多。

---

## 四、面试准备

### 高频问法（≥8个）

1. **BLAS 和 TLAS 的区别？** → BLAS 存几何体（三角形），TLAS 存实例（BLAS 引用+变换矩阵）；BLAS 每静态网格一份，TLAS 每帧/动态场景重建
2. **加速结构构建的完整流程？** → 计算 BuildSizes → 分配 Scratch Buffer → vkCmdBuildAccelerationStructures → 可选压缩 → Barrier → 用于 TraceRay
3. **为什么要压缩 BLAS？** → 节省 30-50% 显存；大型场景 BLAS 数量多，压缩收益大
4. **256MB 批次限制的原因？** → 单次构建占用大量显存，分批避免 OOM
5. **TLAS 的 GeometryType 是什么？** → `VK_GEOMETRY_TYPE_INSTANCES_KHR`，每个 instance 包含 BLAS 设备地址 + 4×3 变换矩阵 + customIndex
6. **加速结构构建前后的 Barrier 分别保护什么？** → 前：输入数据（顶点/索引）就绪；后：AS 构建完成可被光追 Shader 读取
7. **更新（Update）和重建（Build）的区别？** → Update 保留原内存布局只改内部数据（快），Build 重新分配（慢但可改变拓扑）
8. **为什么 Scratch Buffer 需要 `SHADER_DEVICE_ADDRESS_BIT`？** → 构建过程 GPU 通过设备地址访问 Scratch Buffer
9. **Instance 的 customIndex 有什么用？** → 在 Hit Shader 中通过 `InstanceCustomIndex()` 获取，可用于材质 ID、物体 ID 等

### 反问点（≥5个）
- 压缩后的 BLAS 还能用 Update 模式吗？
- 如果 TLAS 中 instance 数量从 1000 变到 2000，需要重建吗？
- `VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT` 和 `PREFER_FAST_BUILD_BIT` 如何选择？
- Scratch Buffer 可以用 `Vulkan Buffer Pool` 池化吗？
- 为什么 BLAS 用 `NonCopyable`？

### 一句话答案（≥5个）
- BLAS = 几何体书架，TLAS = 场景地图
- 压缩 = 给 BLAS 瘦身，通常能省一半
- Scratch Buffer = 构建时的施工脚手架，用完即弃
- Instance = BLAS + 变换矩阵 + 自定义 ID
- Barrier = 写完才能读

---

## 附录（原内容完整保留）

### 原：AccelKHR 结构
```cpp
struct AccelKHR {
    VkAccelerationStructureCreateInfoKHR createInfo{};
    VkAccelerationStructureKHR accel = VK_NULL_HANDLE;
    std::shared_ptr<VulkanBuffer> buffer = nullptr;
    void release();
    void create(VkAccelerationStructureCreateInfoKHR& accelInfo);
};
```

### 原：BLASBuilder 类
```cpp
class BLASBuilder : NonCopyable {
    struct BlasInput {
        std::vector<VkAccelerationStructureGeometryKHR> asGeometry;
        std::vector<VkAccelerationStructureBuildRangeInfoKHR> asBuildOffsetInfo;
        VkBuildAccelerationStructureFlagsKHR flags{0};
    };
    std::vector<AccelKHR> m_blas;
};
```

### 原：TLAS 构建
```cpp
void TLASBuilder::cmdCreateTlas(...) {
    VkMemoryBarrier barrier{};
    barrier.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT | VK_ACCESS_MEMORY_READ_BIT;
    barrier.dstAccessMask = VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
    vkCmdPipelineBarrier(...);
    
    VkAccelerationStructureGeometryInstancesDataKHR instancesVk{};
    instancesVk.data.deviceAddress = instBufferAddr;
    
    cmdBuildAccelerationStructures(cmdBuf, 1, &buildInfo, &pBuildOffsetInfo);
}
```

### 原：压缩
```cpp
void cmdCompactBlas(...) {
    vkGetQueryPoolResults(device, queryPool, ..., compactSizes.data(), ...);
    for (每个BLAS) {
        VkCopyAccelerationStructureInfoKHR copyInfo{};
        copyInfo.mode = VK_COPY_ACCELERATION_STRUCTURE_MODE_COMPACT_KHR;
        cmdCopyAccelerationStructure(cmdBuf, &copyInfo);
    }
}
```
