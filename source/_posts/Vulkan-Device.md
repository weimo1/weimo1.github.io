---
title: Vulkan Device
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# Vulkan Device（设备与队列初始化）

> 适用范围：Vulkan Device 创建流程、GPU 选择策略、队列族管理、特性链配置

## 一、一句话结论

Vulkan Device 初始化是引擎 RHI 层的核心——通过**三层扩展分类 + 多版本特性链 + 队列优先级策略 + CVar 配置驱动**，实现对不同 GPU 硬件的适配和高级功能（HDR/光追/DLSS）的优雅降级。

---

## 二、核心概念解析（≥200字）

### 2.1 Vulkan Device 在渲染管线中的角色

Vulkan Device（`VkDevice`）是逻辑设备，代表应用程序与物理 GPU 之间的连接。它负责：

- **资源创建**：所有 Buffer、Image、Pipeline、DescriptorSet 都由 Device 创建
- **队列管理**：提交命令到不同队列族执行（Graphics/Compute/Transfer）
- **特性协商**：通过 pNext 链向驱动声明需要哪些 GPU 特性
- **扩展启用**：光线追踪、Bindless、HDR 等高级功能需显式启用扩展

**与 DirectX 12 的对比**：

| Vulkan | DX12 |
|--------|------|
| VkDevice | ID3D12Device |
| VkQueue | ID3D12CommandQueue |
| VkPhysicalDevice | IDXGIAdapter |
| pNext 特性链 | CheckFeatureSupport |

### 2.2 物理设备 vs 逻辑设备

- **物理设备**（`VkPhysicalDevice`）：硬件的抽象，枚举得到，用于查询属性和限制
- **逻辑设备**（`VkDevice`）：真正干活的句柄，从物理设备创建，携带启用的扩展和特性

**选择策略**：优先选独立显卡（`VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU`），回退到第一个可用 GPU。

---

## 三、源码解析与实践感悟（≥1000字）

### 3.1 GPU 枚举与选择

```cpp
uint32_t physicalDeviceCount;
RHICheck(vkEnumeratePhysicalDevices(m_instance, &physicalDeviceCount, nullptr));
ASSERT(physicalDeviceCount > 0, "No gpu support vulkan on your computer.");

std::vector<VkPhysicalDevice> physicalDevices;
physicalDevices.resize(physicalDeviceCount);
RHICheck(vkEnumeratePhysicalDevices(m_instance, &physicalDeviceCount, physicalDevices.data()));
```

**两次调用的原因**：第一次获取数量分配内存，第二次获取实际句柄——这是 Vulkan API 的惯用模式。

GPU 选择策略：

```cpp
bool bExistDiscreteGPU = false;
for (auto& gpu : physicalDevices) {
    VkPhysicalDeviceProperties deviceProperties;
    vkGetPhysicalDeviceProperties(gpu, &deviceProperties);
    if (deviceProperties.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
        bExistDiscreteGPU = true;
        m_gpu = gpu;  // 选择独立显卡
        break;
    }
}
if (!bExistDiscreteGPU) {
    LOG_RHI_WARN("No discrete gpu found, using default gpu.");
    m_gpu = physicalDevices[0];
}
```

GPU 类型枚举：
- `VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU`：独立显卡
- `VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU`：集成显卡
- `VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU`：虚拟 GPU
- `VK_PHYSICAL_DEVICE_TYPE_CPU`：CPU 模拟（如 SwiftShader）

### 3.2 三层扩展分类

```cpp
// 1. 基础扩展（必须支持）
deviceExtensionNames.push_back(VK_EXT_MEMORY_BUDGET_EXTENSION_NAME);
deviceExtensionNames.push_back(VK_KHR_MAINTENANCE1_EXTENSION_NAME);
deviceExtensionNames.push_back(VK_EXT_DESCRIPTOR_INDEXING_EXTENSION_NAME);

// 2. 平台特定扩展
if (m_engine->isWindowApplication()) {
    deviceExtensionNames.push_back(VK_KHR_SWAPCHAIN_EXTENSION_NAME);
}

// 3. 可选高级扩展
auto tryInsertIfExistExtension = [&](const char* name) {
    if (existDeviceExtension(name)) {
        deviceExtensionNames.push_back(name);
        return true;
    }
    return false;
};
```

**设计意图**：
- **必需扩展**：缺了引擎无法运行
- **平台扩展**：Swapchain 仅在窗口应用需要
- **可选扩展**：检测到才启用，找不到优雅降级

### 3.3 多版本 Vulkan 特性链

```cpp
VkPhysicalDeviceFeatures         enable10GpuFeatures = {};
VkPhysicalDeviceVulkan11Features enable11GpuFeatures = {};
VkPhysicalDeviceVulkan12Features enable12GpuFeatures = {};
VkPhysicalDeviceVulkan13Features enable13GpuFeatures = {};

// 扩展特性
VkPhysicalDeviceAccelerationStructureFeaturesKHR accelFeature{};
VkPhysicalDeviceRayTracingPipelineFeaturesKHR rtPipelineFeature{};
VkPhysicalDeviceRayQueryFeaturesKHR rayQueryFeatures{};
VkPhysicalDeviceExtendedDynamicState3FeaturesEXT dynamicStateFeatures{};

// pNext 链连接
enable11GpuFeatures.pNext = &enable12GpuFeatures;
enable12GpuFeatures.pNext = &enable13GpuFeatures;
```

**为什么用 pNext 链而不是 `pEnabledFeatures`**：Vulkan 1.1+ 的特性结构体通过 pNext 链扩展，这样可以一次 `vkCreateDevice` 调用传入所有特性需求，避免多次设置。

### 3.4 队列系统设计

```cpp
// 队列类型识别
const bool bSupportGraphics = queueFamily.queueFlags & VK_QUEUE_GRAPHICS_BIT;
const bool bSupportCompute = (!bSupportGraphics) && (queueFamily.queueFlags & VK_QUEUE_COMPUTE_BIT);
const bool bSupportCopy = (!bSupportGraphics) && (!bSupportCompute) && (queueFamily.queueFlags & VK_QUEUE_TRANSFER_BIT);
```

**优先级分配**：
```cpp
std::vector<float> graphicsQueuePriority(graphicsQueueCounts, 0.5f);
std::vector<float> computeQueuePriority(computeQueueCounts, 0.5f);
std::vector<float> copyQueuePriority(copyQueueCounts, 0.5f);

graphicsQueuePriority[0] = 1.0f;  // 主图形队列
computeQueuePriority[0]  = 0.8f;  // 主计算队列
graphicsQueuePriority[1] = 0.8f;  // 次主图形队列
```

### 3.5 GPU 信息查询（pNext 链）

```cpp
VkPhysicalDeviceProperties2KHR deviceProperties{ 
    VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2_KHR 
};
m_descriptorIndexingProperties = { 
    VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_PROPERTIES_EXT 
};
m_accelerationStructureProperties = { 
    VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_PROPERTIES_KHR 
};

deviceProperties.pNext = &m_descriptorIndexingProperties;
m_descriptorIndexingProperties.pNext = &m_accelerationStructureProperties;

getPhysicalDeviceProperties2(m_gpu, &deviceProperties);
```

**一次调用获取**：基础属性 + 描述符索引限制 + 加速结构限制，避免多次 API 调用。

### 3.6 光线追踪支持检查

```cpp
m_graphicsSupportStates.bSupportRaytrace = cVarRHIRayTraceFeatureEnable.get();
if (m_graphicsSupportStates.bSupportRaytrace) {
    m_graphicsSupportStates.bSupportRaytrace &= tryInsertIfExistExtension(VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME);
    m_graphicsSupportStates.bSupportRaytrace &= tryInsertIfExistExtension(VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME);
    m_graphicsSupportStates.bSupportRaytrace &= tryInsertIfExistExtension(VK_KHR_RAY_QUERY_EXTENSION_NAME);
    m_graphicsSupportStates.bSupportRaytrace &= tryInsertIfExistExtension(VK_KHR_RAY_TRACING_PIPELINE_EXTENSION_NAME);
}
```

**需要 4 个扩展同时支持**才能启用光追，缺一个就降级。

### 3.7 双重验证

```cpp
// 创建设备后再次验证
if (m_graphicsSupportStates.bSupportRaytrace) {
    VkPhysicalDeviceFeatures2 deviceFeatures{};
    deviceFeatures.pNext = &asFeatures;
    vkGetPhysicalDeviceFeatures2(m_gpu, &deviceFeatures);
    m_graphicsSupportStates.bSupportRaytrace = 
        (asFeatures.accelerationStructure && rtPipelineFeatures.rayTracingPipeline);
}
```

**为什么双重验证**：扩展存在不代表驱动真正支持该特性，创建设备后还要再查一次 `vkGetPhysicalDeviceFeatures2`。

---

## 四、面试准备

### 高频问法（≥8个）

1. **Vulkan Device 初始化的完整流程是怎样的？** → 枚举物理设备→选 GPU→枚举扩展→三层分类→构造特性链→选队列族→vkCreateDevice→获取队列句柄→验证特性
2. **物理设备和逻辑设备的区别？** → 物理设备是硬件抽象（查询用），逻辑设备是真正干活的句柄（创建资源用）
3. **为什么要用 pNext 链而不是 pEnabledFeatures？** → Vulkan 1.1+ 特性通过 pNext 扩展，一次创建传入所有需求
4. **如何选择 GPU？优先级策略是什么？** → 优先 DISCRETE_GPU，回退到第一个可用 GPU
5. **光线追踪需要哪些扩展？** → 4 个：Deferred Host Operations、Acceleration Structure、Ray Query、Ray Tracing Pipeline
6. **队列族的选择策略？** → 优先选纯图形队列，再选专有计算队列和传输队列；主队列优先级 1.0
7. **什么是 CVar 配置驱动？** → 通过 `AutoCVarBool` 控制功能启用，ReadOnly 标记表示启动时确定
8. **如果用户显卡不支持光追怎么处理？** → 优雅降级：LOG_WARN 提示，关闭光追功能，程序正常运行
9. **Vulkan 1.0/1.1/1.2/1.3 特性链如何串联？** → 通过 pNext 指针依次连接，一次性传入 DeviceCreateInfo

### 反问点（≥5个）
- Bindless 渲染需要哪些扩展支持？
- HDR 元数据扩展在什么平台下启用？
- 队列优先级（0.5 vs 1.0）的实际影响？
- 如果用户有双显卡（集显+独显），代码会选哪个？
- `vkEnumeratePhysicalDevices` 为什么要调两次？

### 一句话答案（≥5个）
- Device 初始化就是"选硬件、开扩展、建队列、验特性"
- pNext 链 = Vulkan 的"多版本特性声明语法"
- 三层扩展 = 必需的 + 平台相关的 + 可选的
- 光追需要 4 扩展缺一不可
- 队列优先级 1.0 给主图形队列，保证呈现不卡顿

---

## 附录（原内容完整保留）

## 原：整体架构

### 初始化流程
```
检查设备状态 → 枚举可用扩展 → 配置扩展列表 → 设置功能特性 → 选择队列族 → 创建设备 → 获取队列句柄 → 验证功能支持
```

### 核心组件
- **扩展管理**：动态检测和启用 Vulkan 扩展
- **特性链**：多版本 Vulkan 特性支持
- **队列系统**：多类型队列（图形、计算、传输）管理
- **配置驱动**：通过 CVar 系统控制功能启用

### 扩展检测（lambda）
```cpp
auto existDeviceExtension = [&](const char* name) {
    for (auto& availableExtension : availableDeviceExtensions) {
        if (strcmp(availableExtension.extensionName, name) == 0) {
            return true;
        }
    }
    return false;
};
```

### 条件编译模式
```cpp
// 通过CVar控制功能启用
if (cVarRHIHDRFeatureEnable.get()) {
    // 启用HDR功能
}
```

### 构建器模式
```cpp
deviceExtensionNames.push_back(...);
enable12GpuFeatures.descriptorIndexing = VK_TRUE;
```

### 策略模式（队列选择）
```cpp
if (bSupportGraphics && (!bGraphicsQueueSet)) {
    // 选择为图形队列
} else if (bSupportCompute && (!bComputeQueueSet)) {
    // 选择为计算队列
}
```

### 错误处理
```cpp
ASSERT(m_gpu != VK_NULL_HANDLE, "You must select one gpu before init device.");
ASSERT(graphicsQueueCounts > 2, "We need more than two graphics queues...");
ASSERT(computeQueueCounts  > 1, "We need more than one compute queues...");
ASSERT(copyQueueCounts     > 0, "We need at least one copy queues...");
```

### 优雅降级
```cpp
if (!m_graphicsSupportStates.bSupportRaytrace) {
    LOG_WARN("Try enable hardware ray tracing, but no support in your machine, close here.");
} else {
    LOG_TRACE("Raytrace extension and feature enable and opening...");
}
```

### 延迟加载扩展函数
```cpp
static auto getPhysicalDeviceProperties2 = 
    reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2KHR>(
        vkGetInstanceProcAddr(m_instance, "vkGetPhysicalDeviceProperties2KHR")
    );
CHECK(getPhysicalDeviceProperties2);
```

### CVar 运行时配置
```cpp
static AutoCVarBool cVarRHIHDRFeatureEnable(
    "r.RHI.HDREnable",
    "Enable hdr feature or not.",
    "RHI",
    true,
    CVarFlags::ReadOnly
);
```
