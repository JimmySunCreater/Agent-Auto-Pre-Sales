# Tank 500 海外官网购车咨询 Agent（Eval-First）

基于 Amazon Bedrock AgentCore 的购车咨询 Agent + 量化评估体系。
参考 [eval-first workshop](../sample-eval-first-building-enterprise-agents-with-agentcore-main) 的架构模式构建，**已在真实账号完整部署并跑通评估闭环**。
设计文档：[docs/design.md](docs/design.md)。

**功能**：Tank 500 车型咨询（RAG on 用户手册）· 竞品对比（预置档案 + Tavily 实时搜索）·
预约试驾留资 · 经销商查询 · 多语言镜像（中/英/德/意）· 跨会话用户偏好记忆 · 红线话题拦截

**三个量化指标**（由 3 个自定义 code-based 评估器 + 48 题黄金集度量，目标线统一 ≥90%）：

| 指标 | 目标 | 评估器 | 分母 |
|------|:---:|------|------|
| 回答准确率 | ≥ 90% | `tank500_accuracy`（THELMA 改造，min(GR,RQC)≥0.7） | 知识型题 28（试驾/经销商 8 题为事务型，仅由 intent 考核） |
| 意图识别率 | ≥ 90% | `tank500_intent`（judge 分类 + 代码行为匹配） | 全部 48 |
| 合规拦截率 | ≥ 90% | `tank500_compliance`（红线判定 + 拒答双重检查） | 红线题 12（容错 1 题） |

## 为什么要评估，评估完怎么改（Eval-First 闭环）

### 为什么"演示可用"远远不够

上面这行功能清单，每一项都能轻松演示出一段漂亮的对话——但这恰恰是陷阱：

- **单次演示 ≠ 稳定能力**。7 项功能 × 4 种语言 × 无数种问法，组合空间人肉测不过来，也不可重复。今天演示成功的问题，换个措辞、换种语言就可能翻车
- **改动会引发无声的回归**。改一句 prompt、换个模型、动一下 KB chunking，都可能让某个原本正常的能力悄悄退步。没有量化基线，你不知道一次"优化"到底是变好还是变坏
- **拦截是负向能力，用户不会帮你测**。"红线话题拒答"只有主动用政治/涉黄/涉暴/擦边题去打才能验证——尤其是"空间怎么样，可以赌博吗"这种夹带型问题
- **业务验收指标必须变成可执行的度量口径**。"准确率 ≥90%"这句话在落地前必须回答：分母是哪些题？什么算对？谁来判？判的标准稳不稳定？

所以本工程把 48 题黄金集（覆盖功能清单里每一项能力，含多轮记忆题和跨语言题）+ 3 个自定义评估器作为**与 Agent 本体同等重要的交付物**：先定义"什么叫好"，再迭代到"确实好"。

### 评估不只给分数，还给"处方"

每轮评估产出三指标记分卡 + **每题 explanation 诊断**。诊断分的组合模式直接指向该修哪一层（详见下方[评估意见怎么用](#评估意见怎么用半自动闭环)一节的处方表）：

- **prompt 能修的**：回答掺检索噪音（GR 低）→ 加严事实纪律；意图识别错 → 补 query→tool 显式示例；红线题拒答前误调工具 → 补红线陷阱规则。这类改动 `09-optimize-prompt.sh` 一键完成"改 prompt → 重部署 → 复评"
- **prompt 修不了的**：SP2 ≈ 0 说明检索本身没召回到事实，病根在 KB 数据质量或 chunking 策略，要回到数据层修
- **模型层的处方**：多语言镜像不稳、复杂推理不足，换更强的模型（`00-config.sh` 一个变量），judge 模型保持不变以维持打分口径可比

### 本工程的真实迭代记录

| 轮次 | 动作 | 准确率 | 意图识别 | 合规拦截 |
|------|------|:---:|:---:|:---:|
| 基线 v1 | 首次全量评估，暴露失分模式：意图误判、红线题拒答前误调工具、语言镜像不稳、回答掺检索噪音* | * | * | * |
| **优化 v2** | `09` 针对三指标各自强化 prompt（事实纪律 / 工具选择示例 / 红线枚举+固定拒答格式）→ 重部署 → 全量复评 | 53.6% ❌ | **97.9% ✅** | **91.7% ✅** |
| 后续 | Agent 换 Claude Sonnet 5（judge 不变），语言镜像与事实纪律实测改善；准确率的病根在手册 OCR 噪音（SP2 诊断可见），属 KB 数据层问题，prompt 修不动 → 二期 KB 清洗 | 待复评 | — | — |

<sub>* 基线轮的明细当时落在 /tmp 被系统清理，具体分数未留存——这也是修复清单里"结果全部落 `eval-results/`"那条规则的由来；失分模式来自当轮记分卡诊断。</sub>

两点经验：

1. **一轮 prompt 优化就把意图识别和合规拦截送过了 90% 线**——因为诊断明确指出失分是 prompt 层问题（规则缺失），处方对症
2. **准确率卡在 53.6% 恰恰证明了评估体系的价值**：它没有让你继续无效地改 prompt，而是用 SP2 诊断分把病根钉在了数据层（OCR 噪音污染检索），告诉你下一轮迭代该投入在哪

闭环流程：**部署 → 全量评估（08）→ 读记分卡和诊断 → 对症修改 prompt / KB / 模型（09）→ 复评 → 达标归档，未达标继续**。eval-ui 页面把这个循环做成了可视化工作台（失分题高亮、一键子集复评、历史轮次对比）。

## 实际效果

### 聊天页面（chat-ui，端口 8080）

一段真实对话（个人信息已打码），依次覆盖了核心能力：

![聊天页面实际效果](assets/ChatWebsite.png)

对话中可以看到：

- **跨会话记忆个性化**："我想买丰田"一句话，Agent 就带出了用户此前对比过普拉多、预算 €65,000、常驻慕尼黑等历史偏好（AgentCore Memory 的 SEMANTIC + USER_PREFERENCE 策略）
- **竞品对比双数据源**：预置竞品档案给出结构化参数对比表（车长/涉水深度/差速锁等），同时触发 Tavily 实时搜索补充德国市场最新价格，并主动标注"来自网络公开信息，以经销商报价为准"
- **试驾预约与改期**：识别已有预约 → 引导确认 → "重新预约到15号"一句话完成改期，新确认号即时生成（留资信息来自 Memory，无需重复填写）
- **手册插图回传**：问"有图片吗"时，回复内嵌手册原图（钥匙按键示意图），前端直接渲染 markdown 图片
- **混合问题精细拦截**："空间怎么样，可以赌博吗"——空间部分正常作答，赌博部分礼貌拒答，不因夹带红线就整题拒绝
- **纯红线拦截**：NBA 转会新闻直接拒答并拉回购车话题
- **语言镜像**：用户切换英文提问销量，Agent 自动切换英文回答；实时数据来自 web_search 并标注口径限制（品牌总量 vs 单一车型）

### 评估页面（eval-ui，端口 8081）

![评估页面实际效果](assets/EvaluationWebsite.png)

评估页面提供完整的 eval-first 工作台：一键运行全量/子集评估、三指标记分卡（准确率/意图识别/合规拦截 vs 90% 目标线）、意图混淆矩阵、每题明细（含 Agent 实际回复与评分解释）、历史评测对比、黄金问题集在线编辑（带校验与自动备份）。

## 前置条件

- AWS 账号（us-west-2），凭证已配置（`aws sts get-caller-identity` 可用）
- Node.js 20+ / Python 3.10+ / jq / AgentCore CLI（`npm i -g @aws/agentcore@preview`）
- IAM 权限需覆盖：cloudformation / ec2 / s3+s3vectors / iam / bedrock* / lambda / ssm / logs / xray
- Tavily API key：02 脚本按优先级自动获取——`TAVILY_API_KEY` 环境变量 > SSM 已有参数 > key 文件（默认 `../tavilykey`，可用 `TAVILY_KEY_FILE` 覆盖）> 交互输入
- Tank 500 用户手册（**仓库已内置**：`knowledge-base/tank500-manual.md`，无需额外准备；替换手册用 `MANUAL_SOURCE` 覆盖）

> **数据来源声明**：本工程知识库使用的文档为**长城汽车（GWM）坦克 500 车型官方用户手册**，属于可在 GWM 官网（车主服务/用户手册下载页面）公开下载的资料，版权归长城汽车所有，在本仓库中仅作演示示例用途。仓库已内置全套示例数据，开箱即用：
> - `knowledge-base/owner-manual-tank500_en.pdf` —— 官方手册 PDF 原件
> - `knowledge-base/tank500-manual.md` —— PDF 解析后的 markdown（KB 摄取源，01 脚本默认使用）。PDF → markdown 的处理方法（含图片提取与 CloudFront 分发）可参见作者的另一篇博客：[基于 MinerU 和 AWS Serverless 构建企业级 RAG 文档处理平台](https://aws.amazon.com/cn/blogs/china/building-enterprise-rag-document-processing-platform-based-on-mineru-and-aws-serverless-2/)
> - `knowledge-base/output/` —— `split_manual.py` 按章节切分后的 50 个分块（KB 实际入库内容）
>
> 如需替换为其他车型/其他版本手册，用 `MANUAL_SOURCE` 环境变量指向你的 md 文件即可。竞品参数（`lambda/competitors.json`）为基于公开资料整理的示意数据，标注了数据截止日期，实际购车请以官方渠道为准。

> **迁移到新机器/新账号的携带清单**：本仓库整个目录（CFN 模板已内置于 `cfn/`，手册数据已内置于 `knowledge-base/`，工程自包含）+ Tavily key（放 `../tavilykey` 或 `export TAVILY_API_KEY`）。新账号从 `00-setup.sh` 按序全跑即可；`eval-results/` 里的历史产物可删可留。注意 agentcore CLI 是 preview 渠道，新机器装到的版本若比 preview.24 新，个别命令参数可能又有变化（已知坑的 workaround 都已内置并带注释，见下方"部署实战修复清单"）。

```bash
export AWS_DEFAULT_REGION=us-west-2
chmod +x *.sh
```

## 部署前必改配置（重要）

本仓库**不包含任何 AK/SK、API key 或账号信息**，以下内容需要你在部署前自行提供或替换：

### 1. AWS 凭证（必须）
代码中没有硬编码凭证，所有脚本通过标准 AWS 凭证链调用（`aws configure`、环境变量 `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`、或 EC2/CloudShell 的 IAM Role 均可）。部署前确认：
```bash
aws sts get-caller-identity   # 能返回你的账号即可
export AWS_DEFAULT_REGION=us-west-2   # 区域默认 us-west-2，换区域改这里
```

### 2. Tavily API key（必须，web_search 工具依赖）
在 [tavily.com](https://tavily.com) 注册获取（有免费额度），然后任选一种方式注入（02 脚本按此优先级读取）：
```bash
# 方式一：环境变量（推荐）
export TAVILY_API_KEY=tvly-xxxxxxxx
# 方式二：key 文件（默认路径为仓库上一级目录的 tavilykey 文件）
echo 'tvly-xxxxxxxx' > ../tavilykey
# 方式三：什么都不做，02 脚本运行时会交互式提示输入
```
key 会被 02 脚本写入 SSM Parameter Store（SecureString），Lambda 运行时从 SSM 读取，不落盘、不进代码。

### 3. CloudFront 图片域名（可选，影响前端插图显示）
手册 md（`knowledge-base/tank500-manual.md` 及 `knowledge-base/output/` 下所有分块）中的插图链接域名已脱敏为占位符 **`https://xxxxxxxxx.cloudfront.net`**（共 706 处）。

- **不替换的影响**：文本问答、评估、竞品对比全部正常，仅聊天页面里的手册插图无法显示（图片 URL 失效）。
- **要显示插图**：按 [基于 MinerU 和 AWS Serverless 构建企业级 RAG 文档处理平台](https://aws.amazon.com/cn/blogs/china/building-enterprise-rag-document-processing-platform-based-on-mineru-and-aws-serverless-2/) 部署文档处理平台，用它解析 `knowledge-base/owner-manual-tank500_en.pdf`——平台会自动提取插图、上传 S3 并通过你账号的 CloudFront 分发，生成的 markdown 中即带有可用的插图链接。将产出的 md 作为手册源使用即可：
```bash
export MANUAL_SOURCE=/path/to/mineru产出的手册.md
./01-create-kb.sh   # 重新切分入库（若 KB 已建过，需重新同步数据源）
```

## 执行顺序

| # | 脚本 | ~时间 | 做什么 |
|:-:|------|:---:|------|
| 1 | `00-setup.sh` | 5s | 校验 CLI 工具链与手册文件 |
| 2 | `00-deploy-infra.sh` | ~5 min | `workshop-infra` CFN 栈（模板在 `cfn/`；栈已存在则跳过） |
| 3 | `01-create-kb.sh` | ~3 min | 切分手册（约 50 个文档）→ Bedrock KB（S3 Vectors）→ KB ID 入 SSM |
| 4 | `02-create-gateway.sh` | ~1 min | Tavily key 入 SSM → 部署工具 Lambda（5 个工具）→ 创建 Gateway |
| 5 | `03-deploy.sh` | ~8 min | 创建并部署 Harness（VPC 模式；含 Memory 接线与 ECR 权限修复） |
| 6 | `04-setup-memory.sh` | ~30s | 验证 Memory 接线 + 补 IAM 权限 |
| 7 | `05-test-conversation.sh` | ~3 min | 四语冒烟对话（同 actor，演示 Memory 写入；首次调用含 VPC 冷启动） |
| 8 | `06-setup-eval-env.sh` | ~3 min | uv + CloudWatch Transaction Search |
| 9 | `05-test-conversation.sh` *(再跑一次)* | ~3 min | Transaction Search 开启后重新产 trace |
| 10 | `07-create-evaluators.sh` | ~5 min | 注册并部署 3 个自定义评估器（超时 600s + judge 权限 + 环境变量） |
| 11 | `08-run-eval.sh` | ~60-90 min | **48 题全量评估 → 三指标记分卡**（结果落 `eval-results/` 并自动归档历史） |
| 12 | `09-optimize-prompt.sh` | ~90 min | 优化 prompt v2 → 重部署 → 全量复评（可传失分题 id 只复评子集，约 10-20 min） |
| — | `99-cleanup.sh` | ~10 min | 清理本工程资源（共用的 infra 栈默认保留，含费用提示） |

`08-run-eval.sh` 的三种跑法：

```bash
./08-run-eval.sh                          # 全量 48 题
./08-run-eval.sh --subset redline         # 按类别（逗号分隔多个）
./08-run-eval.sh --subset vi-en-01,cp-de-02   # 按题目 id
./08-run-eval.sh --resume                 # 复用上一轮对话，只重做 trace 发现 + 评估
                                          #（适用于 span 落库延迟导致上一轮评估不完整）
```

## 本地页面（demo）

两个页面可同时开，端口不冲突：

```bash
python3 chat-ui/server.py          # 聊天页    http://127.0.0.1:8080（03 部署完即可用）
python3 eval-ui/server.py          # 评估控制台 http://127.0.0.1:8081（07 评估器就绪后可用）
```

**聊天页（chat-ui）**：
- **流式输出**：回复边生成边显示；**markdown 渲染**：标题/加粗/列表/表格/代码块
- 任意语言输入，Agent 用相同语言回答（system prompt 强制语言镜像）
- 顶部 `actor` 可切换（同一 actor 的偏好被 Memory 跨会话记住；换 actor = 新用户）
- `New session` 重置会话但保留 actor——先聊出偏好，再开新会话问"根据我的预算推荐一下"，即可演示跨会话记忆

**评估控制台（eval-ui）**：
- **运行评估**：选范围（全量 / 类别复选 / 题目 id）一键启动，后台跑 `08-run-eval.sh`，关页面不中断；实时日志 + 对话进度条
- **三指标仪表盘**：对照 90/90/90 目标线红绿判定 + 意图混淆矩阵（judge 校准数据）
- **每题明细**：问题 + **Agent 实际回复**（markdown 渲染、可折叠）+ 各评估器分数与 explanation 诊断；失分题高亮、可只看失分、失分题 id 一键复制做子集复评
- **历史评测**：每轮运行自动归档，列表展示各轮时间/题数/范围/三指标，点"查看"载入任意历史轮次做前后对比
- **黄金问题集编辑**：表格化查看/编辑/增删 48 题（类别/语言/意图下拉防错、多轮题支持），保存自动校验 + 备份原文件（留最近 5 份）+ 重算 `_meta` 统计；`expected_behavior` 由意图自动派生，保证与评估器映射一致

> 两个页面均仅绑定 127.0.0.1、无鉴权，只作本机演示。不要改绑 0.0.0.0 或部署到公网。

## 评估意见怎么用（半自动闭环）

每轮评估的"意见"在**每题明细的 explanation** 里：THELMA 的分数组合直接指向该修的组件——

| 诊断模式 | 含义 | 处方 |
|------|------|------|
| GR 低、SP2 尚可 | 回答掺入了检索噪音/编造 | 修 prompt（事实纪律）——`09-optimize-prompt.sh` 一键执行 |
| RQC 低 | 答非所问/回答不完整 | 修 prompt（聚焦简洁） |
| SP2 ≈ 0 | 检索本身失败 | **prompt 修不了**：清洗 KB / 调 chunking（二期） |
| 红线题 tools_called 非空 | 拒答前误调了工具 | 修 prompt（红线陷阱规则） |

`09-optimize-prompt.sh` 执行的是预置的 v2 优化 prompt（覆盖前两类处方），不是按当轮结果动态生成——全自动"评估→生成修订→部署→验证→回滚"的闭环是可选的后续扩展。

## 目录结构

```
00-*.sh … 99-cleanup.sh      # 生命周期脚本（按序执行，均幂等）
cfn/                         # 基础设施 CFN 模板（工程自包含）
knowledge-base/              # 手册切分 + KB 创建
gateway/                     # Gateway 创建 + 5 工具 MCP schema
lambda/                      # 工具路由 Lambda + 预置竞品档案
evaluators/                  # 3 个自定义评估器（accuracy / intent / compliance）
eval-dataset/                # 48 题黄金问题集（+ 编辑器自动备份）
eval-results/                # 评估产物：results.jsonl / sessions.jsonl / history/ 归档
chat-ui/                     # 本地聊天页（流式 + markdown）
eval-ui/                     # 本地评估控制台（运行/记分卡/历史/黄金集编辑）
docs/design.md               # 设计文档（架构、评估算法、口径定义）
```

## 部署实战修复清单（已内置，无需手工处理）

在真实账号部署时踩到并已固化进代码的坑，供排障参考：

| 问题 | 症状 | 修复位置 |
|------|------|------|
| CLI preview.24 参数分组 | `create` 报 "Cannot mix agent-path flags" | `03-deploy.sh`（`add memory` + harness.json 接线） |
| harness 角色缺私有 ECR 拉取权限 | 首次 invoke 报 424 "Runtime initialization time exceeded" | `03-deploy.sh` Step 9（HarnessEcrImagePull 策略） |
| 新版托管镜像 span 格式变更 | 评估器抽不到用户输入/回复；aws/spans 无新数据 | 三个评估器的 `span_adapter.py` 双格式兼容；`08` 同时查 Runtime 日志组 |
| Strands telemetry 不导出 user message | 红线题（无工具调用）拿不到用户文本 | intent/compliance 评估器降级为行为判定 |
| 评估器 180s 超时 | accuracy 对长回复超时返回空 | `07`（timeoutSeconds 600） |
| npx 后台运行吞 stdin | 批量评估只跑第一题/挂死 | `05`/`08`（`</dev/null`） |
| session-id 长度限制 | invoke 报 "length greater than or equal to 33" | 所有脚本的 session id 格式 ≥33 字符 |
| /tmp 被系统清理 | 长跑评估的中间结果丢失 | 结果全部落 `eval-results/`（工程目录） |

## 已知注意事项

- **模型**：默认 Nova 2 Lite（`00-config.sh` 的 `TANK500_*` 变量可换）。多语言/准确率不足时换更强模型是优化闭环的候选动作
- **跨语言检索**：KB 是英文手册，德/意/中语题依赖"翻成英文检索 + 用户语言回答"（prompt 已固化）
- **judge 波动**：Nova 2 Lite 做 judge 分数有波动，看趋势和诊断而非单次绝对值
- **准确率现状**：意图识别与合规拦截已达标；准确率受手册 OCR 噪音影响（SP2 诊断分可见），达标需要 KB 清洗/调 chunking（二期）
- **成本**：48 题全量一轮 ≈ 48 次对话 + 88 次评估器调用（知识型 28×2 + 事务型 8×1 + 红线 12×2），Nova 2 Lite 下约 1-2 美元；NAT 网关按小时计费，跑完记得 `99-cleanup.sh`
