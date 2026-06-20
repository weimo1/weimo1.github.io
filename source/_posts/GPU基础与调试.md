---
title: GPU基础与调试
date: 2026-06-20
categories:
  - ["计算机图形学", "性能与调试"]
publish: true
---

# GPU 基础与调试

> 适用范围：GPU 线程模型、RenderDoc 调试、性能分析入门

## 一、一句话结论

GPU 是超大规模并行处理器（数千核心），Shader 以 Warp/Wavefront（32/64 线程）为单位执行。RenderDoc 是 Vulkan/DX 调试利器——抓帧、看 Draw Call、检查资源状态。

---

## 二、核心概念解析（≥200字）

### 2.1 GPU 线程模型

- **Thread**：执行一个 Shader 调用（一个像素/顶点）
- **Warp（NVIDIA）/ Wavefront（AMD）**：32/64 个线程为一组，SIMT 执行
- **SM（Streaming Multiprocessor）/ CU（Compute Unit）**：容纳多个 Warp 的硬件单元
- **Occupancy**：SM 上活跃 Warp 数与理论最大值的比值

关键：**分支发散**（同一 Warp 内线程走不同分支）会降低吞吐量。

### 2.2 RenderDoc

- **Frame Capture**：截取一帧的所有 API 调用
- **Event Browser**：按时间线浏览每个 Draw/Dispatch
- **Texture Viewer**：查看任意 Render Target/Texture 内容
- **Pipeline State**：查看绑定的 Shader、Buffer、Descriptor

---

## 三、面试准备

### 高频问法（≥8个）

1. **GPU 的线程层级？** → Thread → Warp(32) → SM → GPU（数千核心）
2. **什么是分支发散（Branch Divergence）？** → 同一 Warp 中部分线程走 if、部分走 else，GPU 串行执行两条路径
3. **Occupancy 的重要性？** → 高 Occupancy 能隐藏内存延迟（通过切换 Warp）
4. **RenderDoc 能做什么？** → 抓帧、看 Draw Call、检查纹理/Buffer 内容、查看 Pipeline State
5. **NVIDIA 和 AMD 架构差异？** → Warp 32 vs Wavefront 64；N卡 SIMT，A卡更接近 SIMD
6. **如何用 RenderDoc 调试渲染 Bug？** → 抓帧→找异常 Draw Call→看输入的纹理/顶点/Uniform→定位问题
7. **GPU 调试和 CPU 调试的主要区别？** → GPU 无断点（除非用 Nsight/RGA），主要靠抓帧+Shader printf
8. **Timestamp Query 和 RenderDoc 的 GPU Duration 有何不同？** → Timestamp 更精确（硬件 tick），RenderDoc 采集开销大
9. **参考链接**：https://zhuanlan.zhihu.com/p/1966944813740962860

### 反问点（≥5个）
- Warp 大小为什么是 32？
- 如何检测分支发散？
- RenderDoc 能调试光线追踪吗？
- GPU 缓存层级（L1/L2/Shared Memory）？
- Nsight Graphics 和 RenderDoc 的优劣？

### 一句话答案（≥5个）
- GPU = 成千上万个简单核心同时干活
- Warp = 32 线程一组，GPU 的基本调度单位
- 分支发散 = 同一 Warp 内有人走左有人走右，两倍耗时
- RenderDoc = 渲染界的 F12 开发者工具
- Occupancy 高 = 隐藏内存延迟的关键

---

## 附录

### 参考链接
- [浅谈GPU 线程并行](https://zhuanlan.zhihu.com/p/1966944813740962860)
- RenderDoc 使用及调试技巧: https://zhuanlan.zhihu.com/p/1934241882088670618
