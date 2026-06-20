---
title: 并发三剑客future, promise和async
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "并发编程"]
publish: true
---

# 并发三剑客future, promise和async

> C++ 异步编程的核心三件套：`std::future` 获取结果，`std::promise` 设置结果，`std::async` 一键启动异步任务。

## 一、核心概念

**补充**

- 定义：future/promise/async 是 C++11 引入的异步编程基础设施。promise 在生产者端设置值或异常，future 在消费者端获取，async 封装线程创建+promise+future 的整套流程。
- 关键词：`std::future`、`std::promise`、`std::async`、`std::packaged_task`、`std::shared_future`、`std::launch`
- 适用场景：异步 IO、并行计算、任务编排、线程间一次性结果传递
- 边界：future/promise 是一对一一次性通道，不适用于多次通知（用条件变量）或多生产者（需要额外的同步）

## 二、详细解析

### 1.async的用法

`std::async` **是一个用于异步执行函数的模板函数，它返回一个** `std::future` **对象，该对象用于获取函数的返回值**，**包括支持使用** `std::ref` **，以及**`std::move`**。我们下面详细聊一下** `std::async` **参数传递的事。**

std::async支持所有可调用(Callable)对象，并且也是默认按值复制（原因可以参考我之前写的关于thread函数源码解析那部分的文章），必须使用 std::ref 才能传递引用（左值引用）。并且它和 std::thread 一样，内部会将保有的参数副本转换为右值表达式进行传递，这是为了那些只支持移动的类型，左值引用没办法引用右值表达式，所以如果不使用 std::ref，这里 void f(int&) 就会导致编译错误，如果是 void f(const int&) 则可以通过编译，不过引用的不是我们传递的局部对象

async 和 thread 一样，可以接受**只移动类型**：

### async的[执行策略](https://zh.cppreference.com/w/cpp/thread/launch)

`std::async`**函数可以接受几个不同的启动策略，这些策略在**`std::launch`**枚举中定义。除了**`std::launch::async`**之外，还有以下启动策略：**

1. `std::launch::deferred`：这种策略意味着任务将在调用`std::future::get()`或`std::future::wait()`函数时延迟执行。换句话说，任务将在需要结果时同步执行。
2. `std::launch::async` 在不同**线程上**执行异步任务。
3. `std::launch::async | std::launch::deferred`：这种策略是上面两个策略的组合。任务可以在一个单独的线程上异步执行，也可以延迟执行，具体取决于实现。

默认情况下，`std::async`使用`std::launch::async | std::launch::deferred`策略。这意味着任务可能异步执行，也可能延迟执行，具体取决于实现。需要注意的是，不同的编译器和操作系统可能会有不同的默认行为。

### future的wait和get

`std::future::get()` 和 `std::future::wait()` 是 C++ 中用于处理异步任务的两个方法，它们的功能和用法有一些重要的区别。

1. **std::future::get()**:

`std::future::get()` 是一个**阻塞调**用，用于获取 `std::future` 对象表示的值或异常。如果异步任务还没有完成，`get()` 会阻塞当前线程，直到任务完成。如果任务已经完成，`get()` 会立即返回任务的结果。重要的是，`get()` 只能调用一次，因为它会移动或消耗掉 `std::future` 对象的状态。一旦 `get()` 被调用，`std::future` 对象就不能再被用来获取结果。

2. **std::future::wait()**:

`std::future::wait()` 也是一个阻塞调用，**但它与** `get()` **的主要区别在于** `wait()` **不会返回任务的结果**。它只是等待异步任务完成。如果任务已经完成，`wait()` 会立即返回。如果任务还没有完成，`wait()` 会阻塞当前线程，直到任务完成。与 `get()` 不同，`wait()` 可以被多次调用，它不会消耗掉 `std::future` 对象的状态。

总结一下，这两个方法的主要区别在于：

1. `std::future::get()` **用于获取并返回任务的结果**，而 `std::future::wait()` **只是等待任务完成**。
2. `get()` 只能调用一次，而 `wait()` 可以被**多次**调用。
3. 如果任务还没有完成，`get()` 和 `wait()` **都会阻塞当前线程**，但 `get()` 会一直阻塞直到任务完成并返回结果，而 `wait()` 只是在等待任务完成。

你可以使用std::future的wait_for()或wait_until()方法来检查异步操作是否已完成。这些方法返回一个表示操作状态的std::future_status值

### 2.将任务和future关联

在上一节中，我们等待地铁到站的过程中可以通过条件变量提醒我们是否到站，而本节中我们可以通过std::future处理地铁到站的情况。举个例子：我们在车站等车，可能会做一些别的事情打发时间，比如玩手机、和友人聊天等。不过，我们始终在等待一件事情：车到站。

C++ 标准库 将这种事件称为 future。它用于处理线程中需要等待某个事件的情况，线程知道预期结果。等待的同时也可以执行其它的任务。

C++ 标准库有两种 future，都声明在 future 头文件中：独占的 std::future 、共享的 std::shared_future。它们的区别与 std::unique_ptr 和 std::shared_ptr 类似。同一事件仅仅允许关联唯一一个std::future 实例，但可以关联多个 std::shared_future 实例。它们都是模板，它们的模板类型参数，就是其关联的事件（函数）的返回类型。当多个线程需要访问一个独立 future 对象时， 必须使用互斥量或类似同步机制进行保护。而多个线程访问同一共享状态，若每个线程都是通过其自身的 shared_future 对象副本进行访问，则是安全的。

`std::future` 是**只能移动**（拷贝构造和拷贝赋值被delete）的，其所有权可以在不同的对象中互相传递，但只有一个对象可以获得特定的同步结果。而 `std::shared_future` 是**可复制的**，多个对象可以指代同一个共享状态。

**使用 std::async 启动一个异步任务（也就是创建一个子线程执行相关任务，主线程可以执行自己的任务），它会返回一个 std::future 对象，这个对象和任务关联，将持有任务最终执行后的结果。当需要任务执行结果的时候，只需要调用 future.get() 成员函数，就会阻塞当前线程直到 future 为就绪为止（即任务执行完毕），返回执行结果。future.valid() 成员函数检查 future 当前是否关联共享状态，即是否当前关联任务。如果还未关联，或者任务已经执行完（调用了 get()、set()），都会返回 false。**

### 3.future与 packaged_task

`std::packaged_task`和`std::future`是C++11中引入的两个类，它们用于处理异步任务的结果。

`std::packaged_task`是一个可调用目标（函数、lambda 表达式、bind 表达式或其它函数对象），它**包装了一个任务**，该任务可以在另一个线程上（异步）运行。它可以捕获任务的返回值或异常，并将其存储在std::future对象中。

```cpp
template <class _Ret, class... _ArgTypes>
class packaged_task<_Ret(_ArgTypes...)> {}
```

packaged_task 是一个模板类型，其中：

* **_Ret：表示可调用目标的返回类型**
* **_ArgTypes...：可调用目标接受的参数类型**

```cpp
std::packaged_task<double(int, int)> 
std::packaged_task<void()>
```

所以上面初始化的第一个packaged_task实例表示，接受任何返回类型是double，参数是int,int的可调用对象。

第二个packaged_tas实例表示，，接受任何返回类型是void，且无参数的可调用对象。

`std::packaged_task` 重载了 operator() 运算符，并通过重载的 operator() 来执行包装的可调用对象。比如在命令`std::packaged_task<void(int)> task(myFunction);` 中，执行task()其实就算再执行myFunction().

以下是使用`std::packaged_task`和`std::future`的基本步骤：

1. 创建一个`std::packaged_task`对象，该对象包装了要执行的任务。
2. 调用`std::packaged_task`对象的`get_future()`方法，该方法返回一个与任务关联的`std::future`对象。
3. 在另一个线程上调用`std::packaged_task`对象的`operator()`，以执行任务。
4. 在需要任务结果的地方，调用与任务关联的`std::future`对象的`get()`方法，以获取任务的返回值或异常

```cpp
int my_task() {
    std::this_thread::sleep_for(std::chrono::seconds(5));
    std::cout << "my task run 5 s" << std::endl;
    return 42;
}
void use_package() {
    // 创建一个包装了任务的 std::packaged_task 对象，表示返回类型是int，无参数 （Ⅰ）
    std::packaged_task<int()> task(my_task); 
    // 获取与任务关联的 std::future 对象 （Ⅱ）
    std::future<int> result = task.get_future();
    // 在另一个线程上执行任务 （Ⅲ）  
    std::thread t(std::move(task));
    t.detach(); // 将线程与主线程分离，以便主线程可以等待任务完成  
    // 等待任务完成并获取结果  
    int value = result.get();
    std::cout << "The result is: " << value << std::endl;
}
```

因为 `task` 本身是重载了 `operator()` 的，是可调用对象，自然可以传递给 `std::thread` 执行，以及传递调用参数。唯一需要注意的是我们使用了 `std::move` ，这是因为 `std::packaged_task` **只能移动，不能复制**。

简而言之，其实 `std::packaged_task` 就是一个"包装"类而已，它本身并没什么特殊的，老老实实执行我们传递的任务，且方便我们获取返回值。

其实我们使用`std::async`和 `std::packaged_task` 都可以，只不过后者更加精细一些而已。

## 三、动手实践（代码案例）

### 4.promise 用法

C++11引入了`std::promise`和`std::future`两个类，用于实现异步编程。`std::promise`用于在某一线程中设置某个值或异常，而`std::future`则用于在另一线程中获取这个值或异常。

下面是`std::promise`的基本用法：

```cpp
#include <iostream>
#include <thread>
#include <future>

void set_value(std::promise<int> prom) {
    // 设置 promise 的值
    prom.set_value(10);
}

int main() {
    // 创建一个 promise 对象
    std::promise<int> prom;
    // 获取与 promise 相关联的 future 对象
    std::future<int> fut = prom.get_future();
    // 在新线程中设置 promise 的值
    std::thread t(set_value, std::move(prom));
    // 在主线程中获取 future 的值
    std::cout << "Waiting for the thread to set the value...\n";
    std::cout << "Value set by the thread: " << fut.get() << '\n';
    t.join();
    return 0;
}
```

在上面的代码中，我们首先创建了一个`std::promise<int>`对象，然后通过调用`get_future()`方法获取与之相关联的`std::future<int>`对象。然后，我们在新线程中通过调用`set_value()`方法设置`promise`的值，并在主线程中通过调用`fut.get()`方法获取这个值。注意，在调用`fut.get()`方法时，如果`promise`的值还没有被设置，则该方法会阻塞当前线程，直到值被设置为止。

同样的 `std::promise` **只能移动**，**不可复制**，所以我们使用了 `std::move` 进行传递。

除了`set_value()`方法外，`std::promise`还有一个`set_exception()`方法，用于设置异常。该方法接受一个`std::exception_ptr`参数，该参数可以通过调用`std::current_exception()`方法获取。下面是一个例子：

```cpp
#include <iostream>
#include <thread>
#include <future>

void set_exception(std::promise<void> prom) {
    try {
        // 抛出一个异常
        throw std::runtime_error("An error occurred!");
    } catch(...) {
        // 设置 promise 的异常
        prom.set_exception(std::current_exception());
    }
}

int main() {
    // 创建一个 promise 对象
    std::promise<void> prom;
    // 获取与 promise 相关联的 future 对象
    std::future<void> fut = prom.get_future();
    // 在新线程中设置 promise 的异常
    std::thread t(set_exception, std::move(prom));
    // 在主线程中获取 future 的异常
    try {
        std::cout << "Waiting for the thread to set the exception...\n";
        fut.get();
    } catch(const std::exception& e) {
        std::cout << "Exception set by the thread: " << e.what() << '\n';
    }
    t.join();
    return 0;
}
```

上述代码输出

```
Waiting for the thread to set the exception...
Exception set by the thread: An error occurred!
```

当然我们使用promise时要注意一点，如果promise被释放了，而其他的线程还未使用与promise关联的future，当其使用这个future时会报错。如下是一段错误展示

```cpp
void use_promise_destruct() {
    std::thread t;
    std::future<int> fut;
    {
        // 创建一个 promise 对象
        std::promise<int> prom;
        // 获取与 promise 相关联的 future 对象
        fut = prom.get_future();
        // 在新线程中设置 promise 的值
         t = std::thread(set_value, std::move(prom));
    }
    // 在主线程中获取 future 的值
    std::cout << "Waiting for the thread to set the value...\n";
    std::cout << "Value set by the thread: " << fut.get() << '\n';
    t.join();
}
```

随着局部作用域`}`的结束，`prom`可能被释放也可能会被延迟释放，  
`fut.get()`获取的值会报`error_value`的错误。

### 5.共享类型的future

当我们需要多个线程等待同一个执行结果时，需要使用std::shared_future

以下是一个适合使用`std::shared_future`的场景，多个线程等待同一个异步操作的结果：

假设你有一个异步任务，需要多个线程等待其完成，然后这些线程需要访问任务的结果。在这种情况下，你可以使用`std::shared_future`来共享异步任务的结果。

```cpp
void myFunction(std::promise<int>&& promise) {
    // 模拟一些工作
    std::this_thread::sleep_for(std::chrono::seconds(1));
    promise.set_value(42); // 设置 promise 的值
}

void threadFunction(std::shared_future<int> future) {
    try {
        int result = future.get();
        std::cout << "Result: " << result << std::endl;
    }
    catch (const std::future_error& e) {
        std::cout << "Future error: " << e.what() << std::endl;
    }
}

void use_shared_future() {
    std::promise<int> promise;
    std::shared_future<int> future = promise.get_future();

    std::thread myThread1(myFunction, std::move(promise)); // 将 promise 移动到线程中

    // 使用 share() 方法获取新的 shared_future 对象  

    std::thread myThread2(threadFunction, future);

    std::thread myThread3(threadFunction, future);

    myThread1.join();
    myThread2.join();
    myThread3.join();
}
```

在这个示例中，我们创建了一个`std::promise<int>`对象`promise`和一个与之关联的`std::shared_future<int>`对象`future`。然后，我们将`promise`对象移动到另一个线程`myThread1`中，该线程将执行`myFunction`函数，并在完成后设置`promise`的值。我们还创建了两个线程`myThread2`和`myThread3`，它们将等待`future`对象的结果。如果`myThread1`成功地设置了`promise`的值，那么`future.get()`将返回该值。这些线程可以同时访问和等待`future`对象的结果，而不会相互干扰。

但是大家要注意，如果一个`future`被移动给两个`shared_future`是错误的。

```cpp
void use_shared_future() {
    std::promise<int> promise;
    std::shared_future<int> future = promise.get_future();

    std::thread myThread1(myFunction, std::move(promise)); // 将 promise 移动到线程中

    std::thread myThread2(threadFunction, std::move(future));
    std::thread myThread3(threadFunction, std::move(future));

    myThread1.join();
    myThread2.join();
    myThread3.join();
}
```

这种用法是错误的，一个`future`通过隐式构造传递给`shared_future`之后，这个`shared_future`被移动传递给两个线程是不合理的，因为第一次移动后`shared_future`的生命周期被转移了，接下来`myThread3`构造时用的`std::move(future)`future已经失效了，会报错，一般都是`no state` 之类的错误。

### 6.异常处理

`std::future` 是C++的一个模板类，它用于表示一个可能还没有准备好的异步操作的结果。你可以通过调用 `std::future::get` 方法来获取这个结果。如果在获取结果时发生了异常，那么 `std::future::get` 会重新抛出这个异常。

以下是一个例子，演示了如何在 `std::future` 中获取异常：

```cpp
#include <iostream>
#include <future>
#include <stdexcept>
#include <thread>

void may_throw()
{
    // 这里我们抛出一个异常。在实际的程序中，这可能在任何地方发生。
    throw std::runtime_error("Oops, something went wrong!");
}

int main()
{
    // 创建一个异步任务
    std::future<void> result(std::async(std::launch::async, may_throw));

    try
    {
        // 获取结果（如果在获取结果时发生了异常，那么会重新抛出这个异常）
        result.get();
    }
    catch (const std::exception &e)
    {
        // 捕获并打印异常
        std::cerr << "Caught exception: " << e.what() << std::endl;
    }

    return 0;
}
```

在这个例子中，我们创建了一个异步任务 `may_throw`，这个任务会抛出一个异常。然后，我们创建一个 `std::future` 对象 `result` 来表示这个任务的结果。在 `main` 函数中，我们调用 `result.get()` 来获取任务的结果。如果在获取结果时发生了异常，那么 `result.get()` 会重新抛出这个异常，然后我们在 `catch` 块中捕获并打印这个异常。

上面的例子输出

```
Caught exception: Oops, something went wrong!
```

### 7.线程池

**线程池**是一种多线程处理形式，它处理过程中将任务添加到队列，然后在创建线程后自动启动这些任务。线程池线程一般**后台线程**。

1. **后台线程**：线程在主程序（前台线程）结束时不会阻止程序的终止。当主程序结束时，后台线程会被强制终止。
2. **前台线程**：线程在主程序结束之前必须完成。主程序会等待这些线程完成，然后再退出。

每个线程都使用**默认的堆栈大小，以默认的优先级运行**，并处于多线程单元中。如果某个线程在托管代码中空闲（例如等待 I/O 操作完成、等待锁、或者等待其他线程的通知），则线程池将插入另一个辅助线程来使所有处理器保持繁忙。如果所有线程池线程都始终保持繁忙，但队列中包含挂起的工作，则线程池将在一段时间后创建另一个辅助线程但线程的数目永远不会超过**最大值**。超过最大值的线程可以排队，但他们要等到其他线程完成后才启动。

**举例：**

假设我们有一个线程池，它有 4 个线程在工作。现在其中一个线程正在等待文件 I/O 完成，这个操作可能需要几毫秒。在这段等待时间里，如果没有其他线程执行任务，CPU 会处于空闲状态。为了避免这个情况，线**程池可以创建一个新的线程（辅助线程）**，来处理任务队列中的其他任务。这样，即使有一个线程在等待，其他线程仍然可以继续执行任务，从而保持 CPU 的高利用率。

假设我们有一个线程池，包含 4 个线程，编号为 T1、T2、T3 和 T4。现在我们来看看它们的工作情况：

线程池中的线程数：4 个线程（T1、T2、T3、T4）。

线程 T1、T2、T3 和 T4 正在处理任务：

T1 正在处理任务 A。

为了避免 CPU 空闲，线程池会采取以下措施：

创建辅助线程：在 T1 进入等待状态时，线程池会检查任务队列，发现还有任务（如 E 和 F）待处理。于是，线程池可以创建一个辅助线程 T5，来处理任务 E 和 F。  
流程：

0 毫秒：T1 处理任务 A。  
3 毫秒：T1 进入等待状态，T5 开始处理任务 E。  
4 毫秒：T5 完成任务 E。  
5 毫秒：T5 开始处理任务 F。  
6 毫秒：T1 完成 I/O 操作，继续处理任务 A。

线程池可以避免在处理短时间任务时创建与销毁线程的代价，它维护着多个线程，等待着监督管理者分配可并发执行的任务，从而提高了整体性能。

以下是参考博主恋恋风辰博客的线程池源码：

```cpp
#ifndef __THREAD_POOL_H__
#define __THREAD_POOL_H__

#include <atomic>
#include <condition_variable>
#include <future>
#include <iostream>
#include <mutex>
#include <queue>
#include <thread>
#include <vector>

class ThreadPool  {
public:
    ThreadPool(const ThreadPool&) = delete;
    ThreadPool&        operator=(const ThreadPool&) = delete;

    static ThreadPool& instance() {
        static ThreadPool ins;
        return ins;
    }

    using Task = std::packaged_task<void()>;


    ~ThreadPool() {
        stop();
    }

    template <class F, class... Args>
    auto commit(F&& f, Args&&... args) -> std::future<decltype(f(args...))> {
        using RetType = decltype(f(args...));
        if (stop_.load())
            return std::future<RetType>{};

        auto task = std::make_shared<std::packaged_task<RetType()>>(
            std::bind(std::forward<F>(f), std::forward<Args>(args)...));

        std::future<RetType> ret = task->get_future();
        {
            std::lock_guard<std::mutex> cv_mt(cv_mt_);
            tasks_.emplace([task] { (*task)(); });
        }
        cv_lock_.notify_one();
        return ret;
    }

    int idleThreadCount() {
        return thread_num_;
    }

private:
    ThreadPool(unsigned int num = 5)
        : stop_(false) {
            {
                if (num < 1)
                    thread_num_ = 1;
                else
                    thread_num_ = num;
            }
            start();
    }
    void start() {
        for (int i = 0; i < thread_num_; ++i) {
            pool_.emplace_back([this]() {
                while (!this->stop_.load()) {
                    Task task;
                    {
                        std::unique_lock<std::mutex> cv_mt(cv_mt_);
                        this->cv_lock_.wait(cv_mt, [this] {
                            return this->stop_.load() || !this->tasks_.empty();
                        });
                        if (this->tasks_.empty())
                            return;

                        task = std::move(this->tasks_.front());
                        this->tasks_.pop();
                    }
                    this->thread_num_--;
                    task();
                    this->thread_num_++;
                }
            });
        }
    }
    void stop() {
        stop_.store(true);
        cv_lock_.notify_all();
        for (auto& td : pool_) {
            if (td.joinable()) {
                std::cout << "join thread " << td.get_id() << std::endl;
                td.join();
            }
        }
    }

private:
    std::mutex               cv_mt_;
    std::condition_variable  cv_lock_;
    std::atomic_bool         stop_;
    std::atomic_int          thread_num_;
    std::queue<Task>         tasks_;
    std::vector<std::thread> pool_;
};

#endif  // !__THREAD_POOL_H__
```

### 7.1 commit函数

```cpp
template <class F, class... Args>
    auto commit(F&& f, Args&&... args) -> std::future<decltype(f(args...))> {
        using RetType = decltype(f(args...)); // 使用RetType作为可调用对象返回类型的别名
        if (stop_.load()) // 线程池是否处于关闭状态
            return std::future<RetType>{};
    
        // 将可调用对象和参数用装饰器packaged_task进行包装
        auto task = std::make_shared<std::packaged_task<RetType()>>(
            std::bind(std::forward<F>(f), std::forward<Args>(args)...));
        // 从包装器获取future
        std::future<RetType> ret = task->get_future();
        // 在{}内使用lock_guard锁定互斥量，并将task使用emplace插入至任务队列
        {
            std::lock_guard<std::mutex> cv_mt(cv_mt_);
            tasks_.emplace([task] { (*task)(); });
        }
        cv_lock_.notify_one();
        return ret;
    }
```

**模板类型:**

* `F`：回调函数，线程执行的任务
* `... Args`：任务的参数列表

`F&&`**和** `Args&&`**：转发引用，根据传入参数的类型自动推断为左值引用或右值引用**

* 传入的参数是右值（比如使用 `std::move`），被推导为右值引用
* 传入的参数是左值，被推导为左值引用

**返回值类型：**

* `std::future<decltype(f(args...))>` ：使用可调用对象的返回类型作为`std::future`的模板类型，并将`std::future<推断的类型>`返回
* `decltype(f(args...))`：自动推断可调用对象f的返回值类型，args…是传给f的实参

`stop_.load()`**：读取** `stop_` **的当前值**

* 如果是`True`，表示线程池关闭状态，直接返回一个使用默认构造函数构造的`std::future`对象
* 如果是`False`，表示线程池开启状态，继续执行代码

```cpp
auto task = std::make_shared<std::packaged_task<RetType()>>(
     std::bind(std::forward<F>(f), std::forward<Args>(args)...));
```

* `std::packaged_task<RetType()>`：包装任务，任务的返回类型是`RetType()`；
* 需要包装的任务通过`std::bind`绑定起来，并传给包装器`std::packaged_task<RetType()>`
* 包装器传递给智能指针`std::make_shared`进行管理

**ret：从包装器packaged_task获取future，future存储了可调用对象的返回值**

* [task] { (*task)(); })：按值捕获上面定义的 task（伪闭包），task是一个存储packaged_task对象的智能指针，这里插入任务队列的是一个回调函数，该回调函数将会执行 packaged_task 包含的任务（函数）
* packaged_task 重载了 () 运算符，这里其实就相当于再调用可调用对象（使用packaged_task包装的任务）  
  **只要队列中插入新任务，就唤醒线程**

**最后，返回新任务的 future 对象**

### 7.2 start函数

```cpp
void start() {
        for (int i = 0; i < thread_num_; ++i) {
            // 使用容器存储线程对象
            pool_.emplace_back([this]() { // 每个线程执行的lamda函数（线程池执行的任务相同）
                while (!this->stop_.load()) { // 判断线程池是否停止
                    Task task; // 初始化一个接受无参并无返回值可调用对象的packaged_task
                    {
                        std::unique_lock<std::mutex> cv_mt(cv_mt_);
                        // 条件变量判断，当满足任务队列不为空或者stop_为true，并且当前线程被唤醒时，退出挂起状态
                        this->cv_lock_.wait(cv_mt, [this] {
                            return this->stop_.load() || !this->tasks_.empty();
                        });
                        // 队列为空，那么就只有stop_为true一种情况，此时无任务需要处理，直接退出
                        if (this->tasks_.empty())
                            return;
                        // 处理队列剩余任务
                        task = std::move(this->tasks_.front());
                        this->tasks_.pop();
                    }
                    this->thread_num_--; // 减少一个线程数用来执行task任务
                    task(); // 执行任务
                    this->thread_num_++; // task任务在线程内是同步执行的，所以当task任务执行完后，可用的线程数加一
                }
            });
        }
    }
```

### **注意：线程池不能被用于以下两种任务：**

**线程池做得任务是并发的，并且无序，不能保证连续性**。比如在网络编程中，你的接受线程必须要保证收到的**消息顺序是有序**的，所以这里就不能用线程池；

还比如**在逻辑线程**中，我需要先处理消息A，再处理消息B，同样是有顺序的不能使用线程池，只能使用单线程来完成。  
**如果执行的任务互斥性很大，或者说是强关联**，比如玩游戏：第一个任务是玩家A进入工会做任务增加工会贡献，第二个任务是工会会长使用这个贡献。而贡献是所有玩家共享的一个资源，有一个公共互斥量，这也不可以用线程池来用，这只能用一个线程来用。因为来**回加锁会导致效率大幅度下降，还不如使用一个线程来完成。**

## 四、进阶应用（≥500字）

**补充**

- **promise/future 作为线程间同步的最小单元**：相比条件变量（多次通知），promise/future 是一次性通道。适用场景：计算任务的结果通知、资源初始化完成信号。不合适：持续更新的状态（如：每来一个请求都通知消费者）
- **与 C++20 协程的关系**：`std::future` 是协程的 awaitable 类型的基底，C++20 协程可以直接 `co_await` 一个 future，将异步回调的嵌套展平为同步书写。promise 在协程中对应 `promise_type`，协程帧通过它传递结果
- **packaged_task 与线程池的深度耦合**：线程池的 `commit()` 返回 `std::future` 本质靠 `packaged_task` 的 `get_future()`。`packaged_task` 被 `shared_ptr` 管理存入任务队列，worker 线程执行 `task()` 后 future 就绪。这是"任务提交"与"结果获取"解耦的关键
- **异常传播链**：promise → future → get() 是一条完整的异常隧道。异步任务内部 `throw` → `promise.set_exception(current_exception())` → `future.get()` 重新抛出。这比 thread 内部 crash（直接 terminate）安全得多
- **future 的生命周期陷阱**：`std::async` 返回的 future 如果不用具名变量接收（临时对象），析构时阻塞等待任务完成 → 异步变成同步。这是最常见的性能 bug
- **shared_future 的正确使用方式**：多个消费者线程需要同一结果时，用 `promise.get_future().share()` 创建 `shared_future`，然后按值拷贝传递给每个消费者线程（不是 move）
- **与 Qt 信号槽、JavaScript Promise 的类比**：C++ 的 promise-future 等价于 JS 的 Promise（resolve→set_value, reject→set_exception），等价于 Qt5+ 的 QFuture-QPromise
- **性能考量**：`std::async` 每次调用都可能创建新线程（取决于实现），频繁调用可用线程池替代；`packaged_task` 本身无额外线程开销，配合线程池是最优方案

### 关联主题

- [async thread](async%20thread.md) — async vs thread 的详细对比
- [线程池](线程池.md) — 线程池的完整实现
- [线程](线程.md) — std::thread 基础

## 五、源码解析和实践感悟（≥1000字）

**补充** — 深入剖析 libstdc++ 中 promise/future/async 的核心实现路径：

### promise 的内部结构

```cpp
// promise 的核心是持有一个共享状态 shared state
template<typename _Res>
class promise {
    // promise 内部持有 _State 的 shared_ptr
    // _State 继承自 __future_base::_State_baseV2
    // 其中包含：互斥量、条件变量、retrieved 标志、异常指针、alignas 存储空间
    shared_ptr<__future_base::_State_baseV2> _M_state;
    
    future<_Res> get_future() {
        // 标记 shared state 已被 future 关联
        _M_state->_M_set_retrieved_flag();
        return future<_Res>(_M_state);  // future 共享同一个 _M_state
    }
    
    void set_value(const _Res& __r) {
        // 在共享状态中原地构造返回值
        static_cast<_State*>(_M_state.get())->_M_set(__r);
        // 通过条件变量唤醒等待在 future::get() 上的线程
    }
};
```

关键点：
1. promise 和 future 通过 `shared_ptr<shared_state>` 共享状态，解决了生命周期问题——即使 promise 先析构，future 仍能安全获取结果
2. `_M_set_retrieved_flag()` 防止一个 promise 关联多个 future（`future_error`）
3. 返回值通过 placement new 在共享状态的 alignas 缓冲区中构造，避免堆分配

### future::get() 的阻塞机制

```cpp
template<typename _Res>
_Res future<_Res>::get() {
    // 1. 检查 future 是否有效
    if (!_M_state) throw future_error(future_errc::no_state);
    // 2. wait() 内部：获取互斥锁，检查是否就绪，未就绪则条件变量等待
    _M_state->wait();
    // 3. 从共享状态中 move 返回值
    return std::move(static_cast<_State*>(_M_state.get())->_M_result);
    // 4. 释放共享状态引用（future 变为 invalid）
}
```

### async 的线程创建策略

```cpp
// libstdc++ 中 async 的简化实现
future<...> async(launch __policy, _Fn&& __fn, _Args&&... __args) {
    shared_ptr<promise<...>> __promise = make_shared<promise<...>>();
    future<...> __ret = __promise->get_future();
    
    auto __task = [__promise, fn, args...]() mutable {
        try { __promise->set_value(fn(args...)); }
        catch(...) { __promise->set_exception(current_exception()); }
    };
    
    if (__policy & launch::async) {
        // 直接创建新线程 detach
        thread{std::move(__task)}.detach();
    } else if (__policy & launch::deferred) {
        // 将 task 存入 shared state，等 future.get() 时同步调用
        __promise->_M_state->_M_set_deferred(std::move(__task));
    }
    return __ret;
}
```

### 难点与易错点

1. **promise 生命周期问题**：如果 promise（或其 shared_state）在 set_value 前析构，future.get() 会收到 `broken_promise` 异常。这就是 `use_promise_destruct()` 示例的问题根源——promise 在局部作用域结束时可能先于线程执行 set_value 析构
2. **packaged_task 的移动语义陷阱**：`packaged_task` 只能移动不可拷贝。传递给 `std::thread` 时必须 `std::move(task)`，之后 task 无效。常见错误：move 之后还尝试调用 task.get_future()
3. **future::get() 只能调用一次**：get() 内部 move 走结果后 future 变为 invalid。如果多个地方需要结果，必须用 `shared_future`
4. **async 默认策略的不确定性**：MSVC 的 async 用线程池，libstdc++ 创建新线程，行为不同。生产代码应显式指定 `std::launch::async` 或 `std::launch::deferred`
5. **条件变量 vs promise 的选择**：需要多次通知的场景用条件变量，一次性结果传递用 promise。两者可以组合——用 promise 传递"收工"信号，用条件变量传递过程中的状态变化

### 经验总结

- **线程池 + packaged_task 是异步编程的最优组合**：async 简单但不可控（线程数、调度策略），packaged_task 配合自建线程池兼顾灵活性和性能
- **用 shared_future 实现多播通知**：当多个消费者需要同一结果时，从 promise 中 `share()` 出 shared_future，拷贝分发给各消费者
- **异常传播是 promise-future 体系的杀手特性**：传统的 thread+引用传结果无法安全传递异常；promise 的 set_exception 让异常像返回值一样流动
- **promise 和 future 共享 shared_ptr<State>** 的设计是 RAII 在异步编程中的经典应用——资源（结果）的所有权由 shared_ptr 管理，不依赖任何一方的生命周期
- 面试场景的核心价值：展示对异步结果传递机制的理解，不仅仅是 API 调用，而是 shared state、同步原语、生命周期管理的完整链路

## 六、面试准备（高频问法≥10个，反问点/一句话答案≥5个，均带回答）

### 6.1 高频问法（≥10个）

基础理解：
- Q1：future、promise 和 async 三者之间的关系是什么？ — promise 是生产者端，负责 set_value/set_exception；future 是消费者端，通过 get() 获取结果；async 封装了线程创建 + promise + future 的整套流程
- Q2：std::future 和 std::shared_future 的区别？ — future 独占结果，get() 只能调用一次且 move 走结果；shared_future 可复制，多次 get() 返回同一结果，适合多消费者场景
- Q3：std::launch::async 和 std::launch::deferred 的区别？ — async 创建新线程立即异步执行；deferred 在 future.get()/wait() 时当前线程同步执行，不创建新线程

原理深入：
- Q4：future::get() 的底层阻塞机制是什么？ — get() 内部通过互斥锁 + 条件变量实现：未就绪时 wait 在条件变量上，promise::set_value() 后 notify 唤醒
- Q5：如果 promise 在 set_value 之前析构了，future::get() 会发生什么？ — 抛出 `std::future_error`，错误码为 `broken_promise`。因为 shared state 检测到 promise 端已销毁但值未设置
- Q6：packaged_task 和 async 各自适合什么场景？ — async 适合简单的一次性异步调用；packaged_task 适合需要精细控制线程的场景（如配合自建线程池），以及需要把任务和执行线程解耦

实践应用：
- Q7：future::get() 为什么只能调用一次？ — get() 内部 move 走结果后，会将 future 标记为 invalid，再调用报 `no_state` 错误。多消费者需用 shared_future
- Q8：线程池的 commit() 为什么返回 future？ — 通过 packaged_task 的 get_future()，将任务的提交和结果的获取解耦。调用者可以异步等待或同步获取结果
- Q9：future::wait_for 的返回值有哪些？各自含义？ — `future_status::ready` 任务已完成；`future_status::timeout` 超时；`future_status::deferred` 任务使用 deferred 策略且尚未开始执行
- Q10：什么时候用 promise-future 而不是条件变量？ — 一次性结果传递用 promise-future（异常可传播）；多次通知/状态变更用条件变量

### 6.2 反问点/陷阱点（≥5个）

针对面试官的深度问题：
- "你们线上服务的异步任务主要用 async 还是自建线程池+packaged_task？为什么？"
- "在你们的场景中，有没有遇到过 shared_future 的性能瓶颈？比如多消费者争抢共享状态锁？"
- "C++20 协程引入后，你们有没有考虑用 `co_await future` 替代回调式异步？"

常见陷阱：
- 陷阱 1：`std::async([]{ return 42; });` — 返回值 future 是临时对象，析构阻塞 → 异步变同步
- 陷阱 2：`promise.get_future()` 被多次调用 — 第二个调用抛出 `future_errc::future_already_retrieved`
- 陷阱 3：`packaged_task` move 给 thread 后还调用 `get_future()` — task 已无效

### 6.3 一句话答案（≥5个）

快速记忆要点：
- future/promise/async 的核心 = 生产者-消费者 + 共享状态 + 一次性结果传递
- 用 async 的关键 = 显式指定 launch policy，future 生命周期足够长
- 避免常见错误 = promise 只 get_future 一次，packaged_task move 后别用，async 返回值接住
- async 优于 thread 的地方 = 返回值自动获取、异常自动传播、无需手动 join
- shared_future 的场景 = 多个线程需要同一异步结果，按值拷贝分发
- 调试未来体问题先看 = future 是否 valid、promise 是否已 set、task 是否已 move

## 附录（参考链接）

### 8.[**thread,async源码解析**](https://blog.csdn.net/m0_63086198/article/details/143609381)

来自大佬llfc:[视频链接](【C++ 并发编程(10) 答疑汇总(async和thread源码解读)】<https://www.bilibili.com/video/BV1g34y1u7uh?vd_source=6b33b5dcfe7cbae47c11d886af4cc5d2>)
