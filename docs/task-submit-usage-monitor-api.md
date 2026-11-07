# task-submit 卡时监控接口（schema 1，开发预览）

```bash
task-submit --usage-monitor --json
```

普通本机监控账号无需 sudo 即可读取所有提交账号的卡时摘要。查询只读取安装目录的
`state/usage-monitor.json`，不加载调用者配置，不运行任务、不读取登录会话、命令、环境或日志。
它与已有 `--monitor --json` 卡分配快照分开。

## 数据来源和统计口径

独立 publisher 合并旧 `usage-report/usage.sqlite3` 的 tasks 表、尚未归档的完成记录和
daemon 提供的可靠运行中分配，存入私有 `usage-monitor/usage.sqlite3`。不读取旧库 sessions
表，不触发飞书发布。任务按 `(task_id, started)` 去重，最终记录替换临时值，重复导入不累加。

- 卡秒 = 分配卡数 × 运行区间与窗口的交集秒数；显示时除以 3600。
- 今日、7 天、30 天都是所选时区的自然日，包含今日，结束于原始采样时间。
- 使用 START_TIME / FINISH_TIME，包括运行后失败或终止的任务；排队、预留、CPU-only 不计。
- 运行中只计到可靠的 daemon 观察时间；失联或结束时间未知时冻结上次值并标记 partial。
- 明确标记 ACCOUNTING_STATE=not_started 的拒绝任务不计费，可正常清理。
- 旧版拒绝记录按 EXIT_CODE=126、完全省略 START_TIME 字段及有效提交/完成元数据识别，
  auto 和数字设备请求均不计费。空的开始时间或其它不完整记录仍报错；实际运行后退出 126 的任务照常计费。
- 开始时间缺失不回退到提交时间。旧记录仅有用户名时 UID 为 null，不按当前账号反推历史 UID。
- 卡时表示队列任务占用，不是硬件忙时，也不推断队列外任务的用量。
- 历史导入不自动证明完整覆盖；缺记录不能当作零用量证明。
- `task-submit --clean` 先将完成记录提交到已启用的账本，再删除原任务；失败时保留并报错。
- 私有账本保留 35 天，为 30 个自然日及 DST 留出余量。连续采集中断超过 120 秒会重置完整覆盖起点。

## 配置和刷新

安装时默认启用 `pto-task-usage-monitor.timer`，一次结束 30 秒后再次采集，单次最多 25 秒。
`USAGE_MONITOR_ENABLED=false` 关闭；`USAGE_MONITOR_TIMEZONE` 默认 UTC，与已有日报的
`USAGE_TIMEZONE` 独立。需要当地自然日时，所有节点配置相同 IANA 时区。升级保留已有配置。

## 增量更新与性能

完成记录按文件指纹增量入库；常规刷新跳过未变化记录，不重复写账本。完成目录有新增/删除时
核对文件元数据，另每 5 分钟核对一次记录内容，避免漏掉时间戳精度范围内的同长度修改。
未写完的记录下一轮重试；刚变化的目录不立即缓存，避免同一时间戳内新增的任务被漏掉。
旧日报库仅在首次导入或数据库/WAL 文件变化时核对 tasks 表；每轮只读取固定大小的文件头
辅助识别同时间戳的更新。旧库没有逐任务变更序号，不能
仅按 rowid 或完成时间游标读取，否则会漏掉原地修正和迟到记录。

已完成和失联冻结的任务按自然日、用户名与可信 UID 缓存卡秒。每轮只应用新增、修正、删除
的差量，并补算运行中任务；跨日任务在每个窗口中仍只计一次。旧日报不会覆盖更可靠的
完成元数据。差量与每日汇总在同一事务中提交，中断后重试不会重复累计。

升级已有预览账本时自动建立派生表，保留任务和覆盖起点；更换时区时从保留的原始账本重建。
首次建账、改变时区和旧日报库变化会比普通刷新慢。目录变化及周期核对仍需遍历完成文件的
元数据，周期核对还会读取完成记录内容；常规刷新不再随历史任务数重复计算，但上述核对
成本仍受保留文件数量影响。

在 task-submit / npu-taskqueue 源码目录中使用隔离模拟数据复现性能测试（不读取服务器队列或配置）：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tests/benchmark_usage_monitor.py --history-tasks 50000 --done-files 1000
```

本地 ARM64 测试，16 个模拟账号、缓存预热后取 3 次中位数：

| 归档任务 / 完成文件 | 原版统计核心 | 增量统计核心 | 新进程完整刷新 |
| --- | --- | --- | --- |
| 1,000 / 100 | 40 ms | 1.3 ms | 105 ms |
| 10,000 / 500 | 371 ms | 1.5 ms | 106 ms |
| 50,000 / 1,000 | 1,656 ms | 2.1 ms | 110 ms |

统计核心包含采集、汇总、校验和写入快照；新进程还包含解释器启动和数据库打开。
5 万条记录首次建账约 2.56 秒，运行中补算约 2.1 ms，新增一条完成记录约 15 ms，
周期内容核对约 89 ms。上述是本机模拟测试，不代表慢磁盘或生产负载下的耗时上限。
后台仍为 Nice=10 的独立进程，不调用 NPU，不在调度循环内汇总。公开查询只读 JSON。

## 返回字段

完整模拟样例见 [JSON](task-submit-usage-monitor.example.json)。

| 字段 | 含义 |
| --- | --- |
| schema_version | 整数 1 |
| status / reason | ok、partial、unavailable；缺失原因或 null |
| observed_at | UTC 原始观察时间，不随查询或转发更新 |
| age_ms / cached | 本机单调时钟计算年龄；跨启动不可比较时 age_ms 为 null |
| timezone | 自然日使用的 IANA 时区 |
| covered_from | 可证明连续覆盖的起始 Unix 秒 |
| windows | 固定 today、7d、30d 三个窗口；不可用时可为空 |
| windows[].start / end | 窗口边界 Unix 秒，区间 `[start, end)` |
| windows[].complete | 窗口是否完整覆盖且无已知数据缺失 |
| windows[].card_seconds / task_count | 已知总卡秒、有非零卡时的不同任务数 |
| windows[].users | 最多 512 个身份：user、uid、card_seconds、task_count、active_cards |
| windows[].daily | 1、7、30 个升序日期：date、card_seconds、complete |

用户名加可信 UID 定义本机用户身份，UID 可为 null。不同服务器、不同 UID 或未知 UID 不自动
合并为同一人。active_cards 是当前可靠分配卡数，未知为 null。用户卡秒之和、每日卡秒之和
必须等于窗口总卡秒；跨天任务数不能按天重复相加。partial 数值只代表已知数据。

## 权限、时效与兼容

摘要通过同目录临时文件加原子 rename 发布为 0644，账本目录 0700、数据库 0600。
文件和 stdout 最多 256 KiB，无任意路径或命令参数。正常/部分数据退出 0；缺失、损坏、
超过 120 秒或跨启动快照退出非零；保留旧值时显式标记 cached/unavailable。

pto-btop agent 每 30 秒以独立 worker 查询，1 秒硬超时，不影响其它采集。
新增可选 `card_usage` 组，包装沿用 status / observed_monotonic_ms / interval_ms / data。
中心通过 metric_groups 声明支持；新 agent 不向旧中心发送该组，旧节点显示 N/A。
复用已有 HTTPS、证书与 agent/viewer 权限，不增加 HTTP 端口。

跨机只汇总相同窗口起点、时区且新鲜的节点，并显示覆盖数。过期或范围不同的旧值可以查看，
但不伪装成当前完整总量。中心转发累计值，不能把连续快照相加。

## 验收

覆盖运行转完成去重、跨天/DST、未知结束时间、导入及清理、普通用户查询、调用者配置隔离、
损坏/过期快照、协议兼容、用户筛选、分页、缩放和帧差分刷新。
增量路径另外验证旧账本迁移、重启复用缓存、WAL 更新、历史修正、未写完记录重试、事务回滚、
保留期清理、时钟回拨和文件时间戳碰撞，并与逐任务裁剪区间的独立计算结果对照。
