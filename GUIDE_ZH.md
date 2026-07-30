# TaskQueue 使用说明

> 中文版，与 [GUIDE.md](GUIDE.md) 内容一致。改动请两份一起改（见
> [`.claude/rules/docs-language.md`](.claude/rules/docs-language.md)）。

共享 NPU 机器的任务队列。提交你的命令，系统给你分一张卡并锁住，不用再和别人抢。

## 提交

```bash
# NPU 任务 —— 自动分配空闲卡，并自动在命令末尾追加 "--device <卡号>"
task-submit --device auto --run "python train.py"

# NPU 任务 —— 自己指定卡号（不会自动追加，卡号由你自己传给程序）
task-submit --device 9 --run "python train.py -d 9"

# 多卡
task-submit --device auto --device-num 2 --run "python train.py --devices 0,1"

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
task-submit --devices               # 当前设备白名单
task-submit --find "<子串>"          # 按完整命令匹配，只输出 task-id（给脚本用）
```

脚本里要定位任务请用 `--find`，不要解析 `--list`：`--list` 的命令列会在 77 个
字符处截断。

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
