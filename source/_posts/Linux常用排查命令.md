---
title: Linux常用排查命令
date: 2026-06-20
categories:
  - ["项目学习", "基础库与工具"]
publish: true
---

# Linux 常用排查命令

> 适用范围：Linux 系统管理——文件操作、进程管理、网络诊断、性能监控命令速查与源码原理。

## 一、核心概念

- **定义**：Linux 常用命令是后端开发与线上运维的基础技能，涵盖文件操作、系统管理、网络诊断、进程监控四大类。掌握其使用方法和底层原理，是高效排查线上问题的前提。
- **关键词**：文件操作（ls/cd/cat/find/grep）、系统管理（ps/top/df/du/free）、网络诊断（netstat/ss/ping/tcpdump）、进程跟踪（strace/lsof）
- **适用场景/边界**：
  - 线上问题快速定位（CPU 飙升、内存泄漏、磁盘满、网络超时）
  - 日常巡检与监控脚本编写
  - 不适合：大规模自动化运维（需 Ansible/SaltStack 等工具）

## 二、详细解析

### 文件与目录操作

| 命令 | 功能 | 常用选项 |
|------|------|---------|
| `ls` | 查看当前目录内容 | `-l` 长格式, `-a` 含隐藏文件, `-h` 人类可读大小 |
| `cd` | 切换工作目录 | `cd -` 回到上次目录, `cd ~` 回家目录 |
| `pwd` | 显示当前工作目录 | |
| `mkdir` | 创建目录 | `-p` 递归创建多级目录 |
| `touch` | 创建空文件 | |
| `cp` | 拷贝文件/目录 | `-r` 递归拷贝目录 |
| `mv` | 移动/重命名 | |
| `rm -rf` | 递归强制删除 | ⚠️ 慎用！不可恢复 |
| `cat` | 查看/合并文件 | `cat f1 > f3` 覆盖合并, `cat f1 >> f3` 追加 |
| `head/tail` | 查看文件头/尾 | `tail -f error.log` 实时跟踪日志, `-n` 指定行数 |
| `find` | 搜索文件 | `find / -name "*.log" -mtime -1` 24h内修改的日志 |
| `grep` | 文本内容搜索 | `-r` 递归, `-i` 忽略大小写, `-C 5` 上下文5行 |
| `tar` | 压缩/解压 | `-zcvf` 压缩, `-zxvf` 解压 |
| `more` | 分屏显示 | 空格翻页, q 退出 |

### 系统管理命令

| 命令 | 功能 | 常用选项 |
|------|------|---------|
| `cal` | 查看日历 | |
| `date` | 显示/设置时间 | |
| `ps -aux` | 查看进程快照 | `ps aux \| grep java` |
| `export` | 临时设置环境变量 | 窗口关闭后失效 |
| `top` | 动态进程监控 | 按 CPU 排序, `htop` 增强版 (支持鼠标) |
| `kill -9 pid` | 强制终止进程 | ⚠️ 先尝试 `kill` (SIGTERM)，不行再用 `-9` (SIGKILL) |
| `df -h` | 磁盘空间 | 人类可读格式 (GB/MB) |
| `du -sh` | 目录/文件大小 | `--max-depth=1` 控制深度 |
| `free -m` | 内存使用 | `-m` MB 单位, `-s 5` 每5秒刷新 |
| `ifconfig/ip addr` | 网卡信息 | 7.0+ 推荐 `ip addr` |
| `ping` | 测试连通性 | `-c 4` 指定次数 |
| `uptime` | 系统运行时间和负载 | load average: 1/5/15 分钟 |

### 网络命令

| 命令 | 功能 | 备注 |
|------|------|------|
| `wget` | 下载文件 | |
| `yum -y install` | 安装软件包 | RHEL/CentOS 系 |
| `netstat -tunlp` | 查看端口监听 | `ss -tunlp` 更快更推荐 |
| `tcpdump` | 网络抓包 | `-i eth0 port 80` 抓 HTTP, `-w dump.pcap` |
| `firewall-cmd` | 防火墙管理 (7.x) | `--state` 查看状态 |
| `service iptables` | 防火墙管理 (6.x) | `status/start/stop` |

### 性能监控命令

| 命令 | 功能 |
|------|------|
| `vmstat` | 虚拟内存统计 |
| `mpstat` | CPU 统计 (多核) |
| `iostat` | 磁盘 IO 统计 |
| `pidstat` | 进程级资源统计 |
| `ulimit -a` | 查看系统资源限制 (含文件描述符上限) |

## 三、动手实践

### 3.1 快速场景

```bash
# 查看有哪些端口开放
netstat -tunlp
# -t: TCP, -u: UDP, -n: 数字格式, -l: 仅监听, -p: 显示进程
# 推荐使用更快的 ss -tunlp

# 查看磁盘空间
df -h

# 查看文件描述符限制
ulimit -a

# 实时监控日志
tail -f /var/log/nginx/error.log

# 查找大文件
find / -size +100M -exec ls -lh {} \;
```

### 3.2 Java/C++ 服务常用

```bash
# 运行 Java 程序
java -jar app.jar

# 编译 Java
javac App.java

# 查看 Java 进程
ps aux | grep java

# 防火墙管理 (CentOS 7.x)
firewall-cmd --state                   # 查看状态
systemctl stop firewalld.service       # 关闭
systemctl start firewalld.service      # 开启
```

## 四、进阶应用

### 4.1 线上 CPU 100% 排查链

```bash
# 1. 找到 CPU 最高的进程
top
# 2. 找该进程中最高的线程
top -H -p PID
# 3. 线程 TID 转 16 进制
printf "%x\n" TID
# 4. Java 应用：打印线程栈
jstack PID | grep -A 20 16进制TID
# 5. C++ 应用：用 pstack 或 gdb
pstack PID | grep 16进制TID
```

### 4.2 内存泄漏排查链

```bash
# 1. 观察 RES 是否持续增长
top -p PID
# 2. 看内存映射分布
pmap -x PID | tail -1
# 3. 对比 /proc/PID/smaps 快照
cat /proc/PID/smaps | grep -E "^(Rss|Pss):"
# 4. valgrind 离线分析
valgrind --leak-check=full --show-leak-kinds=all ./program
```

### 4.3 磁盘满了紧急处理

```bash
# 1. 定位满分区
df -h
# 2. 层层下钻找大目录
du -sh /* 2>/dev/null | sort -rh | head -20
# 3. 找被删除但仍占空间的僵尸文件
lsof | grep deleted
# 4. 检查日志是否未轮转
ls -lh /var/log/
```

### 4.4 网络超时排查

```bash
# 1. 测试连通性
ping -c 4 target.com
# 2. 路由追踪
traceroute target.com  # 或 mtr -r target.com
# 3. 确认端口监听
ss -tunlp | grep 端口
# 4. 抓包看三次握手
tcpdump -i eth0 'tcp port 端口'
```

---

## 五、源码解析和实践感悟

### 5.1 strace 系统调用跟踪原理（源码级）

```c
// Linux kernel ptrace.c — strace 依赖 ptrace 系统调用实现
// PTRACE_SYSCALL: 让被跟踪进程在每次系统调用入口/出口暂停
SYSCALL_DEFINE4(ptrace, long, request, long, pid, unsigned long, addr, unsigned long, data)
{
    struct task_struct *child = find_get_task_by_vpid(pid);
    switch (request) {
    case PTRACE_SYSCALL:
        // 设置 TIF_SYSCALL_TRACE 标志，使进程在进入/退出系统调用时暂停
        set_tsk_thread_flag(child, TIF_SYSCALL_TRACE);
        // 唤醒子进程继续执行（直到下次 syscall）
        wake_up_process(child);
        break;
    case PTRACE_GETREGS:
        // 读取寄存器（获取系统调用号和参数）
        copy_to_user((void __user *)data, &child->thread.regs, sizeof(struct user_regs_struct));
        break;
    }
}

// 系统调用入口处：tracehook_report_syscall_entry
static inline void syscall_trace_enter(struct pt_regs *regs) {
    if (test_thread_flag(TIF_SYSCALL_TRACE))
        ptrace_report_syscall(regs);  // 暂停被跟踪进程，通知 tracer
}
```

### 5.2 lsof 遍历 /proc 文件系统

```c
// lsof 核心逻辑：遍历 /proc/[pid]/fd/ 目录获取进程文件描述符
// /proc/[pid]/fd/[fdnum] 是指向打开文件的符号链接
static void get_proc_files(int pid) {
    char path[256];
    snprintf(path, sizeof(path), "/proc/%d/fd", pid);
    DIR *dir = opendir(path);
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        char link_path[512];
        snprintf(link_path, sizeof(link_path), "%s/%s", path, entry->d_name);
        char resolved[PATH_MAX];
        ssize_t len = readlink(link_path, resolved, sizeof(resolved) - 1);
        if (len != -1) {
            resolved[len] = '\0';
            // 同时读取 /proc/[pid]/fdinfo/[fdnum] 获取 flags、mnt_id
            printf("PID=%d FD=%s → %s\n", pid, entry->d_name, resolved);
        }
    }
}
```

### 5.3 top 命令读取 /proc/stat 和 /proc/[pid]/stat

```c
// top 通过解析 /proc/stat 计算 CPU 使用率
struct cpu_stats {
    unsigned long long user, nice, system, idle, iowait, irq, softirq, steal;
};

void read_cpu_stats(struct cpu_stats *prev, struct cpu_stats *curr, float *usage) {
    FILE *f = fopen("/proc/stat", "r");
    fscanf(f, "cpu %llu %llu %llu %llu %llu %llu %llu %llu",
           &curr->user, &curr->nice, &curr->system, &curr->idle,
           &curr->iowait, &curr->irq, &curr->softirq, &curr->steal);
    unsigned long long prev_total = prev->user + prev->nice + prev->system +
                                     prev->idle + prev->iowait + prev->irq +
                                     prev->softirq + prev->steal;
    unsigned long long curr_total = curr->user + curr->nice + curr->system +
                                     curr->idle + curr->iowait + curr->irq +
                                     curr->softirq + curr->steal;
    unsigned long long prev_idle = prev->idle + prev->iowait;
    unsigned long long curr_idle = curr->idle + curr->iowait;
    *usage = 100.0 * (curr_total - prev_total - (curr_idle - prev_idle))
             / (curr_total - prev_total);
}
```

### 实践感悟

1. **strace 不是 free lunch**：ptrace 会让被跟踪进程在每次系统调用时 stop-resume，对高频 syscall 的进程（如 Redis、Nginx）性能影响可达 50%+，生产环境慎用 strace -p。
2. **lsof | wc -l 排查 fd 泄漏**：线上服务出现 "Too many open files" 先看哪个进程 fd 异常——`lsof -p PID | wc -l`，同时用 `ulimit -n` 确认当前限制。
3. **top/htop 中的 load average**：load 不等于 CPU 使用率！load 是就绪+等待 IO 的任务数。CPU 密集型看 %CPU，IO 密集型看 %iowait。
4. **netstat -tunlp 已过时**：现代 Linux 推荐 `ss -tunlp`，ss 直接从内核 socket 数据结构读取（不走 /proc），在大规模连接时快 10-100 倍。
5. **df -h vs du -sh 不一致**：常见原因是文件被删除但仍被进程持有（lsof 可查），磁盘空间未释放但 du 看不到。重启持有进程即可释放。
6. **kill -9 别滥用**：默认 kill（SIGTERM）给进程清理机会（释放锁、关闭连接），kill -9（SIGKILL）直接内核杀，可能留下脏数据。先用 kill，不行再 kill -9。

---

## 六、面试准备

### Q1: 线上 CPU 飙到 100%，怎么排查？
**答**：① `top` 找 CPU 最高的进程 PID；② `top -H -p PID` 找最高线程 TID；③ `printf "%x\n" TID` 转 16 进制；④ `jstack PID | grep -A 20 16进制TID`（Java）或 `pstack PID`（C++）定位代码行。

### Q2: 内存泄漏怎么定位？
**答**：① `top/htop` 观察 RES 持续增长；② `pmap -x PID` 看内存映射分布；③ `valgrind --leak-check=full` 离线分析；④ 在线用 `gperftools` (tcmalloc) 的 HEAPPROFILE；⑤ malloc 钩子 + /proc/PID/smaps 看可疑增长区。

### Q3: 磁盘满了怎么办？
**答**：① `df -h` 确认哪个分区满；② `du -sh /*` 层层下钻定位大目录；③ `find / -size +1G` 找大文件；④ 检查是否日志未轮转（logrotate 配置）；⑤ `lsof | grep deleted` 找被删除但仍占空间的僵尸文件。

### Q4: 网络连接超时怎么排查？
**答**：① `ping` 测试连通性；② `traceroute/mtr` 看路由路径和延迟；③ `ss -tunlp` 确认服务端口监听状态；④ `tcpdump -i eth0 port 端口` 抓包看三次握手是否正常；⑤ 检查 iptables/firewalld 规则。

### Q5: 如何查看进程打开了哪些文件？
**答**：① `lsof -p PID` 列出所有 fd（socket、regular file、pipe）；② `ls -la /proc/PID/fd/` 直接查看 fd 目录；③ `lsof -i :端口` 反向查谁占用了端口。

### Q6: 为什么 df 显示满了，du 查不出来？
**答**：文件已被 rm 删除但仍被进程持有（fd 未关闭），inode 未释放。用 `lsof | grep deleted` 定位，重启进程即可释放空间。

### Q7: OOM Killer 杀掉进程怎么分析？
**答**：① `dmesg | grep -i oom` 查看内核 OOM 日志（含杀掉的进程名、PID、内存占用）；② `grep -i "invoked oom-killer" /var/log/messages`；③ 检查 `/proc/PID/oom_score` 和 `oom_score_adj`。

### Q8: 如何查看系统整体的 IO 瓶颈？
**答**：`iostat -x 2` 看 %util（饱和度）和 await（平均等待时间）、svctm（服务时间）。await >> svctm 说明 IO 排队严重。`iotop` 按进程维度看谁在大量读写。

### 面试陷阱

1. **「load average 高就是 CPU 瓶颈」** → 错！也可能是 IO 等待导致（D 状态进程），需结合 %iowait 判断。
2. **「kill -9 一定能杀掉进程」** → 错！D 状态进程（不可中断睡眠）kill -9 也无效，等 IO 返回后自动结束。
3. **「ulimit -n 改大就不怕 fd 泄漏」** → 治标不治本！fd 泄漏应修复代码（未 close/fclose），而非单纯调大限制。
4. **「strace 不会影响生产性能」** → 错！ptrace 会对每次 syscall 造成 stop-resume 开销，高频进程性能显著下降。
5. **「netstat 和 ss 结果完全一致」** → 基本一致但极端连接数下 netstat 可能因 /proc 读取速度慢而丢失瞬时连接，ss 更可靠。

### 一句话答案速记表

| 关键词 | 一句话答案 |
|-------|-----------|
| CPU 100% 排查 | top→线程→jstack/pstack→代码行 |
| 内存泄漏 | pmap + valgrind + gperftools + /proc/smaps |
| 磁盘满 | df→du→find 大文件→lsof deleted |
| 网络超时 | ping→traceroute→ss→tcpdump→iptables |
| fd 泄漏 | lsof -p PID 或 ls /proc/PID/fd |
| df vs du 不一致 | 文件被删但仍被进程持有，lsof grep deleted |
| OOM 排查 | dmesg grep oom, oom_score, /var/log/messages |
| IO 瓶颈 | iostat await/svctm, iotop 定位进程 |
