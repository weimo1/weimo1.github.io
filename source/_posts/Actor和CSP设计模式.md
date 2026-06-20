---
title: Actor和CSP设计模式
date: 2026-06-20
categories:
  - ["项目学习", "设计模式"]
publish: true
---

# Actor/CSP设计模式

**简介：**

在并发编程中，多个线程可能需要**同时访问相同的内存资源**。为了防止不同线程之间的资源冲突，传统并发设计方法通常使用共享内存和加锁机制来确保线程安全。例如，当一个线程在修改共享数据时，其他线程会被"锁住"，无法同时访问该数据。但是传统并发设计方法在**频繁加锁**的情况下会带来性能开销，**降低系统的执行效率**；并且共享内存加锁方式要求线程之间对共享**数据有很强的依赖关系**，**这种依赖增加了代码的复杂性和耦合度**，使代码难以维护。

- **Actor模式**：Actor模式通过消息传递的方式来实现线程间通信。每个Actor都有自己的状态和行为，它们通过发送消息来完成交互，而不需要共享内存。这种方式避免了加锁的复杂性和性能损耗。
- **CSP（Communicating Sequential Processes）模式**：CSP模式也是通过消息传递进行通信，但它强调线程（或进程）之间的严格隔离。各个线程通过通道（Channel）来传递消息，而不直接共享状态，避免了竞争条件和加锁问题。

##  Actor设计模式

**Actor模型的设计模式有以下几个核心要素：**

1. **独立的Actor：**每个Actor是**独立的个体**，拥有自己的状态和行为。Actor之间不共享状态，从而消除了并发编程中的数据共享问题。
2. **异步消息传递**：Actor之间不直接调用方法，而是通过消息传递来通信。消息传递是**异步非阻塞的**，发送方不需要等待接收方完成处理，而是立即继续执行自己的任务，避免了阻塞等待带来的性能问题。
3. **顺序消息处理：**每个Actor都有一个"邮箱"或"消息队列"，它接收来自其他Actor的消息，并按照顺序缓存起来。Actor处理消息时会从邮箱中取出一条消息并执行相应的操作，**并且每个Actor一次只同步能处理一个消息**（处理过程中，除了可以接受消息外，不能左任何其他无关操作），保证了消息处理的原子性。Actor在处理消息时不会被其他消息打断，也不会与其他Actor竞争资源，从而减少了并发问题。
4. **无共享状态**：由于Actor之间不共享数据，只能通过消息传递来交互，因此大大降低了并发编程中的数据竞争和死锁等复杂性。
5. **单线程**：每个Actor在独立的线程中运行，Actor之间通过消息队列来通信。例如，Actor1向Actor2发送消息时，消息会投递至Actor2的队列中，Actor2从队列中取出消息并进行处理。这种设计就像邮件通信一样，一个Actor向另一个Actor"投递"一条消息，接收的Actor从"邮箱"中取出消息进行处理。

![在这里插入图片描述](https://i-blog.csdnimg.cn/direct/fa7eac5e156443f99e29fe921ecd4a72.png)

因为Actor之间不共享数据，只能通过消息传递来交互，因此大大降低了并发编程中的数据竞争和死锁等复杂性。我们需要维护的只有每个Actor接受消息的消息队列，只有**保证是线程安全的消息队列即可**。

## CSP设计模式

**CSP**（Communicating Sequential Processes，**通信顺序进程**）由英国计算机科学家 Tony Hoare 在1978年提出，用于描述两个独立的并发实体通过共享的通讯 `channel`(管道)进行通信的并发模型。

CSP（通信顺序进程）**模式将`channel`视为一等公民（第一类对象），其主要关注点在于通信的通道，而非发送或接收消息的实体。与Actor模型关注"谁在发送或接收消息"不同，CSP更侧重于"通过什么渠道传递消息"，即强调通信本身而非通信双方的具体实现

在CSP中，channel被用作不同进程之间的通信媒介。进程通过channel发送和接收消息来进行同步和数据传递，channel承担了中介的角色。与Actor模型中由每个Actor维护自己的邮箱不同，CSP模型允许进程通过共享的channel进行直接通信**CSP将消息投递给channel，至于谁从channel中取数据，谁从channel中发数据，发送的一方和接收的一方是不关注的**）SP模型不关心消息从哪来或到哪去，只关心消息是通过哪个channel传递的。这种设计实现了进程的解耦，并且允许进程通过**共享channel**来实现安全的**同步通信**


> 简单来说，Actor在发送消息前必须知道接收方是谁，而接受方收到消息后也需知道发送方是谁，更像是邮件的通信模式。而csp是完全解耦合的，不关心消息从哪来或到哪去，只关心消息是通过哪个channel传递的。

## C++ 风格的csp

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

## 利用csp思想实现取款逻辑

《C++并发编程实战》一书中提及了用csp思想实现atm机取款逻辑，我根据书中思想，整理了通信的示意图，书中部分代码存在问题，也一并修复了。

![null](https://cdn.llfc.club/1696562243686.jpg?x-oss-process=image%2Fwatermark%2Ctype_d3F5LW1pY3JvaGVp%2Csize_27%2Ctext_5oGL5oGL6aOO6L6wemFjaw%3D%3D%2Ccolor_FFFFFF%2Cshadow_50%2Ct_80%2Cg_se%2Cx_10%2Cy_10)

主函数实现

```c++
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

主函数中启动了三个线程，分别处理bank，machine以及interface的操作。
由于代码复杂解析来只列举atm类的实现

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

## 五、源码解析和实践感悟

### 5.1 源码解析

#### C++ Channel 的 CSP 实现核心

```cpp
// 条件变量实现的无缓冲/有缓冲 channel
template <typename T>
class Channel {
    std::queue<T> queue_;
    std::mutex mtx_;
    std::condition_variable cv_producer_;
    std::condition_variable cv_consumer_;
    size_t capacity_;
    bool closed_ = false;

    bool send(T value) {
        std::unique_lock<std::mutex> lock(mtx_);
        cv_producer_.wait(lock, [this]() {
            // 关键：capacity_==0 时为无缓冲 channel，需等待消费者就绪
            return (capacity_ == 0 && queue_.empty()) 
                || queue_.size() < capacity_ || closed_;
        });
        if (closed_) return false;
        queue_.push(value);
        cv_consumer_.notify_one();  // 唤醒消费者
        return true;
    }
};
```

无缓冲 channel（`capacity_==0`）等价于 Go 的 `make(chan T)`——发送者必须等待接收者就绪，实现同步通信。`closed_` 机制优雅关闭 channel，与 Go 的 `close(ch)` 语义一致。

#### ATM 状态机的 CSP 消息分发

```cpp
void run() {
    state = &atm::waiting_for_card;
    try {
        for (;;) {
            (this->*state)();  // 状态函数指针驱动
        }
    } catch (messaging::close_queue const&) {
        // 收到关闭消息，优雅退出
    }
}
```

状态通过成员函数指针 `state` 切换——`state = &atm::getting_pin`——每次循环动态调用不同函数。消息驱动状态转换，而非在 switch 中硬编码，符合开闭原则。

#### Actor 消息队列的线程安全机制

```cpp
// dispatcher 的核心——消息路由表
template<typename Message, typename Func>
dispatcher& handle(Func&& f, const std::string& name) {
    // typeid 作为 key 实现消息→处理器映射
    _handlers[std::type_index(typeid(Message))] = 
        [f = std::forward<Func>(f)](const message_base& msg) {
            f(static_cast<const Message&>(msg));
        };
    return *this;  // 链式调用
}
```

利用 `type_index` 建立消息类型到处理函数的映射表，`incoming.wait()` 按类型分发消息——这是 Actor 模型消息处理的核心调度机制。

### 5.2 实践经验

1. **Actor 适合有状态实体**：如游戏角色、银行账户——每个 Actor 维护私有状态，消息保证串行处理
2. **CSP 适合数据流管道**：如生产者-消费者、管道过滤器——通过 channel 连接无状态的处理阶段
3. **Actor 的调试难点**：消息异步传递 → 调用栈不连续 → 难追踪消息来源。需配合分布式追踪（如 OpenTelemetry SpanContext 在消息中传递）
4. **C++ 中 CSP 的 channel 性能瓶颈**：条件变量 + 锁在高频场景不如无锁队列（如 moodycamel::ConcurrentQueue）
5. **Actor 的数量控制**：每个 Actor 独立线程太重，应使用协程/纤程实现 M:N 调度（如 SObjectizer、CAF 框架）
6. **不要过度使用 Actor**：简单场景用 `std::async`/线程池更直接，Actor 只在需要状态隔离和消息契约时引入

## 六、面试准备

### 6.1 面试 Q&A

**Q1: Actor 模型和 CSP 模型的本质区别？**

Actor 关注**谁发送/接收**消息（Actor 身份），消息投递到具体 Actor 的邮箱。CSP 关注**通过什么渠道**通信（channel），发送者不关心接收者是谁。类比：Actor=邮件（知道收件人），CSP=公告板（谁看到谁处理）。

**Q2: Actor 模型如何保证并发安全？**

三个机制：① 无共享状态——Actor 之间不共享内存；② 消息队列串行处理——每个 Actor 一次只处理一条消息；③ 消息传递而非直接调用——消除了锁和竞态条件。

**Q3: CSP 中无缓冲 channel 与有缓冲 channel 的区别？**

无缓冲（capacity=0）：发送者阻塞直到接收者取走（同步通信）。有缓冲（capacity>0）：发送者在缓冲满之前不阻塞（异步通信）。Go 中 `make(chan int)` vs `make(chan int, 10)`。

**Q4: Actor 的消息处理为什么要是原子的？**

如果 Actor 在处理消息 A 时又处理消息 B，会导致状态的中间态被并发访问——破坏 Actor 的隔离性。因此每个 Actor 一次只处理一条消息，处理完成前不取下一个。

**Q5: C++ 中如何实现 Go 风格的 channel？**

用 `std::queue` + `std::mutex` + `std::condition_variable`（如本文实现）。高级版可使用无锁队列（降低锁开销）+ 协程（替代线程阻塞）。C++20 的 `std::latch`/`std::barrier` 可辅助同步。

**Q6: Actor 模型如何处理 Actor 崩溃？**

Erlang 的"Let it crash"哲学：父 Actor 监控子 Actor，子崩溃时父收到通知并决定重启/终止。C++ 实现需配合进程隔离（fork）或异常捕获 + 状态重置。C++ Actor 框架（CAF）提供 `system.monitor()` 机制。

**Q7: ATM 示例中状态机 + CSP 的组合优势？**

状态机管理 ATM 内部状态转换（等待插卡→输密码→选择操作），CSP 处理与外部（bank_machine、interface_machine）的消息通信。状态机保证本地逻辑正确，CSP 保证并发通信安全——两者的职责清晰分离。

**Q8: CSP 的 channel 关闭后发送/接收的行为？**

发送：应禁止并返回 false（Go 中 panic）。接收：应返回剩余缓冲数据，耗尽后返回"已关闭"标识（Go 中 `v, ok := <-ch`，ok=false 表示已关闭）。本文实现中 `closed_` + `receive` 返回 false 等价于 Go 的 ok=false。

### 6.2 常见陷阱与面试反问

1. **陷阱**：Actor 中消息处理时间过长 → Actor 邮箱堆积 → 消息延迟。**修复**：耗时操作异步化（投递到独立线程），Actor 只做状态决策。

2. **陷阱**：channel 关闭后继续 send → 未定义行为（Go 中 panic）。**修复**：send 检查 `closed_` 标志，或设置 `closed_` 后 `notify_all`。

3. **陷阱**：Actor 之间形成死锁（A 等 B 的消息，B 等 A 的消息）。**修复**：避免 Actor 间同步等待，使用超时机制。

4. **反问**：「Actor/CSP 和传统的多线程共享内存模型相比，你觉得各自的适用场景是什么？」希望听到：共享内存适合高吞吐低延迟数据并行（如矩阵运算），Actor/CSP 适合分布式系统的状态管理和容错（如微服务通信）。

5. **反问**：「如果让你从零设计一个 C++ Actor 框架，核心组件有哪些？」希望听到：Actor 抽象基类、邮箱队列、调度器（线程池）、监控树、序列化/网络层用于分布式 Actor。

### 6.3 一句话答案速记

| 问题 | 一句话答案 |
|------|------------|
| Actor 核心？ | 无共享状态 + 消息传递 + 串行消息处理 |
| CSP 核心？ | 通过 channel 通信，发收双方解耦 |
| Actor vs CSP？ | Actor 知道收发方身份，CSP 只管 channel |
| 无缓冲 channel？ | 发送阻塞直到接收者取走，实现同步 |
| Actor 并发安全？ | 无共享 + 邮箱串行处理 |
| Go channel 类比？ | C++ 的 queue + mutex + condition_variable |
| ATM 状态机？ | 成员函数指针驱动，消息触发状态转换 |
