---
title: Maple Tree
date: 2026-06-20
categories:
  - ["系统底层408", "数据结构"]
publish: true
---

# Maple Tree 数据结构

## 概述

Maple Tree（枫树）是 Linux 内核 6.1 版本引入的新型数据结构，专用于替代红黑树管理进程的虚拟内存区间（VMA，Virtual Memory Area）。由 Matthew Wilcox 设计，核心设计思想源自 B 树。Maple Tree 的引入是内核内存管理子系统的一项重要演进。

## 设计动机

传统上 Linux 使用红黑树管理 VMA，其相关代码维护在 mm/mmap.c 和 mm/vma.c 中。每创建一个虚拟内存区间（如通过 mmap、brk、shmat 等）都需要在红黑树中插入或查找节点。在大内存和大并发场景下，红黑树的 O(log n) 查找虽然理论上足够，但指针追踪层次较多，缓存不友好问题突出。Maple Tree 每个节点包含多个条目，大幅降低树高，减少指针追踪次数，提升了 VMA 的查找、插入和删除操作的效率。

## 核心特性

**区间查询**：Maple Tree 天然支持高效的区间查询（range query）。查找特定虚拟地址所在的 VMA 只需一次树遍历，相比红黑树的两次遍历（先查上限再查下限）更为高效。此外还支持区间分裂（split）和合并（merge）操作，这与 mmap/munmap 的语义完全吻合。

**RCU 安全**：Maple Tree 设计上充分考虑 RCU 语义，读操作无需加锁，多个读者可并发执行无需同步。写操作通过 RCU 延迟回收机制保证并发安全，减少了锁竞争带来的性能开销。这对于多线程密集使用内存管理服务的应用场景尤其重要。

**低内存占用**：Maple Tree 相比红黑树减少约 30%-40% 的内存占用。从 Linux 6.5 版本开始，内核完全使用 Maple Tree 管理 VMA，并移除了原有的红黑树相关代码。在拥有大量 VMA 的进程如长时间运行的数据库服务、浏览器等多线程应用中性能提升显著。

## 内核接口

内核通过 mm_struct->mm_mt 字段使用 Maple Tree 管理所有 VMA。操作接口以 mas_（Maple Tree State）前缀命名，包含 mas_init 初始化遍历状态、mas_walk 查找指定地址所在的 VMA、mas_store 插入或更新 VMA、mas_erase 从树中删除 VMA、mas_find 查找下一个 VMA 等一系列接口。Maple Tree 的实现位于内核源码 lib/maple_tree.c，核心数据结构包括 maple_node 和 ma_state。

## 总结

Maple Tree 代表了 Linux 内核在内存管理数据结构上的重要创新，通过引入 B 树思想显著优化了 VMA 管理的性能、可扩展性和代码可维护性。