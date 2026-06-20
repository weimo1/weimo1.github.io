---
title: gRPC通信与连接池
date: 2026-06-20
categories:
  - ["项目学习", "网络与RPC"]
publish: true
---

# gRPC通信与连接池设计

> 适用范围：gRPC服务间通信原理、多Channel/Stub连接池设计、brpc vs gRPC对比分析、gRPC服务端构建。

## 写作约束（铁律）

- **原内容一字不删**：所有原有文字、代码、注释、图片必须全部保留，禁止删除任何原内容。
- **只做归纳重组+增加**：在原有内容基础上调整结构、归类，新增内容以"补充"标记。新增量须让最终篇幅 ≥ 原版。
- **放不进的进附录**：六大段模板容纳不下的原内容，移入最后的「附录」章节，不得丢弃。
- **动笔前先搜索**：做相关知识准备；源码要贴原始代码，有需要可贴汇编。
- **字数硬指标**：详细解析(二)≥200字、进阶应用(四)≥500字、源码解析与实践感悟(五)≥1000字、面试准备(六)高频问法≥8个且带回答，反问点和一句话答案各≥5个。
- 先结论后细节，避免长段堆砌。
- 每节至少 3 条要点。
- 代码必须可运行或可推导，配清楚输入/输出或预期。
- **代码块必须标注语言**：所有代码块必须根据实际语言标注，C++ 代码用 `c++`（不可用 `cpp` 或 `c`），Python 用 `python`，汇编用 `asm`/`x86asm`，shell 用 `bash` 等。禁止无语言标注的裸代码块。

## 一、项目/模块概述

- **模块定位**：gRPC是IM项目中服务间通信的核心框架。GateServer、ChatServer、StatusServer、VerifyServer之间通过gRPC进行高效、跨语言的RPC调用。
- **技术栈与依赖**：gRPC（C++）、Protocol Buffers 3（.proto定义服务接口）、HTTP/2（传输协议）、连接池（mutex + condition_variable + queue）
- **模块边界**：
  - 输入：各服务的.proto接口定义
  - 输出：Stub代理对象、RPC请求/响应
  - 上下游：GateServer ↔ StatusServer、ChatServer ↔ StatusServer、ChatServer ↔ ChatServer

- **RPC 基础概念（补充自 grpc.txt）**：RPC（Remote Procedure Call）框架负责屏蔽底层的传输方式（TCP / UDP）、序列化方式（XML / Json / 二进制）和通信细节。服务调用者可以像调用本地接口一样调用远程的服务提供者，而不需要关心底层通信细节和调用过程。

![RPC 调用流程](../资源/图片/grpc-rpc-overview.png)

- **RPC 核心工作流（补充）**：rpc 是分布式通信的基础。对于服务端，通过 pb 把自己的业务类注册到网络库的回调中，并将自己的 IP 注册到 zk 等服务发现上；对于调用方，通过 pb 将调用方法注册进去，rpc 框架的 channel 在调用时封装 rpc 协议，加上参数和调用函数名，通过轮询或均衡策略找到 zk 服务路径下的节点，发起调用。

- **gRPC 七大优势（补充）**：
  1. 基于 Protocol Buffer 二进制协议 + HTTP/2，进程间通信高效
  2. 具有简单、定义良好的服务接口和协议
  3. 强类型，静态类型减少运行时和交互错误
  4. 支持多语言（C++、Java、Python、Go 等）
  5. 原生支持双向流式传输（客户端/服务端流）
  6. 内置认证、加密、元数据交换、压缩、负载均衡、服务发现等高级特性
  7. CNCF 项目，与云原生生态系统高度集成（Envoy、Kubernetes 等）

- **gRPC Channel 概念（补充）**：gRPC Channel 表示 client 端与 server 端之间的 HTTP/2 连接。当 client 端创建 gRPC Channel 时，后台创建 HTTP/2 连接。Channel 创建后可重用来发送多个远程调用，这些调用映射到 HTTP/2 的流（Stream）中。消息以 HTTP/2 帧的形式发送，一个帧可能携带一个 gRPC 长度前缀消息，大消息可能跨越多个数据帧。

## 二、架构设计（≥200字）

### 第一层：gRPC核心组件

| 组件 | 功能描述 |
| :--- | :--- |
| **Channel** | 客户端与服务端的连接抽象，管理 HTTP/2 连接池和负载均衡策略 |
| **Stub** | 客户端生成的代理类，封装远程方法调用（同步/异步） |
| **Service** | 服务端实现的具体业务逻辑类，继承自 .proto 生成的基类 |
| **ServerBuilder** | 服务端构建器，用于配置监听端口、线程池、拦截器等 |
| **CompletionQueue** | 异步操作队列，用于非阻塞处理请求（仅限异步模式） |

### 第二层：服务端工作流程

1. **定义服务接口**（.proto 文件）：使用 Protocol Buffers 定义服务方法和消息格式
2. **生成服务端代码**：通过 `protoc --grpc_out=. --cpp_out=. user.proto`
3. **实现服务逻辑**：继承生成的基类，实现 RPC 方法
4. **配置并启动服务器**：使用 ServerBuilder 配置监听端口、线程池
5. **处理请求**：同步模式（独立线程）或异步模式（CompletionQueue）

### 第三层：为什么需要多个Channel/Stub而非单个？

**性能优化**：
- **多路复用限制**：单个Channel的HTTP/2多路复用存在流控和TCP层队头阻塞
- **并行处理**：多个Channel可并行处理请求，提高吞吐量
- **负载均衡**：连接池可配合服务发现（如DNS轮询、Consul）将请求分发到不同服务实例
- **容错能力**：当某个Channel对应的服务实例故障时，其他Channel仍可用，避免单点故障
- **线程安全**：每个Stub实例非线程安全，需为每个线程分配独立Stub

## 三、核心实现（代码走读）

### 3.1 gRPC服务接口定义

```c++
syntax = "proto3";
service UserService {
  rpc GetUser (UserRequest) returns (UserResponse) {};
}
message UserRequest { int32 id = 1; }
message UserResponse { string name = 1; }
```

生成代码：`protoc --grpc_out=. --cpp_out=. user.proto`

### 3.2 服务端实现

```c++
class UserServiceImpl final : public UserService::Service {
  Status GetUser(ServerContext* ctx, const UserRequest* req, UserResponse* resp) override {
    // 业务逻辑
    resp->set_name("Alice");
    return Status::OK;
  }
};
```

**配置并启动服务器**：

```c++
void RunServer() {
  UserServiceImpl service;
  ServerBuilder builder;
  // 监听端口
  builder.AddListeningPort("0.0.0.0:50051", grpc::InsecureServerCredentials());
  // 注册服务
  builder.RegisterService(&service);
  // 设置线程池（默认1线程，需手动调整）
  builder.SetSyncServerOption(ServerBuilder::MIN_POLLERS, 4);
  builder.SetSyncServerOption(ServerBuilder::MAX_POLLERS, 8);
  // 构建并启动服务器
  std::unique_ptr<Server> server(builder.BuildAndStart());
  server->Wait(); // 阻塞等待请求
}
```

### 3.3 gRPC线程模型

gRPC 服务端默认使用 **线程池模型**，具体分为两类线程：

1. **I/O 线程**：处理 HTTP/2 协议解析、帧收发（由 ServerBuilder 自动管理）
2. **工作线程**：执行用户定义的 RPC 方法（通过 SetSyncServerOption 配置数量）

### 3.4 gRPC连接池实现（RPCConPool）

```c++
class RPConPool {
public:
    RPConPool(size_t poolSize, std::string host, std::string port)
        : poolSize_(poolSize), host_(host), port_(port), b_stop_(false) {
        for (size_t i = 0; i < poolSize_; ++i) {
            std::shared_ptr<Channel> channel = grpc::CreateChannel(host+":"+port,
                grpc::InsecureChannelCredentials());
            connections_.push(VarifyService::NewStub(channel));
        }
    }

    ~RPConPool() {
        std::lock_guard<std::mutex> lock(mutex_);
        Close();
        while (!connections_.empty()) {
            connections_.pop();
        }
    }

    std::unique_ptr<VarifyService::Stub> getConnection() {
        std::unique_lock<std::mutex> lock(mutex_);
        cond_.wait(lock, [this] {
            if (b_stop_) return true;
            return !connections_.empty();
        });
        if (b_stop_) return nullptr;
        auto context = std::move(connections_.front());
        connections_.pop();
        return context;
    }

    void returnConnection(std::unique_ptr<VarifyService::Stub> context) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (b_stop_) return;
        connections_.push(std::move(context));
        cond_.notify_one();
    }

    void Close() {
        b_stop_ = true;
        cond_.notify_all();
    }

private:
    atomic<bool> b_stop_;
    size_t poolSize_;
    std::string host_;
    std::string port_;
    std::queue<std::unique_ptr<VarifyService::Stub>> connections_;
    std::mutex mutex_;
    std::condition_variable cond_;
};
```

### 3.5 服务间RPC调用示例

**Service A调用Service B**：

```c++
// 创建Service B的客户端Stub
auto channel = grpc::CreateChannel("serviceb-host:50051", grpc::InsecureChannelCredentials());
auto stub = ServiceB::NewStub(channel);

// 发起RPC调用
DataRequest request;
request.set_query("input_data");
DataResponse response;
ClientContext context;
Status status = stub->GetData(&context, request, &response);
```

### 3.6 gRPC Channel 内部机制与连接生命周期（补充自 grpc.txt）

> **Channel is an abstraction over a long-lived connection!**

![gRPC Channel 设计](../资源/图片/grpc-layered-arch.png)

gRPC Channel 封装了 gRPC Core 里的底层 API，其内部连接生命周期如下：

**1. Channel 状态检查**：
对于每次 RPC 调用，首先检查 Channel 状态。gRPC Channel 维护完整的连接状态模型：

```
IDLE → CONNECTING → READY → TRANSIENT_FAILURE → SHUTDOWN
  ↑                     ↓            ↓
  ←←←←← CONNECTING ←←←←←←←←←←←←←←←←←←←←
```

- **IDLE**：连接空闲，可能被关闭
- **CONNECTING**：正在建立连接
- **READY**：连接就绪，可以发送 RPC
- **TRANSIENT_FAILURE**：临时失败，会自动重试
- **SHUTDOWN**：连接已关闭，不会重试

若 Channel 为空闲状态，则尝试连接服务器：

**2. 域名解析（异步操作）**：
🔍 域名解析为异步操作，从名称转化为 IP 和端口以供 TCP 连接。gRPC 支持可插拔的 Resolver 接口，内置 DNS Resolver，也可集成 Consul、Etcd、Kubernetes 等服务发现。

**3. 负载均衡与 Sub-channel 创建**：
⚖ 创建负载均衡相关数据结构，并为每组 IP/端口组合生成一个 sub-channel。gRPC 内置三种负载均衡策略：
- **pick_first**：选择第一个可用连接
- **round_robin**：轮询所有健康连接
- **grpclb**：使用外部负载均衡器

**4. Sub-channel 选择**：
💼 在负载均衡中，选取适当的 sub-channel 用于向指定服务端传输数据。

**5. TCP 连接与握手**：
🕹 TCP 连接过程中包含握手阶段，默认处理三种类型的握手：endpoint、HTTP、TCP。gRPC 基于 HTTP/2，因此需要完成 TCP 三次握手 + TLS 协商（如启用）+ HTTP/2 连接前言（PRI * HTTP/2.0）等步骤。

**补充：单个 Channel 的 HTTP/2 多路复用局限性**：
- 单个 Channel 底层只有一个或少量 HTTP/2 连接
- HTTP/2 虽支持多路复用（多个 Stream 共享一个 TCP 连接），但 TCP 层面的丢包会导致队头阻塞（Head-of-Line Blocking）——一个丢包影响所有 Stream
- 多 Channel 通过建立多个 TCP 连接来缓解这个问 题——一个连接的 TCP 重传不影响其他连接

## 四、工程实践（≥500字）

### brpc 与 gRPC 对比分析

#### 1. 核心定位与背景

- **brpc**：百度开源，目标：高性能、低延迟的 C++ RPC 框架，协议支持：HTTP、Redis、RTMP 等，语言支持：C++ 为主
- **gRPC**：Google 开源，目标：跨语言、标准化的 RPC 框架，协议支持：HTTP/2 + Protocol Buffers，语言支持：C++、Java、Python、Go 等

#### 2. 性能对比

| **指标** | **brpc** | **gRPC** |
| :--- | :--- | :--- |
| 单机 QPS | 100万+（C++ 优化场景） | 10万~50万（依赖语言实现） |
| 延迟 | 微秒级 | 毫秒级 |
| 资源占用 | 内存占用低 | 较高 |

#### 3. 典型应用场景

- **brpc**：高性能 C++ 服务（搜索、广告系统），混合协议接入（HTTP + Redis）
- **gRPC**：跨语言微服务（Java + Go + Python），云原生应用（Kubernetes + Istio）

### gRPC 断线重连

**gRPC 客户端在检测到连接断开后，会按照配置的重连策略进行重连尝试。以下是重连机制的工作流程：**

- 检测断开：客户端检测到与服务器的连接断开
- 初始重连：按照配置的初始重连间隔时间进行第一次重连尝试
- 指数退避：如果第一次重连失败，按照指数退避策略增加重连间隔时间，并进行下一次重连尝试
- 最大重连次数：如果重连次数达到配置的最大重连次数，停止重连
- 成功重连：如果在重连过程中成功建立连接，重连机制结束，客户端恢复正常通信

**重连机制的注意事项**：

- 合理配置重连间隔时间和指数退避策略，以避免在服务器负载过高时频繁重连，导致服务器压力进一步增加
- 配置适当的最大重连次数，以避免客户端在长时间无法连接服务器时陷入无限重连循环
- 在不稳定的网络环境下，重连机制可以提高系统的容错性和可用性，但也需要注意可能的网络抖动和延迟对重连的影响
- 在实现重连机制时，建议添加详细的日志和监控，以便在重连失败或重连次数过多时能够及时发现问题并采取措施

### 自动重连策略

#### (1) 透明重连（Transparent Reconnection）

当 TCP 连接意外断开（如网络闪断），gRPC 客户端自动尝试重建连接，对上层业务透明。适用场景：短时间网络波动、服务器重启。

#### (2) 指数退避（Exponential Backoff）

初次重连立即尝试，后续重试间隔按指数增长（如 1s, 2s, 4s...），避免雪崩。

```c++
args.SetInt(GRPC_ARG_MIN_RECONNECT_BACKOFF_MS, 1000); // 最小重连间隔1秒
args.SetInt(GRPC_ARG_MAX_RECONNECT_BACKOFF_MS, 60000); // 最大重连间隔60秒
```

### 常见优化策略

**连接池优化**：
- 预创建：服务启动时即创建所有Stub，避免运行时创建开销
- 懒加载：配合Defer自动归还，避免遗漏
- 健康检查：定期ping检查Channel可用性，剔除失效连接

**序列化优化**：
- Protobuf比JSON体积小3-10倍，解析快5-10倍
- 对于大消息，考虑使用流式gRPC（streaming）避免内存暴涨

## 五、源码解析和实践感悟（≥1000字）

### 关键实现路径

**连接池的生产者-消费者模型**：

RPConPool本质是一个有界阻塞队列：
- 生产者：returnConnection（归还Stub）
- 消费者：getConnection（获取Stub）
- 同步机制：mutex + condition_variable
- 停止信号：atomic<bool> b_stop_

设计精要：
- getConnection在池为空时wait，被returnConnection的notify_one唤醒，或被Close的notify_all唤醒
- returnConnection在b_stop_为true时直接丢弃Stub（不再放回池中）
- Defer模式配合：调用方获取Stub后立即创建Defer对象，函数退出时自动归还

**为什么Stub用unique_ptr而不是shared_ptr？**

- unique_ptr明确所有权：谁获取谁负责归还
- shared_ptr可能导致"忘记归还"（引用计数在别处被持有）
- unique_ptr配合std::move语义清晰，性能更好（无引用计数开销）

**HTTP/2多路复用的队头阻塞问题**：

gRPC基于HTTP/2，HTTP/2虽然支持多路复用（多个Stream共享一个TCP连接），但TCP层面的丢包仍会影响所有Stream（TCP队头阻塞）。多个Channel通过建立多个TCP连接来缓解这一问题——当一个连接的TCP重传阻塞时，其他连接不受影响。

**brpc为什么比gRPC快？**

1. brpc是纯C++实现，无多语言抽象层开销
2. brpc使用更高效的序列化（mcpack/brpc自定义协议 vs Protobuf）
3. brpc的事件驱动模型更轻量（bthread协程 vs gRPC线程池）
4. brpc的连接复用更激进（单连接多协程 vs 多连接多线程）

但gRPC的多语言生态是brpc无法替代的优势。

**gRPC线程模型的陷阱**：

gRPC C++同步服务端的默认配置是1个CompletionQueue线程 + 1个工作线程。这意味着：
- 所有RPC请求都由1个线程串行处理！
- 如果某个RPC方法阻塞（如数据库查询），会阻塞所有后续请求

解决方案：通过SetSyncServerOption显式配置MIN_POLLERS和MAX_POLLERS。

### 难点与易错点

1. **Stub非线程安全**：每个Stub只能由一个线程同时使用。本项目的连接池通过unique_ptr + 队列确保了"获取-使用-归还"的独占模式。

2. **Channel的生命周期管理**：Channel在内部维护HTTP/2连接，析构时会关闭连接。RPConPool在析构时先Close()标记停止，再逐个pop销毁Stub和关联的Channel。

3. **gRPC超时设置**：ClientContext可以设置deadline，但默认是无限等待。生产环境必须设置合理的超时时间（如3s），避免调用方被慢服务拖死。

4. **Protobuf版本兼容性**：新增字段必须是optional或有默认值，不能修改已有字段的编号和类型——这是Protobuf向后兼容的铁律。

### 经验总结（补充）

- **连接池大小的确定**：一般设为CPU核数的2-4倍。太小→并发能力不足，太大→连接数过多消耗内存和文件描述符。
- **gRPC vs REST**：gRPC延迟更低（HTTP/2 + Protobuf），适合服务间通信；REST更通用（JSON + HTTP/1.1），适合对外API。
- **健康检查必不可少**：生产环境的连接池需要定期检查Channel状态（通过grpc::ConnectivityState），剔除CONNECTING/SHUTDOWN状态的连接。

## 六、面试准备（高频问法≥10个，反问点/一句话答案≥5个，均带回答）

### 6.1 高频问法（≥10个）

**基础理解**：

Q1：gRPC的工作流程是怎样的？

A：1) .proto定义服务接口和消息格式；2) protoc编译器生成服务端基类和客户端Stub；3) 服务端继承基类实现业务逻辑；4) 客户端创建Channel和Stub发起RPC调用；5) 底层通过HTTP/2传输Protobuf序列化的数据。

Q2：为什么需要gRPC连接池？

A：gRPC Channel创建成本高（HTTP/2握手+TLS协商），频繁创建/销毁会导致延迟增加和连接数爆炸。连接池复用Channel和Stub，配合Defer自动归还，降低延迟和资源消耗。

Q3：brpc和gRPC的性能差异原因是什么？

A：brpc纯C++无多语言抽象层开销，使用bthread协程（比线程更轻量），自定义协议比Protobuf更紧凑。gRPC的多语言支持带来了抽象层开销。brpc单机QPS可达100万+，gRPC在10-50万。

**原理深入**：

Q4：gRPC的HTTP/2多路复用有什么优势和局限？

A：优势：多个Stream共享一个TCP连接，减少连接建立开销。局限：TCP层面的队头阻塞——一个丢包会影响所有Stream。缓解方案：多Channel（多TCP连接）分散风险。

Q5：gRPC服务端的线程模型是怎样的？

A：默认有两类线程：I/O线程（处理HTTP/2帧收发）和工作线程（执行RPC方法）。默认配置极低（1+1），需通过SetSyncServerOption显式调整。异步模式通过CompletionQueue实现更高并发。

Q6：Stub为什么是非线程安全的？

A：Stub内部持有序列化缓冲区和调用状态，多线程并发调用会导致数据竞争。每个线程应有独立的Stub，或通过互斥锁保护。

**实践应用**：

Q7：gRPC断线重连的指数退避策略如何配置？

A：通过ChannelArguments设置GRPC_ARG_MIN_RECONNECT_BACKOFF_MS（最小间隔，如1s）和GRPC_ARG_MAX_RECONNECT_BACKOFF_MS（最大间隔，如60s）。gRPC自动在两者之间做指数退避。

Q8：如何监控gRPC服务的健康状态？

A：1) 使用grpc::ConnectivityState检查Channel状态（IDLE/CONNECTING/READY/TRANSIENT_FAILURE/SHUTDOWN）；2) 实现gRPC Health Checking Protocol；3) 定期发送轻量级RPC（如Ping）检测延迟和可用性。

Q9：Protobuf如何保证向后兼容？

A：1) 不修改已有字段的编号和类型；2) 新增字段使用新的编号；3) 删除字段时标记为reserved防止编号复用；4) 使用optional/oneof处理可选字段。旧版客户端忽略未知字段，新版客户端对缺失字段使用默认值。

Q10：gRPC的四种服务类型分别是什么？

A：1) Unary（一元）：一次请求一次响应；2) Server Streaming：一次请求多次响应；3) Client Streaming：多次请求一次响应；4) Bidirectional Streaming：双向流式。IM项目中主要使用Unary模式。

### 6.2 反问点/陷阱点（≥5个）

针对面试官的深度问题：

- 贵团队在gRPC和brpc之间做过技术选型吗？最终选择的依据是什么？
- 跨语言gRPC调用时，贵团队遇到过哪些Protobuf版本不一致导致的问题？
- 贵团队对gRPC的负载均衡是如何实现的？客户端负载均衡还是服务端代理？

常见的陷阱问题：

- **陷阱问题1**：gRPC连接池中的Stub归还后，如果被其他线程获取并使用，Channel的状态（如认证信息）会混淆吗？ → 不会。每个Stub绑定的是创建时的Channel，Channel维护的是与服务端的独立HTTP/2连接。但需注意：如果Stub创建时设置了CallCredentials，归还后再被其他调用方获取可能导致认证信息错误。解决方案：连接池中的Stub不设置per-call credentials，由调用方在ClientContext中设置。
- **陷阱问题2**：gRPC默认的超时时间是多少？ → 默认无超时（infinite）！如果服务端处理时间过长或宕机，客户端会永远阻塞。必须通过ClientContext::set_deadline()设置超时。
- **陷阱问题3**：连接池大小设多大合适？池满了getConnection会怎样？ → 一般CPU核数×2~4。池满时getConnection会阻塞在condition_variable::wait上，直到有Stub被归还。如果业务阻塞时间过长，会导致调用方线程池耗尽。需设置超时等待或动态扩容。

### 6.3 一句话答案（≥5个）

快速记忆要点：

- gRPC的核心三要素是**.proto定义 + protoc代码生成 + HTTP/2传输**
- 连接池设计的核心是**预创建 + 获取/归还 + Defer自动回收**
- brpc vs gRPC的选择依据是**极致性能（brpc） vs 多语言生态（gRPC）**
- 避免的常见错误是**忘记配置gRPC线程池大小导致单线程瓶颈**
- gRPC的最大优势是**跨语言 + 标准化**，最大代价是**性能开销高于专用RPC框架**

情景模拟答案：

- 当被问到"gRPC连接池的必要性"时，回答："每次RPC调用都新建Channel需要HTTP/2握手（至少2个RTT），连接池将延迟从毫秒级降到微秒级。"
- 当被问到"为什么不用brpc"时，回答："项目有Node.js验证服务，需要跨语言支持。gRPC的多语言生态是brpc无法替代的。纯C++场景会优先考虑brpc。"
- 当被问到"gRPC最大的坑是什么"时，回答："默认单工作线程导致高并发下性能极差。必须显式配置MIN_POLLERS和MAX_POLLERS。另外默认无超时也容易导致调用方被拖死。"

## 附录（模板外原内容收纳）

> 以下为原笔记中不直接适配六大段结构、但仍有价值的内容，原样保留于此。

### 基于 Protobuf + Zookeeper 的 RPC 框架分析（原 grpc.txt 笔记）

参考：[一个基于 protobuf 和 zookeeper 的 RPC 框架 —— C++ 实现（施磊）](https://blog.csdn.net/shenmingxueIT/article/details/115773482)

首先 RPC 框架肯定是部署到一台服务器上的，所以我们需要对这个服务器的 ip 和 port 进行初始化。然后创建一个 provider（也就是 server）对象，将当前 UserService 这个对象传递给他，也就是其实这个 RPC 框架和我们执行具体业务的节点是在同一个服务器上的。RPC 框架负责解析其他服务器传递过来的请求，然后将这些参数传递给本地的方法，并将返回值返回给其他服务器。

---

**RPC 调用流程拆解**：

- 初始化 RPC 远程调用要连接的服务器
- 定义一个 UserService 的 stub 桩类，由这个桩类去调用 Login 方法

Login 的 RPC 重载函数有四个参数：controller（表示函数是否出错）、request（参数）、response（返回值）、done（回调函数）。其主要做的也是去围绕着解析参数，将参数放入本地调用的方法，将结果返回并执行回调函数。至于这个回调函数则是在服务端执行读写事件回调函数绑定的。

定义桩类的时候，会传入一个 RpcChannel 的指针，这个绑定到这个桩类的 `channel_` 指针。当我们去调用这个桩类的 `Login` 方法的时候，会去调用传递进来的 channel 的 `CallMethod` 方法。

显而易见，发送方法、参数等，都是在 `CallMethod` 这个方法中执行的。`CallMethod` 里面执行的内容对我们理解 RPC 调用体系至关重要。

![RPC 调用流程](D:\桌面\rpc流程.png)

### gRPC 实现架构（原笔记）

gRPC 采用分层架构实现。

![gRPC 分层架构](https://i-blog.csdnimg.cn/blog_migrate/a5577b7cf92d1e87f86d2e6d51cedcab.png#pic_center)

![gRPC 设计与实现](D:\桌面\zuoye\grpc设计和实现.png)

![Channel 示意图](D:\桌面\zuoye\channel.png)

![Channel 原型图](D:\桌面\zuoye\channel原型图.png)

### 原 gRPC.md 参考链接

- [gRPC Call, Channel, Connection and HTTP/2 Lifecycle - StackOverflow](https://stackoverflow.com/questions/63749113/grpc-call-channel-connection-and-http-2-lifecycle)
