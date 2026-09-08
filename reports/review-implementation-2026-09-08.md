# 全项目审查改进交付记录

审查基线：`40ea6e4`。目标：完成本轮审查的 10 项修复及模块、性能、未使用代码改进。

## 实现与回归证据

| 项目 | 实现 | 验证 |
| --- | --- | --- |
| 1. 显示积压导致转写缺句 | `TranscriptStore` 在识别入口立即记账；显示队列淘汰不取消记录的翻译；迟到翻译按 ID 回填 | `CaptionPipelineTests` 直接调用真实入口，验证超过显示容量的句子全部保留；`TranscriptStoreTests` 验证淘汰记录回填及清空后不复活 |
| 2. 停止后的旧回调污染状态 | `SessionLifecycle` 同步撤销会话 ID；入口验证 ID；采集停止标记在主线程及采集队列之间同步；清空回调 | `CaptionPipelineTests` 验证旧会话在新会话出现后仍被拒绝；已停止采集不能重启或进入权限请求 |
| 3. 启动重入与异步清理 | 新增 starting/stopping；保存启动任务；采集创建即登记清理；取消后不能安装新的采集资源；`stopAndWait` 等待采集及 analyzer 清理 | `SessionLifecycleTests` 验证防重入、清理所有权、幂等撤销；菜单栏、设置同步状态 |
| 4. 翻译超时无法返回 | 独立的一次性 continuation 完成器；取消立即恢复调用方，取消系统 session 并隔离旧 runner；语言对按到达顺序调度 | `TranslationCoordinatorTests` 用不响应取消的假后端及系统可用性查询验证主动取消、reset、迟到结果、语言规范化和公平调度 |
| 5. 重复启动误杀旧进程 | 持锁实例优先；确认超时仅退出新实例；移除 terminate/forceTerminate 接管路径 | 最终安装版执行重复启动验证，结果见交付验证 |
| 6. 多音源共享草稿与去重 | `SourceDraftStore` 按音源保存草稿、译文；草稿翻译任务各自取消；去重包含来源；旧 promotion 不删除新草稿 | `SourceDraftStoreTests` 验证交错、清空、迟到翻译；真实入口测试验证不同音源同文句子分别保留 |
| 7. 旧资源准备任务清除新状态 | `ResourcePreparationCoordinator` 管理任务代次，TaskLocal 所有权传到子任务；旧进度/清理不再发布 | `ResourcePreparationCoordinatorTests` 挂起旧任务、替换后再恢复，验证新任务及更新所有权不受影响 |
| 8. 长会议摘要超上下文 | 保守 UTF-8 分块预算，逐块摘要后递归汇总；遇到系统上下文超限缩小预算重试；不收敛时明确失败；显示快照覆盖时间 | `TranscriptSummarizerTests` 验证 Unicode 全量保留、每块预算、所有块参与汇总及非收敛失败 |
| 9. Xcode/CI 缺少回归入口 | 增加真实 Xcode 单元测试目标；测试宿主不打开更新器、不争用正式实例；CI 运行 Xcode、SwiftPM 并构建 Release；发布先测试 | Xcode 与 SwiftPM 均通过 39 项；`verify-project.py` 校验 43 个源码文件、14 个 Swift 测试文件注册一致 |
| 10. 构建号不同步 | `build-metadata.py` 在每次构建时生成本地 `yyyyMMddHHmm`；验证 Xcode/AppModel/发布 tag；移除旧时间戳加一 | 3 项 Python 测试验证时钟生成、配置一致、tag 不符及旧时间戳行为 |

## 模块与性能

- `AppModel.swift` 从 4475 行减至约 2450 行；资源实现放入 `AppModel+Resources.swift`，翻译、会话所有权、记录存储、草稿、资源任务、摘要分别有独立组件。
- 提取应用音频采集和进程关联组件，缩小转写会话文件职责。
- 设置保存采用 250ms 合并、串行后台写入；退出前 flush。损坏设置原文件保留副本。
- 转写窗口使用按条目的 LazyVStack，不再在每次视图更新时拼接完整记录；记录回填使用 ID 索引。
- 移除未接入的 EntityCache、SpeedMonitor 和不可达的 maybeApplyRevision，以及旧草稿的无效状态字段。
- 本机 Debug 数据层性能测试：3600 条记录写入及翻译回填，最近一轮 Xcode 10 次平均约 0.527 秒、SwiftPM 10 次平均约 0.488 秒（较早一轮约 0.322 秒）。此数字是合成数据回放测量，不代表语音识别或 UI 的端到端延迟，也未与旧版形成相同环境下的速度对比。

## 验证命令

```bash
./scripts/test.sh
./scripts/test.sh --swiftpm
python3 -m unittest discover -s Tests/BuildTools
python3 scripts/verify-project.py
python3 scripts/build-metadata.py
./scripts/build.sh Release
```

## 交付验证

- 本地 Xcode 和 SwiftPM：各 39 项测试通过；构建工具：3 项测试通过。
- 最终 Release 构建：`v0.3.32 (202609081547)`，仅 arm64；安装到 `/Applications/v2s.app`，深度严格签名校验通过。
- 已验证设置窗口启动、字幕预览开关、记录窗口及原文/译文标签页操作。
- 旧实例暂停响应测试：暂停原进程后启动第二个实例；第二个实例正常退出，原 PID 保留，随后恢复原进程。没有强制结束旧实例。
- [远端 CI](https://github.com/orut34iop/voice2subtitle/actions/workflows/ci.yml) 会保留每次提交的测试和 Release 构建结果。

单元测试无需麦克风权限、系统模型下载或真实会议内容；并发与长记录使用可控输入验证。本轮没有执行真实会议内容的多小时录音，也没有触发正式 release/tag 发布。
