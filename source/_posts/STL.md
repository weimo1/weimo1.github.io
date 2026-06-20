---
title: STL
date: 2026-06-20
categories:
  - ["系统底层408", "数据结构"]
publish: true
---

# STL

boost::multi\_index  
<https://david-grs.github.io/why_boost_multi_index_container-part1/>

<https://david-grs.github.io/why_boost_multi_index_container-part2/>

#### **迭代器失效的状态或者原因有哪些？**

|  |  |  |
| --- | --- | --- |
| **容器类型** | **操作** | **迭代器失效情况** |
| **vector/string** | 插入/删除（非尾部） | 插入点/删除点及之后的所有迭代器失效 |
|  | 内存重分配（如`push_back`  ） | 所有迭代器失效 |
| **deque** | 头/尾插入/删除 | 仅头/尾迭代器失效 |
|  | 中间插入/删除 | 所有迭代器失效 |
| **list/forward\_list** | 插入/删除 | 仅指向被删除元素的迭代器失效 |
| **map/set** | 插入 | 不失效（除指向插入元素的迭代器） |
|  | 删除 | 仅指向被删除元素的迭代器失效 |
| **unordered\_map** | 插入（触发Rehash） | 所有迭代器失效 |
|  | 删除 | 仅指向被删除元素的迭代器失效 |
