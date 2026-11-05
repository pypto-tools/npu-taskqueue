# 本地只读监控接口（schema_version 1）

```bash
task-submit --monitor --json
pto-task --monitor --json
```

两者是同一个入口。普通监控账号无需 sudo，可以读取所有提交用户的脱敏资源摘要。
stdout 只有一个 UTF-8 JSON 对象，诊断写到 stderr。不新增 HTTP 服务，不采集登录人数，
不修改 pto-btop。依赖现有部署所用的 Linux /proc、Python 3 和 GNU timeout。

## 数据路径与权限

已安装的 daemon 将快照发布到 `<tools-root>/pto-task/state/monitor.json`，通常是
`/home/pypto-tools/pto-task/state/monitor.json`。即使管理员保留了自定义 STATE_DIR，
公共快照仍在这个固定安装位置。CLI 根据自身真实路径定位，不 source 配置文件，
不受 cwd、项目 task-submit.conf、TASKQUEUE_CONF、STATE_DIR、TASKQUEUE_DEVICE_POOL、
TASKQUEUE_DEVICE_CONF 或 TASKQUEUE_INSIDE 影响。两个命令别名均解析到同一安装。

安装目录和 state/ 由现有 setup.sh 保持 root 所有、0755；快照是 root 所有、0644，
通过同目录 0600 临时文件写入，完成后改为 0644 并原子 rename。无需开放任务 .env、
日志或脚本的权限。CLI 不访问队列元数据、不申请设备锁，也不做硬件探测。
使用 Python 隔离模式，忽略调用者的 PYTHONPATH 和用户 site-packages。

源码模式的默认查询路径为 `runtime/state/monitor.json`。若用 TASKQUEUE_CONF 单独启动
自定义源码测试 daemon，快照跟随该 daemon 的 STATE_DIR；标准 CLI 仍只读默认源码
路径。需要多个可查询实例时使用独立安装树，不通过监控账号环境变量切换实例。

## 返回结构

完整结构示例见 [task-submit-monitor.example.json](task-submit-monitor.example.json)。

| 字段 | 含义 |
| --- | --- |
| schema_version | 固定整数 1 |
| producer.name / version | pto-task / daemon 启动时捕获的 revision；安装新文件不会改写旧进程的版本 |
| boot_id | 每次 daemon 启动生成的 UUID |
| snapshot_seq | 本次启动内递增序号，从 1 开始；发布失败可跳号 |
| observed_at | 原始观察时间，UTC ISO 8601 |
| age_ms | 同机单调时钟计算的数据年龄；查询不刷新观察时间 |
| status / reason | ok、partial、unavailable；机器可读原因码，多个原因用逗号分隔 |
| scheduler | state、mode、accepting_submissions、dispatching、running_tasks、pending_tasks、max_concurrent、reason |
| devices | 最多 256 项，实际 `/dev/davinci<逻辑ID>` 列表，ID 是字符串 |
| summary | total、free、allocated、reserved、disabled、external、error、unknown、occupying_users |
| inventory_complete | 是否完成设备枚举并覆盖池、分配和预留中的 ID |
| external_detection | 第一版为 unsupported |
| daemon | pid、start_ticks、uid，用于校验 daemon 身份；这里的 uid 是 daemon 身份，**不是卡占用者** |
| kernel_boot_id / observed_monotonic_ns | 主机启动身份及内部单调时间，供 CLI 校验缓存 |
| cached | 仅返回不可用的旧观察时为 true |

每个设备包含：

- `id`、`group_id`：真实逻辑编号、配置中的 HCCS 组。组按 DEVICE_GROUPS 顺序命名
  g0、g1 等；未声明的组是 null，不把调度器内部的 solo 分组当成硬件拓扑。
- `pool_eligible`：是否在运行 daemon 的全局自动池中。
- `state`、`reason_codes`：队列资源状态和原因数组。
- `allocation`：null 或 `{task_id,user,uid,started_at,elapsed_seconds}`。
  用户来自 SUBMIT_USER；UID 在生成快照时解析，解析失败为 null、status 为 partial。
  时间描述任务启动而非硬件实际忙碌时间，启动元数据尚未完成时允许 null。
- `reservation`：null 或 `{task_id,user,uid,requested_devices}`，来自真实调度 tick。
- `health`：第一版为 unknown。没有利用率、显存、温度或硬件健康的推断值。

任务数按 running / pending 的任务记录计算，包含 CPU-only 任务。多卡任务只算一个
任务；同一 UID 的多个占卡任务只算一个 occupying_users；仅等待预留者不计入用户数。
完整枚举时，七种互斥设备状态数量之和等于 total。无法确认占用用户总数时为 null。
设备枚举不完整时 summary 各项为 null，不能把截断或缺失的列表当全量。

## 状态与调度语义

`free` 表示全局自动池中，没有实际队列分配、有效持锁或当前预留保护的设备。
它不保证新任务立即启动：维护、并发上限、先到任务、项目策略、八卡限额和同组约束
仍然生效。`dispatching=true` 只表示本轮允许调度，不表示仍有并发余量。
维护时 accepting_submissions 和 dispatching 都是 false；正在运行的占用仍保留。

`allocated` 包括启动和清理阶段。allocation 来自 daemon 的运行队列，结合监管进程
PID + /proc start_ticks 校验；身份缺失、已结束或复用时保留 allocation，但设备显示
unknown。持锁根据只读 `/proc/locks` 的设备号及 inode 匹配，绝不试抢 flock。
只有旧锁文件、残留 pid 文本、或者该旧 PID 恰好仍活着，不构成持锁证据。
有效锁存在但无法归属当前分配时显示 unknown / lock_holder_unattributed；不猜测用户名，
也不将它声称为已验证的队列外 NPU 占用。

设备可以同时具有 allocation 和 reservation；这种情况下通常显示 allocated。
没有占用的预留卡显示 reserved。全局池之外的设备显示 disabled，但仍保留分配、预留
和 outside_auto_pool 原因。优先级是 unknown，再 allocated，再 disabled，再 reserved，
最后 free。schema 保留 external 和 error；第一版没有证据产生这两种状态，计数为 0。

与最初接口草案相比，需要明确以下实际调度语义：

1. pool_aware_reservation 的屏障每轮重新计算。只有当前 tick 实际生效的预留池才导出；
   日志中记住的旧 RESERVED_TASK 不是持续预留。维护或满并发而未扫描等待者时，不导出
   上轮屏障。退出维护或下一轮扫描后立即反映新屏障。free 仍不承诺能启动。
2. 一个预留池可以包含正在用的卡，也可能大于 requested_devices；它保护的是任务的
   候选池，不是提前决定的最终卡组合。第一版调度器每轮最多有一个这样的屏障。
3. 旧调度器在没有显式全局池时，仍存在按设备数量推导连续编号及缺卡时回退两卡的
   兼容行为。本改动不改变分配算法。监控枚举真实 ID，并与实际 scheduler_effective_pool
   比较；不一致返回 partial / pool_devices_not_enumerated 和 null 汇总。非连续编号
   机器应由管理员按现有流程配置准确的 AVAILABLE_DEVICES / available_devices。
4. 维护原因只公开 `maintenance`，不复制管理员可能写入的自由文本。scheduler.reason
   不尝试枚举每个任务的全部阻塞策略。无已确认硬件故障或队列外占用时保持 unsupported。

## 时效、一致性和失败

正常约每 2 秒发布一次；队列目录、占用集合、预留或维护改变时提前发布。调度器在
实际 tick 完成后调用生产者，直接传入其池、模式和预留，不解析日志、不重新运行调度。
生产者只解析当前任务文件中明确允许的归属、设备、启动时间和进程身份字段；不读取
.env、历史任务、任务脚本、日志、/proc/*/cmdline 或 /proc/*/environ，不输出命令或目录。
通过目录/文件 inode、mtime、ctime、大小以及内核锁集合前后复核检测并发变化，最多
重试三次；无法得到稳定视图时发布 unavailable，任务数和汇总为 null。采集进程限时
1 秒，失败不会终止 daemon 或改动调度策略；长期不能采集时已有快照自然过期。

CLI 单次只读最多 256KiB，验证结构、版本、重复设备和汇总一致性。它不会随缓存读取
增长 allocation.elapsed_seconds；那是 observed_at 时刻的占用时长。age_ms 单独增加。

| 情况 | JSON 行为 | 退出码 |
| --- | --- | --- |
| 正常或可描述的 partial / maintenance | 保留真实字段和原因 | 0 |
| daemon 已退出或 PID 的 start_ticks 不匹配 | stopped、unavailable、cached=true；设备改 unknown；任务数 null | 缓存未过期为 0，否则 1 |
| 超过 15 秒 | unavailable / snapshot_expired，设备 unknown，任务数 null | 1 |
| 主机已重启或单调时间不兼容 | unavailable / host_restarted，age_ms=null | 1 |
| 无法验证 daemon 身份 | unavailable / daemon_identity_unreadable | 1 |
| 快照缺失、无权读取、损坏、版本不支持、汇总冲突 | unavailable，devices=[]、汇总和任务数 null | 1 |
| 参数不符合 `--monitor --json` | unavailable，usage 原因 | 2 |

旧数据中的 allocation / reservation 仅作为最后观察保留，device.reason_codes 包含
last_observation，occupying_users 为 null。消费者必须先检查 status / cached，不能把
旧归属当成实时归属。空列表只有在 ok 且 inventory_complete=true 时才表示确实无卡。

## 部署和验证

本次只交付代码，未操作运行中的服务。沿用现有升级保护：

```bash
# 从已审核的 npu-taskqueue checkout 执行，沿用本机已有部署参数
sudo bash deploy.sh
# 部署后以普通监控账号执行
task-submit --monitor --json
pto-task --monitor --json
```

deploy.sh 在维护及升级锁保护下安装文件；发现 running 任务会返回 3 并拒绝重启。
等待任务自然结束后再次执行同一命令即可。不要直接 systemctl restart：旧 daemon 的
TERM 清理会终止其任务。setup.sh 单独执行只更新文件并留下 restart-required 标记。
原有 daemon 在安全激活前不会获得此功能；新 CLI 此时明确返回 snapshot_missing。
新版本上线后再次更新文件时，监控 producer.version 仍报告实际运行 daemon 的旧版本。
原有自动更新仍按既定 manifest、空闲检查和重试机制激活，未改写发布目标或本机配置。

回归测试（普通账号，标准 umask，所有 daemon/任务都在临时目录）：

```bash
umask 022
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_monitor*.py' -v
bash tests/verify_update_candidate.sh
bash tests/test_layout.sh
```

测试覆盖普通账号读取 root/nobody 的归属摘要、别名、不同 cwd 和恶意环境配置、空队列、
CPU-only / 多卡任务、非连续 ID、预留重叠和取消、禁用、维护、真实内核持锁、旧锁及 PID
复用、原子替换、权限失败、损坏/过期/跨启动缓存、序号及运行 revision 保持、计数校验。
硬件节点使用隔离 fixture；真实 NPU 健康和外部进程探测不在第一版范围内。
