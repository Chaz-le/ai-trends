param(
  [int]$Limit = 12,
  [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "data"),
  [switch]$RefreshInsightsOnly
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:RepoCache = @{}
$script:ReadmeCache = @{}

function ConvertFrom-HtmlText {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ""
  }

  $withoutTags = [regex]::Replace($Value, "<[^>]+>", " ")
  $decoded = [System.Net.WebUtility]::HtmlDecode($withoutTags)
  return ([regex]::Replace($decoded, "\s+", " ")).Trim()
}

function Get-FirstMatch {
  param(
    [string]$Text,
    [string]$Pattern,
    [int]$Group = 1
  )

  $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if ($match.Success) {
    return $match.Groups[$Group].Value
  }
  return ""
}

function Get-ExistingSummaries {
  param([string]$OutputDir)

  $summaries = @{}
  $jsonPath = Join-Path $OutputDir "trends.json"
  if (-not (Test-Path $jsonPath)) {
    return $summaries
  }

  try {
    $existing = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($item in @($existing.weekly) + @($existing.monthly)) {
      if ($item.fullName -and $item.zhSummary) {
        $summaries[$item.fullName] = [string]$item.zhSummary
      }
    }
  } catch {
    return $summaries
  }

  return $summaries
}

function Get-RepoMetadata {
  param(
    [string]$Owner,
    [string]$Repo
  )

  $fullName = "$Owner/$Repo"
  if ($script:RepoCache.ContainsKey($fullName)) {
    return $script:RepoCache[$fullName]
  }

  $headers = @{
    "User-Agent" = "GitHub-AI-Trends"
    "Accept" = "application/vnd.github+json"
  }
  $url = "https://api.github.com/repos/$fullName"

  try {
    $repoInfo = Invoke-RestMethod -Uri $url -Headers $headers -UseBasicParsing
    $topics = @()
    if ($repoInfo.topics) {
      $topics = @($repoInfo.topics)
    }

    $meta = [pscustomobject]@{
      description = [string]$repoInfo.description
      topics = $topics
      homepage = [string]$repoInfo.homepage
      stargazersCount = [int]$repoInfo.stargazers_count
      forksCount = [int]$repoInfo.forks_count
      openIssuesCount = [int]$repoInfo.open_issues_count
      defaultBranch = [string]$repoInfo.default_branch
      pushedAt = [string]$repoInfo.pushed_at
      license = if ($repoInfo.license -and $repoInfo.license.spdx_id) { [string]$repoInfo.license.spdx_id } else { "" }
    }
  } catch {
    $meta = [pscustomobject]@{
      description = ""
      topics = @()
      homepage = ""
      stargazersCount = 0
      forksCount = 0
      openIssuesCount = 0
      defaultBranch = ""
      pushedAt = ""
      license = ""
    }
  }

  $script:RepoCache[$fullName] = $meta
  return $meta
}

function ConvertFrom-Base64Utf8 {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ""
  }

  try {
    $clean = $Value -replace "\s", ""
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($clean))
  } catch {
    return ""
  }
}

function Get-RepoReadme {
  param(
    [string]$Owner,
    [string]$Repo
  )

  $fullName = "$Owner/$Repo"
  if ($script:ReadmeCache.ContainsKey($fullName)) {
    return $script:ReadmeCache[$fullName]
  }

  $headers = @{
    "User-Agent" = "GitHub-AI-Trends"
    "Accept" = "application/vnd.github+json"
  }
  $url = "https://api.github.com/repos/$fullName/readme"

  try {
    $readme = Invoke-RestMethod -Uri $url -Headers $headers -UseBasicParsing
    $content = ConvertFrom-Base64Utf8 -Value ([string]$readme.content)
  } catch {
    $content = ""
  }

  $script:ReadmeCache[$fullName] = $content
  return $content
}

function Convert-MarkdownLine {
  param([string]$Line)

  if ([string]::IsNullOrWhiteSpace($Line)) {
    return ""
  }

  $clean = [string]$Line
  $clean = [regex]::Replace($clean, "!\[[^\]]*\]\([^)]+\)", " ")
  $clean = [regex]::Replace($clean, "\[([^\]]+)\]\([^)]+\)", '$1')
  $clean = [regex]::Replace($clean, "^\s{0,3}#{1,6}\s*", "")
  $clean = [regex]::Replace($clean, "^\s*[-*+]\s+\[[ xX]\]\s*", "")
  $clean = [regex]::Replace($clean, "^\s*[-*+]\s*", "")
  $clean = [regex]::Replace($clean, "^\s*\d+[\.)]\s*", "")
  $clean = [regex]::Replace($clean, "<[^>]+>", " ")
  $clean = [System.Net.WebUtility]::HtmlDecode($clean)
  $clean = $clean -replace '[`*_>#~]', ''
  $clean = [regex]::Replace($clean, "\s+", " ").Trim()
  return $clean
}

function Normalize-MarkdownText {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ""
  }

  $plain = [regex]::Replace($Text, '(?is)```.*?```', " ")
  $plain = [regex]::Replace($plain, '(?im)^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$', " ")
  $plain = [regex]::Replace($plain, '!\[[^\]]*\]\([^)]+\)', " ")
  $plain = [regex]::Replace($plain, '\[([^\]]+)\]\([^)]+\)', '$1')
  $plain = [regex]::Replace($plain, '<[^>]+>', " ")
  $plain = [System.Net.WebUtility]::HtmlDecode($plain)
  $plain = $plain -replace '[`*_>#~]', ''
  return ([regex]::Replace($plain, "\s+", " ")).Trim()
}

function Get-ReadmeTitle {
  param([string]$Readme)

  if ([string]::IsNullOrWhiteSpace($Readme)) {
    return ""
  }

  $matches = [regex]::Matches($Readme, "(?m)^\s{0,3}#\s+(.+?)\s*$")
  foreach ($match in $matches) {
    $title = Convert-MarkdownLine $match.Groups[1].Value
    $lower = $title.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($title)) {
      continue
    }
    if ($lower -match "^(\d+|install|installation|quick.?start|usage|getting started|setup|examples?|docs?|documentation|requirements?|sponsors?|support|faq|license|contributing|macos or linux|windows|linux|table of contents)$") {
      continue
    }
    if ($lower -match "^\d+\s*[—-]\s*") {
      continue
    }
    return $title
  }

  return ""
}

function Get-ReadmeSectionText {
  param(
    [string]$Readme,
    [string[]]$Patterns
  )

  if ([string]::IsNullOrWhiteSpace($Readme)) {
    return ""
  }

  $lines = [regex]::Split($Readme, "\r?\n")
  $capture = $false
  $level = 0
  $collected = New-Object System.Collections.Generic.List[string]

  foreach ($line in $lines) {
    $heading = [regex]::Match($line, "^\s{0,3}(#{1,6})\s+(.+?)\s*$")
    if ($heading.Success) {
      $headingLevel = $heading.Groups[1].Value.Length
      $headingText = (Convert-MarkdownLine $heading.Groups[2].Value).ToLowerInvariant()

      if ($capture -and $headingLevel -le $level) {
        break
      }

      foreach ($pattern in $Patterns) {
        if ($headingText -match $pattern) {
          $capture = $true
          $level = $headingLevel
          break
        }
      }

      continue
    }

    if ($capture) {
      $collected.Add($line)
    }
  }

  return ($collected -join "`n")
}

function Test-GoodInsightLine {
  param([string]$Line)

  if ([string]::IsNullOrWhiteSpace($Line)) {
    return $false
  }

  if ($Line.Length -lt 10 -or $Line.Length -gt 190) {
    return $false
  }

  $lower = $Line.ToLowerInvariant()
  if ($lower -match "^[a-z0-9._/\-]+\.(txt|md|json|yaml|yml)\s*[·•-]?$") {
    return $false
  }
  if ($lower -match "^(install|installation|quick.?start|usage|getting started|setup|examples?|docs?|documentation|requirements?|table of contents|sponsors?|support the project|contributing|license|faq)$") {
    return $false
  }
  if ($lower -match "^(pip|uv|npm|pnpm|yarn|node|python|python3|cargo|docker|git|curl|wget|brew|conda)\s+") {
    return $false
  }
  if ($lower -match "disclaimer|sponsor|support the project|open a pull request|open an issue|api key|contributing\.md|license|terms of service") {
    return $false
  }
  if ($Line -match "([·•]\s*){3,}") {
    return $false
  }
  if ($Line -match "^[\p{So}\p{Sk}\p{P}\s]+$") {
    return $false
  }
  if ($lower -match "^\|") {
    return $false
  }
  if ($lower -match "^(badge|license|stars|forks|contributors|install|pip install|npm install|pnpm install|yarn add)\b") {
    return $false
  }
  if ($lower -match "https?://|img\.shields|github\.com/.+/actions|discord\.gg|twitter\.com|x\.com") {
    return $false
  }

  return $true
}

function Select-InsightLines {
  param(
    [string]$Text,
    [string]$FallbackText = "",
    [string]$Keywords = "",
    [int]$Limit = 3
  )

  $source = "$Text`n$FallbackText"
  if ([string]::IsNullOrWhiteSpace($source)) {
    return @()
  }

  $source = [regex]::Replace($source, '(?is)```.*?```', " ")
  $seen = @{}
  $results = New-Object System.Collections.Generic.List[string]

  foreach ($raw in [regex]::Split($source, "\r?\n")) {
    $isList = $raw -match "^\s*([-*+]|\d+[\.)])\s+"
    $clean = Convert-MarkdownLine $raw

    if (-not (Test-GoodInsightLine $clean)) {
      continue
    }

    $lower = $clean.ToLowerInvariant()
    $matchesKeyword = [string]::IsNullOrWhiteSpace($Keywords) -or ($lower -match $Keywords)
    if (-not ($isList -or $matchesKeyword)) {
      continue
    }

    if (-not $seen.ContainsKey($lower)) {
      $seen[$lower] = $true
      $results.Add($clean)
    }

    if ($results.Count -ge $Limit) {
      return @($results)
    }
  }

  if ($results.Count -lt $Limit) {
    $plain = Normalize-MarkdownText $source
    foreach ($sentence in [regex]::Split($plain, "(?<=[\.\!\?。！？])\s+")) {
      $clean = Convert-MarkdownLine $sentence

      if (-not (Test-GoodInsightLine $clean)) {
        continue
      }

      $lower = $clean.ToLowerInvariant()
      $matchesKeyword = [string]::IsNullOrWhiteSpace($Keywords) -or ($lower -match $Keywords)
      if (-not $matchesKeyword) {
        continue
      }

      if (-not $seen.ContainsKey($lower)) {
        $seen[$lower] = $true
        $results.Add($clean)
      }

      if ($results.Count -ge $Limit) {
        return @($results)
      }
    }
  }

  return @($results | Select-Object -First $Limit)
}

function Format-FeaturePoint {
  param([string]$Line)

  $lower = $Line.ToLowerInvariant()
  $prefix = "README 线索"

  if ($lower -match "\bmcp\b|agent|tool use|tool-use|claude code|codex|cursor") {
    $prefix = "Agent / 工具调用"
  } elseif ($lower -match "\brag\b|retrieval|vector|embedding|knowledge|semantic search") {
    $prefix = "检索 / 知识库"
  } elseif ($lower -match "compress|context|memory|token|prompt") {
    $prefix = "上下文处理"
  } elseif ($lower -match "api|sdk|server|cli|command|plugin|extension") {
    $prefix = "接口 / 工具形态"
  } elseif ($lower -match "image|video|audio|voice|speech|multimodal|diffusion") {
    $prefix = "多模态能力"
  } elseif ($lower -match "train|fine.?tune|inference|benchmark|eval|model") {
    $prefix = "模型 / 评测"
  }

  return "$prefix：$Line"
}

function Add-UniqueText {
  param(
    [System.Collections.Generic.List[string]]$List,
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return
  }

  $key = $Value.ToLowerInvariant()
  foreach ($item in $List) {
    if ($item.ToLowerInvariant() -eq $key) {
      return
    }
  }

  $List.Add($Value)
}

function New-ProjectProfile {
  param(
    [string]$FullName,
    [string]$Description,
    [string]$Language,
    [string[]]$Topics,
    [string[]]$Tags,
    [string]$Readme
  )

  $primaryText = "$FullName $Description $Language $($Topics -join ' ') $($Tags -join ' ')".ToLowerInvariant()
  $supportText = "$primaryText $Readme".ToLowerInvariant()
  $features = New-Object System.Collections.Generic.List[string]
  $scenarios = New-Object System.Collections.Generic.List[string]
  $title = ""
  $intro = ""
  $category = "other"

  if ($primaryText -match "headroom|compress|compression|rag chunks? before|tool outputs?.*llm|logs?.*llm") {
    $category = "context-compression"
    $title = "LLM 上下文压缩工具"
    $intro = "在工具输出、日志、文件和 RAG 分块进入大模型前先做压缩，目标是在保留答案质量的同时减少 60% 到 95% 的 token 消耗。"
    Add-UniqueText -List $features -Value "压缩日志、文件内容、RAG 分块和工具调用结果，降低长上下文成本。"
    Add-UniqueText -List $features -Value "提供库、代理和 MCP Server 等接入方式，方便放进 Claude Code、Codex、Cursor 等 Agent 工作流。"
    Add-UniqueText -List $features -Value "强调本地优先和可逆压缩，适合对上下文噪音和 token 成本敏感的场景。"
    Add-UniqueText -List $scenarios -Value "适合长日志分析、RAG 知识库问答、代码仓库阅读和 Agent 工具输出过长的工作流。"
  }
  elseif ($primaryText -match "agent reach|agent-reach|read.*twitter.*reddit|read.*reddit.*youtube|bilibili|xiaohongshu|zero api fees|entire internet") {
    $category = "agent-web-reach"
    $title = "Agent 互联网检索工具"
    $intro = "给 AI Agent 提供读取和搜索 Twitter、Reddit、YouTube、GitHub、Bilibili、小红书等平台的能力，主打无需官方 API。"
    Add-UniqueText -List $features -Value "通过一个 CLI 帮 Agent 读取多个网站和社区平台内容。"
    Add-UniqueText -List $features -Value "面向没有 API 权限或不想接多个平台 API 的信息收集场景。"
    Add-UniqueText -List $features -Value "适合把网页和社交内容作为 Agent 调研、监控和分析的输入。"
    Add-UniqueText -List $scenarios -Value "适合舆情观察、内容调研、竞品动态跟踪和让 Agent 自动查找互联网上的实时资料。"
  }
  elseif ($primaryText -match "last30days|last 30 days|researches any topic across|polymarket|hacker news|grounded summary") {
    $category = "trend-research"
    $title = "近 30 天热点研究技能"
    $intro = "让 AI Agent 围绕一个主题检索 Reddit、X、YouTube、Hacker News、Polymarket 和网页内容，并整理近期真实讨论与趋势结论。"
    Add-UniqueText -List $features -Value "跨社区和网页搜索近期内容，优先捕捉真实用户讨论、投票、热度和市场信号。"
    Add-UniqueText -List $features -Value "把过去 30 天的信息汇总成可引用的研究摘要，减少手动翻多个平台的成本。"
    Add-UniqueText -List $features -Value "以 Agent skill 的形式运行，可接入支持技能机制的 AI 工具。"
    Add-UniqueText -List $scenarios -Value "适合做产品调研、竞品观察、热点复盘、市场信号收集和会议前背景梳理。"
  }
  elseif ($primaryText -match "taste|anti.?slop|generic slop|good taste|boring|frontend framework") {
    $category = "taste-skill"
    $title = "AI 生成质量约束技能"
    $intro = "给 AI 编程或设计 Agent 增加审美和输出质量约束，重点减少模板化、粗糙、空泛的前端与文案结果。"
    Add-UniqueText -List $features -Value "通过技能规则约束 AI 的 UI、文案和产品表达，避免生成千篇一律的界面。"
    Add-UniqueText -List $features -Value "强调前端品味、信息层级和细节打磨，适合作为 AI 生成界面的质量门槛。"
    Add-UniqueText -List $features -Value "不是通用 Agent 框架，而是专门改善 AI 生成结果质感的提示与规范集合。"
    Add-UniqueText -List $scenarios -Value "适合用 AI 快速做页面、组件、产品原型时，提升第一版输出的可用性和观感。"
  }
  elseif ($primaryText -match "pm-skills|pm skills|product decisions|product discovery|roadmap|strategy|launch and growth|from discovery to strategy") {
    $category = "pm-skills"
    $title = "产品经理 Agent 技能市场"
    $intro = "面向产品发现、策略、路线图、执行、发布和增长的 Agent 技能集合，把产品经理工作流拆成可复用命令和插件。"
    Add-UniqueText -List $features -Value "覆盖产品调研、策略制定、路线图、上线和增长等 PM 常见任务。"
    Add-UniqueText -List $features -Value "用技能、命令和插件组织工作流，让 Agent 按产品阶段连续执行。"
    Add-UniqueText -List $features -Value "适合把产品决策过程结构化，而不是只让 AI 做零散问答。"
    Add-UniqueText -List $scenarios -Value "适合产品经理、创业团队或独立开发者用 AI 辅助做需求判断、发布计划和增长分析。"
  }
  elseif ($primaryText -match "skillspector|security scanner|vulnerabilit|malicious|security risks") {
    $category = "security-scanner"
    $title = "AI Agent 技能安全扫描器"
    $intro = "用于扫描 AI Agent 技能中的漏洞、恶意模式和安全风险，帮助判断第三方技能是否值得安装和执行。"
    Add-UniqueText -List $features -Value "扫描 Git 仓库、URL、压缩包、目录或单文件中的 Agent 技能内容。"
    Add-UniqueText -List $features -Value "结合静态规则和可选 LLM 语义分析，识别恶意指令、危险权限和供应链风险。"
    Add-UniqueText -List $features -Value "可查询漏洞数据源，帮助发现依赖或代码中的已知安全问题。"
    Add-UniqueText -List $scenarios -Value "适合在安装第三方 Claude Code、Codex 或其他 Agent 技能前做安全检查。"
  }
  elseif ($primaryText -match "markitdown|convert.*markdown|office documents|pdf|docx|pptx|xlsx") {
    $category = "document-markdown"
    $title = "文档转 Markdown 工具"
    $intro = "把 Office 文档、PDF、图片和其他文件转换成 Markdown，方便后续交给 LLM、RAG 或知识库处理。"
    Add-UniqueText -List $features -Value "支持多种文件格式转成结构化 Markdown，保留对大模型有用的文档结构。"
    Add-UniqueText -List $features -Value "可作为 Python 工具或数据预处理步骤接入 RAG、文档问答和内容分析流程。"
    Add-UniqueText -List $features -Value "重点解决非结构化文件进入 AI 工作流前的格式清洗问题。"
    Add-UniqueText -List $scenarios -Value "适合企业资料入库、PDF/Office 文档问答、知识库构建和批量文档预处理。"
  }
  elseif ($primaryText -match "knowledge graph|codegraph|code graph|repo.*graph|codebase.*graph") {
    $category = "code-knowledge-graph"
    $title = "代码知识图谱工具"
    $intro = "把代码仓库预先索引成知识图谱，让 Claude Code、Codex、Cursor 等工具更快理解符号关系、调用链和项目结构。"
    Add-UniqueText -List $features -Value "为代码库生成符号关系、调用图和结构化索引，减少 Agent 反复 grep 和读文件。"
    Add-UniqueText -List $features -Value "支持本地查询和自动同步，代码变化后保持知识图谱更新。"
    Add-UniqueText -List $features -Value "把代码理解从临时扫描变成可复用上下文。"
    Add-UniqueText -List $scenarios -Value "适合大型代码仓库理解、AI 代码审查、重构分析和让编码 Agent 更快定位相关文件。"
  }
  elseif ($primaryText -match "x1xhlol/system-prompts-and-models-of-ai-tools|full augment code|and other open sourced.*system prompts|internal tools.*ai models") {
    $category = "prompt-model-catalog"
    $title = "AI 工具提示词与模型配置合集"
    $intro = "聚合 Augment Code、Claude Code、Cursor、Devin、Lovable、Replit、Windsurf、v0 等大量 AI 编程和产品工具的系统提示词、内部工具与模型线索。"
    Add-UniqueText -List $features -Value "按产品横向收集系统提示词、内部工具定义和模型使用信息，覆盖大量 AI 编程 Agent 与 AI 产品。"
    Add-UniqueText -List $features -Value "适合快速查找某个 AI 工具背后的角色设定、工具权限、工作流提示和模型配置线索。"
    Add-UniqueText -List $features -Value "更像全景式资料索引和对比清单，不是自动提取器，也不是可直接运行的 Agent 框架。"
    Add-UniqueText -List $scenarios -Value "适合做 AI 编程工具竞品拆解、提示词工程参考、Agent 产品机制研究和资料收藏。"
  }
  elseif ($primaryText -match "asgeirtj/system_prompts_leaks|extracted system prompts from|anthropic.*openai.*google.*xai|updated regularly.*system prompts|claude fable|gpt 5\.5") {
    $category = "prompt-leak-dataset"
    $title = "主流模型系统提示词泄露库"
    $intro = "整理从 Anthropic、OpenAI、Google、xAI 以及 Cursor、Copilot、Perplexity 等产品抽取出的系统提示词，侧重按厂商和模型版本持续更新。"
    Add-UniqueText -List $features -Value "按厂商和产品来源归档 Claude、ChatGPT、Gemini、Grok、Codex、Cursor 等系统提示词。"
    Add-UniqueText -List $features -Value "强调 extracted leaks 和 regular updates，便于追踪不同模型版本的系统指令变化。"
    Add-UniqueText -List $features -Value "更偏模型行为和安全边界研究，不是泛 AI 工具清单，也不重点记录模型配置。"
    Add-UniqueText -List $scenarios -Value "适合观察各家模型如何约束身份、安全边界、工具调用和回答风格。"
    Add-UniqueText -List $scenarios -Value "适合做模型行为研究、提示词演化追踪、安全/越狱防护分析。"
  }
  elseif ($primaryText -match "system prompt|system prompts|internal tools|prompt collection|prompts") {
    $category = "prompt-archive"
    $title = "AI 产品系统提示词资料库"
    $intro = "收集主流 AI 产品、编码工具和 Agent 的系统提示词、内部工具说明和模型相关资料，方便研究产品机制。"
    Add-UniqueText -List $features -Value "整理不同 AI 产品的系统提示词和内部工具暴露信息。"
    Add-UniqueText -List $features -Value "帮助研究提示词设计、工具调用规范和 AI 产品行为差异。"
    Add-UniqueText -List $features -Value "更偏资料归档和逆向观察，不是可直接接入的开发框架。"
    Add-UniqueText -List $scenarios -Value "适合做提示词研究、竞品分析、Agent 行为研究和学习大型 AI 产品的系统设计。"
  }
  elseif ($primaryText -match "persistent memory|agent memory|memory for ai|long.?term memory") {
    $category = "agent-memory"
    $title = "AI Agent 长期记忆工具"
    $intro = "为 AI 编程 Agent 或个人助手提供可持续记忆，让模型跨任务保留项目偏好、经验和上下文。"
    Add-UniqueText -List $features -Value "保存 Agent 在真实项目中的经验、约定和历史决策，减少重复说明。"
    Add-UniqueText -List $features -Value "面向编码 Agent 的长期上下文管理，而不是单次聊天记录。"
    Add-UniqueText -List $features -Value "强调基准和真实工作流中的记忆效果。"
    Add-UniqueText -List $scenarios -Value "适合长期维护同一项目、团队规范复杂或希望 AI 助手逐渐熟悉个人工作流的用户。"
  }
  elseif ($primaryText -match "terminal|cli|lsp|subagents?|hash.?anchored|code edits") {
    $category = "terminal-coding-agent"
    $title = "终端 AI 编码 Agent"
    $intro = "在命令行里运行的 AI 编码 Agent，集成代码编辑、LSP、浏览器、Python、子 Agent 和更可靠的改动定位能力。"
    Add-UniqueText -List $features -Value "在终端中完成代码理解、编辑、运行工具和多 Agent 协作。"
    Add-UniqueText -List $features -Value "通过 hash 锚定等方式提高代码改动定位和应用的可靠性。"
    Add-UniqueText -List $features -Value "把浏览器、Python、语言服务和子任务代理整合进编码工作台。"
    Add-UniqueText -List $scenarios -Value "适合习惯命令行开发、希望用 AI 处理代码修改、调试和多步骤工程任务的开发者。"
  }
  elseif ($primaryText -match "academic|research|write|review|revise|paper|citation") {
    $category = "academic-research"
    $title = "学术研究写作技能集"
    $intro = "把学术研究中的调研、写作、审阅、修改和定稿流程拆成 Claude Code 可调用的技能。"
    Add-UniqueText -List $features -Value "覆盖研究资料整理、论文写作、审稿式检查和修改迭代。"
    Add-UniqueText -List $features -Value "把开放式研究任务拆成可重复执行的技能流程。"
    Add-UniqueText -List $features -Value "强调研究输出质量和可审阅流程，而不是通用聊天问答。"
    Add-UniqueText -List $scenarios -Value "适合科研写作、文献综述、论文初稿打磨和研究项目管理。"
  }
  elseif ($primaryText -match "computer vision|classification|coco|roboflow|object detection|segmentation") {
    $category = "computer-vision"
    $title = "计算机视觉工具库"
    $intro = "围绕分类、检测、分割、数据集格式和视觉模型推理提供可复用工具。"
    Add-UniqueText -List $features -Value "支持常见计算机视觉任务的数据处理、模型连接或推理流程。"
    Add-UniqueText -List $features -Value "面向图像分类、目标检测、分割和 COCO 等数据格式。"
    Add-UniqueText -List $features -Value "适合把视觉模型能力接入实际应用或实验流程。"
    Add-UniqueText -List $scenarios -Value "适合计算机视觉项目、数据集处理、模型推理验证和视觉 AI 原型开发。"
  }
  elseif ($primaryText -match "video|short videos|moviepy|image|audio|voice|speech|multimodal|diffusion") {
    $category = "multimodal-generation"
    $title = "AI 多模态内容生成工具"
    $intro = "围绕图像、视频、语音或多模态内容生成提供自动化能力，适合把大模型输出转成可发布素材。"
    Add-UniqueText -List $features -Value "支持围绕视频、图像或语音素材的生成与自动化处理。"
    Add-UniqueText -List $features -Value "把大模型、脚本和媒体处理流程组合成一键式内容生成。"
    Add-UniqueText -List $features -Value "适合内容生产型 AI 应用原型。"
    Add-UniqueText -List $scenarios -Value "适合短视频生成、营销素材自动化、图文转视频和多媒体内容实验。"
  }
  elseif ($primaryText -match "agent.?skills?|skills for ai coding agents|engineering skills|claude-code|antigravity|coding agents?|skills for real engineers|\.claude directory") {
    $category = "agent-skills"
    $title = "AI 编程 Agent 技能库"
    $intro = "面向 Claude Code、Codex、Cursor 等 AI 编程 Agent 的工程技能集合，把 API 设计、前端工程、测试、评审等工作沉淀成可复用操作规范。"
    Add-UniqueText -List $features -Value "提供按任务触发的 Agent 技能，让模型在写代码、设计接口、构建 UI 等场景调用对应工程流程。"
    Add-UniqueText -List $features -Value "把工程经验写成可复用技能文件，减少 Agent 生成泛泛代码或漏掉关键检查。"
    Add-UniqueText -List $features -Value "适配多种 AI 编程环境，重点提升编码 Agent 的项目执行质量，而不是压缩上下文。"
    Add-UniqueText -List $scenarios -Value "适合经常用 Claude Code、Codex、Cursor 做真实项目开发的人，把常用工程规范变成 Agent 可执行技能。"
  }
  elseif ($primaryText -match "\brag\b|retrieval|vector|embedding|semantic search|knowledge graph|knowledge base|search") {
    $category = "rag-search"
    $title = "RAG / 语义检索工具"
    $intro = "围绕向量索引、语义搜索、知识库或文档问答构建检索能力，让大模型更方便使用外部知识。"
    Add-UniqueText -List $features -Value "支持向量、语义搜索、知识库或文档检索相关能力。"
    Add-UniqueText -List $features -Value "可作为 RAG 管道中的索引、召回或知识组织组件。"
    Add-UniqueText -List $features -Value "帮助把外部资料转成大模型可查询的上下文。"
    Add-UniqueText -List $scenarios -Value "适合企业知识库、资料检索、文档问答和 RAG 原型验证。"
  }
  else {
    $title = "AI 开源工具"
    if ($Description) {
      $intro = "该项目的 GitHub 简介是：" + $Description
      Add-UniqueText -List $features -Value ("核心线索：" + $Description)
    } else {
      $intro = "该项目与 AI 工具、Agent 或模型工作流相关，但 README/简介信息不足，需要进入仓库进一步确认。"
      Add-UniqueText -List $features -Value "信息不足：需要查看 README、示例和 issue 后再判断具体能力。"
    }
    Add-UniqueText -List $scenarios -Value "适合先打开仓库 README 和示例快速试用，再判断是否值得接入自己的工作流。"
  }

  return [pscustomobject]@{
    category = $category
    zhTitle = $title
    zhIntro = $intro
    featurePoints = [object[]]@($features | Select-Object -First 3)
    scenarioPoints = [object[]]@($scenarios | Select-Object -First 2)
  }
}

function Get-RuleFeaturePoints {
  param(
    [string]$FullName,
    [string]$Description,
    [string]$Language,
    [string[]]$Topics,
    [string[]]$Tags,
    [string]$Readme
  )

  $profile = New-ProjectProfile `
    -FullName $FullName `
    -Description $Description `
    -Language $Language `
    -Topics $Topics `
    -Tags $Tags `
    -Readme $Readme

  return @($profile.featurePoints | Select-Object -First 3)
}

function Format-ScenarioPoint {
  param([string]$Line)

  $lower = $Line.ToLowerInvariant()
  if ($lower -match "example|demo|quickstart|usage|workflow|use case") {
    return "可按 README 示例落地：$Line"
  }

  return "适用线索：$Line"
}

function Get-ScenarioFallback {
  param(
    [string]$FullName,
    [string]$Description,
    [string[]]$Topics,
    [string[]]$Tags,
    [string[]]$FeatureLines
  )

  $text = "$FullName $Description $($Topics -join ' ') $($Tags -join ' ') $($FeatureLines -join ' ')".ToLowerInvariant()

  if ($text -match "claude code|codex|cursor|coding|code assistant|developer|repo|codebase") {
    return "适合想把它接入 AI 编程、代码审查、仓库理解或开发自动化流程的开发者。"
  }
  if ($text -match "\brag\b|retrieval|vector|embedding|knowledge|document|semantic search") {
    return "适合做企业知识库、文档问答、资料检索或 RAG 管道验证。"
  }
  if ($text -match "agent|tool use|tool-use|mcp|workflow|automation") {
    return "适合搭建需要工具调用、任务编排、长期运行或多步骤自动化的 AI Agent。"
  }
  if ($text -match "compress|context|memory|token|prompt") {
    return "适合长上下文、日志分析、RAG 分块或 token 成本敏感的 LLM 工作流。"
  }
  if ($text -match "image|video|audio|voice|speech|multimodal|diffusion") {
    return "适合需要图像、视频、语音或多模态内容生成/理解的产品原型。"
  }
  if ($text -match "train|fine.?tune|inference|benchmark|eval|model") {
    return "适合模型训练、推理部署、评测对比或机器学习实验流程。"
  }

  return "适合先根据 README 示例快速试用，再判断是否接入自己的 AI 工具或业务流程。"
}

function New-RepoInsight {
  param(
    [string]$FullName,
    [string]$Description,
    [string]$Language,
    [string[]]$Topics,
    [string[]]$Tags,
    [string]$Readme
  )

  $readmeTitle = Get-ReadmeTitle -Readme $Readme
  $profile = New-ProjectProfile `
    -FullName $FullName `
    -Description $Description `
    -Language $Language `
    -Topics $Topics `
    -Tags $Tags `
    -Readme $Readme

  $overviewSection = Get-ReadmeSectionText -Readme $Readme -Patterns @("overview", "introduction", "about", "what\s+is", "why", "purpose")
  $featureSection = Get-ReadmeSectionText -Readme $Readme -Patterns @("feature", "capabilit", "highlight", "what.*can", "supported", "key")
  $usageSection = Get-ReadmeSectionText -Readme $Readme -Patterns @("usage", "quick.?start", "getting\s+started", "example", "demo", "use\s+case", "workflow", "how\s+to")

  $featureKeywords = "feature|support|provide|enable|allow|integrat|agent|mcp|rag|llm|model|api|sdk|cli|plugin|workflow|memory|context|search|retrieve|generate|compress|deploy|evaluate|benchmark|train|inference|automate"
  $featureCandidates = @(Select-InsightLines -Text $featureSection -FallbackText "$overviewSection`n$Readme" -Keywords $featureKeywords -Limit 3)
  if ($featureCandidates.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($Description)) {
    $featureCandidates = @($Description)
  }

  $featurePoints = New-Object System.Collections.Generic.List[string]
  foreach ($point in @($profile.featurePoints)) {
    Add-UniqueText -List $featurePoints -Value $point
  }
  foreach ($line in $featureCandidates) {
    if ($featurePoints.Count -gt 0) {
      break
    }
    Add-UniqueText -List $featurePoints -Value (Format-FeaturePoint -Line $line)
    if ($featurePoints.Count -ge 3) {
      break
    }
  }
  if ($featurePoints.Count -eq 0) {
    $featurePoints.Add("README 信息不足：当前只能先通过仓库简介、topics 和增长数据判断项目价值。")
  }
  $featurePoints = @($featurePoints | Select-Object -First 3)

  $scenarioKeywords = "use case|example|demo|workflow|quick.?start|getting started|usage|production|deploy|team|developer|research|customer|document|code|agent"
  $scenarioCandidates = @(Select-InsightLines -Text $usageSection -FallbackText "" -Keywords $scenarioKeywords -Limit 2)

  $scenarioPoints = New-Object System.Collections.Generic.List[string]
  foreach ($point in @($profile.scenarioPoints)) {
    Add-UniqueText -List $scenarioPoints -Value $point
  }
  foreach ($line in $scenarioCandidates) {
    if ($scenarioPoints.Count -ge 2) {
      break
    }
    Add-UniqueText -List $scenarioPoints -Value (Format-ScenarioPoint -Line $line)
  }
  if ($scenarioPoints.Count -eq 0) {
    $scenarioPoints.Add((Get-ScenarioFallback -FullName $FullName -Description $Description -Topics $Topics -Tags $Tags -FeatureLines @($featureCandidates)))
  }

  $introParts = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($profile.zhIntro)) {
    $introParts.Add($profile.zhIntro)
  }
  if ($introParts.Count -eq 0) {
    $langText = if ($Language) { "$Language " } else { "" }
    $introParts.Add("$FullName 是一个 ${langText}GitHub 项目，README 可提供进一步判断依据")
  }

  $source = if ([string]::IsNullOrWhiteSpace($Readme)) { "metadata" } else { "readme" }

  return [pscustomobject]@{
    source = $source
    readmeTitle = $readmeTitle
    category = $profile.category
    zhTitle = $profile.zhTitle
    zhIntro = $profile.zhIntro
    projectIntro = ($introParts -join "；")
    featurePoints = [object[]]@($featurePoints)
    scenarioPoints = [object[]]@($scenarioPoints)
  }
}

function Get-AiTags {
  param(
    [string]$Name,
    [string]$Description,
    [string[]]$Topics
  )

  $topicText = ($Topics -join " ")
  $text = "$Name $Description $topicText".ToLowerInvariant()
  $rules = @(
    @{ Tag = "agent"; Pattern = "(^|[^a-z])ai([^a-z]|$)|\bagents?\b|autonomous|tool.?use|mcp|claude code|codex|cursor|computer.?use" },
    @{ Tag = "llm"; Pattern = "\bllm\b|large language model|chatgpt|gpt-|openai|anthropic|claude|gemini|ollama|llama|vllm|transformer|hugging ?face" },
    @{ Tag = "rag"; Pattern = "\brag\b|retrieval|vector database|embeddings?|semantic search|knowledge graph|knowledge base|notebooklm|document ai" },
    @{ Tag = "coding"; Pattern = "codebase|code assistant|coding agent|copilot|programming with ai|developer assistant|repository analysis|code graph|code review" },
    @{ Tag = "multimodal"; Pattern = "multimodal|vision-language|image generation|video generation|speech|voice|whisper|tts|stable diffusion|diffusion|text-to-|text to image|text to video|vtuber|avatar" },
    @{ Tag = "ml"; Pattern = "machine learning|deep learning|neural|training|fine.?tuning|inference|model serving|pytorch|tensorflow|jax|model" },
    @{ Tag = "generation"; Pattern = "generative|generate|prompt|prompt engineering|video generator|image generator|content creation" },
    @{ Tag = "learning"; Pattern = "course|tutorial|learn|awesome|from scratch|roadmap|cookbook|research skills|skills" }
  )

  $tags = New-Object System.Collections.Generic.List[string]
  foreach ($rule in $rules) {
    if ($text -match $rule.Pattern) {
      $tags.Add($rule.Tag)
    }
  }

  return @($tags | Select-Object -Unique)
}

function Get-TrendingProjects {
  param(
    [ValidateSet("weekly", "monthly")][string]$Since,
    [hashtable]$ExistingSummaries
  )

  $url = "https://github.com/trending?since=$Since"
  $headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) GitHub-AI-Trends"
    "Accept" = "text/html,application/xhtml+xml"
  }
  $html = (Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing).Content
  $articles = [regex]::Matches($html, "<article\s+class=`"Box-row`".*?</article>", [System.Text.RegularExpressions.RegexOptions]::Singleline)
  $items = New-Object System.Collections.Generic.List[object]

  foreach ($articleMatch in $articles) {
    $article = $articleMatch.Value
    $repoPath = Get-FirstMatch -Text $article -Pattern "<h2[^>]*>.*?<a[^>]+href=`"/([^`"]+)`"[^>]*>"
    if ([string]::IsNullOrWhiteSpace($repoPath)) {
      continue
    }

    $repoPath = $repoPath.Trim("/")
    $parts = $repoPath.Split("/")
    if ($parts.Count -lt 2) {
      continue
    }

    $owner = $parts[0]
    $repo = $parts[1]
    $fullName = "$owner/$repo"
    $meta = Get-RepoMetadata -Owner $owner -Repo $repo

    $descriptionHtml = Get-FirstMatch -Text $article -Pattern "<p[^>]+class=`"[^`"]*color-fg-muted[^`"]*`"[^>]*>(.*?)</p>"
    $trendingDescription = ConvertFrom-HtmlText $descriptionHtml
    $description = if (-not [string]::IsNullOrWhiteSpace($meta.description)) { $meta.description } else { $trendingDescription }
    $language = ConvertFrom-HtmlText (Get-FirstMatch -Text $article -Pattern "<span itemprop=`"programmingLanguage`">(.*?)</span>")
    $growthText = Get-FirstMatch -Text $article -Pattern "([0-9,]+)\s+stars?\s+this\s+(week|month)"
    $starsGained = 0
    if (-not [string]::IsNullOrWhiteSpace($growthText)) {
      $starsGained = [int]($growthText -replace ",", "")
    }

    $avatar = Get-FirstMatch -Text $article -Pattern "src=`"(https://avatars\.githubusercontent\.com/[^`"]+)`""
    $avatar = [System.Net.WebUtility]::HtmlDecode($avatar)
    $tags = @(Get-AiTags -Name $fullName -Description $description -Topics $meta.topics)
    if ($tags.Count -eq 0) {
      continue
    }

    $readme = Get-RepoReadme -Owner $owner -Repo $repo
    $insight = New-RepoInsight `
      -FullName $fullName `
      -Description $description `
      -Language $language `
      -Topics @($meta.topics) `
      -Tags @($tags) `
      -Readme $readme

    $summary = ""
    $summarySource = "pending"
    if ($ExistingSummaries.ContainsKey($fullName)) {
      $summary = $ExistingSummaries[$fullName]
      $summarySource = "preserved"
    }

    $items.Add([pscustomobject]@{
      owner = $owner
      repo = $repo
      fullName = $fullName
      url = "https://github.com/$fullName"
      avatarUrl = $avatar
      description = $description
      topics = @($meta.topics)
      homepage = $meta.homepage
      language = $language
      starsGained = $starsGained
      totalStars = $meta.stargazersCount
      forks = $meta.forksCount
      license = $meta.license
      pushedAt = $meta.pushedAt
      tags = $tags
      zhSummary = $summary
      summarySource = $summarySource
      insight = $insight
    })
  }

  return @($items | Sort-Object -Property starsGained -Descending | Select-Object -First $Limit)
}

function Update-ExistingInsights {
  param([string]$OutputDir)

  $jsonPath = Join-Path $OutputDir "trends.json"
  $jsPath = Join-Path $OutputDir "trends.js"
  if (-not (Test-Path $jsonPath)) {
    throw "Cannot refresh insights because $jsonPath does not exist."
  }

  $payload = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($groupName in @("weekly", "monthly")) {
    foreach ($item in @($payload.$groupName)) {
      if (-not $item) {
        continue
      }

      $owner = [string]$item.owner
      $repo = [string]$item.repo
      if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repo)) {
        $parts = ([string]$item.fullName).Split("/")
        if ($parts.Count -ge 2) {
          $owner = $parts[0]
          $repo = $parts[1]
        }
      }

      $tags = @($item.tags)
      $topics = @($item.topics)
      $insight = New-RepoInsight `
        -FullName ([string]$item.fullName) `
        -Description ([string]$item.description) `
        -Language ([string]$item.language) `
        -Topics $topics `
        -Tags $tags `
        -Readme ""

      $item.insight = $insight
      if (-not $item.summarySource -or $item.summarySource -eq "pending") {
        $item.summarySource = "structured"
      }
    }
  }

  $payload.generatedAt = [DateTimeOffset]::Now.ToString("o")
  $payload.source = "GitHub Trending + GitHub Repo API + structured Chinese insights"
  $json = $payload | ConvertTo-Json -Depth 10
  Set-Content -LiteralPath $jsonPath -Value $json -Encoding UTF8
  Set-Content -LiteralPath $jsPath -Value "window.GITHUB_AI_TRENDS = $json;" -Encoding UTF8
  Write-Output "Refreshed insights in $jsonPath"
  Write-Output "Updated $jsPath"
}

if (-not (Test-Path $OutputDir)) {
  New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}

if ($RefreshInsightsOnly) {
  Update-ExistingInsights -OutputDir $OutputDir
  return
}

$existingSummaries = Get-ExistingSummaries -OutputDir $OutputDir
$payload = [ordered]@{
  source = "GitHub Trending + GitHub Repo API"
  generatedAt = [DateTimeOffset]::Now.ToString("o")
  weekly = @(Get-TrendingProjects -Since "weekly" -ExistingSummaries $existingSummaries)
  monthly = @(Get-TrendingProjects -Since "monthly" -ExistingSummaries $existingSummaries)
}

$json = $payload | ConvertTo-Json -Depth 10
$jsonPath = Join-Path $OutputDir "trends.json"
$jsPath = Join-Path $OutputDir "trends.js"

Set-Content -LiteralPath $jsonPath -Value $json -Encoding UTF8
Set-Content -LiteralPath $jsPath -Value "window.GITHUB_AI_TRENDS = $json;" -Encoding UTF8

Write-Output "Updated $jsonPath"
Write-Output "Updated $jsPath"
