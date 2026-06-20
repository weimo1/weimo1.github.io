---
title: IM即时通讯
date: 2026-06-20
categories:
  - ["项目学习", "即时通讯(IM)"]
publish: true
---

# IM 即时通讯

> IM（Instant Messaging）即时通讯是通过网络实时传递文字、图片、语音、视频等消息的通信系统。本笔记涵盖 IM 系统的协议选择（TCP vs UDP）和消息序列化（Protobuf）两个核心基础。

参考：[为什么 QQ 用 UDP 而不是 TCP](http://www.52im.net/thread-279-1-1.html) | [Protobuf 从入门到精通](http://www.52im.net/thread-4080-1-1.html)

## 一、核心概念

- 定义：IM 即时通讯是指通过互联网实时进行文字、语音、视频等信息交互的通信方式。核心要素包括：可靠有序的消息传递、低延迟的实时触达、多设备同步、消息持久化。
- 关键词：TCP vs UDP、Protobuf、消息序列化、实时通信、协议选择
- 适用场景/边界：
  - 个人聊天（单聊、群聊）
  - 企业通讯（钉钉/飞书/企业微信）
  - 直播弹幕、在线客服
  - 不适合：E-mail 类异步通信

## 二、详细解析（≥200字）

### 为什么 QQ 用 UDP 而不是 TCP？

TCP 的优势：可靠传输、有序交付、拥塞控制、流控。

但 UDP 在 IM 场景下有自己的优势：

1. **无需连接建立**：UDP 无三次握手，弱网下 TCP 可能一直建立失败，UDP 直接发包
2. **更灵活的重传策略**：TCP 的超时重传和拥塞控制有时过于保守。IM 可能更关心实时性而非可靠性（如视频通话允许丢帧）
3. **无队头阻塞**：TCP 严格按序交付，前面丢包会阻塞后序数据。UDP 各数据包独立
4. **资源消耗更低**：无连接状态，服务端资源占用小

**为什么现代方案更倾向 QUIC？**
- QUIC 基于 UDP 但内置可靠传输、加密、多路复用
- 0RTT 重连、连接迁移、无队头阻塞
- 结合了 UDP 的灵活性和 TCP 的可靠性

**实际选择：**
- 文本消息（必须可靠）→ TCP 或 QUIC
- 音视频通话（实时优先）→ UDP
- 弱网移动端 → QUIC

### 消息序列化——Protobuf

Protobuf 在 IM 中的优势：
1. **压缩率高**：Varint 编码 + 字段编号替代字段名，比 JSON/XML 小 3-10 倍
2. **解析速度快**：二进制格式，无需字符串解析
3. **跨语言**：支持 C++/Java/Go/Python 等
4. **向后兼容**：字段编号保证协议演进兼容性

典型 IM 消息协议的 Protobuf 定义：
```protobuf
message ChatMessage {
    uint64 msg_id     = 1;
    uint64 session_id = 2;
    uint64 from_uid   = 3;
    uint64 to_uid     = 4;
    uint32 msg_type   = 5;  // 0:text, 1:image, 2:audio
    bytes  content    = 6;
    int64  timestamp  = 7;
    uint64 client_id  = 8;  // 客户端生成的顺序 ID
}
```

## 三、动手实践（代码案例）

```c++
// Protobuf 消息序列化示例
#include "chat.pb.h"
#include <string>

std::string serialize_message(uint64_t from, uint64_t to, const std::string& text) {
    ChatMessage msg;
    msg.set_msg_id(generate_msg_id());
    msg.set_from_uid(from);
    msg.set_to_uid(to);
    msg.set_msg_type(0);  // text
    msg.set_content(text);
    msg.set_timestamp(time(nullptr));
    
    std::string serialized;
    msg.SerializeToString(&serialized);
    return serialized;
}
```

## 四、进阶应用（≥500字）

### 与其他主题的关联

- **Protocol Buffers**：核心消息序列化方案，在 gRPC 中广泛使用
- **QUIC 协议**：未来 IM 长连接的主流选择
- **WebSocket**：浏览器端 IM 的标准方案
- **TCP 拥塞控制**：BBR 等新算法提升弱网吞吐

### 工程中的真实用法

- **微信/QQ**：腾讯自研 Mars 长连接框架，TCP 为主、UDP 为辅
- **WhatsApp**：基于 XMPP + 自定义二进制协议
- **Telegram**：自研 MTProto 协议

### 常见优化策略

- **精简协议**：自定义二进制协议比 Protobuf 更小（无 schema 开销），但失去兼容性
- **增量更新**：只传输变更字段，减少重复数据
- **批量消息**：多条消息合并一次 push

## 五、源码解析和实践感悟（≥1000字）

### TCP vs UDP 的工程实践

TCP 在 IM 中的问题不是可靠性，而是**盲目可靠**——TCP 为了保证可靠传输会重传丢失的数据包。但 IM 中有些场景不需要绝对可靠：

- 视频通话中，丢失一帧画面的影响远小于因重传造成的延迟
- 直播弹幕中，偶尔丢失一条弹幕可接受

这就是为什么"QQ 用 UDP"——早期 QQ 包含音视频通话，TCP 不适合实时音视频。文本消息可以单独用更可靠的信道。

### Protobuf 的 Varint 编码

Protobuf 的高效在于 Varint 编码：小整数用更少字节存储。

```
0-127:          1 byte
128-16383:      2 bytes
16384-2097151:  3 bytes
```

IM 中的消息 ID、用户 ID 通常用 varint 存储，比固定 8 字节节省 50-70% 空间。

### 经验总结

1. 协议选择没有银弹：TCP 可靠但慢，UDP 快但不可靠，QUIC 是二者折中
2. 生产环境 TCP 仍是主流——UDP 被运营商限制（QoS、NAT 穿透）
3. Protobuf 是 IM 消息序列化的工业标准——在不牺牲太多性能的前提下保证协议兼容性
4. 自定义二进制协议极快（无 schema 开销），但演化困难——权衡点在于"性能 vs 维护成本"

## 六、面试准备（高频问法≥10个，反问点/一句话答案≥5个，均带回答）

### 6.1 高频问法（≥10个）

Q1：QQ 为什么用 UDP 而不是 TCP？

A：UDP 无连接、无队头阻塞、灵活可控。适合视频音频等实时场景（允许少量丢包）。现代 IM 更倾向 TCP + QUIC 双协议栈。

Q2：TCP 和 UDP 在 IM 场景各适合什么？

A：TCP 适合文本消息（必须可靠）、文件传输。UDP 适合音视频通话（实时优先）。QUIC 试图统一两者。

Q3：Protobuf 相比 JSON 有什么优势？

A：二进制编码（比 JSON 小 3-10 倍）、解析速度快（无需字符串解析）、Schema 演化兼容、跨语言支持。

Q4：Protobuf 的 Varint 编码原理是什么？

A：每个字节最高位为继续位，低 7 位为数据。小整数用更少字节（如 1 只需 1 字节）。int32 字段平均节省 50% 空间。

Q5：IM 消息协议的核心字段有哪些？

A：msg_id（全局唯一）、session_id（会话标识）、from_uid/to_uid（收发方）、msg_type（消息类型）、content（内容）、timestamp（时间戳）、client_id（客户端顺序）。

Q6：自定义二进制协议 vs Protobuf 如何选？

A：自定义协议极快极省，但演化困难，需自己处理兼容性。Protobuf 有 schema 保证兼容性。高性能场景自定义，通用场景 Protobuf。

Q7：弱网场景下 TCP 有什么问题？

A：TCP 严格按序交付，前一个包丢失会阻塞后面所有包（队头阻塞）。拥塞控制保守，弱网下吞吐极低。TCP 建立连接需要 3 次握手（弱网可能一直失败）。

Q8：QUIC 为什么适合移动端 IM？

A：0RTT 重连（TCP+TLS 至少 1RTT）、连接迁移（切换 WiFi→4G 不断连）、无队头阻塞（多 Stream 独立）、内置加密。

Q9：消息序列化如何平衡性能和兼容性？

A：使用 TLV（Type-Length-Value）或 Protobuf。未知字段可安全跳过，新增字段不影响旧版客户端。向后兼容 + 向前兼容。

Q10：IM 系统中消息大小如何控制？

A：文本消息限长（如 5000 字）。图片/视频用缩略图 + URL 引用而非 embedding。批量消息合并压缩。超过阈值的大文件走独立的文件传输通道。

### 6.2 反问点/陷阱点（≥5个）

- 贵公司的 IM 系统是否使用了多协议栈（TCP+QUIC）？在做协议升级时如何兼容老客户端？
- 消息序列化方案是如何选择的？有没有因为性能做过自定义二进制协议？

- 陷阱 1："Protobuf 可以实现零拷贝序列化？" — Protobuf 不是零拷贝。序列化需要分配新 buffer 并逐字段拷贝。可通过 Arena 分配器减少内存碎片，但无法避免拷贝。
- 陷阱 2："用 UDP 就可以随便丢包？" — IM 中的文本消息不能丢。UDP 之上需自建可靠传输层（ACK+重试+排序），复杂度相当于在 UDP 上实现 TCP。
- 陷阱 3："JSON 完全可以替代 Protobuf？" — JSON 在带宽紧张或消息量极大的 IM 场景下，大小和解析开销不可接受。毫秒级的延迟预算不允许 JSON 的解析时间。

### 6.3 一句话答案（≥5个）

- IM 协议选择的核心是：TCP 保证可靠文本消息，QUIC 提升弱网体验，UDP 用于实时音视频。
- Protobuf 优于 JSON 的关键是：二进制编码紧凑（小 3-10 倍）+ 解析快速 + Schema 演化兼容。
- QUIC 的杀手级特性是：0RTT 重连和连接迁移——移动端断网重连体验的质变。
- 自定义二进制协议的取舍是：极致的性能和空间效率换取协议演化的复杂性。
- 当被问到"IM 用什么协议"时回答："文本消息 TCP + Protobuf 序列化，弱网升级 QUIC。音视频用 UDP+RTP。生产环境 TCP 仍是主流。"

## 附录（模板外原内容收纳）

> 以下为原笔记中的参考链接与图片，原样保留于此。

[为什么QQ用的是UDP协议而不是TCP协议？-即时通讯开发者社区](http://www.52im.net/thread-279-1-1.html)

[IM通讯协议专题学习(一)：Protobuf从入门到精通，一篇就够！-即时通讯开发者社区](http://www.52im.net/thread-4080-1-1.html)

![](../资源/图片/1758380013687-0a7cafd4-b710-418e-8e88-ed7415cd0bcd.png) ![](../资源/图片/1758381056120-61439d53-10fb-48e3-9b84-f192e7865acb.png)
