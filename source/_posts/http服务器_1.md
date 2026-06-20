---
title: http服务器
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "网络编程", "boost-asio  网络编程"]
publish: true
---

## HTTP包头信息

一个标准的HTTP报文头通常由请求头和响应头两部分组成。

### HTTP 请求头

HTTP请求头包括以下字段：

- **Request-line**：包含用于描述请求类型、要访问的资源以及所使用的HTTP版本的信息。

- **Host**：指定被请求资源的主机名或IP地址和端口号。

- **Accept**：指定客户端能够接收的媒体类型列表，用逗号分隔，例如 text/plain, text/html。

- **User-Agent**：客户端使用的浏览器类型和版本号，供服务器统计用户代理信息。

- **Cookie**：如果请求中包含cookie信息，则通过这个字段将cookie信息发送给Web服务器。

- **Connection**：表示是否需要持久连接（keep-alive）。

比如下面就是一个实际应用

```apl
GET /index.html HTTP/1.1
Host: www.example.com
Accept: text/html, application/xhtml+xml, */*
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:123.0) Gecko/20100101 Firefox/123.0
Cookie: sessionid=abcdefg1234567
Connection: keep-alive
```

上述请求头包括了以下字段：

- **Request-line**：指定使用GET方法请求/index.html资源，并使用HTTP/1.1协议版本。

- **Host**：指定被请求资源所在主机名或IP地址和端口号。

- **Accept**：客户端期望接收的媒体类型列表，本例中指定了text/html、application/xhtml+xml和任意类型的文件（*/*）。

- **User-Agent**：客户端浏览器类型和版本号。

- **Cookie**：客户端发送给服务器的cookie信息。

- **Connection**：客户端请求后是否需要保持长连接

### HTTP 响应头

HTTP响应头包括以下字段：

- **Status-line**：包含协议版本、状态码和状态消息。

- **Content-Type**：响应体的MIME类型。

- **Content-Length**：响应体的字节数。

- **Set-Cookie**：服务器向客户端发送cookie信息时使用该字段。

- **Server**：服务器类型和版本号。

- **Connection**：表示是否需要保持长连接（keep-alive）。

在实际的HTTP报文头中，还可以包含其他可选字段。
如下是一个http响应头的示例

```apl
HTTP/1.1 200 OK
Content-Type: text/html; charset=UTF-8
Content-Length: 1024
Set-Cookie: sessionid=abcdefg1234567; HttpOnly; Path=/
Server: Apache/2.2.32 (Unix) mod_ssl/2.2.32 OpenSSL/1.0.1e-fips mod_bwlimited/1.4
Connection: keep-alive
```

上述响应头包括了以下字段：

- **Status-line**：指定HTTP协议版本、状态码和状态消息。

- **Content-Type**：指定响应体的MIME类型及字符编码格式。

- **Content-Length**：指定响应体的字节数。

- **Set-Cookie**：服务器向客户端发送cookie信息时使用该字段。

- **Server**：服务器类型和版本号。

- **Connection**：服务器是否需要保持长连接。

## beast搭建服务器

### 头文件和作用域重命名

``` c++
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/version.hpp>
#include <boost/asio.hpp>
#include <ctime>
#include <cstdlib>
#include <memory>
#include <string>
#include <json/json.h>
#include <json/value.h>
#include <json/reader.h>
#include <iostream>
 
// 因为beast、http、net是作用域，所以可以直接用namespace重命名
// 但是tcp是一个类，所以只能通过using重命名
namespace beast = boost::beast;
namespace http = beast::http;
namespace net = boost::asio;
using tcp = boost::asio::ip::tcp;
```

###  reponse时调用的一些函数

``` 
namespace my_program_state {
    std::size_t request_count() { // 统计请求的次数
        static std::size_t count = 0;
        return count++;
    }
 
    std::time_t now() { // 当前的时间
        return std::time(0);
    }
}
```



###  http_connection

``` c++
class http_connection : public std::enable_shared_from_this<http_connection> {
private:
    tcp::socket _socket;
    beast::flat_buffer _buffer{ 8192 }; // 缓存区_buffer
    http::request<http::dynamic_body> _request;// 请求头
    http::response<http::dynamic_body> _response; // 回应
    net::steady_timer _deadline{ // 定时器
        _socket.get_executor(),
        std::chrono::seconds(60)
    };
 
        void read_request() {
        auto self = shared_from_this(); // 伪闭包
        http::async_read(_socket, _buffer, _request,
            [self](beast::error_code ec, std::size_t bytes_transferred) {
                boost::ignore_unused(bytes_transferred); // 没用到bytes_transferred参数，编译器会警告，这里直接忽略掉
                if (!ec) {
                    self->process_request();
                }
            });
    }
 
     void check_deadline() {
        auto self = shared_from_this(); // 伪闭包
        _deadline.async_wait([self](boost::system::error_code ec) {
            if (!ec) {
                self->_socket.close(ec);
            }
            });
    }

 
       void process_request() {
        _response.version(_request.version());
        _response.keep_alive(false); // true是长连接,false是短连接
        switch (_request.method()) {
        case http::verb::get:
            _response.result(http::status::ok);
            _response.set(http::field::server, "Beast");
            create_response();
            break;
        case http::verb::post:
            _response.result(http::status::ok);
            _response.set(http::field::server, "Beast");
            create_post_response();
            break;
        default:
            _response.result(http::status::bad_request);
            _response.set(http::field::content_type, "text/plain");
            beast::ostream(_response.body()) << "Invalid request-method"
                << std::string(_request.method_string()) << "'";
            break;
        }
 
        write_response();
    }
 
        void create_response() {
        if (_request.target() == "/count") {
            _response.set(http::field::content_type, "text/html");
            beast::ostream(_response.body())
                << "<html>\n"
                << "<head><title>Request count</title></head>\n"
                << "<body>\n"
                << "<h1>Request count</h1>\n"
                << "<p>There have been "
                << my_program_state::request_count()
                << " requests so far.</p>\n"
                << "</body>\n"
                << "</html>\n";
        }
        else if (_request.target() == "/time") {
            _response.set(http::field::content_type, "text/html");
            beast::ostream(_response.body())
                << "<html>\n"
                << "<head><title>Current time</title></head>\n"
                << "<body>\n"
                << "<h1>Current time</h1>\n"
                << "<p>The current time is "
                << my_program_state::now()
                << " seconds since the epoch.</p>\n"
                << "</body>\n"
                << "</html>\n";
        }
        else {
            _response.result(http::status::not_found);
            _response.set(http::field::content_type, "text/plain");
            beast::ostream(_response.body()) << "File not found\r\n";
        }
    }
 
        void write_response() {
        auto self = shared_from_this(); // 伪闭包
        _response.content_length(_response.body().size()); // 响应的长度
        http::async_write(_socket, _response, [self](beast::error_code ec, std::size_t) {
            // 只关闭服务器发送端，客户端收到服务器的响应后，也关闭客户端的发送端
            self->_socket.shutdown(tcp::socket::shutdown_send, ec);
            self->_deadline.cancel();
            });
    }
 
   void create_post_response() {
        if (_request.target() == "/email") {
            // 读取并打印收到的request
            auto& body = this->_request.body();
            auto body_str = boost::beast::buffers_to_string(body.data());
            std::cout << "receive body is " << body_str << std::endl;
            // 构造返回的response
            this->_response.set(http::field::content_type, "text/json");
            Json::Value root; // 发送的根
            Json::Reader reader;
            Json::Value src_root; // 原始的根
            // 解析数据
            bool parse_success = reader.parse(body_str, src_root);
            if (!parse_success) { // 解析失败
                std::cout << "Failed to parse JSON data!" << std::endl;
                root["error"] = 1001;
                std::string jsonstr = root.toStyledString();
                beast::ostream(this->_response.body()) << jsonstr; // 将数据写入body
                return;
            }
            // 解析成功
            auto email = src_root["email"].asString(); // 将收到的email转为string
            std::cout << "email is " << email << std::endl;
            root["error"] = 0;
            root["email"] = src_root["email"];
            root["msg"] = "recevie email post success";
            std::string jsonstr = root.toStyledString(); // 序列化root数据
            beast::ostream(this->_response.body()) << jsonstr; // 将数据写入body
        }
        else {
            _response.result(http::status::not_found);
            _response.set(http::field::content_type, "text/plain");
            beast::ostream(_response.body()) << "File not found\r\n";
        }
    }
 
public:
    http_connection(tcp::socket&& socket) : _socket(std::move(socket)) {}
 
    void start() {
        read_request(); // 读请求
        check_deadline(); // 判断超时
    }
 
};
```

### Server

为了方便，server直接写为一个函数，不封装为类

``` c++
void http_server(tcp::acceptor& acceptor, tcp::socket& socket) {
    acceptor.async_accept(socket, [&](boost::system::error_code ec) {
        if (!ec) {
            // 创建一个http_connection新实例，并调用start函数
            std::make_shared<http_connection>(std::move(socket))->start();
        }
 
        http_server(acceptor, socket);
        });
}
```

### main()

``` c++
int main()
{
    try {
        auto const address = net::ip::make_address("127.0.0.1");
        unsigned short port = static_cast<unsigned short>(8080);
        net::io_context ioc{ 1 };
        tcp::acceptor acceptor( ioc,{address,port} );
        tcp::socket socket(ioc);
        http_server(acceptor, socket);
        ioc.run();
 
    }
    catch (std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return EXIT_FAILURE;
    }
    return 0;
}
```

## 一、核心概念

- **定义**：HTTP 服务器基于请求-响应模型，解析 HTTP 报文头（请求行、Host、Content-Type 等），根据请求内容返回响应。Beast 是 Boost 的 HTTP/WebSocket 库，构建在 Asio 之上提供高层 HTTP 协议支持
- **关键词**：HTTP/1.1 报文格式、请求行/状态行、Beast、`http::request`/`http::response`、Content-Length、`http::async_read`/`async_write`
- **适用场景/边界**：REST API 服务器、静态文件服务、WebSocket 升级。Beast 适合需要底层控制的 HTTP 服务；高层框架（cpp-httplib）适合快速原型

## 二、详细解析（≥200字）

- **原理拆解（三层递进）**：
  - **第一层——HTTP 报文结构**：请求 = 请求行（`GET /index.html HTTP/1.1`）+ 头部字段（Host/Accept/User-Agent/Cookie）+ 空行 + 可选 Body。响应 = 状态行（`HTTP/1.1 200 OK`）+ 头部字段（Content-Type/Length/Server）+ 空行 + Body。Content-Length 标记 Body 长度，Transfer-Encoding: chunked 用于动态内容
  - **第二层——Beast 封装**：`http::request<http::string_body>` 解析请求，`http::response<http::string_body>` 构造响应。`http::async_read(socket, buffer, req, handler)` 异步读取完整 HTTP 请求（自动处理粘包/拆包），`http::async_write(socket, res, handler)` 发送响应
  - **第三层——请求处理流程**：`async_accept` → 创建 `tcp::socket` → `async_read` 等待完整 HTTP 请求 → 解析 `req.method()` / `req.target()` → 路由到 handler → 构造 `http::response` → `async_write` 返回 → 根据 `Connection: keep-alive` 决定是否关闭 socket
- **关键数据结构/接口**：`http::request<Body>` / `http::response<Body>`；`req.method()` GET/POST；`req.target()` URL 路径；`res.result(http::status::ok)` 设置状态码；`res.set(http::field::content_type, "text/html")` 设置头部
- **关键公式**：Content-Length = Body 字节数；`Connection: keep-alive` 保持连接复用减少握手开销；`Transfer-Encoding: chunked` → 长度 0 的块表示结束

## 三、动手实践（代码案例）

```c++
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/asio.hpp>
namespace beast = boost::beast;
namespace http = beast::http;
using tcp = boost::asio::ip::tcp;

int main() {
    boost::asio::io_context ioc;
    tcp::acceptor acceptor(ioc, tcp::endpoint(tcp::v4(), 8080));
    while (true) {
        tcp::socket socket(ioc);
        acceptor.accept(socket);
        beast::flat_buffer buf;
        http::request<http::string_body> req;
        http::read(socket, buf, req);

        http::response<http::string_body> res{http::status::ok, req.version()};
        res.set(http::field::content_type, "text/plain");
        res.body() = "Hello HTTP!";
        res.prepare_payload();
        http::write(socket, res);
    }
}
```
```bash
g++ -std=c++17 http.cpp -lboost_system -lpthread -o http && ./http
curl http://localhost:8080/  # → Hello HTTP!
```

## 四、进阶应用（≥500字）

### 异步 HTTP 服务器（Beast 经典模式）

```c++
void do_session(tcp::socket socket) {
    auto buf = std::make_shared<beast::flat_buffer>();
    auto req = std::make_shared<http::request<http::string_body>>();
    http::async_read(socket, *buf, *req,
        [&socket, buf, req](auto ec, auto) {
            http::response<http::string_body> res{http::status::ok, req->version()};
            res.set(http::field::server, "Beast");
            res.body() = "Async Hello";
            res.prepare_payload();
            http::async_write(socket, res, [](auto, auto){});
        });
}
```

### HTTP 方法路由

```c++
if (req.method() == http::verb::get && req.target() == "/api/users") {
    res.body() = get_users_json();
} else if (req.method() == http::verb::post && req.target() == "/api/user") {
    create_user(req.body());
    res.result(http::status::created);
} else {
    res.result(http::status::not_found);
}
```

### 自定义 Body 类型（大文件零拷贝）

```c++
http::response<http::file_body> res;
res.body() = beast::file_body::value_type();
beast::error_code ec;
res.body().open("large_file.bin", beast::file_mode::read, ec);
```

**工程经验**：(1) `prepare_payload()` 必须在 body 设置后调用，自动计算 Content-Length；(2) Beast 同步接口适合简单场景，异步接口适合高并发；(3) 生产环境务必设置超时——`beast::tcp_stream::expires_after()`。

## 五、源码解析和实践感悟

### 5.1 源码解析

#### Beast 的 HTTP 解析流水线

```c++
// http::async_read 内部流程简化
void async_read(socket& s, flat_buffer& buf, request& req, handler h) {
    // 1. 非阻塞读取原始字节到 flat_buffer
    s.async_read_some(buf.prepare(8192), [&](error_code ec, size_t n) {
        buf.commit(n);
        // 2. 用 http::parser 解析 HTTP 请求
        auto result = parser.parse(buf.data(), buf.size());
        if (result == need_more) {
            async_read(s, buf, req, h);  // 递归继续读
        } else {
            req = parser.release();  // 填充 request 对象
            h(ec, n);                // 触发用户回调
        }
    });
}
```

#### dynamic_body 的缓冲区管理

`http::request<http::dynamic_body>` 使用动态缓冲区存储请求体，本质是 `vector<char>` 的封装。`beast::ostream(body)` 返回一个写接口，支持 `<<` 流式写入。`buffers_to_string(body.data())` 将多段缓冲区合并为 `std::string`。

#### steady_timer 的超时机制

```c++
_deadline.async_wait([self](error_code ec) {
    if (!ec) self->_socket.close(ec);  // 60秒无活动 → 关闭连接
});
```
`steady_timer` 绑定到 `io_context` 的执行器上，底层用 `timerfd_create`（Linux）创建定时器 fd 并注册到 epoll，到期时 `io_context::run()` 触发回调。

### 5.2 实践经验

1. **flat_buffer 的预分配**：构造时指定 `8192` 字节可减少动态扩容次数
2. **长连接 vs 短连接**：`_response.keep_alive(false)` 设为短连接避免资源泄漏，但频繁连接建立有开销
3. **伪闭包模式**：`shared_from_this()` 保证回调执行时 `http_connection` 对象仍存活
4. **JSON 解析安全**：`reader.parse()` 返回 false 时必须处理，返回友好错误而非崩溃
5. **shutdown_send 关闭半连接**：`_socket.shutdown(shutdown_send)` 通知对端数据发送完毕，优雅关闭 TCP 连接
6. **deadline 定时器必须在回调中 cancel**：`write_response` 成功后 `_deadline.cancel()` 避免定时器在连接关闭后失效触发

## 六、面试准备

### 6.1 面试高频问答

**Q1：Beast 和 Asio 的关系？**

A：Beast 是基于 Asio 的 HTTP/WebSocket 协议库，提供 HTTP 消息解析和序列化。`http::async_read` 底层仍调用 `socket.async_read_some`。

**Q2：`dynamic_body` 和 `string_body` 的区别？**

A：`dynamic_body` 使用 `vector<char>` 动态管理（灵活但需手动转换），`string_body` 直接使用 `std::string`（方便但复制开销大）。

**Q3：为什么用 `shared_from_this()` 传回调？**

A：Asio 异步回调执行时，`http_connection` 可能已被销毁。`shared_from_this()` 延长对象生命周期直到回调执行完毕。

**Q4：`shutdown(shutdown_send)` 的作用？**

A：关闭写入方向（半关闭），通知客户端"服务器已发送完所有数据"。客户端收到 FIN 后仍可发送数据直到它也关闭。

**Q5：POST 请求中如何获取 JSON body？**

A：`auto body_str = beast::buffers_to_string(body.data())` 将 `dynamic_body` 转为 string，再用 JSON 库解析。body 可能是分段 buffers，不能用单指针访问。

**Q6：`http_server` 递归调用的风险？**

A：每次 `async_accept` 成功后递归调用注册下一次 accept，形成无限异步链。不是真递归（无栈溢出），每次连接创建新 `http_connection`。

**Q7：`make_shared` 为什么用 `std::move(socket)`？**

A：socket 不可拷贝，`std::move` 转移所有权给新创建的 `http_connection`。原 socket 变量可再次用于 `async_accept`。

**Q8：`acceptor` 绑定 `{address, port}` 的含义？**

A：创建监听套接字，绑定到指定 IP 和端口。`tcp::v4()` 表示 IPv4。Asio 自动调用 `bind()` + `listen()`。

### 6.2 陷阱与反问

**陷阱1**：递归 `http_server` 中 socket 已被 move，旧连接处理中不要再用原 socket
**陷阱2**：`_deadline` 定时器未在连接关闭时 cancel → 过期回调操作已关闭的 socket
**陷阱3**：JSON 解析失败只返回错误不记录日志 → 调试困难
**陷阱4**：POST 处理中直接 `_request.body().data()` 当单段缓冲访问 → body 可能是多段 buffers
**陷阱5**：`keep_alive(true)` 时没有超时机制 → 空闲连接永远占用资源

**反问**：为什么 Beast 选择用 `flat_buffer` 而非 `streambuf` 处理请求？
*答案：flat_buffer 提供单段连续缓冲区，解析器不需要处理分段数据，简化 HTTP 协议解析逻辑。*

### 6.3 一句话答案

1. **Beast**：基于 Asio 的 HTTP/WebSocket 库，提供协议级解析
2. **dynamic_body**：`vector<char>` 封装的动态请求体，通过 `ostream` 写入
3. **伪闭包**：`shared_from_this()` 传回调，延长对象生命周期
4. **shutdown_send**：关闭 TCP 写方向，优雅通知对端数据传输完成
5. **steady_timer**：基于 timerfd 的定时器，到期触发回调关闭超时连接
6. **buffers_to_string**：将多段 buffer 合并为 string，处理 `dynamic_body` 的必备工具