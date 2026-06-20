---
title: Actor_CSP设计模式
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "并发编程"]
publish: true
---

# Actor/CSP设计模式

> 放弃共享内存+锁的传统并发模型，转向消息传递：Actor 以实体为中心，CSP 以 Channel 为中心。消除数据竞争，降低耦合。

## 一、核心概念

**补充**

- 定义：Actor 和 CSP 都是基于消息传递的并发模型，线程/进程之间不共享内存，仅通过消息通信，从根本上消除数据竞争和死锁。
- 关键词：Actor 模型、CSP（通信顺序进程）、Channel（通道）、消息传递、邮箱（mailbox）、无共享状态、Go 协程
- 适用场景：高并发后端服务（Erlang/Elixir）、分布式系统（Akka）、Go 语言的 goroutine+channel 编程
- 核心区别：Actor 关注"谁收发"（发送者知道接收者地址），CSP 关注"通过什么通道"（收发双方互不感知）

## 二、详细解析

**简介：**

在并发编程中，多个线程可能需要**同时访问相同的内存资源**。为了防止不同线程之间的资源冲突，传统并发设计方法通常使用共享内存和加锁机制来确保线程安全。例如，当一个线程在修改共享数据时，其他线程会被"锁住"，无法同时访问该数据。但是传统并发设计方法在**频繁加锁**的情况下会带来性能开销，**降低系统的执行效率**；并且共享内存加锁方式要求线程之间对共享**数据有很强的依赖关系**，**这种依赖增加了代码的复杂性和耦合度**，使代码难以维护。

* **Actor模式**：Actor模式通过消息传递的方式来实现线程间通信。每个Actor都有自己的状态和行为，它们通过发送消息来完成交互，而不需要共享内存。这种方式避免了加锁的复杂性和性能损耗。
* **CSP（Communicating Sequential Processes）模式**：CSP模式也是通过消息传递进行通信，但它强调线程（或进程）之间的严格隔离。各个线程通过通道（Channel）来传递消息，而不直接共享状态，避免了竞争条件和加锁问题。

### Actor设计模式

**Actor模型的设计模式有以下几个核心要素：**

1. **独立的Actor：**每个Actor是**独立的个体**，拥有自己的状态和行为。Actor之间不共享状态，从而消除了并发编程中的数据共享问题。
2. **异步消息传递**：Actor之间不直接调用方法，而是通过消息传递来通信。消息传递是**异步非阻塞的**，发送方不需要等待接收方完成处理，而是立即继续执行自己的任务，避免了阻塞等待带来的性能问题。
3. **顺序消息处理：**每个Actor都有一个"邮箱"或"消息队列"，它接收来自其他Actor的消息，并按照顺序缓存起来。Actor处理消息时会从邮箱中取出一条消息并执行相应的操作，**并且每个Actor一次只同步能处理一个消息**（处理过程中，除了可以接受消息外，不能左任何其他无关操作），保证了消息处理的原子性。Actor在处理消息时不会被其他消息打断，也不会与其他Actor竞争资源，从而减少了并发问题。
4. **无共享状态**：由于Actor之间不共享数据，只能通过消息传递来交互，因此大大降低了并发编程中的数据竞争和死锁等复杂性。
5. **单线程**：每个Actor在独立的线程中运行，Actor之间通过消息队列来通信。例如，Actor1向Actor2发送消息时，消息会投递至Actor2的队列中，Actor2从队列中取出消息并进行处理。这种设计就像邮件通信一样，一个Actor向另一个Actor"投递"一条消息，接收的Actor从"邮箱"中取出消息进行处理。

![](../../资源/图片/yuque_5ac49a8b6a04.png)

因为Actor之间不共享数据，只能通过消息传递来交互，因此大大降低了并发编程中的数据竞争和死锁等复杂性。我们需要维护的只有每个Actor接受消息的消息队列，只有**保证是线程安全的消息队列即可**。

### CSP设计模式

**CSP**（Communicating Sequential Processes，**通信顺序进程**）由英国计算机科学家 Tony Hoare 在1978年提出，用于描述两个独立的并发实体通过共享的通讯 `channel`(管道)进行通信的并发模型。

CSP（通信顺序进程）**模式将`channel`视为一等公民（第一类对象），其主要关注点在于通信的通道，而非发送或接收消息的实体。与Actor模型关注"谁在发送或接收消息"不同，CSP更侧重于"通过什么渠道传递消息"，即强调通信本身而非通信双方的具体实现

在CSP中，channel被用作不同进程之间的通信媒介。进程通过channel发送和接收消息来进行同步和数据传递，channel承担了中介的角色。与Actor模型中由每个Actor维护自己的邮箱不同，CSP模型允许进程通过共享的channel进行直接通信**CSP将消息投递给channel，至于谁从channel中取数据，谁从channel中发数据，发送的一方和接收的一方是不关注的**）SP模型不关心消息从哪来或到哪去，只关心消息是通过哪个channel传递的。这种设计实现了进程的解耦，并且允许进程通过**共享channel**来实现安全的**同步通信**

简单来说，Actor在发送消息前必须知道接收方是谁，而接受方收到消息后也需知道发送方是谁，更像是邮件的通信模式。而csp是完全解耦合的，不关心消息从哪来或到哪去，只关心消息是通过哪个channel传递的。

## 三、动手实践（代码案例）

### C++ 风格的 CSP

C++是万能的，我们可以用C++实现一个类似于go的channel，采用csp模式解耦合，实现类似的生产者和消费者问题

```cpp
#include <iostream>
#include <queue>
#include <mutex>
#include <condition_variable>

template <typename T>
class Channel {
private:
std::queue<T> queue_;
std::mutex mtx_;
std::condition_variable cv_producer_;
std::condition_variable cv_consumer_;
size_t capacity_;
bool closed_ = false;

public:
Channel(size_t capacity = 0) : capacity_(capacity) {}

bool send(T value) {
    std::unique_lock<std::mutex> lock(mtx_);
    cv_producer_.wait(lock, [this]() {
        // 对于无缓冲的channel，我们应该等待直到有消费者准备好
        return (capacity_ == 0 && queue_.empty()) || queue_.size() < capacity_ || closed_;
    });

    if (closed_) {
        return false;
    }

    queue_.push(value);
    cv_consumer_.notify_one();
    return true;
}

bool receive(T& value) {
    std::unique_lock<std::mutex> lock(mtx_);
    cv_consumer_.wait(lock, [this]() { return !queue_.empty() || closed_; });

    if (closed_ && queue_.empty()) {
        return false;
    }

    value = queue_.front();
    queue_.pop();
    cv_producer_.notify_one();
    return true;
}

void close() {
    std::unique_lock<std::mutex> lock(mtx_);
    closed_ = true;
    cv_producer_.notify_all();
    cv_consumer_.notify_all();
}
};

// 示例使用
int main() {
    Channel<int> ch(10);  // 10缓冲的channel

    std::thread producer([&]() {
        for (int i = 0; i < 5; ++i) {
            ch.send(i);
            std::cout << "Sent: " << i << std::endl;
        }
        ch.close();
    });

    std::thread consumer([&]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(500)); // 故意延迟消费者开始消费
        int val;
        while (ch.receive(val)) {
            std::cout << "Received: " << val << std::endl;
        }
    });

    producer.join();
    consumer.join();
    return 0;
}
```

简单来说就是通过条件变量实现通信的阻塞和同步的。

### 利用CSP思想实现取款逻辑

《C++并发编程实战》一书中提及了用csp思想实现atm机取款逻辑，我根据书中思想，整理了通信的示意图，书中部分代码存在问题，也一并修复了。

![](../../资源/图片/yuque_f323df2959a0.png)

主函数实现

```cpp
// Actor.cpp : 此文件包含 "main" 函数。程序执行将在此处开始并结束。
//

#include <iostream>
#include "message.h"
#include "withdraw_msg.h"
#include "atm.h"
#include "dispatcher.h"
#include "bank_matchine.h"
#include "interface_matchine.h"

int main()
{
    bank_machine bank;
    interface_machine interface_hardware;
    atm machine(bank.get_sender(), interface_hardware.get_sender());
    std::thread bank_thread(&bank_machine::run, &bank);
    std::thread if_thread(&interface_machine::run, &interface_hardware);
    std::thread atm_thread(&atm::run, &machine);
    messaging::sender atmqueue(machine.get_sender());
    bool quit_pressed = false;
    while (!quit_pressed)
        {
            char c = getchar();
            switch (c)
                {
                    case '0':
                    case '1':
                    case '2':
                    case '3':
                    case '4':
                    case '5':
                    case '6':
                    case '7':
                    case '8':
                    case '9':
                        atmqueue.send(digit_pressed(c));
                        break;
                    case 'b':
                        atmqueue.send(balance_pressed());
                        break;
                    case 'w':
                        atmqueue.send(withdraw_pressed(50));
                        break;
                    case 'c':
                        atmqueue.send(cancel_pressed());
                        break;
                    case 'q':
                        quit_pressed = true;
                        break;
                    case 'i':
                        atmqueue.send(card_inserted("acc1234"));
                        break;
                }
        }
    bank.done();
    machine.done();
    interface_hardware.done();
    atm_thread.join();
    bank_thread.join();
    if_thread.join();
}
```

主函数中启动了三个线程，分别处理bank，machine以及interface的操作。由于代码复杂解析来只列举atm类的实现

```cpp
#pragma once
#include "dispatcher.h"
#include <functional>
#include <iostream>
class atm
{
messaging::receiver incoming;
messaging::sender bank;
messaging::sender interface_hardware;
void (atm::* state)();
std::string account;
unsigned withdrawal_amount;
std::string pin;

void process_withdrawal()
{
    incoming.wait().handle<withdraw_ok, std::function<void(withdraw_ok const& msg)>,
        messaging::dispatcher >(
        [&](withdraw_ok const& msg)
        {
            interface_hardware.send(
                issue_money(withdrawal_amount));
            bank.send(
                withdrawal_processed(account, withdrawal_amount));
            state = &atm::done_processing;
        }, "withdraw_ok").handle<withdraw_denied, std::function<void(withdraw_denied const& msg)>>(
        [&](withdraw_denied const& msg)
        {
            interface_hardware.send(display_insufficient_funds());
            state = &atm::done_processing;
        }, "withdraw_denied").handle<cancel_pressed, std::function<void(cancel_pressed const& msg)>>(
        [&](cancel_pressed const& msg)
        {
            bank.send(
                cancel_withdrawal(account, withdrawal_amount));
            interface_hardware.send(
                display_withdrawal_cancelled());
            state = &atm::done_processing;
        }, "cancel_pressed"
        );
}
void process_balance()
{
    incoming.wait()
        .handle<balance, std::function<void(balance const& msg)>,
        messaging::dispatcher>(
        [&](balance const& msg)
        {
            interface_hardware.send(display_balance(msg.amount));
            state = &atm::wait_for_action;
        },"balance"
        ).handle < cancel_pressed, std::function<void(cancel_pressed const& msg) >>(
        [&](cancel_pressed const& msg)
        {
            state = &atm::done_processing;
        }, "cancel_pressed"
        );
}
void wait_for_action()
{
    interface_hardware.send(display_withdrawal_options());
    incoming.wait()
        .handle<withdraw_pressed, std::function<void(withdraw_pressed const& msg)>,
        messaging::dispatcher>(
        [&](withdraw_pressed const& msg)
        {
            withdrawal_amount = msg.amount;
            bank.send(withdraw(account, msg.amount, incoming));
            state = &atm::process_withdrawal;
        }, "withdraw_pressed"
        ).handle < balance_pressed, std::function<void(balance_pressed const& msg) >>(
        [&](balance_pressed const& msg)
                    {
                        bank.send(get_balance(account, incoming));
                        state = &atm::process_balance;
                    }, "balance_pressed"
                    ).handle<cancel_pressed, std::function<void(cancel_pressed const& msg) >>(
                        [&](cancel_pressed const& msg)
                        {
                            state = &atm::done_processing;
                        }, "cancel_pressed"
                    );
    }
    void verifying_pin()
    {
        incoming.wait()
            .handle<pin_verified, std::function<void(pin_verified const& msg)>,
            messaging::dispatcher>(
                [&](pin_verified const& msg)
                {
                    state = &atm::wait_for_action;
                }, "pin_verified"
                ).handle<pin_incorrect, std::function<void(pin_incorrect const& msg)>>(
                [&](pin_incorrect const& msg)
                {
                    interface_hardware.send(
                        display_pin_incorrect_message());
                    state = &atm::done_processing;
                }, "pin_incorrect"
                ).handle<cancel_pressed, std::function<void(cancel_pressed const& msg)>>(
                        [&](cancel_pressed const& msg)
                        {
                            state = &atm::done_processing;
                        }, "cancel_pressed"
                );
    }
    void getting_pin()
    {
        incoming.wait().handle<digit_pressed, std::function<void(digit_pressed const& msg)>,
            messaging::dispatcher>(
                [&](digit_pressed const& msg)
                {
                    unsigned const pin_length = 6;
                    pin += msg.digit;
                    if (pin.length() == pin_length)
                    {
                        bank.send(verify_pin(account, pin, incoming));
                        state = &atm::verifying_pin;
                    }
                }, "digit_pressed"
                ).handle<clear_last_pressed, std::function<void(clear_last_pressed const& msg)>>(
                [&](clear_last_pressed const& msg)
                {
                    if (!pin.empty())
                    {
                        pin.pop_back();
                    }
                }, "clear_last_pressed"
                ).handle<cancel_pressed, std::function<void(cancel_pressed const& msg)>>(
                        [&](cancel_pressed const& msg)
                        {
                            state = &atm::done_processing;
                        }, "cancel_pressed"
                );
    }

    void waiting_for_card()
    {
        interface_hardware.send(display_enter_card());
        incoming.wait().handle<card_inserted, std::function<void(card_inserted const& msg)>,
            messaging::dispatcher>(
                [&](card_inserted const& msg)
                {
                    account = msg.account;
                    pin = "";
                    interface_hardware.send(display_enter_pin());
                    state = &atm::getting_pin;
                }, "card_inserted"
        );
    }
    void done_processing()
    {
        interface_hardware.send(eject_card());
        state = &atm::waiting_for_card;
    }
    atm(atm const&) = delete;
    atm& operator=(atm const&) = delete;
public:
    atm(messaging::sender bank_,
        messaging::sender interface_hardware_) :
        bank(bank_), interface_hardware(interface_hardware_)
    {}
    void done()
    {
        get_sender().send(messaging::close_queue());
    }
    void run()
    {
        state = &atm::waiting_for_card;
        try
        {
            for (;;)
            {
                (this->*state)();
            }
        }
        catch (messaging::close_queue const&)
        {
        }
    }
    messaging::sender get_sender()
    {
        return incoming;
    }
};
```

atm 主要功能就是通过状态机不断地切换状态监听想要处理的函数。

## 四、进阶应用（≥500字）

**补充**

- **Actor 模型的工业级实现**：Erlang/OTP 是 Actor 模型的鼻祖级实现，每个进程（Actor）约 300 字节开销，一台机器可运行百万级 Actor。Akka（Scala/Java）将其引入 JVM 生态，增加了监督树、位置透明性、持久化等企业特性。C++ 生态中 CAF（C++ Actor Framework）提供了类似能力
- **Go 语言的 goroutine + channel 是 CSP 的标杆实现**：goroutine 是轻量级协程（2KB 栈起），channel 支持有缓冲/无缓冲、select 多路复用。Go 的设计哲学是"不要通过共享内存来通信，而要通过通信来共享内存"——这正是 CSP 的核心思想在工程实践中的最成功推广
- **C++ 中 Actor/CSP 的折中方案**：C++ 没有语言级支持，但可以通过 `std::queue` + `std::mutex` + `std::condition_variable` 手动实现。上面的 Channel 模板类就是 CSP 模式的最小可行实现。更完整的方案可以用 `boost::lockfree::queue` 做无锁 mailbox
- **ATM 示例中的 dispatcher 模式**：`messaging::dispatcher` 通过模板+类型匹配实现了消息的路由分发——每个状态函数等待特定的消息类型并绑定对应的处理 lambda。这本质是一个 compile-time visitor 模式，将消息类型到处理函数的映射在编译期确定，运行时零开销
- **状态机 + 消息驱动的威力**：atm 类的 `run()` 函数用成员函数指针 `state` 实现了状态机——`waiting_for_card` → `getting_pin` → `verifying_pin` → `wait_for_action` → `process_withdrawal/process_balance` → `done_processing`。每个状态函数调用 `incoming.wait().handle<MsgType>(handler)` 等待特定消息——消息不匹配时自动跳过，匹配时执行 handler 并切换状态
- **Actor vs CSP 的选择指南**：需要状态隔离和容错（监督）选 Actor；需要流式数据处理和组件解耦选 CSP。实际项目中两者可以混合——用 Actor 做服务边界，Actor 内部用 CSP channel 做流水线处理

### 关联主题

- [锁](锁.md) — 传统共享内存+锁 vs 消息传递
- [交换队列](交换队列.txt) — mailbox 的高效 swap 技巧
- [条件变量](条件变量.md) — Channel 的底层同步机制

## 五、源码解析和实践感悟（≥1000字）

**补充** — 深入剖析 Channel 模板类的实现细节和设计权衡：

### Channel 的核心设计

```cpp
template <typename T>
class Channel {
    std::queue<T> queue_;
    std::mutex mtx_;
    std::condition_variable cv_producer_;  // 生产者等待"队列有空位"
    std::condition_variable cv_consumer_;  // 消费者等待"队列有数据"
    size_t capacity_;  // 0 表示无缓冲（同步 channel）
    bool closed_;      // 关闭标志
};
```

设计要点：

1. **双条件变量设计**：为什么用两个条件变量而不是一个？因为生产者和消费者等待的是不同条件——生产者等"队列有空位"（`queue_.size() < capacity_`），消费者等"队列有数据"（`!queue_.empty()`）。一个条件变量不能满足两种等待方向。这是生产者-消费者问题的标准解法
2. **无缓冲 channel（capacity_ = 0）的特殊处理**：`send()` 的 wait 谓词中多了一个条件 `(capacity_ == 0 && queue_.empty())`——无缓冲时，发必须等有人收。这等价于 Go 的 `make(chan int)`（无缓冲channel），send/receive 是同步的
3. **closed_ 标志的语义**：一旦 close()，所有阻塞的生产者和消费者都被唤醒（`notify_all()`）。生产者检查 `closed_` 返回 false（发送失败），消费者在队列空且 closed 时返回 false（receive 结束信号）。这个设计让消费者可以优雅地遍历 channel 直到 close——等价于 Go 的 `for v := range ch {}`
4. **mutex 的粒度**：`send()` 和 `receive()` 都持有 `mtx_` 整个函数体——对 `queue_` 的操作、条件判断、notify 都在锁保护下，保证状态一致性

### ATM 状态机的消息分发机制

atm 类的核心是 `run()` 循环：

```cpp
void run() {
    state = &atm::waiting_for_card;
    try {
        for (;;) {
            (this->*state)();  // 调用当前状态的成员函数
        }
    }
    catch (messaging::close_queue const&) {
        // 收到关闭信号，退出循环
    }
}
```

每个状态函数调用 `incoming.wait().handle<MsgType1>(handler1).handle<MsgType2>(handler2)...` 的形式等待并匹配消息。`wait()` 阻塞直到有消息到达，`handle<>()` 通过模板匹配消息类型——如果消息类型不匹配当前 handle，消息保留在队列中，继续尝试下一个 handle。

这种设计相当于在 C++ 中模拟了模式匹配（pattern matching）——每个状态只关心自己感兴趣的消息，不匹配的消息会被后续状态处理。这和 Erlang 的 `receive` 模式或 Akka 的 `become()` 机制异曲同工。

### 成员函数指针的状态机

```cpp
void (atm::* state)();  // 指向成员函数的指针
// 状态切换：
state = &atm::waiting_for_card;
state = &atm::getting_pin;
state = &atm::process_withdrawal;
```

用成员函数指针做状态机是 C++ 中的经典技巧——每个状态是类的一个成员函数，状态切换就是改变指针目标。比 enum+switch 更灵活：状态处理逻辑封装在独立函数中，状态切换只需要一个赋值。每次循环 `(this->*state)()` 调用当前状态的处理函数，该函数内部会阻塞等待匹配的消息，处理完后切换到下一状态。

### 难点与易错点

1. **无缓冲 channel 的死锁陷阱**：`capacity_ = 0` 时 send 必须等 receive，如果先启动消费者等 receive 再启动生产者发 send 没问题；但如果生产者和消费者在同一个线程中交替 send/receive，就会死锁——因为 send 等 receive，receive 又可能在 send 之后
2. **close() 后资源泄漏风险**：close 调用 `notify_all()` 唤醒所有等待线程，但如果某个线程在 close 之后才调用 send/receive，它会检查 `closed_` 标志并及时返回。但如果 `queue_` 中还有未消费的数据，消费者可以继续 receive 直到队列空后再收到 false
3. **Channel 的线程安全边界**：`send()` 和 `receive()` 各自持有 `mtx_`，但如果有多个生产者（或消费者），每个线程独立调用 send/receive，互斥量自动保证线程安全——这是 CSP 中 channel 的优势：不必在外围加锁
4. **ATM 示例中消息类型的运行时开销**：`handle<>()` 通过模板生成代码，每种消息类型产生一个 dispatch 分支。消息类型数量 * 状态数量决定了代码膨胀程度。对于类型多的场景可用虚函数或 `std::variant` 替代模板

### 经验总结

- **消息传递模型的最大价值不是性能，而是正确性**：消除了数据竞争的根源（共享状态），并发 bug 从"需要全程警惕"变成"只需要保证消息队列线程安全"
- **C++ 实现 CSP 的核心挑战是类型安全的消息分发**：Go 的 channel 有语言级类型检查，C++ 需要用模板 + 类型擦除（`std::any`/`std::variant` 或自定义 dispatcher）来实现
- **Channel 模式可以天然支持背压（backpressure）**：有界 channel（capacity_ > 0）时，队列满后 send 阻塞——生产者自动减速，避免了无界队列的内存爆炸
- **ATM 示例展示了 CSP 在 GUI/事件驱动场景的适配性**：用户按键 → 构造消息 → 发送到 atm 邮箱 → atm 状态机处理 → 发送消息给 bank/interface。整条链路无锁、无回调地狱、状态变迁清晰可跟踪
- 实际项目中从锁到 Channel 的迁移策略：先识别模块边界，在模块间用 Channel 替代共享数据结构，模块内部可以继续用锁（或也用 Channel）

## 六、面试准备（高频问法≥10个，反问点/一句话答案≥5个，均带回答）

### 6.1 高频问法（≥10个）

基础理解：
- Q1：Actor 模型和 CSP 模式的核心区别是什么？ — Actor 以实体为中心（发送者知道接收者地址），消息投递到邮箱；CSP 以 Channel 为中心（收发双方不感知对方），消息通过通道流动
- Q2：消息传递模型相比共享内存+锁有什么优势？ — 消除数据竞争（无共享状态）、降低耦合（模块间仅通过消息交互）、天然支持分布式（消息序列化后可在网络传输）
- Q3：Actor 模型中的邮箱是什么？怎么保证线程安全？ — 每个 Actor 维护一个消息队列（邮箱），用 mutex + CV 或无锁队列实现。消息入队和出队是线程安全的，Actor 线程串行处理消息

原理深入：
- Q4：为什么 Actor 一次只处理一个消息？ — 保证状态变更的原子性——Actor 在处理消息期间不会被其他消息打断，无需内部加锁，简化状态管理
- Q5：CSP 中有缓冲 channel 和无缓冲 channel 的区别？ — 无缓冲（capacity=0）：send 必须等 receive，同步通信；有缓冲：send 在缓冲未满时立即返回，异步通信，缓冲满后阻塞
- Q6：Channel 的 close() 机制有什么用？ — 通知消费者"不再有数据"，消费者可以用 `for v := range ch`（Go）或 while(receive) 模式优雅遍历直到 close，避免消费者永久阻塞

实践应用：
- Q7：在 C++ 中如何实现类似 Go 的 channel？ — 用 `std::queue` + `std::mutex` + 两个 `std::condition_variable`（分别等空位和等数据），参考上面 Channel 模板类实现
- Q8：Actor 模型的监督（supervision）是什么？ — Erlang/OTP 的核心特性：父 Actor 监控子 Actor，子 Actor 崩溃时父 Actor 根据策略重启/停止/忽略。这是"Let it crash"哲学的工程基础
- Q9：消息传递模型的性能瓶颈在哪？ — 消息序列化/反序列化开销、消息队列的锁竞争（高吞吐时）、Actor 串行处理导致的延迟（一个慢消息阻塞后续消息）
- Q10：什么时候该用 Actor/CSP，什么时候该用传统锁？ — 模块边界清晰、需要容错和分布式扩展用 Actor/CSP；极低延迟、简单共享状态用锁；高性能计算场景用无锁数据结构

### 6.2 反问点/陷阱点（≥5个）

针对面试官的深度问题：
- "你们项目中用到了 Actor 或 CSP 模式吗？是用的哪些框架？"
- "在你们的场景下，消息传递带来的序列化开销和锁竞争相比，哪个是更大的瓶颈？"
- "如果一个 Actor 处理消息太慢导致邮箱堆积，你们怎么做流控？"

常见陷阱：
- 陷阱 1：认为 Actor 模型不需要锁 — Actor 内部不需要锁，但邮箱队列本身需要线程安全保护（mutex 或 lock-free queue）
- 陷阱 2：无缓冲 channel 使用不当导致死锁 — 同一协程/线程内 send 等 receive 形成循环等待
- 陷阱 3：消息类型爆炸 — 每种消息定义一个类/结构体，N 个 Actor 可能导致 M*N 种消息类型，需合理抽象

### 6.3 一句话答案（≥5个）

快速记忆要点：
- Actor 核心 = 独立实体 + 邮箱队列 + 异步消息 + 无共享状态
- CSP 核心 = 通过 Channel 通信 + 收发解耦 + 通道即一等公民
- Actor vs CSP 一句话 = Actor 像邮件（知道收件人），CSP 像水管（只管通道）
- 消息传递的本质优势 = 消灭数据竞争，简化并发推理
- Channel 的底层 = 队列 + 双条件变量（生产者等空位、消费者等数据）
- 选择指南 = 分布式容错选 Actor（Erlang/Akka），流式管道选 CSP（Go channel）
