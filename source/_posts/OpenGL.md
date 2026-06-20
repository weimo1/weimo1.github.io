---
title: OpenGL
date: 2026-06-20
categories:
  - ["计算机图形学", "基础理论"]
publish: true
---

# OpenGL

> 适用范围：OpenGL 基础概念、与 Vulkan 的对比

## 一、一句话结论

OpenGL 是上一代跨平台图形 API，驱动层隐式管理状态和同步，适合快速原型；Vulkan 是新一代显式 API，全部手动管理，性能上限更高。

---

## 二、核心对比

| | OpenGL | Vulkan |
|---|---|---|
| 设计理念 | 隐式状态机 | 显式控制 |
| 内存管理 | 驱动自动 | 手动（VMA 辅助） |
| 同步 | 隐式 Fence | 显式 Semaphore/Fence/Barrier |
| 多线程 | 有限支持 | 原生多线程 |
| 学习曲线 | 低 | 高 |
| 性能上限 | 受驱动开销限制 | 接近硬件极限 |

---

## 三、补充说明

本知识库以 Vulkan 为主。关于 OpenGL 的详细内容请参考：
- LearnOpenGL: https://learnopengl.com/
- OpenGL 规范: https://registry.khronos.org/OpenGL/

> 关联文档：见 [Vulkan](03-Vulkan/Vulkan.md) 系列了解 Vulkan 对应概念
