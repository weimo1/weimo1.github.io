---
title: Vulkan 资源类
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# Vulkan 资源类（Buffer & Image）

> 适用范围：VulkanBuffer / VulkanImage 封装、VMA 集成、Bindless 支持、设备地址

## 一、一句话结论

基于 VMA 的 Vulkan 资源类（`VulkanBuffer` / `VulkanImage`）通过 RAII + 不可复制 + 视图缓存 + 子资源布局追踪，将 Vulkan 资源管理的复杂度降至最低，同时无缝支持 Bindless 和光线追踪。

---

## 二、核心概念解析（≥200字）

### 2.1 资源类层次结构

```
GpuResource (基类，NonCopyable)
├── VulkanBuffer - GPU 缓冲（Vertex/Index/Uniform/Storage）
└── VulkanImage  - GPU 图像（纹理/渲染目标）
```

**设计要点**：
- `NonCopyable`：防止浅拷贝导致 double-free
- `UUID64u m_runtimeUUID`：全局唯一标识，便于调试和资源追踪
- `std::string m_name`：RenderDoc/Nsight 中可识别的资源名

### 2.2 VMA（Vulkan Memory Allocator）的作用

VMA 是由 AMD 开源的内存分配库，解决 Vulkan 原生内存管理的痛点：
- 自动子分配：一个大 `vkAllocateMemory` 拆成多个小资源
- 碎片整理：类似 C++ 内存池，减少 `vkAllocateMemory` 调用次数
- 类型适配：自动选择 `HOST_VISIBLE` / `DEVICE_LOCAL` 等内存类型

### 补充：两种构造方式的设计意义

- **方式 A（VMA）**：推荐，引擎内部资源创建走这条路径，享受 VMA 的碎片整理
- **方式 B（原生 Vulkan）**：保留给特殊场景（如与外部库交互、需要精确控制内存属性）

---

## 三、源码解析与实践感悟（≥1000字）

### 3.1 GpuResource 基类

```cpp
class GpuResource : NonCopyable  // 禁止复制
{
protected:
    std::string m_name;        // 资源名称（用于调试）
    VkDeviceSize m_size;       // 资源大小（字节）
    UUID64u m_runtimeUUID;     // 运行时唯一标识符
};
```

**为什么禁止复制**：Vulkan 资源句柄（`VkBuffer`、`VkImage`）的本质是 `uint64_t`，浅拷贝后两个对象持有相同句柄，析构时会 double-free。`NonCopyable` 在编译期阻止这种风险。

### 3.2 VulkanBuffer：VMA 构造

```cpp
VulkanBuffer(
    VmaAllocator vma,                     // VMA 分配器
    const std::string& name,              // 资源名称
    VkBufferUsageFlags usageFlags,        // 缓冲用途
    VmaAllocationCreateFlags vmaUsage,    // VMA 分配标志
    VkDeviceSize size,                    // 缓冲大小
    void* data = nullptr);                // 初始数据
```

**便捷方法**：
```cpp
static VmaAllocationCreateFlags getStageCopyForUploadBufferFlags();
static VmaAllocationCreateFlags getReadBackFlags();
```
两个静态方法分别返回上传和回读时推荐的内存分配标志，避免每次手动拼参数。

### 3.3 内存映射与一致性

```cpp
void map(VkDeviceSize size = VK_WHOLE_SIZE);
void* getMapped() const;
void unmap();

void invalidate(VkDeviceSize size = VK_WHOLE_SIZE, VkDeviceSize offset = 0);
void flush(VkDeviceSize size = VK_WHOLE_SIZE, VkDeviceSize offset = 0);
```

**invalidate vs flush 的区别**：
- `flush`：CPU 写 → GPU 读（Host → Device）
- `invalidate`：GPU 写 → CPU 读（Device → Host）

### 3.4 设备地址（Device Address）

```cpp
bool m_bSupportDeviceAddress = false;
uint64_t m_deviceAddress = 0;
uint64_t getDeviceAddress() const;
```

用于光线追踪中的 `VK_KHR_buffer_device_address` 扩展。GPU 端可以直接通过 64 位地址访问缓冲区，无需先绑定描述符——这对 DXR/VKR 光追管线中的 Shader Binding Table 和 Acceleration Structure 构建至关重要。

**获取地址的前置条件**：创建 Buffer 时必须带 `VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT_KHR`。

### 3.5 VulkanImage：视图缓存

```cpp
struct ViewAndBindlessIndex {
    VkImageView view = VK_NULL_HANDLE;
    uint32_t srvBindless = ~0U;  // bindless 渲染索引
};

std::unordered_map<uint64_t, ViewAndBindlessIndex> m_cacheImageViews;
```

**为什么缓存 ImageView**：
- `vkCreateImageView` 每次都要驱动调用，有一定开销
- 同一 Texture 经常需要多个 View（如不同 mip 级别、不同 array layer）
- 用 `VkImageSubresourceRange` 的哈希作为 key，避免重复创建

### 3.6 图像布局转换

```cpp
void transitionLayout(VkCommandBuffer cmd, VkImageLayout newLayout, VkImageSubresourceRange range);
void transitionShaderReadOnly(VkCommandBuffer cmd, ...);
void transitionAttachment(VkCommandBuffer cmd, ...);
void transitionTransferDst(VkCommandBuffer cmd, ...);
void transitionGeneral(VkCommandBuffer cmd, ...);
```

**典型纹理加载流程**：
```
1. 创建图像（初始布局：UNDEFINED）
2. transitionTransferDst()    → 转换为 TRANSFER_DST_OPTIMAL
3. vkCmdCopyBufferToImage()   → 上传数据
4. transitionShaderReadOnly() → 转换为 SHADER_READ_ONLY_OPTIMAL
5. 着色器采样
```

### 3.7 子资源状态追踪

```cpp
struct SubResourceState {
    uint32_t ownerQueueFamilyIndex;
    VkImageLayout imageLayout;
};
std::vector<SubResourceState> m_subresourceStates;

VkImageLayout getCurrentLayout(uint32_t layerIndex, uint32_t mipLevel) const;
```

**为什么需要**：不同 mip 级别和 array layer 可以有不同布局。如果一个 mip 已经被设为 `SHADER_READ_ONLY`，另一个还在 `TRANSFER_DST`，需要分别跟踪，避免不必要的 barrier。

---

## 四、面试准备

### 高频问法（≥8个）

1. **VMA 的作用是什么？为什么不直接用 vkAllocateMemory？** → VMA 自动子分配、减少 Allocation 数量、碎片整理，大幅度减少 vulkan 内存管理的 boilerplate
2. **GpuResource 为什么继承 NonCopyable？** → 防止浅拷贝导致 Vulkan 句柄 double-free
3. **Device Address 在光追中怎么用？** → 通过 `VK_KHR_buffer_device_address` 扩展，GPU 可直接用 64 位地址访问 Buffer，用于 SBT 和 AS 构建
4. **ImageView 为什么要缓存？** → 避免重复 `vkCreateImageView` 驱动调用，用 subresource range 哈希做 key
5. **图像布局转换的典型流程？** → UNDEFINED → TRANSFER_DST（上传） → SHADER_READ_ONLY（采样）
6. **flush 和 invalidate 的区别？** → flush = CPU→GPU，invalidate = GPU→CPU；本质是缓存一致性操作
7. **子资源状态为什么要逐个追踪？** → 不同 mip/array layer 可同时处于不同布局，统一 barrier 会浪费
8. **VulkanBuffer 的两种构造方式何时用？** → VMA 方式用于引擎内部资源；原生方式用于外部库交互或精确控制
9. **如何获取 Bindless 纹理索引？** → 通过 `VulkanImage::getOrCreateView()` 返回的 `ViewAndBindlessIndex.srvBindless`

### 反问点（≥5个）
- VMA 的内存碎片如何整理？
- 如果没有 `VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT` 会怎样？
- `vkFlushMappedMemoryRanges` 和 Buffer::flush 的关系？
- 为什么 Undefined 布局转换时不需要 pipeline barrier？
- Bindless 索引是在什么时候分配的？

### 一句话答案（≥5个）
- VMA = Vulkan 世界的 tcmalloc/jemalloc
- NonCopyable = 编译期防 double-free
- Device Address = GPU 端裸指针，光追必需
- ImageView 缓存 = 用哈希换掉驱动调用
- 布局转换 = GPU 内部数据重排，必须显式声明

---

## 附录（原内容完整保留）

### 原：GpuResource 基类
```cpp
class GpuResource : NonCopyable  // 禁止复制
{
protected:
    std::string m_name;        // 资源名称（用于调试）
    VkDeviceSize m_size;       // 资源大小（字节）
    UUID64u m_runtimeUUID;     // 运行时唯一标识符
};
```

### 原：VulkanBuffer 构造（方式 A：VMA）
```cpp
VulkanBuffer(
    VmaAllocator vma,
    const std::string& name,
    VkBufferUsageFlags usageFlags,
    VmaAllocationCreateFlags vmaUsage,
    VkDeviceSize size,
    void* data = nullptr);
```

### 原：VulkanBuffer 构造（方式 B：原生）
```cpp
VulkanBuffer(
    VkBufferUsageFlags usageFlags,
    VkMemoryPropertyFlags memoryPropertyFlags,
    const std::string& name,
    VkDeviceSize size,
    void* data = nullptr,
    bool bBindAfterCreate = true);
```

### 原：内存操作
```cpp
void map(VkDeviceSize size = VK_WHOLE_SIZE);
void* getMapped() const;
void unmap();
void copyTo(const void* data, VkDeviceSize size);
void copyAndUpload(VkCommandBuffer cmd, const void* data, VulkanBuffer* dstBuffer);
void invalidate(VkDeviceSize size = VK_WHOLE_SIZE, VkDeviceSize offset = 0);
void flush(VkDeviceSize size = VK_WHOLE_SIZE, VkDeviceSize offset = 0);
```

### 原：图像布局转换
```cpp
void transitionLayout(VkCommandBuffer cmd, VkImageLayout newLayout, VkImageSubresourceRange range);
void transitionShaderReadOnly(VkCommandBuffer cmd, ...);
void transitionAttachment(VkCommandBuffer cmd, ...);
void transitionTransferDst(VkCommandBuffer cmd, ...);
void transitionGeneral(VkCommandBuffer cmd, ...);
```

### 原：子资源状态
```cpp
struct SubResourceState {
    uint32_t ownerQueueFamilyIndex;
    VkImageLayout imageLayout;
};
```

### 原：创建顶点缓冲
```cpp
VulkanBuffer* vertexBuffer = new VulkanBuffer(
    vma, "MeshVertices",
    VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
    VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
    vertices.size() * sizeof(Vertex),
    vertices.data());
```

### 原：创建 Uniform 缓冲
```cpp
VulkanBuffer* uniformBuffer = new VulkanBuffer(
    vma, "CameraUBO",
    VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
    VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
    sizeof(UniformData));
uniformBuffer->map();
UniformData* data = (UniformData*)uniformBuffer->getMapped();
data->view = camera.getViewMatrix();
uniformBuffer->unmap();
```

### 原：Bindless 渲染支持
```cpp
ViewAndBindlessIndex viewInfo = texture->getOrCreateView();
uint32_t bindlessIndex = viewInfo.srvBindless;
// 在着色器中使用
// layout(binding = 0) uniform texture2D textures[];
// 通过bindlessIndex索引访问特定纹理
```
