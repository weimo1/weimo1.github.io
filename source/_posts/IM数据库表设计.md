---
title: IM数据库表设计
date: 2026-06-20
categories:
  - ["项目学习", "数据库"]
publish: true
---

# IM 数据库表设计

> 适用范围：即时通讯系统数据库表设计、用户表、消息表、会话表、好友关系表、群聊表

## 一、项目/模块概述

- **模块定位**：IM 聊天系统的数据库表设计是整个系统数据持久化的基础，涵盖用户、消息、会话、好友关系、群聊等核心实体。设计质量直接影响查询性能、扩展性和数据一致性。
- **技术栈与依赖**：MySQL InnoDB、UTF8MB4 字符集、BIGINT 主键、复合索引。
- **模块边界**：上游为业务逻辑层（`LogicSystem`、`MysqlDao`），下游为 MySQL 存储引擎。数据库仅负责持久化，实时消息推送由应用层处理。

## 二、架构设计

### 表关系总览

```
users ──────────────────────────────────────┐
  │                                          │
  ├── messages (sender_id, receiver_id)      │
  │     └── 索引: (thread_id, created_at)    │
  │                                          │
  ├── conversations (user_id)                │
  │     └── 关联 last_message_id             │
  │                                          │
  ├── private_chat (user1_id, user2_id)      │
  │     └── UNIQUE(user1_id, user2_id)       │
  │                                          │
  ├── group_chat + group_chat_member         │
  │                                          │
  ├── friend_request (sender, receiver)      │
  └── friend_relationship (user, friend)     │
```

### 核心设计原则

- **消息与会话分离**：会话表维护最新消息预览（last_message_id + updated_at），消息表存储完整历史。
- **单聊唯一性**：`UNIQUE(user1_id, user2_id)` 保证每对用户只有一个私聊会话。
- **群聊成员独立表**：复合主键 `(thread_id, user_id)`，支持角色管理和禁言。
- **好友关系双向**：`friend_relationship` 表每行代表单向关系，双向好友需两行（或业务层保证对称）。

## 三、核心实现

### 3.1 用户表（users）

| 字段名 | 类型 | 说明 | 约束 |
|--------|------|------|------|
| user_id | BIGINT | 用户唯一ID | AUTO_INCREMENT, PK |
| username | VARCHAR(64) | 用户名 | UNIQUE |
| password_hash | CHAR(64) | SHA-256 密码哈希 | NOT NULL |
| salt | CHAR(32) | 密码盐值 | NOT NULL |
| avatar_url | VARCHAR(255) | 头像链接 | DEFAULT NULL |
| online_status | TINYINT | 0离线/1在线 | DEFAULT 0 |
| last_active_at | DATETIME | 最后活跃时间 | DEFAULT NULL |

### 3.2 聊天消息表（messages）

```sql
CREATE TABLE `chat_message` (
  `message_id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `thread_id`  BIGINT UNSIGNED NOT NULL,
  `sender_id`  BIGINT UNSIGNED NOT NULL,
  `recv_id`    BIGINT UNSIGNED NOT NULL,
  `content`    TEXT NOT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `status`     TINYINT NOT NULL DEFAULT 0 COMMENT '0=未读 1=已读 2=撤回',
  PRIMARY KEY (`message_id`),
  KEY `idx_thread_created` (`thread_id`, `created_at`),
  KEY `idx_thread_message` (`thread_id`, `message_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

### 3.3 会话表（conversations）

| 字段名 | 类型 | 说明 |
|--------|------|------|
| session_id | VARCHAR(64) | 会话ID (PK) |
| user_id | BIGINT | 用户ID (FK) |
| session_type | TINYINT | 0单聊/1群聊 |
| unread_count | INT | 未读消息数 |
| last_message_id | BIGINT | 最后一条消息ID |
| updated_at | DATETIME(3) | 最后更新时间 |

### 3.4 单聊表（private_chat）

```sql
CREATE TABLE `private_chat` (
  `thread_id`  BIGINT UNSIGNED NOT NULL,
  `user1_id`   BIGINT UNSIGNED NOT NULL,
  `user2_id`   BIGINT UNSIGNED NOT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`thread_id`),
  UNIQUE KEY `uniq_private_thread` (`user1_id`, `user2_id`),
  KEY `idx_private_user1_thread` (`user1_id`, `thread_id`),
  KEY `idx_private_user2_thread` (`user2_id`, `thread_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### 3.5 群聊表

```sql
-- 群聊基本信息
CREATE TABLE `group_chat` (
  `thread_id`  BIGINT UNSIGNED NOT NULL,
  `name`       VARCHAR(255) DEFAULT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`thread_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 群成员
CREATE TABLE `group_chat_member` (
  `thread_id`   BIGINT UNSIGNED NOT NULL,
  `user_id`     BIGINT UNSIGNED NOT NULL,
  `role`        TINYINT NOT NULL DEFAULT 0 COMMENT '0=普通 1=管理 2=创建者',
  `joined_at`   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `muted_until` TIMESTAMP NULL,
  PRIMARY KEY (`thread_id`, `user_id`),
  KEY `idx_user_threads` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### 3.6 好友申请表 + 好友关系表

```sql
-- 好友申请
CREATE TABLE friend_request (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    sender_id BIGINT NOT NULL,
    receiver_id BIGINT NOT NULL,
    status TINYINT DEFAULT 0 COMMENT '0待处理 1已同意 2已拒绝 3已撤回',
    create_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    update_time DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- 好友关系
CREATE TABLE friend_relationship (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT NOT NULL,
    friend_id BIGINT NOT NULL,
    create_time DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

## 四、工程实践

- **索引设计**：`(thread_id, created_at)` 复合索引支撑消息时间线查询；`(thread_id, message_id)` 支撑消息分页。
- **单聊唯一性**：`UNIQUE(user1_id, user2_id)` 保证每对用户只有一个私聊会话。
- **UTF8MB4**：支持 Emoji 表情等 4 字节 UTF-8 字符。MySQL 的 utf8 只是 utf8mb3（3 字节），不含 4 字节字符。
- **密码安全**：密码哈希加盐存储，不存明文。`salt` 字段每条记录随机生成。
- **消息状态**：TINYINT 枚举（0未读/1已读/2撤回），可通过 status 变更实现撤回。
- **时间精度**：`DATETIME(3)` 毫秒精度，满足消息排序需求。`TIMESTAMP` 受 2038 问题限制。
- **分库分表预留**：以 `thread_id` 作为分片键（sharding key），同一会话消息落在同一分片，保证查询效率。
- **软删除**：消息撤回用 status 标记而非物理删除，可追溯、可恢复。

## 五、源码解析

### 5.1 MySqlDao 层封装的注册示例

```cpp
// MysqlDao::RegUser — 用户注册时的数据库操作
bool MysqlDao::RegUser(const std::string& name, const std::string& email,
                       const std::string& pwd, const std::string& icon) {
    // 1. 生成密码盐值和哈希
    std::string salt = generateSalt(32);       // CSPRNG 32字节
    std::string hash = sha256(salt + pwd);

    // 2. 从连接池获取连接
    auto guard = pool_->getConnectionGuard();
    if (!guard.valid()) return false;

    // 3. 执行插入
    auto stmt = guard->prepareStatement(
        "INSERT INTO users (username, email, password_hash, salt, avatar_url) "
        "VALUES (?, ?, ?, ?, ?)");
    stmt->setString(1, name);
    stmt->setString(2, email);
    stmt->setString(3, hash);
    stmt->setString(4, salt);
    stmt->setString(5, icon);
    return stmt->executeUpdate() > 0;
}
```

### 5.2 消息分页查询（利用复合索引）

```cpp
// 拉取某个会话最近的消息（分页）
std::vector<Message> MysqlDao::getMessages(uint64_t threadId,
                                            uint64_t beforeMessageId,
                                            int limit) {
    auto guard = pool_->getConnectionGuard();
    // (thread_id, message_id) 复合索引命中
    auto stmt = guard->prepareStatement(
        "SELECT message_id, sender_id, content, created_at, status "
        "FROM chat_message "
        "WHERE thread_id = ? AND message_id < ? "
        "ORDER BY message_id DESC LIMIT ?");
    stmt->setUInt64(1, threadId);
    stmt->setUInt64(2, beforeMessageId);
    stmt->setInt(3, limit);

    std::vector<Message> messages;
    auto rs = stmt->executeQuery();
    while (rs->next()) {
        Message msg;
        msg.messageId = rs->getUInt64("message_id");
        msg.senderId = rs->getUInt64("sender_id");
        msg.content = rs->getString("content");
        msg.createdAt = rs->getString("created_at");
        msg.status = rs->getInt("status");
        messages.push_back(msg);
    }
    return messages;
}
```

### 5.3 单聊会话查询（利用 UNIQUE 约束）

```cpp
// 获取或创建两个用户间的私聊会话
uint64_t MysqlDao::getOrCreatePrivateChat(uint64_t user1, uint64_t user2) {
    auto guard = pool_->getConnectionGuard();

    // 查询已有会话（无论 user1/user2 顺序）
    auto stmt = guard->prepareStatement(
        "SELECT thread_id FROM private_chat "
        "WHERE (user1_id = ? AND user2_id = ?) "
        "   OR (user1_id = ? AND user2_id = ?)");
    stmt->setUInt64(1, user1); stmt->setUInt64(2, user2);
    stmt->setUInt64(3, user2); stmt->setUInt64(4, user1);
    auto rs = stmt->executeQuery();
    if (rs->next()) return rs->getUInt64("thread_id");

    // 不存在则创建（利用 UNIQUE 约束防竞态）
    stmt = guard->prepareStatement(
        "INSERT INTO private_chat (user1_id, user2_id) VALUES (?, ?)");
    stmt->setUInt64(1, std::min(user1, user2));
    stmt->setUInt64(2, std::max(user1, user2));
    stmt->executeUpdate();
    return getLastInsertId();
}
```

## 六、面试准备

### 6.1 高频问法

**Q1：IM 系统的核心表有哪些？**
users（用户）、messages（消息）、conversations（会话）、private_chat（单聊）、group_chat（群聊）、group_chat_member（群成员）、friend_request（好友申请）、friend_relationship（好友关系）。

**Q2：消息表如何设计以支持高效查询？**
`(thread_id, created_at)` 复合索引实现消息时间线查询；`(thread_id, message_id)` 支持分页拉取。以 thread_id 为最左前缀保证所有会话查询都能用到索引。

**Q3：单聊如何保证唯一性？**
`UNIQUE(user1_id, user2_id)` 约束保证每对用户只有一个私聊会话。查询时用 `WHERE (user1=A AND user2=B) OR (user1=B AND user2=A)` 覆盖双向。

**Q4：为什么用 BIGINT 而不是 INT？**
BIGINT 支持 2^63 ≈ 922亿亿条记录，IM 系统消息量巨大，INT（21 亿）不够。且自增 ID 全局唯一，适合分布式 ID 生成。

**Q5：为什么用 utf8mb4 而不是 utf8？**
MySQL 的 utf8 最多 3 字节（实际是 utf8mb3），不支持 Emoji 等 4 字节字符。utf8mb4 是完整的 UTF-8 实现。

**Q6：会话表和消息表的关系？**
会话表维护最新消息预览（last_message_id + updated_at），消息表存储完整消息历史。打开聊天列表只需查询会话表（轻量），进入具体聊天才查消息表。

**Q7：群聊成员如何设计？**
独立表 `group_chat_member`，复合主键 `(thread_id, user_id)`，支持角色（普通/管理/创建者）和禁言（muted_until）。

**Q8：好友关系是单向还是双向？**
`friend_relationship` 表每行代表单向关系。A 加 B 为好友需插入 (A,B) 和 (B,A) 两行，或业务层保证对称性。好处是查询"我的好友"只需 `WHERE user_id = ?`。

**Q9：消息撤回如何在数据库层面实现？**
不物理删除消息，而是更新 `status = 2`（撤回）。好处：可追溯审计、恢复简单、索引无需重建。客户端收到 status 变更后做 UI 替换。

**Q10：如何实现未读计数？**
会话表维护 `unread_count` 字段。新消息到达时 `UPDATE conversations SET unread_count = unread_count + 1`。用户进入会话时重置为 0。高并发场景用 Redis 计数器 + 定期同步到 MySQL。

### 6.2 反问点

- 消息表太大如何分库分表？分片键选什么？
- 如何实现消息的已读回执？群聊已读怎么做？
- 离线消息如何存储和推送？有没有用 Redis 做热数据缓存？
- 消息的时序一致性如何保证？分布式场景下时钟偏移怎么办？
- 好友关系是双向表还是单表双行？为什么这样设计？

### 6.3 一句话答案

- 核心表 = users + messages + conversations + private/group_chat + friend_*
- 消息查询索引 = (thread_id, created_at/message_id)
- 单聊唯一 = UNIQUE(user1_id, user2_id)
- utf8mb4 = 完整 UTF-8，支持 Emoji
- 会话表 = 消息预览；消息表 = 完整历史
- BIGINT ≈ 922亿亿；INT ≈ 21亿
- 撤回 = status=2，不物理删除
- 分页 = WHERE thread_id=? AND message_id<? ORDER BY message_id DESC
- 未读计数 = 会话表 unread_count，进入清零

## 附录

- [MySQL 官方文档：InnoDB 索引](https://dev.mysql.com/doc/refman/8.0/en/innodb-indexes.html)
- [UTF8MB4 字符集说明](https://dev.mysql.com/doc/refman/8.0/en/charset-unicode-utf8mb4.html)
