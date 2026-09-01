# TaskQueue 使用说明

> 项目结构、安装和完整配置见 [README.md](README.md)。

共享 NPU 机器的任务队列。提交你的命令，系统给你分一张卡并锁住，不用再和别人抢。

## 管理员部署

首次安装和后续手动升级都只需一条命令；它会初始化但不覆盖已有配置，完成
systemd 重载、启动/安全重启、开机自启和状态验证：

```bash
sudo bash deploy.sh
```

在交互式终端首次执行时，部署脚本会询问本机 NPU 卡数量和最大并发数；直接
回车即可接受自动检测/推荐值。无人值守部署可加 `--non-interactive`，也可以用
`--available-devices` 和 `--max-concurrent` 直接指定而不回答问题。

部署时会一次性创建完整运行目录，不依赖首个用户在使用过程中临时创建：

```text
/home/pypto-tools/pto-task/
├── app/
├── config/
├── state/{pending,running,done,locks,kill,fifo,usage}/
├── logs/
└── tmp/
```

重复部署会保留配置和队列数据，同时校正 `pending/`、`locks/`、`kill/`、
`fifo/` 等多用户共享目录及已有设备锁的权限。管理目录和锁文件统一由
`root:root` 持有；共享目录为 `1777`，设备锁为 `0666`，所以所有用户都能使用，
也不需要普通用户修改锁权限。部署会按照最终卡列表预先创建每张卡的持久锁文件，
后续任务只打开并复用同一个锁，不再由首个用户创建。

常用配置可以直接随部署命令传入，不必手改配置文件：

```bash
sudo bash deploy.sh --max-concurrent 8 --available-devices 0,1,2,3 \
  --ptoas-base /usr/local/ptoas --task-execution-mode HwHiAiUser
```

调度策略由 root 管理的独立模块提供。默认的 `backfill` 与历史行为一致：暂时
无法获得设备的任务不会阻塞后面可运行的任务。若要避免持续到来的少卡任务让
多卡任务一直凑不齐卡，可启用 `pool_aware_reservation`（卡池感知预约）：最老的
多卡任务暂时凑不齐卡时，保护它由 `task-submit.conf` 算出的有效卡池，让已运行
任务释放的卡自然积累。
后续任务若能从保护范围之外找到足够的空卡仍可运行；无卡任务也可运行，但会为
多卡任务保留一个并发槽。

```bash
# 历史吞吐优先策略
SCHEDULER_MODE="backfill"

# 或：卡池感知预约策略（修改后需重启 daemon）
SCHEDULER_MODE="pool_aware_reservation"
POOL_AWARE_RESERVATION_MIN_DEVICES=2
```

`POOL_AWARE_RESERVATION_MIN_DEVICES` 指定从几卡任务开始触发预约，必须不小于
2；例如设为 `4` 时，2 卡任务仍按普通回填处理，4 卡及以上任务可建立预约。攒卡不会
终止已经运行的任务，因此实际等待时间仍取决于这些任务何时结束。同一 auto
范围有 5 张空卡时，3 卡任务启动后，后面的 2 卡任务可使用剩余 2 张；若前面是
4 卡任务，后面的 2 卡任务会因只剩 1 张而继续等待。

未知模式会导致 daemon 拒绝启动，不会静默切换策略。
调度模式在 daemon 启动时读取；切换时应先等待 pending 和 running 队列为空，
再重启服务，避免重启过程终止正在执行的任务。

调度实现由公共规划核心 `schedulers/_core.sh` 和独立策略模块组成。公共核心统一
遍历 pending 队列、读取任务设备快照、执行 8 卡与总并发限制，并在真正认领任务前
重新校验设备数、有效卡池和当前占用；策略模块只通过 `start`、`defer`、`stop`
返回决策，不能移动队列文件或启动进程。当前两个策略都使用模块 API v2。

新增策略只需增加安全命名的 `schedulers/<模式名>.sh`，声明
`SCHEDULER_MODULE_API_VERSION=2`、与文件名一致的 `SCHEDULER_MODULE_NAME`，并实现
`scheduler_consider_task`；安装脚本会自动安装仓库中的调度文件，不需要修改 daemon
的模式列表。公共 `_core.sh` 不是可选调度模式。所有已安装调度文件继续要求由 root
拥有且不能被组或其他用户写入。

升级时若仍有任务运行，脚本不会杀任务，只更新程序文件并提示任务结束后重新执行。
旧版 `/etc/taskqueue.conf` 中安全的 `BASE_DIR` 和 `MAX_CONCURRENT` 会自动迁移，
`taskqueue.service` 也保留为 `pto-task.service` 的兼容名称。

自动更新只保留主仓控制模式，不再直接跟随分支 HEAD。服务器定时读取主仓
`update/rollout.json` 指定的精确 commit，验证通过后先阻止新任务提交，等待 pending
和 running 都为空，再安装并安全重启正在运行的 daemon。重启失败会保留待激活标记
供下次重试；原本处于停止状态的 daemon 不会被自动启动。完整安装输出和退出码写入
`logs/auto-update.log`，可用 `task-submit --version` 查看当前安装 revision。

定时器固定在北京时间（`Asia/Shanghai`）每天凌晨 03:37，并加入最多 20 分钟随机
延迟。等待队列空闲的单次上限为 2 小时，每 5 分钟检查一次；新版的 2 小时硬上限
也会限制仍保存旧版 6 小时配置的服务器。

如需关闭自动更新，部署时使用 `sudo bash deploy.sh --disable-auto-update`；后续
手动升级也继续携带该选项，因为普通部署默认会重新安装并验证自动更新 timer。

默认清单采用 `enabled: true`、空 `target`、`sequence: 0` 的待命状态：本服务器
保留并运行自动更新 timer，但主仓未指定 commit 时不会更新。主仓把 `target` 指向
已经合入目标分支的完整 commit ID 并递增 `sequence` 后，服务器才会验证、部署并
激活该版本。序号倒退或被不同 commit 重用会被拒绝；回退到旧版本还必须显式设置
`allow_rollback: true`。

候选版本先由 `config/repo-auto-update.env` 配置的非 root 用户（默认 `daemon`）运行
测试，再执行空闲队列部署。集中发布状态保存在 `<tools-root>/pto-task/update/`，本机
任务配置、队列、日志不会被覆盖。
仓库默认由 root 拉取；若 root 无法直接出网，可在同一配置中设置
`REPO_AUTO_UPDATE_FETCH_USER` 和 `REPO_AUTO_UPDATE_FETCH_ALL_PROXY`。

推荐先合入并测试代码提交，再单独提交一次 rollout 清单变更。需要停止推广时将
`enabled` 改回 `false`。主仓代码最终会以 root 安装，必须严格保护仓库写入、合入
和管理员权限。

如果某台共享开发服务器需要限制 8 卡用例并发，可仅在该机的
`/home/pypto-tools/pto-task/config/taskqueue.conf` 中设置：

```bash
MAX_CONCURRENT_8_CARD_TASKS=1
```

默认值为 `0`（关闭），其他服务器自动更新代码后不会自动开启。开启后，
已有一个 8 卡用例运行时，后续 8 卡用例保持 pending；daemon 会跳过它
继续调度后面的小卡任务。

## 提交

```bash
# NPU 任务 —— 自动分配空闲卡，并自动在命令末尾追加 "--device <卡号>"
task-submit --device auto --run "python train.py"

# NPU 任务 —— 自己指定卡号（不会自动追加，卡号由你自己传给程序）
task-submit --device 9 --run "python train.py -d 9"

# 多卡
task-submit --device auto --device-num 2 --run "python train.py --devices 0,1"

# 指定 PTOAS 版本；自动设置 PTOAS_ROOT，并依次把版本根目录和 bin 放到 PATH 前面
task-submit --ptoas 0.54 --device auto --run "python train.py"

# 非 NPU 任务 —— 不写 --device 就不分配卡
task-submit --run "make build"
task-submit --run "pytest tests/test_foo.py"

# 长训练（默认 300 秒会被 kill，必须加 --max-time 0）
task-submit --device auto --max-time 0 --run "python train.py"

# 一直等到任务结束（--timeout 0 = 客户端不超时）
task-submit --device auto --max-time 0 --timeout 0 --run "python train.py"

# 交互式任务（执行过程中可以从终端输入）
task-submit -i --device auto --run "python interactive_script.py"
```

未指定 `--ptoas` 时保留提交者已有的 `PTOAS_ROOT` 和 `PATH`，不自动切换版本。
指定版本必须在服务器配置项 `PTOAS_BASE` 下包含可执行的 `ptoas` 或 `bin/ptoas`；
版本根目录优先，以便旧版包装脚本自动加载对应的 `lib/`。当前默认
根目录为 `/usr/local/ptoas`。管理员可在 `taskqueue.conf` 中为服务器单独配置；
提交用户显式导出的 `PTOAS_BASE` 优先级更高。
如果已经导出了非空的 `PTOAS_ROOT`，它的优先级也高于冲突的 `--ptoas` 参数，
此时任务会保留原有的 `PTOAS_ROOT` 和 `PATH`。

### 怎么把卡号告诉你的程序

`--device auto` 时 daemon 默认在命令末尾追加 `--device <卡号>`。如果你的程序用
别的参数名，改用 `{}` 占位符或 `TASK_DEVICE` 环境变量：

```bash
# {} 占位符 —— daemon 替换为实际卡号（双引号即可）
task-submit --device auto --run "python train.py -d {}"
task-submit --device auto --run "python train.py --npu-id {}"

# $TASK_DEVICE 环境变量（必须用单引号，否则提交时就被你的 shell 展开了）
task-submit --device auto --run 'python train.py -d $TASK_DEVICE'

# 代码里读取: device = os.environ.get("TASK_DEVICE", "0")
```

拿到的是**物理卡号**，原样用即可。

## 查看

```bash
task-submit --list                  # 所有任务
task-submit --status <task-id>      # 单个任务状态
task-submit --log <task-id>         # 任务日志
task-submit --wait <task-id>        # 重新连上并跟到结束
task-submit --devices               # 当前 auto 白名单、来源、项目策略与冲突
task-submit --find "<子串>"          # 按完整命令匹配，只输出 task-id（给脚本用）
```

脚本里要定位任务请用 `--find`，不要解析 `--list`：`--list` 的命令列会在 77 个
字符处截断。

`task-submit --devices status` 会分别显示运行时 `available_devices`、服务器静态
`AVAILABLE_DEVICES`、自动探测结果、`TASKQUEUE_DEVICE_POOL`，以及从当前目录向上
找到的 `task-submit.conf`。输出还会计算 daemon 最终可分配的 auto 候选集合，并
提示空交集、被全局池排除的卡和固定 `DEVICE_SEQ_N` 超出全局池等兼容行为。

### 同 HCCS plane 借卡（卡组）

有些服务器的卡分属不同的 HCCS plane（通信域），跨 plane 的多卡通信在
pypto/simpler 上不会报错返回，而是挂起并把卡楔死到只能靠平台带外 reset。

服务器管理员在 `config/taskqueue.conf` 里声明本机拓扑，分号分组、组内逗号分隔：

```bash
DEVICE_GROUPS="0,1;2,3"     # 0 和 1 同组，2 和 3 同组
```

需要同组借卡的仓库在自己的 `task-submit.conf` 里开启：

```bash
DEVICE_GROUP_AFFINITY=1
```

开启后本仓的多卡任务必须整体落在一个组内：

- `--device auto --device-num N` 只会从某个有 N 张空闲卡的组里整组分配；哪个组
  由 daemon 在调度时决定，所以一个组忙着不会挡住另一个空闲组。凑不齐就继续排队，
  绝不会跨组凑数。
- 显式 `--device 0,2` 或跨组的 `DEVICE_SEQ_N` 在提交时直接报错，并指出每张卡属于
  哪个组。
- 请求卡数超过最大卡组时（如 024 上要 3 张而每组只有 2 张）当场报错，不会排队等
  一个永远不会出现的组合。

未配置 `DEVICE_GROUPS` 时，本机拓扑视为**未知**，而不是"所有卡同 plane"——真的
单 plane 的机器应显式写成一个大组（如 `DEVICE_GROUPS="0,1,2,3"`）。此时开启了
`DEVICE_GROUP_AFFINITY` 的仓库，其多卡任务会在提交时报错，直到管理员补上拓扑；
单卡任务和未开启的仓库都不受影响。

`task-submit --devices status` 会显示本机卡组、本仓的同组候选，以及单次请求的
多卡上限。确实能跨 plane 的负载（如 torch_npu 纯 HCCL collective 加
`HCCL_INTRA_ROCE_ENABLE=1`）用 `--ignore-group-affinity`（或
`TASKQUEUE_IGNORE_GROUP_AFFINITY=1`）放行。

## 管理

```bash
task-submit --cancel <task-id>      # 取消排队中的任务
task-submit --kill <task-id>        # 终止运行中的任务（Ctrl+C 同样可以）
task-submit --clean                 # 清理 1 天前完成的任务
task-submit --clean --days 7        # 清理 7 天前完成的任务
```

## 时间参数

| 参数 | 作用 | 默认 | `0` 的含义 |
|---|---|---|---|
| `--max-time N` | 服务端的任务最大运行时间，超时被 kill | `300` 秒 | 不限时 |
| `--timeout N` | 客户端等待时间 | `600` 秒 | 一直等 |

`--timeout` 只是断开等待，**任务仍在运行**，可以用
`task-submit --wait <task-id>` 重新连上。

## 注意事项

1. **用系统给你的卡号。** 它是物理卡号，通过自动追加的 `--device`、`{}` 占位符
   或 `$TASK_DEVICE` 传给你。系统不会把卡重映射成逻辑 0，所以写死卡号意味着
   锁着一张卡、算在另一张卡上。
2. **长训练记得加 `--max-time 0`**，默认 300 秒会被 kill。
3. **不要自己包 `npu-lock`**，daemon 会锁卡；命令里手写 `npu-lock` 会被拒绝。
4. **不要在任务内部再调 `task-submit`**，嵌套提交会被拒绝（防队列死锁）。
5. **不要绕过队列**直接跑 NPU 任务，会和队列里的任务抢卡。
6. **危险命令在提交时被拦截**（`rm -rf /`、`mkfs`、`reboot` 等）。匹配是子串
   匹配，所以正常命令里带上这些词也会被拒，改个写法即可。
7. **交互式任务用 `-i`**，必须搭配 `--run` 且需要真实终端。只支持按行输入，
   断开后无法重连 stdin（日志仍可用 `--wait` 继续看）。
