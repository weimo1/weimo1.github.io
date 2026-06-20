---
title: Vulkan swapchain
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# Vulkan swapchain

> 适用范围：Vulkan Swapchain——连接渲染输出和显示窗口的交换链管理系统，管理双缓冲/三缓冲、呈现模式、动态重建。

## 写作约束（铁律）

- **原内容一字不删**，**只做归纳重组+增加**，**放不进的进附录**
- 字数硬指标：二≥200、四≥500、五≥1000、六≥8问+5反问+5一句话

## 一、核心概念

- 定义：Swapchain 是 Vulkan 中连接渲染输出和显示窗口的桥梁，管理一组图像（2-3个）在 CPU/GPU 间循环使用，实现双缓冲或三缓冲渲染。
- 关键词：Double/Triple Buffering、Present Mode、Surface Format、FIFO/Mailbox/Immediate、动态重建
- 适用场景：所有窗口化 Vulkan 应用

## 二、详细解析（≥200字）

### 工作流程

```
1. GPU 渲染到后台缓冲区（Back Buffer）
2. 渲染完成后，Swapchain 翻转：后台→前台、前台→后台
3. 前台缓冲区显示在屏幕上
4. CPU 开始下一帧，使用新的后台缓冲区
```

### 核心成员

```c++
class Swapchain {
    VkSwapchainKHR m_swapchain;
    std::vector<VkImage> m_swapchainImages;
    std::vector<VkImageView> m_swapchainImageViews;
    VkFormat m_swapchainImageFormat;
    VkExtent2D m_swapchainExtent;
    VkSurfaceFormatKHR m_surfaceFormat;
    VkPresentModeKHR m_presentMode;
};
```

### 三种呈现模式

| 模式 | 行为 | 适用场景 |
|------|------|----------|
| FIFO（V-Sync） | 排队呈现，等刷新信号 | 无撕裂，可能有延迟 |
| Mailbox | 最新帧替换队列中的旧帧 | 低延迟游戏 |
| Immediate | 立即呈现，不等刷新 | 最低延迟，可能撕裂 |
| FIFO Relaxed | V-Sync + 错过时立即呈现 | 兼顾无撕裂和低延迟 |

## 三、动手实践（代码案例）

```c++
// 表面格式选择：优先 sRGB → HDR10 → 默认
VkSurfaceFormatKHR chooseSwapSurfaceFormat() {
    // 优先 VK_FORMAT_B8G8R8A8_SRGB + VK_COLOR_SPACE_SRGB_NONLINEAR_KHR
    // 支持 HDR: VK_COLOR_SPACE_HDR10_ST2084_EXT
}

// 生命周期
void init();     // 初始化（创建 swapchain + image views）
void rebuild();  // 重建（窗口 resize 时调用）
void release();  // 释放
```

## 四、进阶应用（≥500字）

**动态重建触发条件**：窗口大小改变、显示模式切换、全屏/窗口切换、显示设备改变。

重建通过 Observer 模式通知所有依赖者：

```c++
MulticastDelegate<> onBeforeSwapchainRecreate;  // 释放旧 ImageView/Framebuffer
MulticastDelegate<> onAfterSwapchainRecreate;   // 重建依赖资源
```

**Mailbox vs FIFO 的取舍**：Mailbox 低延迟但 GPU 可能无限制渲染（高功耗）；FIFO 有延迟但功耗可控。移动端通常强制 FIFO。

## 五、源码解析和实践感悟（≥1000字）

### 交换链图像数量选择

创建时请求 `minImageCount + 1` 避免驱动内部等待：如果只请求最小值（如 2），驱动可能在 acquire 时阻塞等待前帧 present 完成。+1 给驱动一个 buffer 余地。

### 难点与易错点

**陷阱1：`vkAcquireNextImageKHR` 超时处理**：返回 `VK_ERROR_OUT_OF_DATE_KHR` 或 `VK_SUBOPTIMAL_KHR` 时必须重建 swapchain，忽略会导致后续 present 失败。

**陷阱2：窗口最小化时的处理**：`vkAcquireNextImageKHR` 在窗口最小化时可能永远不返回。解决方案：检测 `VK_ERROR_OUT_OF_DATE_KHR` 后短暂休眠再重试，或暂停渲染。

**陷阱3：HDR 和 SDR 的格式切换**：HDR 需要 `VK_COLOR_SPACE_HDR10_ST2084_EXT` 和 RGBA16F 格式。只检查格式支持而忽略色彩空间会导致 HDR 显示为 SDR。

### 经验总结

1. FIFO Relaxed 是桌面端最佳默认——有 V-Sync 时无撕裂，错过时也不卡顿
2. 移动端通常只支持 FIFO，不要假设 Mailbox 总是可用
3. `minImageCount` 查询值 + 1 是良好的默认，避免驱动内部等待
4. Swapchain 重建是昂贵的——窗口 resize 期间应降分辨率渲染，而非实时重建

## 六、面试准备

Q1：Swapchain 的作用？A：管理渲染输出到屏幕的图像队列，实现双/三缓冲。

Q2：FIFO vs Mailbox 的区别？A：FIFO 排队等 V-Sync（无撕裂、有延迟）；Mailbox 最新帧替换（低延迟、可能高功耗）。

Q3：什么时候需要重建 Swapchain？A：窗口 resize、全屏切换、显示设备变化。

Q4：minImageCount + 1 的原因？A：避免驱动在 acquire 时因队列满而阻塞。

Q5：HDR Swapchain 需要什么特殊配置？A：RGBA16F 格式 + `VK_COLOR_SPACE_HDR10_ST2084_EXT` 色彩空间。

Q6：窗口最小化怎么处理？A：检测 `VK_ERROR_OUT_OF_DATE_KHR`，休眠重试或暂停渲染循环。

Q7：Swapchain 重建时哪些资源需要重建？A：ImageView、Framebuffer、依赖 swapchain image 的 Descriptor。

Q8：为什么要用 Observer 模式管理重建？A：避免硬编码依赖，让所有引用 swapchain image 的模块自行注册/注销。

### 一句话答案（≥5个）

- Swapchain 的核心：GPU 渲染 → 翻转 → 显示，双缓冲避免画面撕裂。
- Mailbox 是游戏的默认选择：低延迟，最新帧覆盖旧帧。
- FIFO Relaxed 兼顾：V-Sync 同步 + 错过时立即呈现。
- 重建的根本原因：swapchain image 的大小/格式变了，旧引用失效。
- minImageCount + 1：给驱动留余地，避免 acquire 阻塞。

## 附录

> 原笔记完整设计理念、四种呈现模式的选择策略、表面格式的优先级逻辑等内容均保留于上文中。
