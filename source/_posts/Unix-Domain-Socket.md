---
title: Unix Domain Socket
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "网络编程"]
publish: true
---

# Unix Domain Socket

> 适用范围：Linux本地进程间通信(IPC)、Unix Domain Socket、UDS TCP/STREAM、与TCP/IP Socket对比

## 一、核心概念

- **定义**：Unix Domain Socket(UDS)是Linux系统用于本地进程间通信的Socket机制，通过文件系统路径（如`/tmp/server.sock`）通信，无需经过网络协议栈
- **关键词**：IPC、SOCK_STREAM、SOCK_DGRAM、抽象命名空间、sendmsg/recvmsg、SCM_RIGHTS
- **适用场景/边界**：
  - 同一主机上高性能进程间通信（数据库连接、守护进程通信、容器内通信）
  - 需要类似TCP的流式可靠通信但不经过网络栈的场景
  - 边界：不能跨主机通信（与TCP/IP Socket互补而非替代）

## 二、详细解析（≥200字）

### 2.1 什么是 UDS TCP？

UDS（Unix Domain Socket）是 Linux 系统中用于**本地进程间通信（IPC）的高效机制**，TCP 模式（`SOCK_STREAM`）提供**面向连接的可靠数据传输**，类似网络 TCP 但无需经过网络协议栈，直接通过文件系统路径（如 `/tmp/server.sock`）通信。

**核心优势**：

* **可靠性**：基于流式传输，保证数据顺序和完整性，支持流量控制和错误重传。
* **高效性**：无需网络层开销（如 IP 协议、校验和），性能优于传统网络 Socket。
* **适用场景**：需稳定传输的场景，如文件传输、长连接服务、复杂协议交互。

**Linux 使用 ss -lx 可以看到 Unix Domain Socket 有没有数据在读取 / 发送队列**

### 2.2 UNIX Domain Socket 与 TCP/IP Socket 对比

socket API原本是为网络通讯设计的，但后来在socket的框架上发展出一种IPC机制，就是UNIX Domain Socket。

TCP是使用TCP端口连接127.0.0.1:9000，Socket是使用unix domain socket连接[套接字](https://zhida.zhihu.com/search?content_id=220129651&content_type=Article&match_order=1&q=%E5%A5%97%E6%8E%A5%E5%AD%97&zhida_source=entity)/dev/shm/php-cgi.sock（很多教程使用路径/tmp，而路径/dev/shm是个[tmpfs](https://zhida.zhihu.com/search?content_id=220129651&content_type=Article&match_order=1&q=tmpfs&zhida_source=entity)，速度比磁盘快得多）

虽然网络socket也可用于同一台主机的进程间通讯（通过loopback地址127.0.0.1），但是UNIX Domain Socket用于IPC更有效率：不需要经过网络协议栈，不需要打包拆包、计算校验和、维护序号和应答等，只是将应用层数据从一个进程拷贝到另一个进程。

UNIX域套接字与TCP套接字相比较，在同一台主机的传输速度前者是后者的两倍。这是因为，IPC机制本质上是可靠的通讯，而网络协议是为不可靠的通讯设计的。

UNIX Domain Socket也提供面向流和面向数据包两种API接口，类似于TCP和UDP，但是面向消息的UNIX Domain Socket也是可靠的，消息既不会丢失也不会顺序错乱。

### 一、使用方法

Unix Domain Socket（后面统一简称 UDS） 使用起来和传统的 socket 非常的相似。区别点主要有两个地方需要关注。

```
fastcgi_pass unix:/dev/shm/fpm-cgi.sock;
```

如果 对于一个 UDS 的 server 来说，它的代码示例大概结构如下，大家简单了解一下。只是个示例不一定可运行。

```
int main()
{
    // 创建 unix domain socket
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);

    // 绑定监听
    char *socket_path = "./server.sock";
    strcpy(serun.sun_path, socket_path); 
    bind(fd, serun, ...);
    listen(fd, 128);

    while(1){
        //接收新连接
        conn = accept(fd, ...);

        //收发数据
        read(conn, ...);
        write(conn, ...);
    }
}
```

基于 UDS 的 client 也是和普通 socket 使用方式差不太多，创建一个 socket，然后 connect 即可。

```
int main(){
    sock = socket(AF_UNIX, SOCK_STREAM, 0);
    connect(sockfd, ...)
    }
```

### 二、连接过程

总的来说，基于 UDS 的连接过程比 inet 的 socket 连接过程要简单多了。客户端先创建一个自己用的 socket，然后调用 connect 来和服务器建立连接。

在 connect 的时候，会申请一个新 socket 给 server 端将来使用，和自己的 socket 建立好连接关系以后，就放到服务器正在监听的 socket 的接收队列中。这个时候，服务器端通过 accept 就能获取到和客户端配好对的新 socket 了。

总的 UDS 的连接建立流程如下图。

![](../../资源/图片/yuque_d0aa5af6fbe3.png)

内核源码中最重要的逻辑在 connect 函数中，我们来简单展开看一下。unix 协议族中定义了这类 socket 的所有方法，它位于 net/unix/af\_unix.c 中。

```
//file: net/unix/af_unix.c
static const struct proto_ops unix_stream_ops = {
    .family = PF_UNIX,
    .owner = THIS_MODULE,
    .bind =  unix_bind,
    .connect = unix_stream_connect,
    .socketpair = unix_socketpair,
    .listen = unix_listen,
    ...
    };
```

我们找到 connect 函数的具体实现，unix\_stream\_connect。

```
//file: net/unix/af_unix.c
static int unix_stream_connect(struct socket *sock, struct sockaddr *uaddr,
                               int addr_len, int flags)
{
    struct sockaddr_un *sunaddr = (struct sockaddr_un *)uaddr;

    ...

        // 1. 为服务器侧申请一个新的 socket 对象
        newsk = unix_create1(sock_net(sk), NULL);

    // 2. 申请一个 skb，并关联上 newsk
    skb = sock_wmalloc(newsk, 1, 0, GFP_KERNEL);
    ...

        // 3. 建立两个 sock 对象之间的连接
        unix_peer(newsk) = sk;
    newsk->sk_state  = TCP_ESTABLISHED;
    newsk->sk_type  = sk->sk_type;
    ...
        sk->sk_state = TCP_ESTABLISHED;
    unix_peer(sk) = newsk;

    // 4. 把连接中的一头（新 socket）放到服务器接收队列中
    __skb_queue_tail(&other->sk_receive_queue, skb);
}
```

主要的连接操作都是在这个函数中完成的。和我们平常所见的 TCP 连接建立过程，这个连接过程简直是太简单了。没有三次握手，也没有全连接队列、半连接队列，更没有啥超时重传。

直接就是将两个 socket 结构体中的指针互相指向对方就行了。就是 unix\_peer(newsk) = sk 和 unix\_peer(sk) = newsk 这两句。

```
//file: net/unix/af_unix.c
#define unix_peer(sk) (unix_sk(sk)->peer)
```

当关联关系建立好之后，通过 \_\_skb\_queue\_tail 将 skb 放到服务器的接收队列中。注意这里的 skb 里保存着新 socket 的指针，因为服务进程通过 accept 取出这个 skb 的时候，就能获取到和客户进程中 socket 建立好连接关系的另一个 socket。

怎么样，UDS 的连接建立过程是不是很简单！？

### 三、发送过程

看完了连接建立过程，我们再来看看基于 UDS 的数据的收发。这个收发过程一样也是非常的简单。发送方是直接将数据写到接收方的接收队列里的。

![](../../资源/图片/yuque_d376f62e331a.png)

我们从 send 函数来看起。send 系统调用的源码位于文件 net/socket.c 中。在这个系统调用里，内部其实真正使用的是 sendto 系统调用。它只干了两件简单的事情：

第一是在内核中把真正的 socket 找出来，在这个对象里记录着各种协议栈的函数地址。

第二是构造一个 struct msghdr 对象，把用户传入的数据，比如 buffer地址、数据长度啥的，统统都装进去. 剩下的事情就交给下一层，协议栈里的函数 inet\_sendmsg 了，其中 inet\_sendmsg 函数的地址是通过 socket 内核对象里的 ops 成员找到的。大致流程如图。

![](../../资源/图片/yuque_a567ec7c2a5f.png)

在进入到协议栈 inet\_sendmsg 以后，内核接着会找到 socket 上的具体协议发送函数。对于 Unix Domain Socket 来说，那就是 unix\_stream\_sendmsg。我们来看一下这个函数

```
/file:
static int unix_stream_sendmsg(struct kiocb *kiocb, struct socket *sock,
                               struct msghdr *msg, size_t len)
{
    // 1.申请一块缓存区
    skb = sock_alloc_send_skb(sk, size, msg->msg_flags&MSG_DONTWAIT,
                           &err);

    // 2.拷贝用户数据到内核缓存区
    err = memcpy_fromiovec(skb_put(skb, size), msg->msg_iov, size);

    // 3. 查找socket peer
    struct sock *other = NULL;
    other = unix_peer(sk);

    // 4.直接把 skb放到对端的接收队列中
    skb_queue_tail(&other->sk_receive_queue, skb);

    // 5.发送完毕回调
    other->sk_data_ready(other, size);
}
```

和复杂的 TCP 发送接收过程相比，这里的发送逻辑简单简单到令人发指。申请一块内存（skb），把数据拷贝进去。根据 socket 对象找到另一端，直接把 skb 给放到对端的接收队列里了，接收函数主题是 unix\_stream\_recvmsg，这个函数中只需要访问它自己的接收队列就行了，源码就不展示了。所以在本机网络 IO 场景里，基于 Unix Domain Socket 的服务性能上肯定要好一些的。

### 四、性能对比

为了验证 Unix Domain Socket 到底比基于 127.0.0.1 的性能好多少，我做了一个性能测试。在网络性能对比测试，最重要的两个指标是延迟和吞吐。我从 Github 上找了个好用的测试源码：https://github.com/rigtorp/ipc-bench。我的测试环境是一台 4 核 CPU，8G 内存的 KVM 虚机。

在延迟指标上，对比结果如下图。

![](../../资源/图片/yuque_b43da513cb3e.png)

可见在小包（100 字节）的情况下，UDS 方法的“网络” IO 平均延迟只有 2707 纳秒，而基于 TCP（访问 127.0.0.1）的方式下延迟高达 5690 纳秒。耗时整整是前者的两倍。

在包体达到 100 KB 以后，UDS 方法延迟 24 微秒左右（1 微秒等于 1000 纳秒），TCP 是 32 微秒，仍然高一截。这里低于 2 倍的关系了，是因为当包足够大的时候，网络协议栈上的开销就显得没那么明显了。

再来看看吞吐效果对比。

![](../../资源/图片/yuque_14e28eecf325.png)

在小包的情况下，带宽指标可以达到 854 M，而基于 TCP 的 IO 方式下只有 386 M。数据就解读到这里。

### 五、总结

本文分析了基于 Unix Domain Socket 的连接创建、以及数据收发过程。其中数据收发的工作过程如下图。

![](../../资源/图片/yuque_831cffa03e04.png)

相对比本机网络 IO 通信过程上，它的工作过程要清爽许多。其中 127.0.0.1 工作过程如下图。

![](../../资源/图片/yuque_4c5d81188c8a.png)

我们也对比了 UDP 和 TCP 两种方式下的延迟和性能指标。在包体不大于 1KB 的时候，UDS 的性能大约是 TCP 的两倍多。所以，在本机网络 IO 的场景下，如果对性能敏感，飞哥建议你使用 Unix Domain Socket。

我们最多看到Unix domain socket的地方可能就是docker了，作为一种[容器技术](https://zhida.zhihu.com/search?content_id=197877330&content_type=Article&match_order=1&q=%E5%AE%B9%E5%99%A8%E6%8A%80%E6%9C%AF&zhida_source=entity)，docker需要和实体机进行快速的数据传输和信息交换，一般情况下UDS的文件是以.socket结尾的，我们可以在/var/run目录下面使用下面的命令来查找：

```
find . -name "*.sock"
```

如果你有docker在运行的话，可以得到下面的结果：

```
./docker.sock
./docker/libnetwork/6d66a24bfbbfa231a668da4f1ed543844a0514e4db3a1f7d8001a04a817b91fb.sock
./docker/libcontainerd/docker-containerd.sock
```

可以看到docker是通过上面的3个sock文件来进行通讯的。

## 使用socat来创建Unix Domain Sockets

之前提到了socat这个万能的工具，不仅可以创建tcp的监听服务器，还能创建udp的监听服务器，当然对于UDS来说也不在话下。我们来看下使用socat来创建UDS服务器所需要用到的参数：

```
unix-listen:<filename>    groups=FD,SOCKET,NAMED,LISTEN,CHILD,RETRY,UNIX
unix-recvfrom:<filename>  groups=FD,SOCKET,NAMED,CHILD,RETRY,UNIX
```

这里我们要使用到unix-listen和unix-recvfrom这两个参数，unix-listen表示的是创建stream-based UDS服务，而unix-recvfrom表示的是创建datagram-based UDS。

可以看到两个参数后面都需要传入一个文件名，表示UDS socket的地址。

我们可以这样使用：

```
socat unix-listen:/tmp/stream.sock,fork /dev/null&
socat unix-recvfrom:/tmp/datagram.sock,fork /dev/null&
```

这里我们使用/tmp/datagram.sock来表示这个socket信息。

其中fork参数表示程序在接收到[程序包](https://zhida.zhihu.com/search?content_id=197877330&content_type=Article&match_order=1&q=%E7%A8%8B%E5%BA%8F%E5%8C%85&zhida_source=entity)之后继续运行，如果不用fork，那么程序会自动退出。

socat后面本来要接一个bi-address，这里我们使用/dev/null，表示丢弃掉所有的income信息。

运行后我们可能得到下面的结果：

```
[1] 27442
[2] 27450
```

表示程序已经成功执行了，返回的是程序的pid。

## 使用ss命令来查看Unix domain Socket

在使用ss命令之前，我们先来看下使用socat生成的两个文件：

```
srwxrwxr-x   1 flydean flydean    0 Mar  2 21:58 stream.sock
srwxrwxr-x   1 flydean flydean    0 Mar  2 21:59 datagram.sock
```

可以看到这两个文件的权限，rwx大家都懂，分别是read，write和执行权限。那么最前面的s是什么呢？

最前面的一位表示的是文件类型，s表示的就是socket文件。

扩展一下，这个位置还可以有其他几种选项：p、d、l、s、c、b和-:

其中p表示[命名管道文件](https://zhida.zhihu.com/search?content_id=197877330&content_type=Article&match_order=1&q=%E5%91%BD%E5%90%8D%E7%AE%A1%E9%81%93%E6%96%87%E4%BB%B6&zhida_source=entity)，d表示目录文件，l表示符号连接文件，-表示普通文件，s表示socket文件，c表示字符设备文件，b表示[块设备](https://zhida.zhihu.com/search?content_id=197877330&content_type=Article&match_order=1&q=%E5%9D%97%E8%AE%BE%E5%A4%87&zhida_source=entity)文件。

接下来我们使用ss命令来查看一下之前建立的UDS服务。

这里需要使用到下面几个参数：

```
-n, --numeric       don't resolve service names
   -l, --listening     display listening sockets
   -x, --unix          display only Unix domain sockets
```

这里我们需要使用到上面3个选项，x表示的是显示UDS，因为是监听，所以使用-l参数，最后我们希望看到具体的数字，而不是被解析成了服务名，所以这里使用-n参数。

我们可以尝试执行一下下面的命令：

```
ss -xln
```

输出会很多，我们可以grep我们需要的socket如下所示：

```
ss -xln | grep tmp
u_str  LISTEN     0      5      /tmp/stream.sock 11881005              * 0                  
u_dgr  UNCONN     0      0      /tmp/datagram.sock 11882190              * 0
```

u\_str表示的是UDS stream socket，而u\_dg表示的是UDS datagram socket。

我们可以使用stat命令来查看socket文件的具体信息：

```
stat /tmp/stream.sock /tmp/datagram.sock
  File: ‘/tmp/stream.sock’
  Size: 0               Blocks: 0          IO Block: 4096   socket
Device: fd02h/64770d    Inode: 134386049   Links: 1
Access: (0775/srwxrwxr-x)  Uid: ( 1002/    flydean)   Gid: ( 1002/    flydean)
Access: 2022-03-01 22:33:21.533000000 +0800
Modify: 2022-03-01 22:33:21.533000000 +0800
Change: 2022-03-01 22:33:21.533000000 +0800
 Birth: -
  File: ‘/tmp/datagram.sock’
  Size: 0               Blocks: 0          IO Block: 4096   socket
Device: fd02h/64770d    Inode: 134386050   Links: 1
Access: (0775/srwxrwxr-x)  Uid: ( 1002/    flydean)   Gid: ( 1002/    flydean)
Access: 2022-03-01 22:33:22.306000000 +0800
Modify: 2022-03-01 22:33:22.306000000 +0800
Change: 2022-03-01 22:33:22.306000000 +0800
 Birth: -
```

## 使用nc连接到Unix domain Socket服务

nc是一个非常强大的工具，除了可以进行TCP，UDP连接之外，还可以进行UDS的连接，我们需要使用到下面的参数：

```
-U, --unixsock             Use Unix domain sockets only
  -u, --udp                  Use UDP instead of default TCP
  -z                         Zero-I/O mode, report connection status only
```

-U表示连接的是一个unixsocket。-u表示是一个UDP连接。

默认情况下nc使用的是TCP连接，所以不需要额外的参数。

另外我们直接建立连接，并不发送任何数据，所以这里使用-z参数。

先连接Stream UDS看看：

```
nc -U -z /tmp/stream.sock
```

如果没有输出任何异常数据，说明连接成功了。

然后再连接Datagram UDS看看：

```
nc -uU -z /tmp/datagram.sock
```

同样的，如果没有任何异常数据，说明Socket连接成功了

## 四、进阶应用（≥500字）

### 4.1 Docker 与 UDS

Docker daemon 通过 `/var/run/docker.sock` 提供 UDS 接口供 CLI 客户端通信：

```bash
# 查看 Docker 使用的 UDS 文件
find /var/run -name "*.sock" 2>/dev/null
# 输出示例：
# /var/run/docker.sock
# /var/run/docker/libnetwork/xxx.sock
# /var/run/docker/libcontainerd/docker-containerd.sock
```

Docker 选择 UDS 而非 TCP localhost 的原因：性能优势（2倍延迟优势）+ 基于文件权限的访问控制（`chmod 660 /var/run/docker.sock`）无需额外认证。

### 4.2 Nginx + PHP-FPM 通过 UDS 通信

生产环境推荐配置：

```nginx
# Nginx 配置
location ~ \.php$ {
    fastcgi_pass unix:/dev/shm/php-fpm.sock;  # 使用 tmpfs 路径，速度更快
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    include fastcgi_params;
}
```

`/dev/shm` 是 tmpfs（内存文件系统），比 `/tmp` 磁盘路径快数倍，避免磁盘 I/O 瓶颈。

### 4.3 systemd Socket Activation

systemd 支持在服务启动前创建 UDS 监听 socket，按需激活服务：

```ini
# /etc/systemd/system/myapp.socket
[Socket]
ListenStream=/run/myapp.sock

[Install]
WantedBy=sockets.target
```

服务空闲时不占资源，首连接到达时 systemd 唤醒服务进程并传递已就绪的 socket fd。

### 4.4 D-Bus 与抽象命名空间

D-Bus（桌面/系统 IPC 总线）大量使用 UDS。**抽象命名空间 socket** 通过在 `sun_path[0] = '\0'` 创建：

```c++
struct sockaddr_un addr;
addr.sun_family = AF_UNIX;
addr.sun_path[0] = '\0';           // 抽象命名空间
strcpy(addr.sun_path + 1, "myapp"); // 名称不创建文件
bind(fd, (struct sockaddr*)&addr, sizeof(addr));
```

优势：不依赖文件系统路径、不担心残留文件、无需文件系统权限。

### 4.5 辅助数据：SCM_RIGHTS 传递文件描述符

UDS 的独特能力——通过 `sendmsg`/`recvmsg` 在进程间传递 fd：

```c++
// 发送方：传递 fd
struct msghdr msg = {0};
struct cmsghdr *cmsg;
char buf[CMSG_SPACE(sizeof(int))];
msg.msg_control = buf;
msg.msg_controllen = sizeof(buf);
cmsg = CMSG_FIRSTHDR(&msg);
cmsg->cmsg_level = SOL_SOCKET;
cmsg->cmsg_type = SCM_RIGHTS;
cmsg->cmsg_len = CMSG_LEN(sizeof(int));
*(int*)CMSG_DATA(cmsg) = fd_to_send;  // 要传递的 fd
sendmsg(sockfd, &msg, 0);

// 接收方：接收 fd
recvmsg(sockfd, &msg, 0);
cmsg = CMSG_FIRSTHDR(&msg);
int received_fd = *(int*)CMSG_DATA(cmsg);
```

应用场景：systemd 通过 SCM_RIGHTS 将 socket fd 传递给服务进程，进程间共享已打开的连接。

### 4.6 UDS 与其他主题的关联

| 关联主题 | 关联点 |
|---------|--------|
| select/poll/epoll | UDS 的 fd 同样可被 I/O 多路复用监控 |
| TCP | UDS SOCK_STREAM 提供类 TCP 的可靠流式通信 |
| Docker/容器 | Docker daemon 通信、容器内服务间 IPC |
| systemd | Socket Activation 基于 UDS 实现按需服务激活 |

## 五、源码解析和实践感悟（≥1000字）

### 5.1 Unix Domain Socket 连接建立源码深入

`unix_stream_connect` 是整个连接建立的核心，位于 `net/unix/af_unix.c`：

```c
// net/unix/af_unix.c
static int unix_stream_connect(struct socket *sock, struct sockaddr *uaddr,
                               int addr_len, int flags)
{
    struct sockaddr_un *sunaddr = (struct sockaddr_un *)uaddr;
    struct sock *sk = sock->sk;
    struct sock *newsk, *other;
    struct sk_buff *skb;

    // 查找目标 socket（通过文件路径或抽象名）
    other = unix_find_other(net, sunaddr, addr_len, sock->type, &err);
    if (!other) return -ECONNREFUSED;

    // 1. 为服务器侧创建新的 socket 对象
    newsk = unix_create1(sock_net(sk), NULL);
    
    // 2. 分配 skb，关联 newsk
    skb = sock_wmalloc(newsk, 1, 0, GFP_KERNEL);
    UNIXCB(skb).fp = NULL;
    
    // 3. 建立双向 peer 指针（关键！）
    unix_peer(newsk) = sk;        // 新 socket 指向客户端
    newsk->sk_state = TCP_ESTABLISHED;
    sk->sk_state = TCP_ESTABLISHED;
    unix_peer(sk) = newsk;        // 客户端指向新 socket
    
    // 4. 将关联 newsk 的 skb 放入监听 socket 接收队列
    //    服务端 accept() 时从此队列取出
    __skb_queue_tail(&other->sk_receive_queue, skb);
    other->sk_data_ready(other);  // 唤醒阻塞在 accept 的服务端
    
    return 0;
}
```

关键设计：**没有三次握手**——直接将两个 `struct sock` 通过 `unix_peer()` 互相指向即完成"连接"。`unix_peer` 是一个简单的指针访问宏：

```c
#define unix_peer(sk) (unix_sk(sk)->peer)
```

### 5.2 数据发送与接收源码路径

**发送路径** `unix_stream_sendmsg`：

```c
static int unix_stream_sendmsg(struct kiocb *kiocb, struct socket *sock,
                               struct msghdr *msg, size_t len)
{
    struct sock *sk = sock->sk, *other;
    struct sk_buff *skb;
    
    // 1. 查找对端 socket
    other = unix_peer(sk);
    if (!other) return -ECONNRESET;
    
    // 2. 分配 skb 并拷贝用户数据
    skb = sock_alloc_send_skb(sk, len, msg->msg_flags & MSG_DONTWAIT, &err);
    err = memcpy_fromiovec(skb_put(skb, len), msg->msg_iov, len);
    
    // 3. 直接将 skb 放到对端接收队列（零拷贝！）
    skb_queue_tail(&other->sk_receive_queue, skb);
    
    // 4. 通知对端数据就绪
    other->sk_data_ready(other, len);
    return len;
}
```

**接收路径** 只需从自己的 `sk_receive_queue` 取数据：

```c
static int unix_stream_recvmsg(struct kiocb *kiocb, struct socket *sock,
                               struct msghdr *msg, size_t size, int flags)
{
    struct sock *sk = sock->sk;
    struct sk_buff *skb;
    
    // 从接收队列获取 skb
    skb = skb_dequeue(&sk->sk_receive_queue);
    if (!skb) {
        if (flags & MSG_DONTWAIT) return -EAGAIN;
        // 阻塞等待
        sk_wait_data(sk, &timeo, NULL);
        continue;
    }
    // 拷贝数据到用户空间
    err = memcpy_toiovec(msg->msg_iov, skb->data, chunk);
    skb_free_datagram(sk, skb);
    return chunk;
}
```

### 5.3 SCM_RIGHTS 传递 fd 的内核机制

`SCM_RIGHTS` 的工作原理是利用 `skb` 的共享信息结构 `scm_cookie`（而非直接拷贝文件描述符的整数编号）：

```c
// net/core/scm.c 简化
int __scm_send(struct socket *sock, struct msghdr *msg, struct scm_cookie *p)
{
    struct cmsghdr *cmsg;
    for (cmsg = CMSG_FIRSTHDR(msg); cmsg; cmsg = CMSG_NXTHDR(msg, cmsg)) {
        if (cmsg->cmsg_type == SCM_RIGHTS) {
            int *fds = (int *)CMSG_DATA(cmsg);
            int num = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
            for (int i = 0; i < num; i++) {
                struct file *fp = fget(fds[i]);  // 增加引用计数
                scm_fp_dup(p->fp + i);
            }
        }
    }
    // scm_cookie 附着在 skb->scm 上传递
}
```

关键：fd 传递的是 `struct file*` 指针（引用计数递增），而非整数 fd 编号。接收方随后通过 `scm_recv` 获取并分配新的 fd 编号。

### 5.4 UDS vs TCP localhost 内存拷贝对比

| 步骤 | UDS | TCP localhost |
|------|-----|--------------|
| 用户数据→内核 | 1 次拷贝 | 1 次拷贝 |
| 内核协议栈 | 直接入对端队列 | TCP分段→IP路由→链路层→回环设备 |
| 内核→对端用户 | 1 次拷贝 | 1 次拷贝 |
| 总拷贝次数 | 2 次 | 2 次 |
| CPU 开销 | 极小（只做数据搬运） | 大（校验和、分段、路由、ACK） |

UDS 的延迟优势来源于跳过的 CPU 计算开销（校验和、分段、路由查找、拥塞控制），而非减少数据拷贝次数。

### 5.5 实践感悟与易错点

1. **路径残留问题**：UDS server 退出后路径文件不会自动删除，再次 `bind` 返回 `EADDRINUSE`。正确做法：启动时 `unlink()` 旧路径文件，或在 `main()` 注册 `atexit` 清理。

2. **`/dev/shm` vs `/tmp`**：`/dev/shm` 是 tmpfs（纯内存），比 `/tmp` 磁盘快但重启后丢失。对性能敏感的 UDS（如 PHP-FPM），建议使用 `/dev/shm`。

3. **SOCK_DGRAM 的发送缓冲区满**：UDS DGRAM 模式下，对端接收缓冲区满时 `sendto` 静默丢弃——不同于 UDP 的网络丢包也不给错误提示。需应用层自行保证接收速率。

4. **Docker 的 docker.sock 安全风险**：挂载 `/var/run/docker.sock` 到容器内等于赋予 root 权限。生产环境建议使用 Docker API proxy 或 TLS 认证。

5. **`ss -xln` 快速诊断**：`ss -xln` 列出所有 UDS 监听状态，`Recv-Q` 非零说明对端发送了数据但服务端未 accept。结合 `ss -xp` 查看进程关联。

## 六、面试准备

### 6.1 面试高频问答

**Q1：Unix Domain Socket 和 TCP Socket 的核心区别？**

A：UDS 用于同一主机进程间通信（IPC），走内核内存不经过网卡，延迟极低。TCP Socket 用于网络通信，经过完整协议栈。UDS 用文件路径代替 IP+Port 寻址。

**Q2：UDS 的 SOCK_STREAM 和 SOCK_DGRAM 各适用什么场景？**

A：SOCK_STREAM 面向连接，可靠有序，适合 RPC/数据库通信。SOCK_DGRAM 无连接，保留消息边界但不保证可靠性，适合低延迟日志转发。

**Q3：UDS 为什么不经过网卡？**

A：数据在 `sock_sendmsg` → 对端 `sock_recvmsg` 之间通过内核缓冲区直接传递，不调用 `dev_queue_xmit`，跳过网络层和链路层。

**Q4：UDS 的路径文件是什么？**

A：bind 时创建的 socket 文件（如 `/tmp/app.sock`），仅作为命名入口，不存储数据。连接关闭后需手动删除路径文件。

**Q5：UDS 和管道 (pipe) 的区别？**

A：UDS 支持双向通信 + 多客户端连接，管道只能单向；UDS 支持 SOCK_DGRAM 消息边界，管道是纯字节流。

### 6.2 陷阱与反问

**陷阱1**：忘记 unlink 残留路径文件 → bind 失败（Address already in use）
**陷阱2**：UDS 的 SO_SNDBUF 设置仍有效，小缓冲区限制吞吐
**陷阱3**：SOCK_DGRAM UDS 的 sendto 在接收缓冲区满时静默丢弃

**反问**：UDS 比 TCP localhost 快多少？
*答案：UDS 延迟约为 TCP localhost 的 1/3 ~ 1/2，因为跳过 TCP/IP 协议栈的大部分处理（校验和、分段、路由等），吞吐量通常高出 2-3 倍。*

### 6.3 一句话答案

1. **UDS**：同一主机进程间通信，走内核内存不经过网卡
2. **路径文件**：bind 创建的命名入口，需手动清理
3. **SOCK_STREAM**：面向连接可靠有序，类似 TCP
4. **SOCK_DGRAM**：无连接保留边界，类似 UDP 但可靠
5. **优势**：低延迟，高吞吐，零网络协议栈开销
