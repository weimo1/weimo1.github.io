---
title: Linux进程管理
date: 2026-06-20
categories:
  - ["系统底层408", "操作系统"]
publish: true
---

# Linux进程管理

---

## **一、进程创建与生命周期**

---

### **1. 进程描述符：**`task_struct`

`task_struct`是Linux内核中描述进程的核心数据结构，包含进程的所有元信息：

```
// 内核源码：include/linux/sched.h（简化版）
struct task_struct {
    volatile long state;               // 进程状态（TASK_RUNNING等）
    void *stack;                       // 内核栈指针
    struct mm_struct *mm;              // 内存管理结构（地址空间）
    struct files_struct *files;        // 打开文件表
    pid_t pid;                         // 进程ID
    pid_t tgid;                        // 线程组ID（主线程PID）
    struct list_head tasks;            // 全局进程链表节点
    struct thread_struct thread;       // CPU上下文（寄存器值）
    struct sched_entity se;            // CFS调度实体（含vruntime）
    int prio;                          // 动态优先级
    int static_prio;                   // 静态优先级（nice值映射）
    unsigned int policy;               // 调度策略（SCHED_NORMAL等）
    // ...
};
```

* **关键字段说明**：

+ `state`：进程状态（TASK\_RUNNING, TASK\_INTERRUPTIBLE, TASK\_STOPPED等）
+ `mm`：指向虚拟内存管理结构，包含页表、内存区域（VMA）链表
+ `files`：文件描述符表，决定`fork()`后是否共享文件（由`CLONE_FILES`标志控制）

---

### **2.** `fork()`**系统调用深度解析**

#### **a. 执行流程**

```
用户层：fork() → glibc封装 → 系统调用号SYS_fork
内核层：sys_fork() → _do_fork() → copy_process()
```

* **关键步骤**：

1. **复制**`task_struct`：`dup_task_struct()`创建子进程描述符
2. **拷贝资源**：

- 文件描述符表（`files`）：根据`CLONE_FILES`标志决定是否共享
- 信号处理表（`sighand`）：根据`CLONE_SIGHAND`标志决定是否共享
- 内存空间（`mm`）：触发写时复制（COW）机制

3. **设置返回值**：子进程的`eax`寄存器设为0，父进程返回子进程PID

#### b. 写时复制（Copy-On-Write）

* **实现原理**：

+ 父进程和子进程共享物理内存页，页表项标记为只读
+ 当任一进程尝试写入时触发缺页异常（Page Fault），内核复制该页并修改页表

* **内核代码路径**：  
  `do_page_fault() → handle_mm_fault() → handle_pte_fault() → do_wp_page()`
* **优化价值**：

+ 避免立即复制整个地址空间（如`fork()`后立即`exec()`的场景）
+ 减少内存开销和复制时间

---

* **细节**：
* **页表标记**：

```
// 内核源码：kernel/fork.c (copy_page_range)
for each 页表项 in 父进程页表:
    if 页可写:
        设置页表项为只读（清除_PAGE_RW标志）
        增加页的引用计数
```

* **缺页异常处理**：

```
// 内核源码：arch/x86/mm/fault.c (do_page_fault)
if 触发写操作的页是COW页:
    分配新物理页
    复制原页内容到新页
    修改当前进程页表项指向新页，并设置为可写
```

#### **c.** `vfork()`**的特殊行为**

* **与**`fork()`**的区别**：

|  |  |  |
| --- | --- | --- |
| **特性** | `vfork()` | `fork()` |
| **地址空间** | 子进程共享父进程地址空间 | 使用COW机制延迟复制 |
| **执行顺序** | 父进程阻塞直到子进程exit/exec | 父子进程并行执行 |
| **使用场景** | 子进程立即exec新程序 | 通用进程复制 |

* **内核实现**：

```
sys_vfork() → _do_fork(CLONE_VFORK | CLONE_VM | SIGCHLD)
```

+ `CLONE_VM`：共享地址空间
+ `CLONE_VFORK`：父进程休眠，直到子进程释放地址空间

##### **d** `clone()`**系统调用**

* **函数原型**：

```
  int clone(int (*fn)(void *), void *stack, int flags, void *arg, ...);
```

* **关键标志位**：

|  |  |
| --- | --- |
| **Flag** | **作用** |
| `CLONE_VM` | 共享地址空间（线程的核心标志） |
| `CLONE_FS` | 共享文件系统信息（根目录、当前目录等） |
| `CLONE_FILES` | 共享文件描述符表 |
| `CLONE_SIGHAND` | 共享信号处理函数表 |

**整个过程实现如下：**

1. p = dup\_task\_struct(current); 为新进程创建一个内核栈、thread\_iofo和task\_struct,这里完全copy父进程的内容，所以到目前为止，父进程和子进程是没有任何区别的。
2. 为新进程在其内存上建立内核堆栈对子进程task\_struct任务结构体中部分变量进行初始化设置，检查所有的进程数目是否已经超出了系统规定的最大进程数，如果没有的话，那么就开始设置进程描诉符中的初始值，从这开始，父进程和子进程就开始区别开了。
3. 把父进程的有关信息复制给子进程，建立共享关系设置子进程的状态为不可被TASK\_UNINTERRUPTIBLE，从而保证这个进程现在不能被投入运行，因为还有很多的标志位、数据等没有被设置
4. 复制标志位（falgs成员）以及权限位(PE\_SUPERPRIV)和其他的一些标志
5. 调用get\_pid()给子进程获取一个有效的并且是唯一的进程标识符PID
6. return ret\_from\_fork;返回一个指向子进程的指针，开始执行

**总结**

linux创建一个新的进程是从复制开始的，在系统内核里首先是将父进程的进程控制块PCB进行拷贝，然后再根据自己的情况修改相应的参数，获取自己的进程号，再开始执行。我觉得整个过程重点就是理解子进程如何创建，在内核调用的几个重要的内核函数，以及子进程怎么返回开始执行的。把握这些点就OK了。

### **3.** `exe()`**系统调用深度解析**

[exec 函数族](https://zhida.zhihu.com/search?content_id=243188821&content_type=Article&match_order=1&q=exec+%E5%87%BD%E6%95%B0%E6%97%8F&zhida_source=entity)是 Linux 系统中的系统调用函数，它们都以 exec 开头，共有 6 个，分别是 `execl`、`execle`、`execlp`、`execv`、`execve`、`execvp`，使用 exec 函数可以将当前的进程替换为一个新进程，且新进程与原进程具有相同的 PID。

## 函数原型

```
#include <unistd.h>

extern char **environ;

int execl(const char *path, const char *arg, ...);
int execlp(const char *file, const char *arg, ...);
int execle(const char *path, const char *arg,..., char * const envp[]);
int execv(const char *path, char *const argv[]);
int execvp(const char *file, char *const argv[]);
int execvpe(const char *file, char *const argv[], char *const envp[]);
```

## 参数说明

* `path`：指定要执行的可执行文件及其路径，可以是相对路径、也可以是绝对路径。
* `arg`：指定传递给可执行文件的一系列参数，以可变参数列表的形式，一般第一个参数为可执行文件的名称，且最后一个参数必须是 `NULL`。
* `file`：若参数中包含"`/`"则视为路径并在指定路径下查找可执行文件，否则将在 `PATH` 环境变量指定的路径中查找可执行文件。
* `envp`：指定新进程的环境变量，不使用当前的环境变量。
* `argv`：指定传递给可执行文件的一系列参数，以参数数组的形式，且该数组最后一个元素必须是 `NULL`。

## 返回值

* 成功：不返回，从新程序的 main 函数开始执行。
* 失败：返回 -1，继续执行原程序。

## 函数区别

分别以函数中的字符 `l`、`p`、`v`、`e` 说明：

* `l`：表示使用参数列表的形式传递参数。
* `p`：表示使用文件名，若不指定路径，将在 [PATH 环境变量](https://zhida.zhihu.com/search?content_id=243188821&content_type=Article&match_order=1&q=PATH+%E7%8E%AF%E5%A2%83%E5%8F%98%E9%87%8F&zhida_source=entity)指定的路径中查找可执行文件。
* `v`：表示使用参数数组的形式传递参数。
* `e`：表示要使用新的环境变量给新进程。

---

## **二、线程**

---

### **1. 线程的底层本质**

Linux线程通过轻量级进程（LWP）实现，与进程共享资源：

```
// pthread_create底层调用（glibc实现）
clone(CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND, stack, ...)
```

* **关键标志位**：

+ `CLONE_VM`：共享地址空间（`mm_struct`）
+ `CLONE_FILES`：共享文件描述符表
+ `CLONE_SIGHAND`：共享信号处理函数表

### **2. 线程本地存储（TLS）实现**

#### **1. TLS的核心目标**

线程本地存储（Thread-Local Storage）是一种允许每个线程拥有独立变量副本的机制，其核心特性包括：

* **线程隔离性**：每个线程对TLS变量的读写操作互不影响。
* **高效访问**：通过硬件寄存器直接寻址，避免通过全局锁或哈希表查询。
* **隐式传递**：无需显式传递线程上下文，函数可直接访问当前线程的变量副本。

---

#### **2. Linux TLS实现架构**

Linux的TLS实现分为三个层级：

1. **编译器支持**（如GCC的`__thread`关键字）
2. **动态链接器（GLIBC）管理**
3. **内核系统调用支持**

---

##### **一、编译器层：**`__thread`**关键字**

###### **1. 变量声明**

```
// 声明TLS变量
__thread int tls_var = 42;

// 在函数中使用
void foo() {
    tls_var++;  // 每个线程独立修改自己的副本
}
```

##### **2. 编译器生成的代码**

以x86\_64为例，编译器会将TLS变量访问转换为`%fs`段寄存器相对寻址：

```
# 反汇编结果（GCC生成）
movl    %gs:0xfffffffffffffffc, %eax  # 假设tls_var偏移为-4
addl    $1, %eax
movl    %eax, %gs:0xfffffffffffffffc
```

---

#####3333 **二、动态链接器（GLIBC）管理**

###### **1. TLS内存模型**

* **静态TLS（Static TLS）**：  
  程序启动时加载的模块（主程序、静态库）的TLS变量，在进程初始化时分配空间。
* **动态TLS（Dynamic TLS）**：  
  通过`dlopen()`加载的共享库中的TLS变量，在模块加载时动态分配。

###### **2. 内存布局**

每个线程的TLS区域分为两部分：

```
+----------------------+
| 系统保留区域          |  // 如线程ID、栈保护值等（struct pthread）
+----------------------+
| 用户TLS变量区         |  // __thread变量存储在此
+----------------------+
| 动态TLS模块区         |  // dlopen加载的模块TLS数据
+----------------------+
```

##### #**3. 关键数据结构**

* `dtv`**（Dynamic Thread Vector）**：  
  每个线程的`dtv`数组记录动态加载模块的TLS块地址。

```
typedef struct {
    void* tcb;          // 线程控制块（TCB）指针
    size_t counter;     // 模块生成计数器
    void* entries[];    // 模块TLS块指针数组
} dtv_t;
```

* `tls_index`：  
  动态模块的TLS变量通过`tls_index`结构定位：

```
struct tls_index {
    unsigned long ti_module;  // 模块ID（对应dtv索引）
    unsigned long ti_offset;  // 变量在模块TLS块内的偏移
};
```

---

##### **三、内核层支持**

###### **1. 系统调用**`arch_prctl`

* **功能**：设置线程的`fs`/`gs`寄存器基址（TLS起始地址）。
* **使用场景**：

```
// GLIBC在创建线程时设置fs寄存器基址
arch_prctl(ARCH_SET_FS, tls_base);
```

###### **2. 内核数据结构**

* `struct thread_struct`：  
  存储线程的寄存器状态和TLS基址。

```
// x86架构定义（arch/x86/include/asm/processor.h）
struct thread_struct {
    unsigned long   fsbase;    // 用户态fs基址
    unsigned long   gsbase;    // 用户态gs基址
    // ...
};
```

---

##### **四、TLS访问全过程**

###### **1. 静态TLS变量访问**

```
用户代码访问tls_var → 编译器生成`%fs:offset`指令 → 
CPU通过FS寄存器基址 + 固定偏移 → 直接访问内存
```

###### **2. 动态TLS变量访问（dlopen模块中的变量）**

```
用户代码访问dyn_tls_var → 编译器生成`__tls_get_addr()`调用 →
动态链接器通过tls_index查询dtv → 返回变量地址
```

###### **3.** `__tls_get_addr()`**实现**

GLIBC中的关键函数：

```
void* __tls_get_addr(struct tls_index* ti) {
    dtv_t* dtv = THREAD_DTV();          // 获取当前线程的dtv
    if (ti->ti_module > dtv->counter) {
        // 触发动态TLS分配（_dl_allocate_tls）
    }
    return (char*)dtv->entries[ti->ti_module] + ti->ti_offset;
}
```

---

##### **五、调试与诊断**

###### **1. 查看线程TLS地址**

```
# 使用GDB查看fs寄存器基址
(gdb) p $fs_base
$1 = 140737488347136

# 查看TLS变量内存
(gdb) x/xw $fs_base - 4  # 假设tls_var偏移为-4
```

###### **2. 分析TLS内存布局**

```
# 查看线程的TCB和TLS区域
LD_DEBUG=files ./program 2>&1 | grep 'TLS'

# 使用readelf查看模块的TLS大小
readelf -S libfoo.so | grep TLS
```

---

##### **六、设计哲学与权衡**

1. **性能 vs 灵活性**：

+ 静态TLS访问快但无法动态加载，动态TLS灵活但有性能损耗。

2. **兼容性挑战**：

+ Windows使用`TlsAlloc()`+索引方式，Linux直接使用地址偏移，导致ABI不兼容。

3. **硬件依赖**：

+ TLS性能高度依赖架构提供的段寄存器支持（如x86的`fs`/`gs`）。

---

## **三、进程同步机制**

---

### **一、共享内存（Shared Memory）**

##### **特点**：

* **最高效的IPC方式**：直接操作内存，无需内核介入数据拷贝。
* **无结构化**：需自行设计同步机制（如配合信号量）。
* **两种实现**：

+ **System V共享内存**：`shmget()` + `shmat()`
+ **POSIX共享内存**：`shm_open()` + `mmap()`

#### **底层实现**：

* **内核数据结构**：

```
struct shmid_kernel {    // System V共享内存
    struct kern_ipc_perm shm_perm;
    struct file *shm_file;   // 关联的tmpfs文件
    unsigned long shm_nattch; // 附加计数
};
```

* **内存映射**：通过`tmpfs`文件系统实现，`shmat()`调用触发`mmap()`系统调用。

#### **同步要求**：

* **必须配合信号量/互斥锁**：因共享内存本身无同步机制。

---

### **二、信号量（Semaphore）**

##### **特点**：

* **计数同步**：可控制N个线程同时访问资源。
* **两种类型**：

+ **System V信号量**：`semget()`/`semop()`，支持信号量集。
+ **POSIX信号量**：`sem_init()`，更轻量。

#### **底层实现**（System V）：

* **内核数据结构**：

```
struct sem_array {        // 信号量集
    struct kern_ipc_perm sem_perm;
    struct sem *sems;     // 信号量数组
    struct list_head pending; // 等待队列
};

struct sem {
    int semval;           // 当前计数值
    int sempid;           // 最后操作进程PID
};
```

* **原子操作**：

+ `semop()`操作通过`ipc_lock()`锁定信号量集。
+ 修改计数值使用`ADD_VAL`原子指令。

* **等待队列**：当信号量不足时，进程加入`pending`队列，状态设为`TASK_INTERRUPTIBLE`。

---

### **三、管道（Pipe）**

##### **特点**：

* **半双工通信**：数据单向流动，需两个管道实现双向。
* **字节流传输**：无消息边界。
* **容量限制**：默认64KB（Linux 2.6+可通过`fcntl(fd, F_SETPIPE_SZ)`调整）。

#### **底层实现**：

* **内核数据结构**：

```
struct pipe_inode_info {
    unsigned int head;      // 写指针
    unsigned int tail;      // 读指针
    struct page *pages;     // 环形缓冲区页数组
    wait_queue_head_t wait; // 读写等待队列
};
```

* **环形缓冲区**：使用16个内存页（默认64KB）组成循环队列。
* **同步机制**：

+ **写阻塞**：缓冲区满时，写入进程进入`wait`队列。
+ **读阻塞**：缓冲区空时，读取进程进入`wait`队列。
+ 使用`wake_up_interruptible()`唤醒等待进程。

---

### **四、消息队列（Message Queue）**

##### **特点**：

* **结构化数据**：每条消息有明确边界和类型标识。
* **优先级支持**：可指定消息优先级。
* **两种实现**：

+ **System V消息队列**：`msgget()`/`msgsnd()`
+ **POSIX消息队列**：`mq_open()`，更现代。

#### **底层实现**（System V）：

* **内核数据结构**：

```
struct msg_queue {
    struct kern_ipc_perm q_perm;
    struct list_head q_messages; // 消息链表
    struct list_head q_receivers;// 接收等待队列
    size_t q_cbytes;             // 当前字节数
};

struct msg_msg {          // 单个消息
    struct list_head m_list;
    long m_type;          // 消息类型
    size_t m_ts;          // 消息大小
    /* 数据跟随在此结构之后 */
};
```

* **存储管理**：消息超过4KB时分割为多个`msg_msgseg`页。
* **同步机制**：

+ `msgsnd()`在队列满时阻塞，加入`q_senders`队列。
+ `msgrcv()`在队列空时阻塞，加入`q_receivers`队列。

---

### **五、互斥锁（Mutex）**

##### **特点**：

* **二元锁**：仅允许一个线程持有锁。
* **睡眠等待**：竞争失败时线程进入睡眠，触发上下文切换。
* **优先级继承**：防止优先级反转（高优先级线程等待低优先级线程）。

#### **底层实现**（基于futex）：

* **用户态快速路径**：

```
// 无竞争时使用原子操作
atomic_cmpxchg(&lock, 0, 1);  // CAS操作尝试获取锁
```

* **内核态慢速路径**：

```
futex_wait(&lock, 1);  // 锁被占用时进入等待
futex_wake(&lock, 1);  // 释放锁时唤醒一个等待者
```

* **内核数据结构**：

```
struct mutex {
    atomic_long_t owner;      // 锁持有者任务结构指针
    spinlock_t wait_lock;     // 保护等待队列
    struct list_head wait_list; // 等待队列
};
```

---

### **六、自旋锁（Spinlock）**

#### **特点**：

* **忙等待**：线程持续检查锁状态，不释放CPU。
* **适用场景**：临界区极短（上下文切换时间）且不可睡眠（如中断上下文）。
* **无优先级继承**：可能引发优先级反转问题。

#### **底层实现**（x86）：

* **原子指令**：

```
lock; cmpxchg %edx, (%ecx)  // 原子比较交换
```

* **内核实现**：

```
typedef struct {
    volatile unsigned int lock; // 0=未锁，1=已锁
} spinlock_t;

void spin_lock(spinlock_t *lock) {
    while (atomic_xchg(&lock->lock, 1) != 0)
        cpu_relax();         // 降低CPU占用（PAUSE指令）
}
```

---

### **七、读写锁（Reader-Writer Lock）**

#### **特点**：

* **并发优化**：允许多个读线程同时访问。
* **写独占**：写锁请求会阻塞后续所有读写请求。
* **防写饥饿**：通常实现为写优先模式。

#### **底层实现**（以futex为基础）：

* **状态表示**：

```
struct rwlock {
    int readers;        // 当前读者数
    int writer;         // 写者标记（0/1）
    futex_t write_futex; // 写者等待队列
    futex_t read_futex;  // 读者等待队列
};
```

* **获取读锁**：

```
while (atomic_load(&lock->writer)) 
    futex_wait(&lock->read_futex);
atomic_inc(&lock->readers);
```

* **获取写锁**：

```
atomic_store(&lock->writer, 1);
while (atomic_load(&lock->readers) > 0)
    futex_wait(&lock->write_futex);
```

---

### **对比与选型指南**

|  |  |  |  |
| --- | --- | --- | --- |
| **机制** | **适用场景** | **性能特点** | **注意事项** |
| 共享内存 | 高频数据交换（如视频流处理） | 零拷贝，最高速 | 必须自行实现同步 |
| 信号量 | 资源池管理（如数据库连接池） | 精确控制并发数 | 复杂场景易死锁 |
| 管道 | 父子进程简单通信 | 内核自动同步 | 无消息边界，容量受限 |
| 消息队列 | 结构化跨进程通信（如任务分发） | 支持优先级和类型过滤 | 数据拷贝影响性能 |
| 互斥锁 | 通用临界区保护 | 可睡眠，支持优先级继承 | 上下文切换开销大 |
| 自旋锁 | 极短临界区（如计数器更新） | 无上下文切换开销 | 高竞争时浪费CPU |
| 读写锁 | 读多写少场景（如配置热加载） | 读并发性能优化 | 写者可能饥饿（需实现公平策略） |

---

### **底层实现关键点总结**

1. **原子操作**：所有同步机制的基石（如x86的`LOCK`前缀指令）。
2. **等待队列**：阻塞线程的管理（`wait_queue_head_t` + `wake_up()`系列函数）。
3. **内存屏障**：确保指令执行顺序（如`mb()`, `rmb()`, `wmb()`）。
4. **优先级继承**：解决优先级反转问题（如互斥锁的`PI`模式）。
5. **混合模式优化**：用户态快速路径 + 内核态慢速路径（如futex）。

---

## **四、进程调度算法**

##### **1. 实时进程调度策略**

* **SCHED\_FIFO**：

+ 优先级范围：1（低）~99（高）
+ 行为：同优先级进程按队列顺序执行，直到主动让出CPU

* **SCHED\_RR**：

+ 优先级范围同SCHED\_FIFO
+ 行为：时间片轮转（默认时间片100ms），超时后移到队列尾部

##### **2. 完全公平调度器（CFS）**

* **核心思想**：

+ 虚拟运行时间（vruntime）决定调度顺序
+ 红黑树管理可运行进程，选择vruntime最小的进程

* **vruntime计算公式**：

```
vruntime += (实际运行时间) * (NICE_0_LOAD / 权重)
```

+ **权重计算**：

```
static const int prio_to_weight[40] = {
    /* -20 */ 88761, 71755, 56483, ..., // nice值映射到权重
};
```

+ **NICE\_0\_LOAD**：1024（对应nice=0的基准权重）

* **调度周期（sched\_latency）**：

```
sysctl kernel.sched_latency_ns  # 默认值24,000,000 ns（24ms）
```

+ 每个进程分配的时间片 = 调度周期 \* (权重 / 总权重)

##### **3. 影响vruntime的因素**

1. **进程优先级（nice值）**：

+ nice值每降低1（优先级升高），权重增加约25%
+ 示例：nice=0（权重1024），nice=-5（权重2726）

2. **CPU负载**：

+ 当运行队列进程数增加，调度周期延长，每个进程时间片减少

3. **多核负载均衡**：

+ 通过`migration`内核线程迁移进程，平衡各CPU的vruntime

##### **4. 调度器决策流程**

```
// 内核调度主函数（schedule()）
prev = rq->curr;
next = pick_next_task(rq);  // 从红黑树选择最小vruntime进程
context_switch(rq, prev, next);
```

---

## **五、进程管理工具与诊断**

---

### **1. 进程状态监控命令**

```
# 查看进程树及线程
ps -eLf         # 显示所有线程（LWP列）
pstree -p       # 树形显示进程关系

# 实时监控调度信息
top -H          # 显示线程级CPU使用率
perf sched record -- sleep 1  # 记录调度事件

# 分析进程地址空间
pmap -X pid>    # 显示内存映射详情
```

### **2. 调试与性能分析**

```
# 跟踪fork调用
strace -e fork,clone,futex ./program

# 检测锁竞争
valgrind --tool=helgrind ./program

# 分析调度延迟
trace-cmd record -e sched_switch
```

---

## **六、总结与最佳实践**

---

### **1. 关键知识点**

* **进程创建**：`fork()`的COW优化与`vfork()`的阻塞特性
* **线程本质**：通过`clone()`共享资源的轻量级进程
* **同步机制**：自旋锁（短临界区） vs 信号量（长等待） vs RCU（读多写少）
* **调度策略**：实时进程（FIFO/RR）优先于普通进程（CFS）

### **2. 性能调优建议**

* **减少**`fork()`**开销**：在需要立即`exec()`时使用`vfork()`
* **避免锁竞争**：

+ 使用读写锁替代互斥锁（读多场景）
+ 缩短临界区代码（如将非关键操作移出锁外）

* **优化调度策略**：

+ 关键线程设置为`SCHED_FIFO`（需谨慎，避免饥饿）
+ 调整CFS参数（`sched_latency_ns`, `sched_min_granularity_ns`）

---

## **进程同步机制深度解析**

---

### **一、共享内存（Shared Memory）**

##### **特点**：

* **最高效的IPC方式**：直接操作内存，无需内核介入数据拷贝。
* **无结构化**：需自行设计同步机制（如配合信号量）。
* **两种实现**：

+ **System V共享内存**：`shmget()` + `shmat()`
+ **POSIX共享内存**：`shm_open()` + `mmap()`

#### **底层实现**：

* **内核数据结构**：

```
struct shmid_kernel {    // System V共享内存
    struct kern_ipc_perm shm_perm;
    struct file *shm_file;   // 关联的tmpfs文件
    unsigned long shm_nattch; // 附加计数
};
```

* **内存映射**：通过`tmpfs`文件系统实现，`shmat()`调用触发`mmap()`系统调用。

#### **同步要求**：

* **必须配合信号量/互斥锁**：因共享内存本身无同步机制。

---

### **二、信号量（Semaphore）**

##### **特点**：

* **计数同步**：可控制N个线程同时访问资源。
* **两种类型**：

+ **System V信号量**：`semget()`/`semop()`，支持信号量集。
+ **POSIX信号量**：`sem_init()`，更轻量。

#### **底层实现**（System V）：

* **内核数据结构**：

```
struct sem_array {        // 信号量集
    struct kern_ipc_perm sem_perm;
    struct sem *sems;     // 信号量数组
    struct list_head pending; // 等待队列
};

struct sem {
    int semval;           // 当前计数值
    int sempid;           // 最后操作进程PID
};
```

* **原子操作**：

+ `semop()`操作通过`ipc_lock()`锁定信号量集。
+ 修改计数值使用`ADD_VAL`原子指令。

* **等待队列**：当信号量不足时，进程加入`pending`队列，状态设为`TASK_INTERRUPTIBLE`。

---

### **三、管道（Pipe）**

##### **特点**：

* **半双工通信**：数据单向流动，需两个管道实现双向。
* **字节流传输**：无消息边界。
* **容量限制**：默认64KB（Linux 2.6+可通过`fcntl(fd, F_SETPIPE_SZ)`调整）。

#### **底层实现**：

* **内核数据结构**：

```
struct pipe_inode_info {
    unsigned int head;      // 写指针
    unsigned int tail;      // 读指针
    struct page *pages;     // 环形缓冲区页数组
    wait_queue_head_t wait; // 读写等待队列
};
```

* **环形缓冲区**：使用16个内存页（默认64KB）组成循环队列。
* **同步机制**：

+ **写阻塞**：缓冲区满时，写入进程进入`wait`队列。
+ **读阻塞**：缓冲区空时，读取进程进入`wait`队列。
+ 使用`wake_up_interruptible()`唤醒等待进程。

---

### **四、消息队列（Message Queue）**

##### **特点**：

* **结构化数据**：每条消息有明确边界和类型标识。
* **优先级支持**：可指定消息优先级。
* **两种实现**：

+ **System V消息队列**：`msgget()`/`msgsnd()`
+ **POSIX消息队列**：`mq_open()`，更现代。

#### **底层实现**（System V）：

* **内核数据结构**：

```
struct msg_queue {
    struct kern_ipc_perm q_perm;
    struct list_head q_messages; // 消息链表
    struct list_head q_receivers;// 接收等待队列
    size_t q_cbytes;             // 当前字节数
};

struct msg_msg {          // 单个消息
    struct list_head m_list;
    long m_type;          // 消息类型
    size_t m_ts;          // 消息大小
    /* 数据跟随在此结构之后 */
};
```

* **存储管理**：消息超过4KB时分割为多个`msg_msgseg`页。
* **同步机制**：

+ `msgsnd()`在队列满时阻塞，加入`q_senders`队列。
+ `msgrcv()`在队列空时阻塞，加入`q_receivers`队列。

---

### **五、互斥锁（Mutex）**

##### **特点**：

* **二元锁**：仅允许一个线程持有锁。
* **睡眠等待**：竞争失败时线程进入睡眠，触发上下文切换。
* **优先级继承**：防止优先级反转（高优先级线程等待低优先级线程）。

#### **底层实现**（基于futex）：

* **用户态快速路径**：

```
// 无竞争时使用原子操作
atomic_cmpxchg(&lock, 0, 1);  // CAS操作尝试获取锁
```

* **内核态慢速路径**：

```
futex_wait(&lock, 1);  // 锁被占用时进入等待
futex_wake(&lock, 1);  // 释放锁时唤醒一个等待者
```

* **内核数据结构**：

```
struct mutex {
    atomic_long_t owner;      // 锁持有者任务结构指针
    spinlock_t wait_lock;     // 保护等待队列
    struct list_head wait_list; // 等待队列
};
```

---

### **六、自旋锁（Spinlock）**

#### **特点**：

* **忙等待**：线程持续检查锁状态，不释放CPU。
* **适用场景**：临界区极短（上下文切换时间）且不可睡眠（如中断上下文）。
* **无优先级继承**：可能引发优先级反转问题。

#### **底层实现**（x86）：

* **原子指令**：

```
lock; cmpxchg %edx, (%ecx)  // 原子比较交换
```

* **内核实现**：

```
typedef struct {
    volatile unsigned int lock; // 0=未锁，1=已锁
} spinlock_t;

void spin_lock(spinlock_t *lock) {
    while (atomic_xchg(&lock->lock, 1) != 0)
        cpu_relax();         // 降低CPU占用（PAUSE指令）
}
```

---

### **七、读写锁（Reader-Writer Lock）**

#### **特点**：

* **并发优化**：允许多个读线程同时访问。
* **写独占**：写锁请求会阻塞后续所有读写请求。
* **防写饥饿**：通常实现为写优先模式。

#### **底层实现**（以futex为基础）：

* **状态表示**：

```
struct rwlock {
    int readers;        // 当前读者数
    int writer;         // 写者标记（0/1）
    futex_t write_futex; // 写者等待队列
    futex_t read_futex;  // 读者等待队列
};
```

* **获取读锁**：

```
while (atomic_load(&lock->writer)) 
    futex_wait(&lock->read_futex);
atomic_inc(&lock->readers);
```

* **获取写锁**：

```
atomic_store(&lock->writer, 1);
while (atomic_load(&lock->readers) > 0)
    futex_wait(&lock->write_futex);
```

---

### **对比与选型指南**

|  |  |  |  |
| --- | --- | --- | --- |
| **机制** | **适用场景** | **性能特点** | **注意事项** |
| 共享内存 | 高频数据交换（如视频流处理） | 零拷贝，最高速 | 必须自行实现同步 |
| 信号量 | 资源池管理（如数据库连接池） | 精确控制并发数 | 复杂场景易死锁 |
| 管道 | 父子进程简单通信 | 内核自动同步 | 无消息边界，容量受限 |
| 消息队列 | 结构化跨进程通信（如任务分发） | 支持优先级和类型过滤 | 数据拷贝影响性能 |
| 互斥锁 | 通用临界区保护 | 可睡眠，支持优先级继承 | 上下文切换开销大 |
| 自旋锁 | 极短临界区（如计数器更新） | 无上下文切换开销 | 高竞争时浪费CPU |
| 读写锁 | 读多写少场景（如配置热加载） | 读并发性能优化 | 写者可能饥饿（需实现公平策略） |

---

### **底层实现关键点总结**

1. **原子操作**：所有同步机制的基石（如x86的`LOCK`前缀指令）。
2. **等待队列**：阻塞线程的管理（`wait_queue_head_t` + `wake_up()`系列函数）。
3. **内存屏障**：确保指令执行顺序（如`mb()`, `rmb()`, `wmb()`）。
4. **优先级继承**：解决优先级反转问题（如互斥锁的`PI`模式）。
5. **混合模式优化**：用户态快速路径 + 内核态慢速路径（如futex）。

## 五、源码解析和实践感悟

### 5.1 源码解析

#### CFS 调度器的 vruntime 与红黑树——最核心调度逻辑

```c
// kernel/sched/fair.c——CFS 调度入口
static struct task_struct *pick_next_task_fair(struct rq *rq) {
    struct cfs_rq *cfs_rq = &rq->cfs;
    struct sched_entity *se = __pick_first_entity(cfs_rq);
    if (!se) return NULL;
    return task_of(se);
}

static void update_curr(struct cfs_rq *cfs_rq) {
    u64 delta_exec = now - curr->exec_start;
    curr->vruntime += calc_delta_fair(delta_exec, curr);
    if (entity_before(curr, __pick_first_entity(cfs_rq)))
        resched_curr(rq_of(cfs_rq));
}
```

CFS 核心：`vruntime` = 实际运行时间 × (1024 / 权重)，nice 值越低权重越大 vruntime 增长越慢。每次选 vruntime 最小进程运行——红黑树 O(log n) 保证调度延迟可控。

#### fork() 的 COW 内核路径

```c
// mm/memory.c——COW 缺页处理
static vm_fault_t do_wp_page(struct vm_fault *vmf) {
    if (page_count(vmf->page) == 1)
        return reuse_page(vma, vmf);
    new_page = alloc_page_vma(GFP_HIGHUSER_MOVABLE, vma, vmf->address);
    copy_user_highpage(new_page, vmf->page, vmf->address, vma);
    set_pte_at(vma->vm_mm, vmf->address, vmf->pte, 
               mk_pte(new_page, vma->vm_page_prot) | _PAGE_RW);
    put_page(vmf->page);
}
```

fork 后父子共享只读页，第一个写入触发 `do_wp_page` 分配新页——另一个进程仍用原页。

#### 上下文切换中 CR3 的开销

进程切换必须换 CR3 → TLB 全失效 → ~几百 cycles 额外开销。线程切换共享地址空间跳过了 CR3 切换——比进程切换快 5-10 倍。

### 5.2 实践经验

1. **fork 后立即 exec 的优化**：用 `vfork` + COW 配合 `exec` 避免无意义的内存复制
2. **nice 值不是简单的优先级**：nice(-20) 权重是 nice(19) 的 36 倍
3. **CFS 延迟目标**：`sysctl_sched_latency`（默认 6ms）保证交互式响应
4. **进程 TLB 开销**：大型应用（>1GB 内存）切换开销可达 5-10μs
5. **futex 是用户态锁的基础**：`pthread_mutex` 竞争路径最终调用 `futex(FUTEX_WAIT)`
6. **task_struct 用 slab 分配**：内核缓存复用，减少碎片

## 六、面试准备

### 6.1 面试 Q&A

**Q1: fork() 后父子进程共享什么？不共享什么？**

共享：代码段、已映射文件、文件描述符（引用计数+1）。不共享：地址空间逻辑独立（COW）、PID、信号挂起队列。

**Q2: 写时复制（COW）的内核实现细节？**

fork 时拷贝页表而非物理页，PTE 标记只读。任一写入触发缺页异常 → `do_wp_page`：引用计数==1 直接可写，>1 分配新页复制。

**Q3: CFS 调度算法的核心思想？**

每个进程有 `vruntime`（= 运行时间 × 1024/权重），CFS 始终选 vruntime 最小的运行。nice 低权重高→vruntime 增长慢→更多 CPU 时间。

**Q4: 进程上下文切换的完整流程和开销？**

保存寄存器 → 切换页表 CR3 → 恢复寄存器 → 切换栈。开销 ~1-5μs，线程切换（不切 CR3）快 5-10 倍。

**Q5: 用户态和内核态的切换如何发生？**

三种：系统调用（同步）、中断（异步硬件）、异常（同步）。CPU 自动压栈 SS/RSP/CS/RIP，切换内核栈。

**Q6: CFS 红黑树为什么用 vruntime 而非实际时间作键？**

实际时间相同但权重不同不公平。vruntime 按权重归一化，vruntime 相等 = 真正公平。

**Q7: 僵尸进程和孤儿进程的区别？**

僵尸：子进程结束父进程未 wait——task_struct 残留。孤儿：父进程先于子进程死——init 收养并回收。

**Q8: futex 如何实现用户态锁？**

快路径：用户态 CAS，不涉及内核。慢路径：`futex(FUTEX_WAIT)` 内核挂起。解锁 `FUTEX_WAKE` 唤醒。

### 6.2 常见陷阱与面试反问

1. **陷阱**：fork 后共享 FILE* 导致输出混乱。**修复**：fork 前 `fflush(stdout)`。

2. **陷阱**：多线程 fork——子进程只有调用线程存活，其他消失可能持有锁。**修复**：用 `pthread_atfork` 或子进程立即 exec。

3. **陷阱**：短命进程池 fork+exec 开销大。**修复**：用 `posix_spawn`。

4. **反问**：「为什么 Linux 用 CFS？」希望听到：O(1) 交互场景不公平，CFS 的 vruntime 保证长时间公平。

5. **反问**：「为什么线程切换比进程快？」希望听到：共享地址空间→不换 CR3→TLB 不刷新。

### 6.3 一句话答案速记

| 问题 | 一句话答案 |
|------|------------|
| task_struct？ | 内核描述进程核心结构体，含状态/PID/内存/文件 |
| fork() 核心？ | copy_process 克隆 task_struct + COW 共享页 |
| COW 原理？ | fork 共享只读页，写入缺页触发物理页复制 |
| CFS 调度？ | 选 vruntime 最小进程，nice 低权重高增长慢 |
| 上下文切换开销？ | 进程 ~1-5μs（含 TLB flush），线程 ~0.2μs |
| 用户态→内核态？ | syscall / 中断 / 异常 |
| 僵尸进程？ | 子死父未 wait，task_struct 未释放 |
| futex？ | 用户 CAS 快路径 + 内核等待队列慢路径 |
