---
title: grpc和brpc
date: 2026-06-20
categories:
  - ["项目学习", "网络与RPC"]
publish: true
---

# gRPC 与 brpc 对比选型

> gRPC 和 brpc 是 C++ 领域两大主流 RPC 框架。gRPC 由 Google 开源，主打跨语言标准化和云原生生态；brpc 由百度开源，主打极致性能和多协议支持。此外还有腾讯的 tRPC 等多语言框架。本文提供选型框架和实践建议。

## 一、核心概念

- **定义**：gRPC 基于 HTTP/2 + Protobuf，是跨语言、标准化的 RPC 框架。brpc 基于自研高性能网络库，支持 HTTP、Redis、RTMP 等多协议。两者设计哲学不同——gRPC 追求通用性和生态，brpc 追求性能和灵活性。
- **关键词**：RPC 框架选型、gRPC、brpc、tRPC、Protobuf、HTTP/2、bthread、多协议支持
- **适用场景/边界**：
  - gRPC：跨语言微服务、云原生应用、需要 gRPC 生态（拦截器/服务网格）的项目
  - brpc：C++ 为主的高性能服务、需要多协议混合接入的场景

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：设计哲学对比**

| 维度 | gRPC | brpc |
|------|------|------|
| 设计目标 | 跨语言、标准化、通用性 | C++ 极致性能、多协议、灵活性 |
| 核心协议 | HTTP/2 + Protobuf | 自研高性能协议 + Protobuf/JSON/HTTP |
| 线程模型 | I/O线程 + 工作线程池 | bthread（M:N 用户态线程） |
| 服务定义 | .proto 文件 + protoc 编译 | .proto 文件（兼容 Protobuf） |

**第二层：gRPC 核心组件**

| 组件 | 功能描述 |
|------|---------|
| **Channel** | 客户端与服务端的连接抽象，管理 HTTP/2 连接池和负载均衡策略 |
| **Stub** | 客户端生成的代理类，封装远程方法调用（同步/异步） |
| **Service** | 服务端实现的具体业务逻辑类，继承自 .proto 生成的基类 |
| **ServerBuilder** | 服务端构建器，用于配置监听端口、线程池、拦截器 |
| **CompletionQueue** | 异步操作队列，用于非阻塞处理请求（异步模式） |

**第三层：性能差异的根源**

- **bthread vs pthread**：brpc 的 bthread 是用户态线程，创建/切换约 100ns，pthread 约 1μs。在高并发 I/O 场景差距 10 倍
- **协议实现**：brpc 直接操作 buffer，零拷贝路径更多。gRPC 的 HTTP/2 栈有多层抽象
- **内存管理**：brpc 内置对象池和内存池，减少 malloc 开销

**第四层：gRPC 线程模型**

gRPC 服务端默认使用线程池模型，分为两类线程：
- **I/O 线程**：处理 HTTP/2 协议解析、帧收发（ServerBuilder 自动管理）
- **工作线程**：执行用户定义的 RPC 方法（通过 SetSyncServerOption 配置数量，默认仅 1 个——生产环境必须调整）

**第五层：生态与社区**

| 维度 | gRPC | brpc |
|------|------|------|
| 维护方 | Google + CNCF | 百度 |
| 语言支持 | 10+ 语言 | 主要 C++（Java/Go 有限） |
| 云原生集成 | Istio/Envoy/K8s 原生支持 | 需自行集成 |
| 文档质量 | 英文为主，完善 | 中文为主，完善 |

## 三、动手实践（代码案例）

```c++
// gRPC 服务示例
service UserService {
    rpc GetUser(UserRequest) returns (UserResponse);
}

// brpc 服务示例
class UserServiceImpl : public UserService {
public:
    void GetUser(google::protobuf::RpcController* cntl,
                 const UserRequest* request,
                 UserResponse* response,
                 google::protobuf::Closure* done) override {
        brpc::ClosureGuard done_guard(done);
        response->set_name("Alice");
    }
};

// brpc 服务器启动（支持多协议）
int main() {
    brpc::Server server;
    UserServiceImpl service;
    
    server.AddService(&service, brpc::SERVER_DOESNT_OWN_SERVICE);
    
    brpc::ServerOptions options;
    // 同一端口支持 HTTP + Protobuf
    options.idle_timeout_sec = 60;
    server.Start(50051, &options);
    server.RunUntilAskedToQuit();
}
```

## 四、进阶应用（≥500字）

### 选型决策框架

| 决策因素 | 权重 | gRPC 得分 | brpc 得分 |
|---------|------|----------|----------|
| 跨语言需求 | 高 | ★★★★★ | ★★☆☆☆ |
| 极致性能 | 中 | ★★★☆☆ | ★★★★★ |
| 云原生集成 | 高 | ★★★★★ | ★★☆☆☆ |
| 多协议接入 | 中 | ★★☆☆☆ | ★★★★★ |
| 团队 C++ 能力强 | 中 | ★★★★☆ | ★★★★★ |
| 社区活跃度 | 高 | ★★★★★ | ★★★☆☆ |

### 腾讯 tRPC 简介

腾讯开源的 tRPC 是多语言、高性能 RPC 框架，吸取了 gRPC 和 brpc 的优点：
- 支持 C++、Go、Java、Python 等多语言
- 插件化架构（协议插件、序列化插件、名字服务插件）
- 内置服务治理（限流、熔断、负载均衡）
- 腾讯内部大规模实践验证

参考：<https://cloud.tencent.com/developer/article/2351926>

### 混合使用策略

大型项目中可以混合使用：
- **对外 API**：gRPC（跨语言、标准化、生态工具完善）
- **核心服务间通信**：brpc（高性能、低延迟）
- **统一网关**：通过 API Gateway 对外暴露 gRPC/REST，内部转 brpc

### 与其他主题的关联

- **服务发现**：gRPC 通过 Resolver 插件，brpc 通过 NamingService 插件
- **负载均衡**：gRPC 内置 pick_first/round_robin/grpclb，brpc 更丰富
- **监控**：gRPC 集成 OpenCensus/OpenTelemetry，brpc 内置 bvar 指标系统

## 五、源码解析和实践感悟（≥1000字）

### brpc 的 bthread 深入

bthread 是 brpc 性能优势的核心：
- **M:N 调度**：M 个 bthread 运行在 N 个 pthread 上（类似 Go 的 goroutine）
- **协作式调度**：bthread 在 I/O 等待时主动让出（yield），而非被动抢占
- **上下文切换**：用户态切换比内核态快 10 倍以上
- **栈管理**：bthread 使用小栈（默认 1MB），按需增长

### gRPC 同步 vs 异步模式

**同步模式**：
- 每个请求绑定一个工作线程，在方法返回前线程被独占
- RPC 方法内可直接使用同步 API，编程简单
- 适合请求处理时间短、并发量可控的场景

**异步模式**：
- 通过 CompletionQueue 管理异步操作
- 线程不会被单个请求阻塞，适合高并发长时处理
- 编程复杂度高，需要理解 CompletionQueue 的事件驱动模型

### gRPC 的拦截器链

gRPC 的拦截器是高度可扩展的中间件机制：
```c++
// 客户端拦截器
class LoggingInterceptor : public experimental::Interceptor {
    void Intercept(experimental::InterceptorBatchMethods* methods) {
        if (methods->QueryInterceptionHookPoint(
                experimental::InterceptionHookPoints::PRE_SEND_MESSAGE)) {
            std::cout << "Sending RPC..." << std::endl;
        }
        methods->Proceed();  // 传递给下一个拦截器或实际调用
    }
};
```

### 经验总结

1. **不要神话性能数据**：brpc 的百万 QPS 是在特定场景下的结果，实际业务中差距没这么大
2. **生态比性能更重要**：gRPC 的拦截器、健康检查、反射、grpc-gateway 等工具链大幅降低开发成本
3. **团队能力是关键**：如果团队以 C++ 为主且有性能极致需求，brpc 更合适；多语言团队选 gRPC
4. **实际选择往往不是非此即彼**：API Gateway 对外 gRPC + 内部 brpc 是常见的混合方案

## 六、面试准备（高频问法≥10个，反问点/一句话答案≥5个，均带回答）

### 6.1 高频问法（≥10个）

Q1：gRPC 和 brpc 如何选择？

A：跨语言需求 → gRPC；纯 C++ 极致性能 → brpc；云原生生态 → gRPC；多协议接入 → brpc。核心：看团队栈和主要矛盾。

Q2：brpc 的 bthread 和 Go 的 goroutine 有什么异同？

A：都是 M:N 用户态调度。bthread 是协作式（I/O 时 yield），goroutine 是抢占式（GC 时抢占）。创建开销都极小（~100ns）。区别：goroutine 栈可动态增长且可移动，bthread 栈固定。

Q3：为什么 gRPC 选择 HTTP/2 作为传输协议？

A：1）标准化（HTTP/2 广泛部署）2）多路复用（单连接承载多 RPC）3）头部压缩（HPACK）4）流优先级 5）双向流式支持 6）可穿透防火墙和代理。

Q4：brpc 如何实现单端口多协议？

A：通过协议嗅探——读取连接的前几个字节，根据协议特征（HTTP: "GET"/"POST"，Redis: "*数字"，Protobuf: 特定魔数）自动识别并分发到对应的协议处理器。

Q5：gRPC 和 REST 如何共存？

A：通过 grpc-gateway 自动生成 RESTful JSON API（gRPC 服务的 HTTP 代理）。同一个 .proto 文件同时生成 gRPC 和 REST 接口。也支持 gRPC-Web 在浏览器中使用。

Q6：brpc 内置了哪些服务治理能力？

A：限流（bvar 计数器）、熔断（Circuit Breaker）、负载均衡（多种策略）、健康检查、并发控制（最大并发度）、自适应限流。

Q7：如何迁移现有服务从 gRPC 到 brpc（或反之）？

A：1）都用 Protobuf 定义接口，迁移成本主要在服务端实现。2）通过网关层做协议转换，逐步迁移。3）客户端支持双协议（gRPC Channel + brpc Channel），灰度切换。

Q8：tRPC 相比 gRPC 和 brpc 有什么优势？

A：腾讯内部大规模实践验证；插件化架构更灵活；多语言支持比 brpc 好；内置服务治理比 gRPC 丰富。适合从腾讯生态出发的项目。

Q9：gRPC 的流式传输有什么典型应用？

A：1）大文件分块传输 2）实时数据推送（股票行情）3）长时间运行任务的状态推送 4）双向对话（语音助手）。

Q10：如何评估一个 RPC 框架的性能？

A：核心指标：QPS（吞吐）、P99/P999 延迟、CPU 使用率、内存占用。测试场景：不同 payload 大小（1B/1KB/1MB）、不同并发数、长连接 vs 短连接。

Q11：gRPC 的 Channel 和 Stub 分别是什么？

A：Channel 是客户端到服务端的 HTTP/2 连接抽象，管理连接池和负载均衡。Stub 是客户端代理类，封装远程方法调用（由 .proto 自动生成）。

Q12：gRPC ServerBuilder 配置哪些关键参数？

A：监听地址端口、认证凭据（Insecure/Ssl）、线程池大小（MIN_POLLERS/MAX_POLLERS）、注册的 Service 列表、拦截器（Interceptor）。

Q13：gRPC 的同步和异步模式如何选择？

A：同步模式编程简单，适合短请求低并发。异步模式通过 CompletionQueue 非阻塞处理，适合高并发长请求。核心判断：请求处理时间是否可能阻塞工作线程。

Q14：CompletionQueue 的工作原理？

A：异步操作完成后将事件标签（tag）推入 CompletionQueue。应用通过 Next() 或 AsyncNext() 等待并取出完成事件，根据 tag 分发处理。

Q15：gRPC 服务端启动的核心步骤？

A：1）定义 .proto 2）protoc 生成代码 3）实现 Service 类 4）ServerBuilder 配置 5）BuildAndStart() 6）server->Wait() 阻塞。

### 6.2 反问点/陷阱点（≥5个）

- 贵公司在 RPC 框架选型时，最看重的三个指标是什么？是什么决定了最终的选择？
- 如果贵团队使用 brpc，是否遇到过 bthread 栈溢出或调度延迟的问题？如何监控和排查？

- 陷阱 1："brpc 的百万 QPS 意味着比 gRPC 快 10 倍"——性能数据高度依赖测试场景，实际业务中差异小得多
- 陷阱 2："gRPC 跨语言调用零成本"——不同语言的序列化/反序列化性能差异可能很大
- 陷阱 3："选了一个 RPC 框架就不能换"——通过 API Gateway 做协议转换，可逐步迁移

### 6.3 一句话答案（≥5个）

- 选型第一原则：跨语言选 gRPC，极致性能选 brpc，腾讯生态选 tRPC。
- brpc 性能秘诀：bthread 用户态线程 + 零拷贝 + 多协议嗅探 + 对象池。
- gRPC 生态优势：拦截器 + 健康检查 + grpc-gateway + OpenTelemetry + CNCF 支持。
- bthread vs goroutine：都是 M:N 调度，bthread 协作式，goroutine 抢占式。
- 当被问到"RPC 框架选型"时回答："看团队栈（C++ vs 多语言）、看性能需求（极致 vs 够用）、看生态需求（云原生 vs 独立部署）。"

## 附录（模板外原内容收纳）

> 以下为原笔记中的完整对比和断线重连内容，原样保留于此。

### 原笔记：brpc 与 gRPC 对比分析

**brpc**
- 开发方：百度开源
- 目标：高性能、低延迟的 C++ RPC 框架
- 协议支持：HTTP、Redis、RTMP 等
- 语言支持：C++ 为主

**gRPC**
- 开发方：Google 开源
- 目标：跨语言、标准化的 RPC 框架
- 协议支持：HTTP/2 + Protocol Buffers
- 语言支持：C++、Java、Python、Go 等

**性能对比**

| 指标 | brpc | gRPC |
|------|------|------|
| 单机 QPS | 100万+（C++ 优化场景） | 10万~50万（依赖语言实现） |
| 延迟 | 微秒级 | 毫秒级 |
| 资源占用 | 内存占用低 | 较高 |

**典型应用场景**
- brpc：高性能 C++ 服务（搜索、广告系统）、混合协议接入（HTTP + Redis）
- gRPC：跨语言微服务（Java + Go + Python）、云原生应用（Kubernetes + Istio）

### 原笔记：gRPC 服务端核心组件

| 组件 | 功能描述 |
|------|---------|
| Channel | 客户端与服务端的连接抽象，管理 HTTP/2 连接池和负载均衡策略 |
| Stub | 客户端生成的代理类，封装远程方法调用（同步/异步） |
| Service | 服务端实现的具体业务逻辑类，继承自 .proto 生成的基类 |
| ServerBuilder | 服务端构建器，用于配置监听端口、线程池、拦截器等 |
| CompletionQueue | 异步操作队列，用于非阻塞处理请求（仅限异步模式） |

### 原笔记：gRPC 同步 vs 异步模式

同步模式：每个请求绑定一个工作线程，在方法返回前线程被独占。RPC 方法内可直接使用同步API，编程简单。适合请求处理时间短、并发量可控的场景。

异步模式：通过 CompletionQueue 管理异步操作。线程不会被单个请求阻塞，适合高并发长时处理。编程复杂度高，需要理解 CompletionQueue 的事件驱动模型。

### 原笔记：gRPC 线程模型

gRPC 服务端默认使用线程池模型，分为两类线程：I/O线程（处理HTTP/2协议解析、帧收发，ServerBuilder 自动管理）和工作线程（执行用户定义的RPC方法，通过 SetSyncServerOption 配置数量，默认只有1个工作线程——生产环境必须配置）。

### 原笔记：gRPC 断线重连

gRPC 客户端在检测到连接断开后，会按照配置的重连策略进行重连尝试：
- 检测断开：客户端检测到与服务器的连接断开
- 初始重连：按照配置的初始重连间隔时间进行第一次重连尝试
- 指数退避：如果第一次重连失败，按照指数退避策略增加重连间隔时间
- 最大重连次数：如果重连次数达到配置的最大重连次数，停止重连
- 成功重连：如果在重连过程中成功建立连接，重连机制结束

注意事项：
- 合理配置重连间隔时间和指数退避策略，避免服务器压力增加
- 配置适当的最大重连次数，避免无限重连循环
- 在实现重连机制时，建议添加详细的日志和监控

### 原笔记：参考链接

- 腾讯开源 tRPC：<https://cloud.tencent.com/developer/article/2351926>
