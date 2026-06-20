---
title: epoll
date: 2026-06-20
categories:
  - ["C++知识库", "C++语言核心", "网络编程"]
publish: true
---

# epoll

> 适用范围：Linux I/O多路复用、epoll 事件驱动机制、epoll_create/epoll_ctl/epoll_wait 系统调用、LT与ET触发模式、eventpoll/epitem 内核源码实现

## 一、核心概念

- **定义**：epoll 是 Linux 内核提供的可扩展 I/O 多路复用机制，用于高效监视大量文件描述符上的 I/O 事件。与 select/poll 的轮询遍历不同，epoll 采用事件驱动+回调机制，通过红黑树管理监视集、就绪链表交付激活事件，实现 O(1) 就绪获取
- **关键词**：eventpoll、epitem、红黑树(rbr)、就绪链表(rdllist)、ep_poll_callback、水平触发(LT)、边缘触发(ET)、EPOLLONESHOT、EPOLLEXCLUSIVE、ovflist
- **适用场景/边界**：
  - 高并发网络服务器（C10K/C100K 的经典解决方案）
  - 需要同时监视大量 socket fd 且只有少数活跃的场景
  - 边界：仅 Linux 平台可用（BSD 用 kqueue，Windows 用 IOCP）；主要优化网络 socket，对普通文件（磁盘文件总是就绪）支持有限

## 二、详细解析（≥200字）

epoll 并不是对 select 和 poll 的缝缝补补，而是全新的架构，但是其底层仍然是文件系统的 poll 机制和等待队列。

select 和 poll 是无状态的，每次调用都需要将需要监视的 fd 从用户空间拷贝到内核，完成时将整个数据再次拷贝回用户空间，拷回的并不是就绪的 fd，而是所有的 fd，用户需要遍历才能获取哪个 fd 就绪了。

epoll 是有状态的，每个 epoll 在内核中都记录了需要监视的 fd，调用 epoll\_ctl(2) 注册事件的时候将相关数据拷入内核，以后调用 epoll\_wait(2) 不会像 select(2) 或 poll(2) 那样，每次都从用户空间拷贝数据到内核空间，并且 epoll\_wait(2) 返回的是就绪的 fd。

```
#include <sys/epoll.h>
int epoll_create(int size);
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
int epoll_wait(int epfd, struct epoll_event *events, 
               int maxevents, int timeout);

/// include/uapi/linux/eventpoll.h
typedef union epoll_data
{
    void *ptr;
    int fd;
    uint32_t u32;
    uint64_t u64;
} epoll_data_t;

struct epoll_event
{
    uint32_t events;      /* IO 事件 */
    epoll_data_t data;    /* User data variable */
} __EPOLL_PACKED;
```

### epoll\_create() 做了什么

如前文所说，epoll 是有状态的，epoll(7) 在内核中会保存需要监视事件（文件和期望的就绪状态），可以通过 epoll\_ctl(2) 来完成监听事件的添加、修改和移除。所以需要某种方法标识每一个 epoll 实例，以区分不同的 epoll 实例。

按照 Linux 一切皆文件的思想，epoll 是借助虚拟文件系统，通过文件描述符来标识每一个 epoll 实例。epoll 使用 eventpoll 顶层结果管理所有的事件。

#### eventpoll

一切皆文件，创建 eventpoll 对象会绑定一个匿名文件的 file 对象。我们可以像操作文件一样操作 eventpoll 对象。struct file 结构中 private\_data 指向的是文件系统私有数据，eventpoll 就是挂到 private\_data 指针上。其总体布局如下所示：

![](../../资源/图片/yuque_309f0692223a.webp)

eventpoll 结构几个成员简单备注一下

* **1）wq：等待队列，调用 epoll\_wait() 的进程会被挂在上面；**
* **2）poll\_wait：epoll 文件的等待队列。epfd 也可以注册到其他 epoll 中；**
* **3）rdllist：就绪队列，epoll\_wait() 将 rdllist 链表上就绪事件拷贝到用户空间返回；**
* **4）rbr：红黑树根节点，所有 epitem 都在一棵红黑树上；**
* **5）ovflist：当 rdllist 正在使用时（占用 lock），就绪的事件添加到 ovflist 链表上；**

```
/// fs/eventpoll.c
struct eventpoll {
    struct mutex mtx;
    /* epoll_wait 的等待队列 */
    wait_queue_head_t wq;
    /* epoll 的等待队列 */
    wait_queue_head_t poll_wait;
    /* 就绪事件链表 */
    struct list_head rdllist;
    /* 保护 rdllist and ovflist */
    rwlock_t lock;
    /* 红黑树根节点，管理所有 fd */
    struct rb_root_cached rbr;
    /* 备用就绪队列，在 fdllist 占用 lock 时被使用 */
    struct epitem *ovflist;
    /* wakeup_source used when ep_scan_ready_list is running */
    struct wakeup_source *ws;
    /* The user that created the eventpoll descriptor */
    struct user_struct *user;
    /* eventpoll 归属的文件 */
    struct file *file;
    /* used to optimize loop detection check */
    u64 gen;

    #ifdef CONFIG_NET_RX_BUSY_POLL
    /* used to track busy poll napi_id */
    unsigned int napi_id;
    #endif

    #ifdef CONFIG_DEBUG_LOCK_ALLOC
    /* tracks wakeup nests for lockdep validation */
    u8 nests;
    #endif
};
```

总结一下：eventpoll 结构体管理所有的监视事件：

* 1）所有监视事件用红黑树串联起来
* 2）一切皆文件，创建 eventpoll 对象会绑定一个匿名文件的 file 对象。我们可以像操作文件一样操作 eventpoll 对象。

**ep\_alloc()** 用于申请一个 eventpoll 对象，ovflist 被初始化为 EP\_UNACTIVE\_PTR，当 rdllist 在使用时，ovflist 被修改为 NULL，开始暂时接受就绪事件。

```
/// fs/eventpoll.c
static int ep_alloc(struct eventpoll **pep)
{
    int error;
    struct user_struct *user;
    struct eventpoll *ep;

    user = get_current_user();
    error = -ENOMEM;
    ep = kzalloc(sizeof(*ep), GFP_KERNEL); // 申请 epitem 实例
    if (unlikely(!ep))
        goto free_uid;

    mutex_init(&ep->mtx);
    rwlock_init(&ep->lock);
    init_waitqueue_head(&ep->wq);
    init_waitqueue_head(&ep->poll_wait);
    INIT_LIST_HEAD(&ep->rdllist);
    ep->rbr = RB_ROOT_CACHED;
    ep->ovflist = EP_UNACTIVE_PTR; // 未使用
    ep->user = user;

    *pep = ep;

    return 0;

    free_uid:
    free_uid(user);
    return error;
}
```

#### epitem

向 epoll 注册的 fd，epoll 都使用 epitem 表示。epoll 中所有的 epitem 用红黑树串联起来。

* **rbn 是红黑树节点，挂在红黑树上**
* **rdllink 是就绪队列，所有就绪的 epitem 连接成链表**
* **pwqlist 连接 eppoll\_entry**

```
/// fs/eventpoll.c
struct epitem {
    union {
        struct rb_node rbn; // 挂到红黑树上
        struct rcu_head rcu; // 释放 epitem 时使用
    };

    struct list_head rdllink; // 挂到就绪队列 
    struct epitem *next; // 挂到备用队列
    struct epoll_filefd ffd; // 包含 file 和 fd

    /* Number of active wait queue attached to poll operations */
    int nwait;

    /* List containing poll wait queues */
    struct list_head pwqlist;

    struct eventpoll *ep; // 所属 eventpoll

    /* List header used to link this item to the "struct file" items list */
    struct list_head fllink; // 链接所有 file

    /* wakeup_source used when EPOLLWAKEUP is set */
    struct wakeup_source __rcu *ws;
    struct epoll_event event; // 监视事件
};
```

#### epoll\_create()

可以看到 size 参数没有任何作用，只要大于 0 就行。

```
/// fs/eventpoll.c
SYSCALL_DEFINE1(epoll_create, int, size)
{
    if (size <= 0)
        return -EINVAL;

    return do_epoll_create(0);
}
```

do\_epoll\_create() 函数做三件事：

* **1）调用 ep\_alloc() 申请一个 eventpoll 对象；**
* **2）调用 get\_unused\_fd\_flags() 获取一个 fd；**
* **3）调用 anon\_inode\_getfile() 从匿名文件系统申请一个 file 对象，filp->private\_data 指向 eventpoll 对象；另外文件系统 file\_operations 是 eventpoll\_fops；**

![](../../资源/图片/yuque_5e79e297f603.webp)

```
/// fs/eventpoll.c
static int do_epoll_create(int flags)
{
    int error, fd;
    struct eventpoll *ep = NULL;
    struct file *file;
    // ...
    error = ep_alloc(&ep); // 申请一个 eventpoll 对象
    if (error < 0)
        return error;
    // 申请一个未使用的 fd
    fd = get_unused_fd_flags(O_RDWR | (flags & O_CLOEXEC));
    if (fd < 0) {
        error = fd;
        goto out_free_ep;
    }
    // 匿名文件，文件操作是 eventpoll_fops
    file = anon_inode_getfile("[eventpoll]", &eventpoll_fops, ep,
                              O_RDWR | (flags & O_CLOEXEC));
    if (IS_ERR(file)) {
        error = PTR_ERR(file);
        goto out_free_fd;
    }
    ep->file = file; // 绑定 file 实例
    fd_install(fd, file);
    return fd;

    out_free_fd:
    put_unused_fd(fd);
    out_free_ep:
    ep_free(ep);
    return error;
}
```

anon\_inode\_getfile() 函数不会申请 inode，而是使用匿名文件统一的 inode。然后调用 alloc\_file\_pseudo() 申请一个 file 对象，private\_data 指向 eventpoll 对象。

eventpoll\_fops.poll 指向的是 ep\_eventpoll\_poll 函数。

```
/// fs/eventpoll.c
static const struct file_operations eventpoll_fops = {
    #ifdef CONFIG_PROC_FS
    .show_fdinfo	= ep_show_fdinfo,
    #endif
    .release	= ep_eventpoll_release,
    .poll		= ep_eventpoll_poll,
    .llseek		= noop_llseek,
};
```

根据 f\_op 是否执行 eventpoll\_fops，可以判断 file 是否是被 epoll 绑定。

```
/// fs/eventpoll.c
static inline int is_file_epoll(struct file *f)
{
    return f->f_op == &eventpoll_fops;
}
```

epoll\_create(2) 系统调用完成了 fd、file 和 eventpoll 三个对象之间的关联，并将 fd 返回给用户态应用程序。每一个 fd 都会对应一个 eventpoll 对象，用户通过 fd 可以将需要监视的目标事件添加到 eventpoll 中。

### epoll 为什么高效

前文讲到，epoll\_wait 返回的是就绪的 fd，而不是全部的监视 fd，减少了用户遍历的时间。

另外一点，不需要像 select 和 poll 那样需要遍历整个 fd 集合，核查是否就绪才将其移动到就绪队列。epoll 不需要遍历所有监视的 fd，就能获取就绪的 fd。目标文件就绪事件发生后，就将对应的 epitem 挂到就绪队列上了，epoll 直接检查就绪队列就可以了，所以 epoll 很高效。这是如何做到的呢？

我们提前看看向 epoll 注册 fd 时，调用 vfs\_poll() 获取文件状态时，回调函数是如何设置的。

```
/// fd/eventpoll.c
static int ep_insert(struct eventpoll *ep, const struct epoll_event *event,
                     struct file *tfile, int fd, int full_check)
{
    // ...
    struct epitem *epi;
    struct ep_pqueue epq;
    // ...
    epq.epi = epi;
    // 设置 poll 机制的回调函数
    init_poll_funcptr(&epq.pt, ep_ptable_queue_proc);
    // 调用 vs_poll
    revents = ep_item_poll(epi, &epq.pt, 1);
    // ...
}
```

ep\_pqueue 就是封装了 poll\_table 和 epitem，这样可以很好地通过 pt 找到对应的 epitem

```
/// fs/eventpoll.c
struct ep_pqueue {
    poll_table pt;
    struct epitem *epi;
};
```

#### ep\_item\_poll()

因为 epoll 实例也可以被添加到其他 epoll 实例中（但是不能添加到自己），所以 ep\_item\_poll 需要区分普通文件和 epoll 文件。

* 对于普通文件，调用 vfs\_poll 使用其 pull 机制
* 对于 epfd 文件，直接调用 poll\_wait() 函数，然后遍历目标 epoll 实例的 rdllist

首先查看普通文件的操作，vfs\_poll() 函数会调用 file->f\_op->poll 指向的函数。在 poll 机制的文章中，分析到最后回调用 poll\_table 设置的回调函数，在这里，也就是 ep\_ptable\_queue\_proc() 函数。

如果是 epoll 文件，不使用 file\_operation::poll 指向的函数，直接使用 poll\_wait() 函数，然后检查就绪队列是否有就绪事件。

```
/// fs/eventpoll.c
static __poll_t ep_item_poll(const struct epitem *epi, poll_table *pt,
                             int depth)
{
    struct eventpoll *ep;
    bool locked;

    pt->_key = epi->event.events; // 等待事件
    if (!is_file_epoll(epi->ffd.file)) // 非 epoll 文件，走 vfs
        return vfs_poll(epi->ffd.file, pt) & epi->event.events;
    // epoll 文件，调用 poll_wait
    // 将 epi 挂到目标 epoll 实例的 poll_wait 等待队列上
    ep = epi->ffd.file->private_data;
    poll_wait(epi->ffd.file, &ep->poll_wait, pt);
    locked = pt && (pt->_qproc == ep_ptable_queue_proc);
    // 检查目标 epoll 实例是否有就绪事件
    return ep_scan_ready_list(epi->ffd.file->private_data,
                              ep_read_events_proc, &depth, depth,
                              locked) & epi->event.events;
}
```

#### ep\_ptable\_queue\_proc()

ep\_ptable\_queue\_proc() 将一个 eppoll\_entry 对象挂到某个文件（监视的文件）的等待队列上，并且设置就绪事件发生时，调用的函数是 ep\_poll\_callback() 函数。

这里不太明白 pwqlist 作用，难道不是只有一个 eppoll\_entry 吗？

```
/// fs/eventpoll.c
static void ep_ptable_queue_proc(struct file *file, wait_queue_head_t *whead,
                                 poll_table *pt)
{
    struct epitem *epi = ep_item_from_epqueue(pt);
    struct eppoll_entry *pwq;

    if (epi->nwait >= 0 && (pwq = kmem_cache_alloc(pwq_cache, GFP_KERNEL))) {
        init_waitqueue_func_entry(&pwq->wait, ep_poll_callback);
        pwq->whead = whead;
        pwq->base = epi;
        if (epi->event.events & EPOLLEXCLUSIVE)
            add_wait_queue_exclusive(whead, &pwq->wait);
        else
            add_wait_queue(whead, &pwq->wait);
        list_add_tail(&pwq->llink, &epi->pwqlist);
        epi->nwait++;
    } else {
        /* We have to signal that an error occurred */
        epi->nwait = -1;
    }
}
```

pt->\_qproc 只有在 ep\_insert() 函数中被赋值，指向 ep\_ptable\_queue\_proc() 函数，其他时候调用时，其为 NULL。当 \_qproc 为 NULL 时，poll\_wait() 只获取文件事件状态。

eppoll\_entry 也是为了从 wait 找到对应的 epitem

```
/// fs/eventpoll.c
struct eppoll_entry {
    struct list_head llink; // 连接 epitem::pwdlist
    struct epitem *base; // 所属的 epitem
    wait_queue_entry_t wait; // 挂到等待队列上
    wait_queue_head_t *whead; // 挂在哪个等待队列上
};
```

#### ep\_poll\_callback()

回调函数 ep\_poll\_callback() 在事件就绪后，将对应的 epitem 对象添加到 eventpoll 的就绪链表中，然后唤醒阻塞的进程，包括阻塞在 epoll\_wait() 系统调用的进程，以及监视 epollfd 的其他 epoll 实例。

```
/// fs/eventpoll.c
static int ep_poll_callback(wait_queue_entry_t *wait, unsigned mode, int sync, void *key)
{
    int pwake = 0;
    struct epitem *epi = ep_item_from_wait(wait);
    struct eventpoll *ep = epi->ep;
    __poll_t pollflags = key_to_poll(key); // 发生的事件
    unsigned long flags;
    int ewake = 0;

    read_lock_irqsave(&ep->lock, flags);

    ep_set_busy_poll_napi_id(epi);

    if (!(epi->event.events & ~EP_PRIVATE_BITS)) // 没有事件，返回
        goto out_unlock;

    // 不是监视的事件，返回
    if (pollflags && !(pollflags & epi->event.events))
        goto out_unlock;

    // 获取备用队列 ovflist 的状态，如果被启用，就使用 ovflist
    if (READ_ONCE(ep->ovflist) != EP_UNACTIVE_PTR) {
        if (chain_epi_lockless(epi)) // 添加到 ovflist 链表（无锁操作）
            ep_pm_stay_awake_rcu(epi);
    } else if (!ep_is_linked(epi)) { // 添加到 rdllink（无锁操作）
        if (list_add_tail_lockless(&epi->rdllink, &ep->rdllist))
            ep_pm_stay_awake_rcu(epi);
    }

    // 唤醒调用 epoll_wiat() 被阻塞的进程
    if (waitqueue_active(&ep->wq)) { // 有阻塞的进程
        if ((epi->event.events & EPOLLEXCLUSIVE) &&
            !(pollflags & POLLFREE)) {
            switch (pollflags & EPOLLINOUT_BITS) {
                case EPOLLIN:
                    if (epi->event.events & EPOLLIN)
                        ewake = 1;
                    break;
                case EPOLLOUT:
                    if (epi->event.events & EPOLLOUT)
                        ewake = 1;
                    break;
                case 0:
                    ewake = 1;
                    break;
            }
        }
        wake_up(&ep->wq); // 唤醒
    }
    // 唤醒监视 epoll 的其他 epoll 实例
    if (waitqueue_active(&ep->poll_wait)) // 有阻塞的进程
        pwake++;

    out_unlock:
    read_unlock_irqrestore(&ep->lock, flags);

    /* We have to call this outside the lock */
    if (pwake)
        ep_poll_safewake(ep, epi); // 唤醒

    if (!(epi->event.events & EPOLLEXCLUSIVE))
        ewake = 1;

    if (pollflags & POLLFREE) {
        /*
         * If we race with ep_remove_wait_queue() it can miss
         * ->whead = NULL and do another remove_wait_queue() after
         * us, so we can't use __remove_wait_queue().
         */
        list_del_init(&wait->entry);
        /*
         * ->whead != NULL protects us from the race with ep_free()
         * or ep_remove(), ep_remove_wait_queue() takes whead->lock
         * held by the caller. Once we nullify it, nothing protects
         * ep/epi or even wait.
         */
        smp_store_release(&ep_pwq_from_wait(wait)->whead, NULL);
    }

    return ewake;
}
```

#### ep\_scan\_ready\_list()

ep\_scan\_ready\_list() 遍历就绪链表 rdllist

* 1）处理 rdllist 就绪链表。为了减少对 ep->lock 锁的占用，ep\_scan\_ready\_list() 会先将 rdllist 链表替换出来，然后将 ovflist 赋值为 NULL。后续就绪的事件会添加到 ovflist 链表上，而不用获取锁。
* 2）处理 ovflist 链表。当 rdllist 链表处理完，接着处理 ovflist 上的就绪链表。处理 ovflist 链表时，lock 锁一直被占用。
* 3）将处理后的就绪链表，再次替换到 rdllist 链表。此时 rdllist 链表上都是就绪的。

```
/// fs/eventpoll.c
static __poll_t ep_scan_ready_list(struct eventpoll *ep,
                                   __poll_t (*sproc)(struct eventpoll *,
                                    struct list_head *, void *),
                                   void *priv, int depth, bool ep_locked)
{
    __poll_t res;
    struct epitem *epi, *nepi;
    LIST_HEAD(txlist);

    lockdep_assert_irqs_enabled();

    if (!ep_locked)
        mutex_lock_nested(&ep->mtx, depth); // 获取 mtx

    // 将 rddlist 替换成 txlist 空链表
    write_lock_irq(&ep->lock);
    list_splice_init(&ep->rdllist, &txlist);
    WRITE_ONCE(ep->ovflist, NULL); // 启用 ovflist
    write_unlock_irq(&ep->lock);

    // 处理就绪队列
    res = (*sproc)(ep, &txlist, priv);

    write_lock_irq(&ep->lock);
    // 处理 rdllist 期间，ovflist 可能有新的就绪事件，将其移动到 rdllist
    for (nepi = READ_ONCE(ep->ovflist); (epi = nepi) != NULL;
         nepi = epi->next, epi->next = EP_UNACTIVE_PTR) {
        if (!ep_is_linked(epi)) {
            list_add(&epi->rdllink, &ep->rdllist); // 添加到 rdlist
            ep_pm_stay_awake(epi);
        }
    }
    WRITE_ONCE(ep->ovflist, EP_UNACTIVE_PTR); // 弃用 ovflist
    list_splice(&txlist, &ep->rdllist); // txlist 添加到 rdlist
    __pm_relax(ep->ws);

    if (!list_empty(&ep->rdllist)) { // rdlist 不为空
        if (waitqueue_active(&ep->wq))
            wake_up(&ep->wq); // 唤醒阻塞在 epoll_wait() 的进程
    }

    write_unlock_irq(&ep->lock);

    if (!ep_locked)
        mutex_unlock(&ep->mtx);

    return res;
}
```

### epoll\_ctl()

epoll\_ctl() 负责添加、修改和移除 fd。首先将 fd 集合从用户空间拷贝到内核空间。

```
/// fs/eventpoll.c
SYSCALL_DEFINE4(epoll_ctl, int, epfd, int, op, int, fd,
                struct epoll_event __user *, event)
{
    struct epoll_event epds;

    if (ep_op_has_event(op) &&
        copy_from_user(&epds, event, sizeof(struct epoll_event)))
        return -EFAULT;

    return do_epoll_ctl(epfd, op, fd, &epds, false);
}
```

在添加监视事件的时候，首先要保证没有注册过，如果存在，返回 -EEXIST 错误。不过，检测是否注册不仅仅依靠文件描述符，还会查看其绑定的 file 对象的地址。添加到 epoll 的 fd，默认监听 POLLERR 和 POLLHUP 事件。

```
/// fs/eventpoll.c
int do_epoll_ctl(int epfd, int op, int fd, struct epoll_event *epds,
                 bool nonblock)
{
    int error;
    int full_check = 0;
    struct fd f, tf;
    struct eventpoll *ep;
    struct epitem *epi;
    struct eventpoll *tep = NULL;

    error = -EBADF;
    f = fdget(epfd); // epoll 绑定的 file
    // ...

    tf = fdget(fd); // 目标文件绑定的 file
    // ...

    error = -EINVAL;
    if (f.file == tf.file || !is_file_epoll(f.file))
        goto error_tgt_fput; // 不能监视自己

    // ...
    ep = f.file->private_data;
    // ...

    epi = ep_find(ep, tf.file, fd); // 在红黑树查找 fd

    error = -EINVAL;
    switch (op) {
        case EPOLL_CTL_ADD:
            if (!epi) { // ADD 操作并且没有注册，执行 ep_insert 插入
                epds->events |= EPOLLERR | EPOLLHUP;
                error = ep_insert(ep, epds, tf.file, fd, full_check);
            } else // 已经存在，返回错误
                error = -EEXIST;
            break;
        case EPOLL_CTL_DEL: 
            if (epi) // DEL 操作并且存在，执行 ep_remove 删除
                error = ep_remove(ep, epi);
            else // 不存在，返回错误
                error = -ENOENT;
            break;
        case EPOLL_CTL_MOD:
            if (epi) { // MOD 操作并且，存在
                if (!(epi->event.events & EPOLLEXCLUSIVE)) {
                    epds->events |= EPOLLERR | EPOLLHUP;
                    error = ep_modify(ep, epi, epds); // 修改 ep_insert
                }
            } else // 不存在，返回错误
                error = -ENOENT;
            break;
    }
    if (tep != NULL)
        mutex_unlock(&tep->mtx);
    mutex_unlock(&ep->mtx);

    // ...
}
```

#### ep\_insert()

ep\_insert() 函数，其函数核心的两个工作是：

* 将回调函数加入到要监视的文件文件描述符的等待队列上
* 将要监听事件插入到的红黑树里面

```
/// fs/eventpoll.c
static int ep_insert(struct eventpoll *ep, const struct epoll_event *event,
                     struct file *tfile, int fd, int full_check)
{
    int error, pwake = 0;
    __poll_t revents;
    long user_watches;
    struct epitem *epi;
    struct ep_pqueue epq;

    // ... 分配 epitem
    if (!(epi = kmem_cache_alloc(epi_cache, GFP_KERNEL)))
        return -ENOMEM;

    INIT_LIST_HEAD(&epi->rdllink);
    INIT_LIST_HEAD(&epi->fllink);
    INIT_LIST_HEAD(&epi->pwqlist);
    epi->ep = ep;
    ep_set_ffd(&epi->ffd, tfile, fd); // 设置监视文件
    epi->event = *event; // 设置监视事件
    epi->nwait = 0;
    epi->next = EP_UNACTIVE_PTR;
    if (epi->event.events & EPOLLWAKEUP) {
        error = ep_create_wakeup_source(epi);
        if (error)
            goto error_create_wakeup_source;
    } else {
        RCU_INIT_POINTER(epi->ws, NULL);
    }

    // 将 epitem 添加到 file 的 f_ep_links 链表中
    spin_lock(&tfile->f_lock);
    list_add_tail_rcu(&epi->fllink, &tfile->f_ep_links);
    spin_unlock(&tfile->f_lock);

    ep_rbtree_insert(ep, epi); // 插入到红黑树

    // ... 使用 poll 机制
    epq.epi = epi;
    init_poll_funcptr(&epq.pt, ep_ptable_queue_proc);
    revents = ep_item_poll(epi, &epq.pt, 1); // 获取文件状态

    // ... 添加到就绪链表
    if (revents && !ep_is_linked(epi)) {
        list_add_tail(&epi->rdllink, &ep->rdllist);
        ep_pm_stay_awake(epi);

        /* Notify waiting tasks that events are available */
        if (waitqueue_active(&ep->wq))
            wake_up(&ep->wq);
        if (waitqueue_active(&ep->poll_wait))
            pwake++;
    }

    write_unlock_irq(&ep->lock);

    atomic_long_inc(&ep->user->epoll_watches);

    if (pwake)
        ep_poll_safewake(ep, NULL);

    return 0;
    // ...
}
```

ep\_ptable\_queue\_proc() 在调用 ep\_scan\_ready\_list() 函数时，传入了 ep\_read\_events\_proc() 函数。该函数遍历传入的链表，都调用 ep\_item\_poll() 处理，如果有一个文件就绪，就返回。没有就绪事件的 epi，从就绪链表中删除。

```
/// fs/eventpoll.c
static __poll_t ep_read_events_proc(struct eventpoll *ep, struct list_head *head,
                                    void *priv)
{
    struct epitem *epi, *tmp;
    poll_table pt;
    int depth = *(int *)priv;

    init_poll_funcptr(&pt, NULL); // 仅仅获取文件事件状态
    depth++;

    list_for_each_entry_safe(epi, tmp, head, rdllink) {
        if (ep_item_poll(epi, &pt, depth)) { // 有就绪事件，返回
            return EPOLLIN | EPOLLRDNORM;
        } else { // 没有就绪事件，从就绪队列删除
            __pm_relax(ep_wakeup_source(epi));
            list_del_init(&epi->rdllink); // 没有就绪事件，删除
        }
    }

    return 0;
}
```

#### ep\_remove()

ep\_remove 负责将 fd 从 epoll 中移除。首先取消所有监视的事件，解除和 file 绑定；然后从红黑树中移除；最后从就绪队列（如果存在的话）移除。

```
/// fs/eventpoll.c
static int ep_remove(struct eventpoll *ep, struct epitem *epi)
{
    struct file *file = epi->ffd.file;

    lockdep_assert_irqs_enabled();

    // 取消所有监视的事件
    ep_unregister_pollwait(ep, epi);
    // 和 file 解除绑定
    spin_lock(&file->f_lock);
    list_del_rcu(&epi->fllink); 
    spin_unlock(&file->f_lock);
    // 从红黑树中移除
    rb_erase_cached(&epi->rbn, &ep->rbr);
    // 从就绪队列 rdllikn 移除
    write_lock_irq(&ep->lock);
    if (ep_is_linked(epi))
        list_del_init(&epi->rdllink);
    write_unlock_irq(&ep->lock);

    wakeup_source_unregister(ep_wakeup_source(epi));

    call_rcu(&epi->rcu, epi_rcu_free);

    atomic_long_dec(&ep->user->epoll_watches);

    return 0;
}
```

#### ep\_modify()

ep\_modify() 负责更新 fd 的监视事件。

```
/// fs/eventpoll.c
static int ep_modify(struct eventpoll *ep, struct epitem *epi,
                     const struct epoll_event *event)
{
    int pwake = 0;
    poll_table pt;

    lockdep_assert_irqs_enabled();

    init_poll_funcptr(&pt, NULL);

    epi->event.events = event->events; 
    epi->event.data = event->data;
    if (epi->event.events & EPOLLWAKEUP) {
        if (!ep_has_wakeup_source(epi))
            ep_create_wakeup_source(epi);
    } else if (ep_has_wakeup_source(epi)) {
        ep_destroy_wakeup_source(epi);
    }

    smp_mb();

    if (ep_item_poll(epi, &pt, 1)) { // 获取当前文件事件
        write_lock_irq(&ep->lock);
        if (!ep_is_linked(epi)) {
            list_add_tail(&epi->rdllink, &ep->rdllist);
            ep_pm_stay_awake(epi);

            if (waitqueue_active(&ep->wq))
                wake_up(&ep->wq);
            if (waitqueue_active(&ep->poll_wait))
                pwake++;
        }
        write_unlock_irq(&ep->lock);
    }

    if (pwake)
        ep_poll_safewake(ep, NULL);

    return 0;
}
```

### epoll\_wait()

epoll\_wait() 负责将就绪队列返回给用户，主要的逻辑是调用 ep\_poll() 函数。

```
/// fs/eventpoll.c
SYSCALL_DEFINE4(epoll_wait, int, epfd, struct epoll_event __user *, events,
                int, maxevents, int, timeout)
{
    return do_epoll_wait(epfd, events, maxevents, timeout);
}

static int do_epoll_wait(int epfd, struct epoll_event __user *events,
                         int maxevents, int timeout)
{
    int error;
    struct fd f;
    struct eventpoll *ep;

    // ...
    f = fdget(epfd);
    // ...
    error = -EINVAL;
    if (!is_file_epoll(f.file)) // 不是 epoll 文件
        goto error_fput;

    ep = f.file->private_data;
    error = ep_poll(ep, events, maxevents, timeout); // 主要操作

    error_fput:
    fdput(f);
    return error;
}
```

#### ep\_poll()

ep\_poll() 函数逻辑如下

* 设置超时时间，如果超时时间为 0，表示非阻塞，ep\_poll() 直接检查就绪队列
* 调用 ep\_events\_available() 判断是否存在就绪队列，如果存在就绪队列，调用 ep\_send\_events() 将就绪事件拷贝到 user 空间返回
* 不存在就绪队列，将当前调用进程挂在 ep->wq 等待队列上，然后让出 CPU，等待唤醒

```
/// fs/eventpoll.c
static int ep_poll(struct eventpoll *ep, struct epoll_event __user *events,
                   int maxevents, long timeout)
{
    int res = 0, eavail, timed_out = 0;
    u64 slack = 0;
    wait_queue_entry_t wait;
    ktime_t expires, *to = NULL;

    lockdep_assert_irqs_enabled();
    // 设置超时时间
    if (timeout > 0) {
        struct timespec64 end_time = ep_set_mstimeout(timeout);

        slack = select_estimate_accuracy(&end_time);
        to = &expires;
        *to = timespec64_to_ktime(end_time);
    } else if (timeout == 0) { // 非阻塞，需要立即返回
        timed_out = 1;

        write_lock_irq(&ep->lock);
        eavail = ep_events_available(ep); // 是否有就绪事件
        write_unlock_irq(&ep->lock);

        goto send_events;
    }

    fetch_events:

    if (!ep_events_available(ep))
        ep_busy_loop(ep, timed_out); // 和配置有关，是否使用忙等

    eavail = ep_events_available(ep);
    if (eavail)
        goto send_events;

    ep_reset_busy_poll_napi_id(ep);

    do {
        init_wait(&wait);
        write_lock_irq(&ep->lock);
        __set_current_state(TASK_INTERRUPTIBLE); // 准备睡眠
        // 再次检查一次
        eavail = ep_events_available(ep);
        if (!eavail) {
            if (signal_pending(current))
                res = -EINTR;
            else
                __add_wait_queue_exclusive(&ep->wq, &wait);
        }
        write_unlock_irq(&ep->lock);

        if (!eavail && !res) // 调度，让出 CPU，投入睡眠
            timed_out = !schedule_hrtimeout_range(to, slack,
                                                  HRTIMER_MODE_ABS);

        eavail = 1;
    } while (0);

    __set_current_state(TASK_RUNNING); // 被唤醒，开始处理

    if (!list_empty_careful(&wait.entry)) {
        write_lock_irq(&ep->lock);
        if (timed_out)
            eavail = list_empty(&wait.entry);
        __remove_wait_queue(&ep->wq, &wait);
        write_unlock_irq(&ep->lock);
    }

    send_events:
    if (fatal_signal_pending(current)) {
        res = -EINTR;
    }
    if (!res && eavail &&
        !(res = ep_send_events(ep, events, maxevents)) && !timed_out)
        goto fetch_events;

    return res;
}
```

#### ep\_send\_events()

如果有就绪事件发生，则调用 ep\_send\_events() 函数做进一步处理。ep\_send\_events() 函数调用 ep\_send\_events\_proc() 函数处理 rdllist 就绪队列。

```
/// fs/eventpoll.c
struct ep_send_events_data {
    int maxevents;
    struct epoll_event __user *events;
    int res;
};

static int ep_send_events(struct eventpoll *ep,
                          struct epoll_event __user *events, int maxevents)
{
    struct ep_send_events_data esed;

    esed.maxevents = maxevents;
    esed.events = events;

    ep_scan_ready_list(ep, ep_send_events_proc, &esed, 0, false);
    return esed.res;
}
```

ep\_send\_events\_proc() 遍历 rdllink 就绪链表，将就绪的事件拷贝到 user 空间。在拷贝前，再次调用 ep\_item\_poll() 检查是否真的就绪。

如果采用边缘触发 LT，就绪的事件会被再次添加到 rdllist 链表中。

```
/// fs/eventpoll.c
static __poll_t ep_send_events_proc(struct eventpoll *ep, struct list_head *head,
                                    void *priv)
{
    struct ep_send_events_data *esed = priv;
    __poll_t revents;
    struct epitem *epi, *tmp;
    struct epoll_event __user *uevent = esed->events;
    struct wakeup_source *ws;
    poll_table pt;

    init_poll_funcptr(&pt, NULL); // 仅仅获取文件状态
    esed->res = 0;

    lockdep_assert_held(&ep->mtx);

    list_for_each_entry_safe(epi, tmp, head, rdllink) {
        if (esed->res >= esed->maxevents)
            break;

        ws = ep_wakeup_source(epi);
        if (ws) {
            if (ws->active)
                __pm_stay_awake(ep->ws);
            __pm_relax(ws);
        }
        // 从就绪队列删除
        list_del_init(&epi->rdllink); 
        // 检查是否真的就绪
        revents = ep_item_poll(epi, &pt, 1);
        if (!revents)
            continue;

        if (__put_user(revents, &uevent->events) ||
            __put_user(epi->event.data, &uevent->data)) {
            list_add(&epi->rdllink, head); // 出错，重新加入 rdllist
            ep_pm_stay_awake(epi);
            if (!esed->res)
                esed->res = -EFAULT; // 返回错误
            return 0;
        }
        esed->res++;
        uevent++;
        if (epi->event.events & EPOLLONESHOT)
            epi->event.events &= EP_PRIVATE_BITS;
        else if (!(epi->event.events & EPOLLET)) {
            // LT 触发，重新加入 rdllist
            list_add_tail(&epi->rdllink, &ep->rdllist);
            ep_pm_stay_awake(epi);
        }
    }

    return 0;
}
```

## 三、动手实践（代码案例）

### 3.1 epoll 基本 ET 模式使用

```c++
#include <sys/epoll.h>
#define MAX_EVENTS 64
int epfd = epoll_create1(0);
struct epoll_event ev, events[MAX_EVENTS];
ev.events = EPOLLIN | EPOLLET;   // 边缘触发
ev.data.fd = listen_sock;
epoll_ctl(epfd, EPOLL_CTL_ADD, listen_sock, &ev);

while (1) {
    int nfds = epoll_wait(epfd, events, MAX_EVENTS, -1);
    for (int i = 0; i < nfds; i++) {
        if (events[i].data.fd == listen_sock) {
            int conn = accept(listen_sock, NULL, NULL);
            ev.events = EPOLLIN | EPOLLET;
            ev.data.fd = conn;
            epoll_ctl(epfd, EPOLL_CTL_ADD, conn, &ev);
        } else {
            char buf[4096];
            while (1) {  // ET 模式必须循环读到 EAGAIN
                ssize_t n = read(events[i].data.fd, buf, sizeof(buf));
                if (n <= 0) break;
                // 处理 buf...
            }
        }
    }
}
```

### 3.2 EPOLLONESHOT 多线程安全模式

```c++
// 注册 ONESHOT，一次就绪后自动挂起
ev.events = EPOLLIN | EPOLLET | EPOLLONESHOT;
ev.data.ptr = conn_ptr;  // 存储连接对象指针
epoll_ctl(epfd, EPOLL_CTL_ADD, conn_fd, &ev);

// 工作线程处理完后重新激活
ev.events = EPOLLIN | EPOLLET | EPOLLONESHOT;
epoll_ctl(epfd, EPOLL_CTL_MOD, conn_fd, &ev);
```

## 四、进阶应用（≥500字）

### 4.1 Reactor 模式中的 epoll 角色

epoll 是 Reactor（事件分发器）模式在 Linux 上的最佳底层实现。核心设计：通过 `epoll_event.data.ptr` 直接存储 handler 指针，避免 fd→handler 的查找开销。

### 4.2 EPOLLEXCLUSIVE 解决惊群

Linux 4.5+ 引入 `EPOLLEXCLUSIVE`：多线程 `epoll_wait` 同一 epfd 且监听 fd 标记该标志时，内核只唤醒一个线程：

```c++
ev.events = EPOLLIN | EPOLLEXCLUSIVE;
epoll_ctl(epfd, EPOLL_CTL_ADD, listen_fd, &ev);
// 多个线程 epoll_wait 同一 epfd 时，只有一个被唤醒处理 accept
```

### 4.3 epoll 与 io_uring 的对比与选择

| 维度 | epoll | io_uring |
|------|-------|----------|
| I/O 模型 | 就绪通知（用户执行 I/O） | 提交/完成（内核执行 I/O） |
| 适用场景 | 网络 I/O（socket） | 存储 I/O（文件读写）、也可网络 |
| 系统调用 | epoll_wait + read/write | io_uring_enter (SQ/CQ 共享内存) |
| 零拷贝 | 无 | 支持 registered buffers |
| 典型框架 | Nginx, Redis, libuv | ScyllaDB, RocksDB io_uring backend |

### 4.4 epoll 嵌套

epoll fd 可被其他 epoll 监视——当被监视的 epoll 实例有就绪事件时，回调 `ep_eventpoll_poll` 遍历其 rdllist。使用场景：分层事件管理（上层 epoll 管理多个下层 epoll 实例）。

### 4.5 与其他主题的关联

| 关联主题 | 关联点 |
|---------|--------|
| select/poll | epoll 的前代技术，同为 I/O 多路复用但性能模型不同 |
| 虚拟文件系统 | epoll 借助 anon_inode 实现一切皆文件 |
| TCP Socket | epoll 主要监视对象，通过 sock_def_readable 触发回调 |
| 等待队列 | epoll_wait 阻塞依赖等待队列 wake_up 机制 |
| io_uring | 新一代异步 I/O，在存储场景逐步替代 epoll |

## 五、源码解析和实践感悟（≥1000字）

### 5.1 ep_insert 核心流程

```c
/// fs/eventpoll.c
static int ep_insert(struct eventpoll *ep, const struct epoll_event *event,
                     struct file *tfile, int fd, int full_check)
{
    struct epitem *epi;
    struct ep_pqueue epq;
    // 1. 分配 epitem（从 slab 缓存）
    epi = kmem_cache_alloc(epi_cache, GFP_KERNEL);
    INIT_LIST_HEAD(&epi->rdllink);
    epi->ep = ep;
    ep_set_ffd(&epi->ffd, tfile, fd);
    epi->event = *event;
    // 2. 加入 file->f_ep_links（双向关联：file ↔ epitem）
    list_add_tail_rcu(&epi->fllink, &tfile->f_ep_links);
    // 3. 插入红黑树
    ep_rbtree_insert(ep, epi);
    // 4. 设置回调函数并通过 vfs_poll 检查当前状态
    epq.epi = epi;
    init_poll_funcptr(&epq.pt, ep_ptable_queue_proc);
    revents = ep_item_poll(epi, &epq.pt, 1);
    // 5. 如果已经就绪，直接加入就绪链表
    if (revents && !ep_is_linked(epi)) {
        list_add_tail(&epi->rdllink, &ep->rdllist);
        if (waitqueue_active(&ep->wq)) wake_up(&ep->wq);
    }
    return 0;
}
```

关键设计：注册时立即调用 `vfs_poll` 获取当前状态——如果 fd 已经可读/可写，直接加入就绪链表。

### 5.2 ep_poll_callback 事件驱动核心

```c
static int ep_poll_callback(wait_queue_entry_t *wait, unsigned mode,
                            int sync, void *key)
{
    struct epitem *epi = ep_item_from_wait(wait);
    struct eventpoll *ep = epi->ep;
    __poll_t pollflags = key_to_poll(key);
    
    // 过滤非关注事件
    if (pollflags && !(pollflags & epi->event.events))
        goto out_unlock;
    
    // rdllist 空闲→直接加入；被占用→加入 ovflist
    if (READ_ONCE(ep->ovflist) != EP_UNACTIVE_PTR) {
        chain_epi_lockless(epi);       // 无锁加入备用队列
    } else if (!ep_is_linked(epi)) {
        list_add_tail_lockless(&epi->rdllink, &ep->rdllist);
    }
    // 唤醒阻塞在 epoll_wait 的进程
    if (waitqueue_active(&ep->wq)) wake_up(&ep->wq);
    // 唤醒监视此 epoll 的其他 epoll 实例
    if (waitqueue_active(&ep->poll_wait)) pwake++;
    return ewake;
}
```

### 5.3 ep_send_events_proc LT/ET 的实现差异

```c
static __poll_t ep_send_events_proc(struct eventpoll *ep,
    struct list_head *head, void *priv)
{
    list_for_each_entry_safe(epi, tmp, head, rdllink) {
        list_del_init(&epi->rdllink);  // 先从就绪链表移除
        revents = ep_item_poll(epi, &pt, 1);  // 再次确认就绪
        if (!revents) continue;
        
        // 拷贝到用户空间
        __put_user(revents, &uevent->events);
        __put_user(epi->event.data, &uevent->data);
        
        if (epi->event.events & EPOLLONESHOT)
            epi->event.events &= EP_PRIVATE_BITS;   // 挂起
        else if (!(epi->event.events & EPOLLET)) {
            // LT 模式：重新加入就绪链表
            list_add_tail(&epi->rdllink, &ep->rdllist);
        }
        // ET 模式：不再重新加入
    }
    return 0;
}
```

### 5.4 ep_scan_ready_list 双缓冲区并发设计

这个函数体现了内核并发设计的高水准：
1. **取出阶段**：将 rdllist 替换为 txlist，启用 ovflist（此时锁释放，新事件无锁流入 ovflist）
2. **处理阶段**：遍历 txlist 中的就绪事件，拷贝到用户空间
3. **合并阶段**：将 ovflist 中的新事件合并回 rdllist

设计精髓：处理期间释放锁，极大减少锁竞争，同时 ovflist 保证不丢事件。

### 5.5 实践感悟与易错点

1. **ET 模式的核心陷阱**：边缘触发只在状态变化时通知一次。如果只调用一次 `read` 而没有循环读到 `EAGAIN`，缓冲区剩余数据永远不会触发新通知 → 数据永久丢失。正确代码示例见 3.1。

2. **fd 关闭前必须 epoll_ctl DEL**：内核在 fd 关闭时会自动移除关联的 epitem（通过 `file->f_ep_links` 链表），但若后续 `socket()` 复用了同一 fd 编号，旧 epitem 可能指向新的 file 对象 → 未定义行为。

3. **epoll_create 的 size 参数已废弃**：Linux 2.6.8 后内核动态管理红黑树，`size` 仅需 > 0。所有关于 `size 限制 fd 数量` 的说法均已过时。

4. **惊群问题**：多线程 `epoll_wait` 同一 epfd + 同一 listen fd → 所有线程被唤醒竞争 accept。Linux 4.5+ `EPOLLEXCLUSIVE` 是标准解决方案，低版本需在 accept 前加锁。

5. **`epoll_event.data` 的设计智慧**：使用 union 支持 `fd`、`ptr`、`u32`、`u64` 四种模式，允许直接存储对象指针（`data.ptr = conn`），避免额外的 fd→handler 查找。

可以看到，select(2) 和 poll(2) 也利用了虚拟文件系统poll 机制，只不过仅仅是唤醒 do_select() 或者 do_poll() 进程，而 epoll(7) 的实现中就绪文件不仅唤醒 epoll_wait(2) 进程，在这之前还将就绪的事件添加到就绪的队列，减少了唤醒之后的遍历所有文件描述符检查就绪工作，而是仅仅检查处于就绪链表上的事件，复杂度大大减少。

## 相关笔记

- [Select](/posts/Select/) — select 多路复用机制
- [Poll](/posts/Poll/) — poll 多路复用机制
- [io_uring](/posts/io_uring/) — Linux io_uring 异步 IO
- [IOC  AOP](/posts/IOC-AOP/) — IOCP 与 AOP 模式
- [网络编程](/posts/网络编程/) — 网络编程全景

## 六、面试准备

### 6.1 面试高频问答

**Q1：epoll 为什么比 select/poll 快？**

A：三个核心优化：(1) epoll_ctl 用红黑树管理 fd，O(log n) 增删；(2) epoll_wait 直接从就绪链表取事件，O(1) 就绪数；(3) 事件驱动——就绪 fd 主动加入链表，非遍历所有 fd。

**Q2：LT（水平触发）和 ET（边缘触发）的核心差异？**

A：LT：只要 fd 处于就绪状态，每次 `epoll_wait` 都返回（不丢事件，编程简单）。ET：只在状态变化时通知一次，必须循环非阻塞 I/O 直到 EAGAIN（性能更好，编程复杂）。

**Q3：EPOLLONESHOT 的作用？**

A：注册后 fd 就绪只通知一次，直到重新 `epoll_ctl(EPOLL_CTL_MOD)` 重新注册。防止多线程下同一 fd 被多个线程同时处理。

**Q4：epoll 的惊群问题怎么解决？**

A：Linux 4.5+ `EPOLLEXCLUSIVE` 标志：多线程 `epoll_wait` 同一 fd 时只唤醒一个线程。或 accept 前加锁。

**Q5：epoll_create 的参数 size 还有意义吗？**

A：Linux 2.6.8 后 size 被忽略（红黑树动态扩缩），仅作为兼容保留。内核自行管理内存。

**Q6：epoll 的实现中红黑树和就绪链表的关系？**

A：红黑树存储所有监视的 fd（用于 epoll_ctl 的增删改查），就绪链表只存当前就绪的 fd（epoll_wait 直接消费）。事件触发时通过 `ep_poll_callback` 将 fd 从红黑树移到就绪链表。

### 6.2 陷阱与反问

**陷阱1**：ET 模式下只读一次就认为读完了 → 数据丢失（必须循环读到 EAGAIN）
**陷阱2**：`epoll_ctl(EPOLL_CTL_ADD)` 重复添加同一 fd → 覆盖旧事件
**陷阱3**：关闭 fd 前未 `epoll_ctl(EPOLL_CTL_DEL)` → 内核自动移除但可能遗留事件
**陷阱4**：多线程 `epoll_wait` 同一 epoll fd 不设 EPOLLEXCLUSIVE → 惊群

**反问**：epoll 与 io_uring 的适用场景对比？
*答案：epoll 适合网络 I/O（socket、pipe），io_uring 适合存储 I/O（文件读写）。io_uring 提供真正的异步 I/O（提交+完成通知），epoll 是 I/O 多路复用（就绪通知，用户自行 I/O）。*

### 6.3 一句话答案

1. **epoll_create**：创建 epoll 实例，返回 epoll fd
2. **epoll_ctl**：ADD/MOD/DEL 监视的 fd，红黑树管理 O(log n)
3. **epoll_wait**：获取就绪事件，直接从就绪链表取 O(1)
4. **LT vs ET**：水平触发反复通知易用，边缘触发一次通知高性能
5. **EPOLLONESHOT**：一次通知后挂起，多线程安全
6. **红黑树+就绪链表**：前者管理所有监视 fd，后者供应就绪事件
