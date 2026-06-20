---
title: CVar 系统
date: 2026-06-20
categories:
  - ["计算机图形学", "Vulkan"]
publish: true
---

# CVar（控制台变量）系统

> 适用范围：运行时配置管理、INI 持久化、AutoCVar 自动注册、ReadOnly/ReadAndWrite 权限控制

## 一、一句话结论

CVar 系统 = **静态自动注册 + 类型安全模板 + 数组连续存储 + 哈希 O(1) 查找 + shared_mutex 读写锁**。`AutoCVarFloat/Bool/Int32/String` 在构造时自动注册到全局单例，`get()` 通过预存数组索引 O(1) 读取，无需字符串查找。

---

## 二、核心概念解析（≥200字）

### 2.1 三层架构

```
用户接口层（AutoCVarXXX）
    ↓ static 构造时自动注册
管理层（CVarSystem 单例）
    ↓ 数组索引 + 哈希查找
存储层（CVarArray<T> 连续数组）
```

- **用户接口层**：`AutoCVarFloat gamma("render.gamma", "Gamma", "Render", 2.2f)`，构造即注册
- **管理层**：`CVarSystem::get()` 全局单例，提供 `getCVar<T>/setCVar<T>/exportAllConfig/importConfig`
- **存储层**：每种类型独立数组（int32[5000]/float[5000]/bool[5000]/string[2500]），连续内存，cache-friendly

### 2.2 元数据分离

```cpp
struct CVarParameter {
    int32_t  arrayIndex;     // 存储层索引 → O(1) 访问
    CVarType type;
    uint32_t flag;           // ReadOnly / ReadAndWrite
    const char* category;
    const char* name;
    const char* description;
};

template<typename T>
struct CVarStorage {
    T initVal;               // 默认值
    T currentVal;            // 当前值
    CVarParameter* parameter;
};
```

**分离设计**：元数据（~40B）存 HashMap 用于查找；实际数据（8B）存连续数组用于快速读写。

---

## 三、源码解析与实践感悟（≥1000字）

### 3.1 自动注册机制

```cpp
AutoCVarFloat::AutoCVarFloat(name, desc, category, defaultValue, flags) {
    CVarParameter* cvar = CVarSystem::get()->addFloatCVar(
        name, desc, category, defaultValue, defaultValue);
    cvar->flag = flags;
    index = cvar->arrayIndex;  // 保存索引 → O(1) 读取！
}
```

**关键**：构造时把 `arrayIndex` 存在 `AutoCVarFloat` 内部，后续 `get()` 直接用 `CVarArray[index]` 取数据——零哈希、零锁（读取场景）。

### 3.2 线程安全设计

```cpp
// 读：共享锁（多线程并发读）
std::shared_lock<std::shared_mutex> lock(m_lockMutex);

// 写：独占锁（单线程写）
std::unique_lock<std::shared_mutex> lock(m_lockMutex);
```

**get() 为什么通常不需要锁**：`AutoCVarFloat::get()` 走 `getCVarCurrentByIndex(index)`，直接数组索引访问，不经过 HashMap。只有在通过名称字符串查找时才需锁。

### 3.3 命令模式（AutoCVarCmd）

```cpp
using AutoCVarCmd = AutoCVarBool;

inline void CVarCmdHandle(AutoCVarCmd& cmd, std::function<void()>&& func) {
    if (cmd.get()) {
        cmd.set(false);  // 自动重置
        func();          // 执行命令
    }
}
```

**设计精妙**：Cmd 本质是 Bool，set true 后执行一次自动 reset——避免手动清理状态。

### 3.4 INI 导出

```cpp
void CVarSystem::exportAllConfig(const std::string& path) {
    // 按 category 分组
    for (const auto& cVarPair : m_cacheCVars) {
        cVarCategories[cVar.category].push_back(&cVar);
    }
    // 写入 .ini，带注释
    // [Render]
    // render.gamma = 2.2 # Gamma correction value
}
```

### 3.5 INI 导入

```cpp
bool CVarSystem::importConfig(const std::string& path) {
    // 按类型解析值
    if (cVar->type == CVarType::Bool) {
        if (valueStr.starts_with("false") || valueStr.starts_with("0"))
            setCVar<bool>(name, false);
        else
            setCVar<bool>(name, true);
    }
    // ... Int32 / Float / String
}
```

### 3.6 性能数据

- 5000 个变量 ≈ 240KB 内存
- AutoCVar 包装类 `get()`：O(1) 数组索引
- 名称查找：O(1) 哈希
- 读操作：可并发（shared_lock）

---

## 四、面试准备

### 高频问法（≥8个）

1. **CVar 系统的整体架构？** → 三层：AutoCVarXXX（用户接口）→ CVarSystem（单例）→ CVarArray（连续存储）
2. **如何实现 O(1) 读取？** → 构造时保存 `arrayIndex`，`get()` 直接 `CVarArray[index].currentVal`
3. **线程安全怎么保证？** → `shared_mutex`：读 shared_lock 并发，写 unique_lock 独占
4. **AutoCVarCmd 的原理？** → 本质是 Bool（Cagetory="Cmd"），触发后自动 reset
5. **配置持久化怎么实现？** → `exportAllConfig` 写 INI 文件（按 category 分 section），`importConfig` 读回
6. **为什么每种类型独立数组？** → 连续内存 cache-friendly，模板特化类型安全
7. **ReadOnly 和 ReadAndWrite 标志的作用？** → ReadOnly 禁止控制台修改但允许代码/配置文件改；ReadAndWrite 无限制
8. **哈希函数的设计？** → `hash = hash * 131 + char`，简单高效，tolower 忽略大小写
9. **initVal 和 currentVal 分别存什么？** → initVal=默认值（重置用），currentVal=当前运行时值

### 反问点（≥5个）
- 如果 CVar 数量超过 5000 怎么办？
- `addCVarTypeParam` 为什么用 `unique_lock` 而不是 `shared_lock`？
- INI 文件解析如何处理注释行？
- `exportAllConfig` 里的 `ini.interpolate()` 做了什么？
- 为什么 CVarSystem 是 NonCopyable？

### 一句话答案（≥5个）
- CVar = 运行时可调的全局开关/参数
- arrayIndex = O(1) 读的秘诀
- Cmd = 一次性 Bool，用完自动关
- shared_mutex = 读并发、写互斥
- INI = category 分 section，值带注释

---

## 附录（原内容完整保留）

### 原：CVarParameter & CVarStorage
```cpp
struct CVarParameter {
    int32_t  arrayIndex;
    CVarType type;
    uint32_t flag;
    const char* category;
    const char* name;
    const char* description;
};

template<typename T>
struct CVarStorage {
    T initVal;
    T currentVal;
    CVarParameter* parameter = nullptr;
};
```

### 原：CVarArray
```cpp
template<typename T>
struct CVarArray : private NonCopyable {
    CVarStorage<T>* cvars;
    int32_t lastCVar = 0;
    int32_t capacity;

    inline int32_t add(const T& value, CVarParameter* param) {
        int32_t index = lastCVar;
        cvars[index].currentVal = value;
        cvars[index].initVal = value;
        cvars[index].parameter = param;
        param->arrayIndex = index;
        lastCVar++;
        return index;
    }
};
```

### 原：CVarSystem 单例
```cpp
class CVarSystem : private NonCopyable {
    CVarArray<int32_t> m_int32CVars{ kCVarMaxInt32Num };
    CVarArray<float> m_floatCVars{ kCVarMaxFloatNum };
    CVarArray<bool>  m_boolCVars{ kCVarMaxBoolNum };
    CVarArray<std::string> m_stringCVars{ kCVarMaxStringNum };
    std::shared_mutex m_lockMutex;
    std::unordered_map<size_t, CVarParameter> m_cacheCVars;
};
```

### 原：AutoCVar 使用示例
```cpp
AutoCVarFloat Config::Gamma("render.gamma", "Gamma correction", "Render", 2.2f);
float gamma = Config::Gamma.get();
Config::Gamma.set(2.4f);
```

### 原：CVarCmdHandle
```cpp
inline void CVarCmdHandle(AutoCVarCmd& in, std::function<void()>&& func) {
    if (in.get()) { in.set(false); func(); }
}
```
