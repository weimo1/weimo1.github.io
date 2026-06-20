---
title: Redis事务与Lua
date: 2026-06-20
categories:
  - ["项目学习", "数据库"]
publish: true
---

# Redis 事务 vs Lua

> 适用范围：Redis 事务机制（MULTI/EXEC）与 Lua 脚本（EVAL/EVALSHA）的对比——原子性保证、逻辑处理能力、网络开销、主从复制、Redis 7.0 Functions。

## 一、核心概念

- **定义**：Redis 提供两种原子性操作方案——事务（MULTI/EXEC，命令批量入队后执行）和 Lua 脚本（EVAL，服务器端执行，整个脚本作为一个原子整体）。两者各有适用场景，Lua 脚本在逻辑处理能力和性能上通常更优。
- **关键词**：MULTI/EXEC、EVAL/EVALSHA、SCRIPT LOAD、SCRIPT KILL、lua_pcall、主从复制脚本传播、NOSCRIPT 回退、Redis Functions（Redis 7.0）
- **适用场景/边界**：
  - 事务：简单批量执行（批量 SET/DEL），无逻辑判断需求
  - Lua 脚本：需要条件判断（if/then）、原子性读-改-写、减少网络往返
  - 边界：脚本执行期间阻塞所有其他命令，需控制脚本执行时间

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：事务 vs Lua 本质差异**

Redis 事务（MULTI/EXEC）只保证命令的原子性——事务中的每个命令要么全部执行成功，要么全部不执行。但事务**没有逻辑处理能力**，只是命令的批量入队和依次执行。

Lua 脚本可以将整个脚本发送给 Redis 服务器，在服务器端作为一个整体执行。这意味着可以在一个 Lua 脚本中执行多个 Redis 命令，配合判断语句和循环语句实现复杂逻辑。

| 维度 | Redis 事务 | Lua 脚本 |
|------|-----------|----------|
| 原子性 | 命令级原子（入队期+执行期） | 脚本级原子（整个脚本作为一个整体） |
| 逻辑处理 | 无（只批量执行） | 支持 if/else、循环、变量 |
| 网络开销 | N 条命令 N 次网络往返 | 1 次脚本传输，服务器端执行 |
| 复用性 | 每次重新发送所有命令 | SCRIPT LOAD 预加载，EVALSHA SHA 复用 |

**第二层：Lua 脚本执行流程**

```
客户端 → EVAL script numkeys key... arg... → Redis
  → evalCommand() 解析参数
  → evalGenericCommand() 设置 KEYS[]/ARGV[] 全局变量
  → lua_pcall() 执行脚本（阻塞其他命令）
  → luaReplyToRedisReply() 将返回值转为 Redis 协议
  → 返回结果给客户端
```

**第三层：主从复制中 Lua 脚本的传播**

Lua 脚本执行写命令时，Redis **传播脚本本身**到从节点（而非逐个传播命令结果）。这保证了主从一致性，但也要求脚本必须是确定性的——脚本内不能使用随机数、时间等非确定性数据。

## 三、动手实践（代码案例）

### 3.1 事务示例

```bash
# Redis 事务：批量设值
redis-cli> MULTI
redis-cli> SET key1 "value1"
redis-cli> INCR counter
redis-cli> EXEC
# 返回：OK, (integer) 1
```

### 3.2 Lua 脚本示例

```lua
-- 原子性地检查并更新（防止超卖）
local current = redis.call('GET', KEYS[1])
if current and tonumber(current) > 0 then
    redis.call('DECR', KEYS[1])
    return 1
end
return 0
```

### 3.3 SCRIPT LOAD + EVALSHA 复用

```bash
# 加载脚本体，返回 SHA 摘要
redis-cli> SCRIPT LOAD "return redis.call('GET', KEYS[1])"
"a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9"

# 后续通过 SHA 调用（省去网络传输脚本体）
redis-cli> EVALSHA a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9 1 mykey
```

### 3.4 分布式锁的正确解锁

```lua
-- 用 Lua 保证"判断归属 + 删除"是原子的
if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('del', KEYS[1])
else
    return 0
end
```

## 四、进阶应用（≥500字）

### 工程中的真实用法

**验证码场景**：用 Lua 脚本原子性地检查验证码 + 删除，防止重复使用。

**限流场景**：Lua 脚本实现滑动窗口限流，比事务更高效。在单次 EVAL 中完成"检查当前窗口计数 → 判断是否超限 → 更新计数 → 设置 TTL"的全流程。

**分布式锁**：`SET lock:key uuid NX EX 30` 加锁 → 业务执行 → Lua 脚本判断 uuid 后 DEL 解锁。核心：SETNX 保证互斥，EX 防止死锁，UUID 防止误删，Lua 保证判断+删除原子性。

### EVALSHA 注意事项

生产环境建议客户端先 EVALSHA，收到 NOSCRIPT 错误后再回退 EVAL 发送完整脚本体同时重新 LOAD。原因是脚本缓存可能因重启 / SCRIPT FLUSH 丢失。

### Redis 7.0 Functions（推荐迁移）

Redis 7.0 引入 Functions 替代 Lua 脚本缓存：
- Script 是脚本缓存（非持久），重启丢失；Function 是库级脚本（持久到 AOF/RDB）
- 支持 FUNCTION LOAD/LIST/DELETE 库管理
- 支持多函数共享逻辑、版本管理、更好的 ACL 控制

### 常见优化策略

- **脚本应幂等且无副作用扩散**：脚本内执行的写命令通过 replication 传播脚本本身（非逐个命令），要求脚本必须是纯函数
- **lua-time-limit 默认 5000ms**：脚本执行超时进入 hook 等待，`SCRIPT KILL` 仅当脚本未执行写操作时生效（lua_write_dirty==0），否则只能 `SHUTDOWN NOSAVE`
- **redis.call() vs redis.pcall()**：前者遇错直接中断脚本，后者捕获错误返回 error 对象，业务逻辑中推荐 pcall + 自定义错误处理
- **避免在 Lua 中做大量计算**：Redis 单线程模型下，脚本执行会阻塞所有其他命令

## 五、源码解析和实践感悟（≥1000字）

### 5.1 Redis Lua 脚本执行核心路径（源码级）

```c
// Redis scripting.c — evalCommand 入口：EVAL script numkeys key [key...] arg [arg...]
void evalCommand(client *c) {
    long long numkeys = c->argv[2]->ptr ? strtoll(c->argv[2]->ptr, NULL, 10) : 0;
    // 参数合法性校验：numkeys 必须在 [0, argc-3] 之间
    if (numkeys > (c->argc - 3)) {
        addReplyError(c, "Number of keys can't be greater than number of args");
        return;
    }
    // 核心执行
    evalGenericCommand(c, 0);  // 0 表示 EVAL, 1 表示 EVALSHA
}

void evalGenericCommand(client *c, int evalsha) {
    char *sha = c->argv[1]->ptr;
    // EVALSHA 路径：从 server.lua_scripts 字典中按 SHA 查找缓存脚本
    if (evalsha) {
        sds body = dictFetchValue(server.lua_scripts, sha);
        if (!body) {
            addReplyErrorObject(c, shared.noscripterr);  // NOSCRIPT 错误
            return;  // 客户端应回退到 EVAL
        }
        c->argv[1] = createStringObject(body, sdslen(body));
    }
    // 设置 keys/argv 到 Lua 全局变量 KEYS[] 和 ARGV[]
    luaSetGlobalArray(lua, "KEYS", c->argv + 3, numkeys);
    luaSetGlobalArray(lua, "ARGV", c->argv + 3 + numkeys, c->argc - 3 - numkeys);
    // 执行 Lua 脚本（popen/pcall 调用 lua_pcall）
    lua_pcall(lua, 0, 1, 0);
    // 将 Lua 返回值转换为 Redis 协议
    luaReplyToRedisReply(c, lua);
}
```

### 5.2 SCRIPT LOAD + EVALSHA 缓存机制

```c
// 缓存结构：server.lua_scripts 是一个 dict，SHA摘要 → 脚本体
void scriptCommand(client *c) {
    if (!strcasecmp(c->argv[1]->ptr, "load")) {
        char sha1[41];
        sha1hex(sha1, c->argv[2]->ptr, sdslen(c->argv[2]->ptr));  // SHA-1 计算
        // 存储到 lua_scripts 字典
        dictAdd(server.lua_scripts, sdsnewlen(sha1, 40),
                sdsnewlen(c->argv[2]->ptr, sdslen(c->argv[2]->ptr)));
        addReplyBulkCBuffer(c, sha1, 40);
    } else if (!strcasecmp(c->argv[1]->ptr, "flush")) {
        // SCRIPT FLUSH: 清空 scriptCache + 重置 Lua VM
        scriptingReset();
        addReply(c, shared.ok);
    } else if (!strcasecmp(c->argv[1]->ptr, "kill")) {
        // SCRIPT KILL: 仅当脚本未执行写操作时有效
        if (server.lua_write_dirty == 0) {
            lua_sethook(lua, NULL, 0, 0);  // 取消 hook
            lua->lua->status = LUA_YIELD;
            addReply(c, shared.ok);
        }
    }
}
```

### 5.3 主从复制中 Lua 脚本的传播

```c
// 写操作传播：脚本中执行写命令时，Redis 传播脚本本身而非命令结果
void propagateNow(int dbid) {
    if (server.lua_caller) {
        // 脚本执行环境：传播原始 EVAL/EVALSHA
        alsoPropagate(server.lua_caller->cmd, dbid,
                      server.lua_caller->argv, server.lua_caller->argc);
    }
}
// 关键：SCRIPT FLUSH 也会传播到从节点，确保主从脚本缓存一致
```

### 实践感悟

1. **EVALSHA 必须配 Fallback**：生产环境建议 client 端先 EVALSHA，收到 NOSCRIPT 错误后再 EVAL，避免脚本缓存因重启/SCRIPT FLUSH 丢失导致调用失败。
2. **脚本应幂等且无副作用扩散**：脚本内执行的写命令会通过 replication 传播脚本本身（非逐个命令），这保证了主从一致性，但也意味着脚本必须纯函数——不要读随机数、时间等非确定性数据。
3. **lua-time-limit 默认 5000ms**：脚本执行超时不自动杀（防止写操作丢失一半），而是进入 lua-time-limit hook 等待。`SCRIPT KILL` 仅当脚本未执行写操作时生效，否则只能 `SHUTDOWN NOSAVE`。
4. **redis.call() vs redis.pcall()**：前者遇错直接中断脚本，后者捕获错误返回 error 对象。业务逻辑中推荐 pcall + 自定义错误处理。
5. **Redis 7.0 引入 Functions**：Script 是脚本缓存（非持久），重启丢失；Function 是库级脚本（持久到 AOF/RDB），支持多函数共享逻辑。推荐新项目迁移到 Redis Functions。
6. **避免在 Lua 中做大量计算**：Redis 单线程模型下，脚本执行会阻塞所有其他命令。复杂计算应拆分为多次小脚本调用或移到客户端处理。

## 六、面试准备

### 6.1 高频问法（≥8个）

**Q1: Redis 事务能保证 ACID 吗？**
答：不能。Redis 事务只保证原子性（命令要么全执行要么全不执行），但不支持回滚（某条命令语法错误时其他命令继续执行）。持久性和隔离性依赖配置（RDB/AOF）。C（一致性）由 Redis 自身保证。

**Q2: Lua 脚本相比 MULTI/EXEC 事务的优势？**
答：① 真正的逻辑处理能力（if/else、循环、变量）；② 减少网络往返（整个脚本一次发送）；③ 更灵活的原子边界（脚本内任意多个命令天然原子）；④ 可复用（SCRIPT LOAD 后通过 SHA 重复调用）。

**Q3: EVALSHA 返回 NOSCRIPT 怎么处理？**
答：客户端捕获 NOSCRIPT 错误后回退执行 EVAL（发送完整脚本体），同时重新 SCRIPT LOAD 缓存。这是生产环境的标准模式，主流客户端（Jedis、Lettuce、go-redis）均已内置。

**Q4: SCRIPT KILL 和 SHUTDOWN NOSAVE 什么区别？**
答：SCRIPT KILL 仅当脚本未执行写操作时可终止（lua_write_dirty==0），适用于纯读脚本超时；脚本已写入数据时 KILL 无效，只能 SHUTDOWN NOSAVE（放弃本次修改并重启）。

**Q5: Lua 脚本中执行 Redis 命令要注意什么？**
答：① 使用 redis.call() 出错直接中断，redis.pcall() 可捕获错误继续；② 所有 Redis 命令返回的 key 名必须用 KEYS[] 传递（保证集群模式下 hash tag 路由正确）；③ 非确定性命令（TIME、RANDOMKEY）会导致主从不一致，应避免。

**Q6: Redis 集群模式下 Lua 脚本有什么限制？**
答：脚本涉及的所有 key 必须属于同一个 hash slot（同一个节点），否则报 CROSSSLOT 错误。解决方案：用 hash tag（{user}:id 和 {user}:name 路由到同一节点）。

**Q7: Lua 脚本性能开销有多大？**
答：lua_pcall 调用本身开销极小（微秒级），主要耗时在脚本内执行的 Redis 命令。复杂逻辑（大循环、字符串拼接）可能在单线程中阻塞。建议每个脚本控制在几十毫秒以内。

**Q8: Redis 7.0 的 Functions 相比 Lua 脚本改进在哪？**
答：① 持久化：Function 存储在 AOF/RDB 中，重启不丢失；② 库管理：支持 FUNCTION LOAD/LIST/DELETE；③ 版本管理：支持 LIBRARY 级别的隔离和替换；④ 更好的 ACL 控制。

### 6.2 反问点/陷阱点（≥5个）

1. **「Redis 事务支持回滚」** → 错！语法错误不会触发其他命令回滚，Redis 认为语法错误是编程 bug 应在开发阶段发现。
2. **「Lua 脚本一定比 Pipeline 快」** → 不一定！Pipeline 对简单批量操作更快（无 Lua VM 开销），Lua 优势在需要条件判断和中间变量时。
3. **「SCRIPT KILL 可以终止任何超时脚本」** → 错！写操作后的脚本只能用 SHUTDOWN NOSAVE。
4. **「Lua 脚本天然解决并发问题」** → 脚本本身原子执行，但多客户端并发调同一个脚本时，脚本间仍有竞态。
5. **「SCRIPT FLUSH 不影响主从复制」** → 错！FLUSH 命令会传播到从节点，导致从节点脚本缓存也清空。

### 6.3 一句话答案（≥5个）

| 关键词 | 一句话答案 |
|-------|-----------|
| MULTI/EXEC 原子性 | 入队期+执行期，执行期间不响应其他客户端，但不支持回滚 |
| EVAL vs EVALSHA | EVAL 传脚本体，EVALSHA 传 SHA 摘要，更快但需预先 LOAD |
| NOSCRIPT 处理 | 捕获后回退 EVAL + 重新 LOAD |
| SCRIPT KILL 条件 | 仅 lua_write_dirty==0 时生效 |
| 主从复制 | 传播脚本体(非命令结果)，要求脚本确定性 |
| Redis 7.0 Functions | 持久化脚本库，替代 SCRIPT LOAD 缓存 |
| cluster 限制 | 所有 KEY 必须同一 hash slot，用 hash tag 解决 |

## 附录（原笔记内容归档）

### Lua 脚本相比事务的四大优势

1. **原子性**：Lua 脚本内的多个命令作为一个整体执行，比事务的命令级原子更彻底。
2. **逻辑处理能力**：支持 if/else、循环、变量，可进行复杂的数据筛选和转换。
3. **减少网络开销**：只需发送脚本体，服务器端执行后返回结果，明显提升大量命令的执行效率。
4. **复用性和扩展性**：脚本可在 Redis 中定义保存并重复使用，增加代码复用率。
