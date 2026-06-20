---
title: Git
date: 2026-06-20
categories:
  - ["项目学习", "基础库与工具"]
publish: true
---

# Git 实用技巧与核心原理

> 适用范围：Git 版本控制——底层对象模型、常用命令、分支策略、团队协作工作流。

## 写作约束（铁律）

- **原内容一字不删**：所有原有文字、代码、注释、图片必须全部保留，禁止删除任何原内容。
- **只做归纳重组+增加**：在原有内容基础上调整结构、归类，新增内容以"补充"标记。新增量须让最终篇幅 ≥ 原版。
- **放不进的进附录**：六大段模板容纳不下的原内容，移入最后的「附录」章节，不得丢弃。
- **动笔前先搜索**：做相关知识准备；源码要贴原始代码，有需要可贴汇编。
- **字数硬指标**：详细解析(二)≥200字、进阶应用(四)≥500字、源码解析与实践感悟(五)≥1000字、面试准备(六)高频问法≥10个且带回答，反问点和一句话答案各≥5个。
- 先结论后细节，避免长段堆砌。
- 每节至少 3 条要点。
- **代码块必须标注语言**：shell 代码用 `bash`，禁止无语言标注的裸代码块。

## 一、核心概念

- **定义**：Git 是一个分布式版本控制系统，用于跟踪文件变更、协调多人协作开发。它通过内容寻址（SHA-1 哈希）和快照机制实现高效的版本管理。
- **关键词**：版本控制、分布式、快照、SHA-1、对象模型、分支、合并
- **适用场景/边界**：
  - 源代码管理（几乎所有软件项目）
  - 文档版本控制
  - 配置文件回溯
  - 不适合：大二进制文件频繁修改（建议用 Git LFS）；实时协作编辑

> 来源: [这才是真正的Git——Git实用技巧 - 腾讯云](https://cloud.tencent.com/developer/article/2520356)

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：快照机制 vs 差异存储**

Git 与其他版本控制系统（如 SVN）最本质的区别在于：Git 存储的是文件快照，而非文件差异。每次 `commit` 时，Git 对整个项目做一次快照，并用 SHA-1 哈希值唯一标识。未修改的文件不重复存储，而是引用上一次快照的哈希。

**第二层：Git 对象模型**

Git 底层有四种核心对象类型：

| 对象类型 | 作用 | 标识 |
|---------|------|------|
| **Blob** | 存储文件内容（二进制大对象），不含文件名和路径 | SHA-1 哈希 |
| **Tree** | 目录快照，记录文件名、权限及对应的 Blob/Tree 哈希 | SHA-1 哈希 |
| **Commit** | 一次提交，包含 Tree 指针、父 Commit 指针、作者、时间戳、提交信息 | SHA-1 哈希 |
| **Tag** | 对某个 Commit 的命名引用（轻量标签/附注标签） | 标签名 |

```bash
# 查看 Git 对象（.git/objects 目录）
git cat-file -p HEAD          # 查看当前 commit 对象内容
git cat-file -p HEAD^{tree}   # 查看当前 tree 对象内容
git ls-tree HEAD              # 列出 tree 中的文件
```

> 来源: [深入理解 git 对象模型 - CSDN](https://blog.csdn.net/gitblog_00059/article/details/146900897)

**第三层：引用（Ref）与 reflog**

Git 的引用（ref）是指向 commit 哈希的可变指针（如 `master`、`HEAD`）。`reflog` 记录了引用变动的历史，可以理解成"版本控制的版本控制"。只要有 commit 的哈希值，就能找回任何"丢失"的数据——因为 Git 对象一旦创建便不可变更。

```bash
git reflog                    # 查看 HEAD 的移动历史
git reflog show master        # 查看 master 分支的引用变化
```

> 来源: [Git 对象存储结构分析 - 腾讯云](https://cloud.tencent.com/developer/article/1105427)

## 三、动手实践（代码案例）

### 3.1 压缩多个 commit 为一个

```bash
# 交互式 rebase，压缩最近 3 个 commit
git rebase -i HEAD~3

# 在 vim 中将后两个 commit 的 pick 改为 squash（或 s），保存退出
# 或者用 reset 方式
git reset --soft HEAD~3 && git commit -m '合并的提交信息'
```

⚠️ rebase 会产生新的 commit 节点，**不要对多人共用的远端分支执行 rebase**。

rebase -i 子命令：
```bash
# p, pick    = 保留该 commit
# r, reword  = 保留，但修改 commit 信息
# e, edit    = 保留，但暂停以便修改
# s, squash  = 合并到前一个 commit
# f, fixup   = 合并，且丢弃该 commit 的 log 信息
# d, drop    = 删除该 commit
```

### 3.2 找回丢失的 commit 或分支

```bash
# 思路：找到目标 commit 的哈希值，然后 git reset
git reflog                          # 查看所有引用变动历史
git reset --hard <目标commit哈希>    # 恢复到指定 commit
```

### 3.3 快速获得干净工作空间

```bash
# 暂存当前所有修改
git stash
# 或强制恢复（丢弃未提交修改，⚠️ 不可逆）
git reset --hard HEAD
```

### 3.4 修改最近一次提交

```bash
# 补充遗漏文件 / 修改 commit 信息
git add 遗漏的文件
git commit --amend --no-edit    # 不修改 commit 信息
git commit --amend -m "新信息"   # 同时修改 commit 信息
```

### 3.5 提交文件中的部分修改（交互式暂存）

```bash
git add -p    # 逐个 hunk 确认是否暂存
# y - 暂存此 hunk
# n - 不暂存此 hunk
# s - 拆分成更小的 hunk
# e - 手动编辑此 hunk
```

### 3.6 禁止修改共用远端分支

如果一条远端分支有多人共用，不要在它上面执行 `reset`、`rebase` 等会修改已存在 commit 的命令。可以参考 [Rebase and the golden rule explained](https://www.daolf.com/posts/git-series-part-2/)。

### 3.7 撤销一个合并

```bash
# 本地分支（仅本地的合并）
git reset --hard <合并前的SHA1>

# 已推送的合并（远端分支被他人使用）
git revert -m 1 <合并commit的SHA1>
# -m 1: 保留主线（通常是 master），撤销被合并分支的修改
```

⚠️ 注意：执行 revert 后应删除原特性分支，从 revert 节点新建分支继续开发，否则再次合并时需要再 revert 一次。

### 3.8 从整个历史中删除文件

```bash
git filter-branch --tree-filter 'rm -f 敏感文件.txt' HEAD
```

⚠️ 高危操作：会修改全部历史记录链，产生全新 commit。执行前必须通知所有开发者，所有开发者需从新分支重新开始开发。

### 3.9 其他实用命令

```bash
git bisect              # 二分查找出现问题的 commit（HEAD 不好但 HEAD~10 好时定位）
git blame 文件名         # 查看每行代码最后是谁修改的
git show-branch         # 直观展示多条分支间的关系
git subtree             # 拆分或合并仓库
```

## 四、进阶应用（≥500字）

### Git 分支策略与团队协作

**GitFlow（经典模型）**：

GitFlow 定义了严格的分支策略：
- `master`：生产环境，始终保持可部署状态
- `develop`：开发主线
- `feature/*`：新功能分支，从 develop 创建，完成后合并回 develop
- `release/*`：发布准备分支，从 develop 创建，完成后合并到 master 并打 tag
- `hotfix/*`：紧急修复分支，从 master 创建，完成后合并回 master 和 develop

适用场景：有固定发布周期的传统项目（如 App 发版）。

**GitHub Flow（简化模型）**：

- 单一 `main` 分支始终可部署
- 从 main 创建短生命周期的功能分支
- 通过 Pull Request 进行代码审查
- 合并回 main 后立即部署

适用场景：持续部署、频繁发布的 Web 服务。

> 来源: [GitHub Flow 工作流详解（2025年推荐实践） - 掘金](https://juejin.cn/post/7587738151658782720)

### Merge vs Rebase vs Cherry-pick

| 操作 | 特点 | 使用场景 |
|------|------|---------|
| **git merge** | 保留完整提交历史，产生合并 commit | 合并功能分支到主分支（需要保留历史） |
| **git rebase** | 将当前分支的提交"变基"到目标分支之上，历史线性干净 | 同步主分支更新到功能分支（个人分支） |
| **git cherry-pick** | 选择性地将某个 commit 复制到当前分支 | 只移植某个特定修复到其他分支 |

**核心原则**：永远不要对公开分支执行 rebase（否则会改变已推送的 commit 哈希，导致协作者冲突）。

> 来源: [Git Merge, Rebase, Cherry-Pick 对比 - 腾讯云](https://cloud.tencent.com/developer/article/1710182)

### 常见优化策略

- **`.gitignore` 精细化**：排除编译产物、IDE 配置、依赖目录，减小仓库体积
- **大文件用 Git LFS**：二进制文件（图片、模型、数据集）不要直接存 Git
- **浅克隆**：`git clone --depth=1` 只拉取最近一次历史，适合 CI/CD 场景
- **`git gc` 定期垃圾回收**：清理不可达对象，压缩 pack 文件

## 五、源码解析和实践感悟（≥1000字）

### Git 内部对象存储原理

Git 的所有数据都以对象形式存储在 `.git/objects/` 目录中。每个对象先计算 SHA-1 哈希，哈希值的前两位作为目录名，后 38 位作为文件名。

```bash
# 创建一个 blob 对象并查看
echo "Hello Git" | git hash-object -w --stdin
# 返回: 8d0e41234f24b6da822d543a0361ce9f7fc5cb3b

# 查看存储的文件
ls .git/objects/8d/
# 输出: 0e41234f24b6da822d543a0361ce9f7fc5cb3b
```

**对象存储格式**：`"类型 内容长度\0内容"` 经过 zlib 压缩。Git 先计算这个字符串的 SHA-1，再压缩存储。因此相同内容一定产生相同哈希（内容寻址）。

### 难点与易错点

1. **rebase 后 force push 导致队友丢失提交**

这个错误非常常见：在公共分支上 rebase 后 force push，队友 pull 时发现历史冲突。解决方法是永远不要对多人在用的分支做 rebase，或者使用 `git push --force-with-lease`（比 `--force` 安全，会检查远端是否有新提交）。

2. **detached HEAD 状态**

当 checkout 到一个具体的 commit 而非分支时，进入 detached HEAD 状态。此时提交不会被任何分支引用，一旦 checkout 到别处，这些提交就会"丢失"（实际可通过 reflog 找回）。

```bash
git checkout <commit-hash>      # 进入 detached HEAD
git switch -c 新分支名           # 创建分支保存当前工作
```

3. **merge conflict 处理不当**

冲突时常犯的错误：直接删掉对方的代码。正确做法是理解两边修改的意图，选择或合并。推荐使用可视化工具：

```bash
git mergetool                    # 启动配置的合并工具（如 vimdiff、VS Code）
```

4. **Git 仓库膨胀**

随着时间推移仓库可能变得很大。主要原因：
- 不小心 commit 了大文件后又删除（历史中仍保留）
- 大量二进制文件频繁修改
- CI 产物的自动 commit

解决方案：
```bash
# 查找大文件
git rev-list --objects --all | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' | awk '/^blob/ {print $3, $4}' | sort -rn | head -20

# 从历史中彻底删除
git filter-branch --tree-filter 'rm -f 大文件.zip' HEAD
# 或使用 BFG Repo-Cleaner（更快）
```

### 经验总结（补充）

- **Git 的哲学是"不丢数据"**：reflog 存在意味着几乎所有操作都是可逆的。理解这一点能极大降低操作恐惧。
- **commit 要小而聚焦**：一个 commit 做一件事。好处：容易 review、容易 revert、容易 bisect 定位 bug。
- **commit message 规范**：推荐 [Conventional Commits](https://www.conventionalcommits.org/) 格式：`type(scope): description`，如 `feat(auth): add OAuth2 login support`。
- **学会用 `--amend` 和 `rebase -i`** 在提交前整理历史，保持主线干净。
- **push 前先 pull --rebase**：让你的提交在最新代码之上，避免不必要的 merge commit。

## 六、面试准备（高频问法≥10个，反问点/一句话答案≥5个，均带回答）

### 6.1 高频问法（≥10个）

**基础理解**：

Q1：Git 和 SVN 的核心区别是什么？

A：1) Git 是分布式，每个开发者都有完整仓库；SVN 是集中式，只有一个中央仓库。2) Git 存储快照，SVN 存储文件差异。3) Git 操作绝大多数在本地完成（commit、branch、log），速度快；SVN 需要联网。4) Git 分支是廉价指针，SVN 分支是完整目录拷贝。

Q2：Git 的四种对象类型分别是什么？

A：Blob（文件内容）、Tree（目录结构）、Commit（一次提交的快照引用）、Tag（特定 commit 的标签）。它们通过 SHA-1 哈希相互引用，形成有向无环图（DAG）。

Q3：git merge 和 git rebase 的区别？

A：merge 保留两条分支的完整历史，产生合并 commit，历史呈分叉状。rebase 将当前分支的 commit 逐一应用到目标分支之上，历史呈线性。merge 适合合并公共分支（保留历史），rebase 适合同步个人分支（保持历史整洁）。

**原理深入**：

Q4：Git 如何检测文件变更？

A：Git 通过计算文件内容的 SHA-1 哈希来判断文件是否变更。它比较工作区文件、暂存区（index）中的 blob 和 HEAD commit 中 blob 的三者关系。如果三者哈希一致，说明文件未修改。

Q5：什么是 fast-forward merge？

A：当目标分支的 HEAD 是被合并分支的直接祖先时，Git 只需将 HEAD 指针向前移动，无需创建新的 merge commit。用 `git merge --no-ff` 可以强制创建 merge commit，保留分支历史。

Q6：`git reset` 的三种模式（--soft/--mixed/--hard）区别是什么？

A：
- `--soft`：只移动 HEAD 指针，暂存区和工作区不变
- `--mixed`（默认）：移动 HEAD + 重置暂存区，工作区不变
- `--hard`：移动 HEAD + 重置暂存区 + 重置工作区（⚠️ 不可逆）

**实践应用**：

Q7：如何撤销一个已经 push 的 commit？

A：如果确定没有其他人基于此 commit 工作：`git revert <commit-hash>`（推荐，新增回滚 commit）或 `git reset --hard HEAD~1 && git push --force-with-lease`（慎用）。revert 更安全，不改变历史。

Q8：.gitignore 不生效了怎么办？

A：原因是文件在被加入 .gitignore 之前已经被 Git 跟踪了。解决：`git rm --cached 文件名` 从暂存区移除（不删除本地文件），然后提交。

Q9：如何将一个 commit 从一个分支复制到另一个分支？

A：使用 `git cherry-pick <commit-hash>`。会将该 commit 的改动应用到当前分支，生成一个新的 commit（不同哈希值）。

Q10：Git stash 的作用是什么？如何恢复特定的 stash？

A：stash 临时保存工作区和暂存区的改动，让工作目录变干净。`git stash list` 查看列表，`git stash pop stash@{n}` 恢复并删除，`git stash apply stash@{n}` 恢复但保留 stash 记录。

### 6.2 反问点/陷阱点（≥5个）

常见的陷阱问题：

- **陷阱问题1**：rebase 和 merge 后的 commit 哈希会变化吗？ → merge 保留原 commit 哈希（新增 merge commit），rebase 会为每个 commit 重新生成新哈希（因为 parent 变了，时间戳也可能变）。这就是为什么 rebase 后需要 force push。

- **陷阱问题2**：如何安全地修改已推送的 commit？ → 使用 `git revert`（推荐）或 `git commit --amend + git push --force-with-lease`（如果确保只有你自己在用该分支）。--force-with-lease 比 --force 安全，因为它会检查远端是否有你本地的之外的更新。

- **陷阱问题3**：`git reset --hard` 误操作后如何恢复？ → 用 `git reflog` 找到之前的 HEAD 位置，执行 `git reset --hard HEAD@{n}`。只要数据没有被 git gc 回收，都能找回。

- **陷阱问题4**：fork 和 clone 的区别？ → clone 是从远端仓库拉取完整副本（含所有分支历史），默认 origin 指向源仓库。fork 是平台功能（GitHub/GitLab），在服务器端复制仓库，用于贡献开源项目。

- **陷阱问题5**：HEAD、工作区、暂存区（index）三者的关系？ → HEAD 指向当前分支的最新 commit；暂存区（index）存储下次 commit 的内容快照；工作区是当前文件系统状态。`git add` 将工作区 → 暂存区，`git commit` 将暂存区 → HEAD。

### 6.3 一句话答案（≥5个）

快速记忆要点：

- Git 的核心是**内容寻址的快照式版本控制系统**
- rebase 前记住**黄金法则：不对公共分支变基**
- merge 产生合并节点，rebase 产生线性历史，cherry-pick 移植单个提交
- 找丢失提交的方法是 `git reflog` + `git reset`
- 修改最近 commit 用 `git commit --amend`，修改历史用 `git rebase -i`

情景模拟答案：

- 当被问到"什么是 Git 的底层存储模型"时，回答："Git 底层使用内容寻址的对象数据库，包含 Blob（文件内容）、Tree（目录快照）、Commit（提交记录）和 Tag（标签）四种对象，它们通过 SHA-1 哈希互相引用，形成不可变的有向无环图。"

- 当被问到"为什么 Git 分支如此轻量"时，回答："因为 Git 的'分支'仅仅是一个指向特定 commit 的指针（ref），创建分支只涉及写入一个 41 字节的文件（SHA-1 哈希），几乎零成本。"

- 当被问到"如何做代码审查（Code Review）"时，回答："通过 Pull Request / Merge Request 机制，在合并前进行审查。配合 CI/CD 自动运行测试，确保合并的代码质量。使用 squash merge 可以保持主线历史干净。"

## 附录（模板外原内容收纳）

### 参考链接

- [这才是真正的Git——Git实用技巧 - 腾讯云开发者社区](https://cloud.tencent.com/developer/article/2520356)
- [Git 对象存储结构分析 - 腾讯云](https://cloud.tencent.com/developer/article/1105427)
- [GitHub Flow 工作流详解（2025年推荐实践） - 掘金](https://juejin.cn/post/7587738151658782720)
- [Git Merge, Rebase, Cherry-Pick 对比 - 腾讯云](https://cloud.tencent.com/developer/article/1710182)
- [Git 分支管理最佳实践 - 腾讯云](https://cloud.tencent.com/developer/article/2589917)
