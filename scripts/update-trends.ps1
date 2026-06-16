param(
  [int]$Limit = 12,
  [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "data")
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

function Get-RuleFeaturePoints {
  param(
    [string]$FullName,
    [string]$Description,
    [string]$Language,
    [string[]]$Topics,
    [string[]]$Tags,
    [string]$Readme
  )

  $text = "$FullName $Description $Language $($Topics -join ' ') $($Tags -join ' ') $Readme".ToLowerInvariant()
  $points = New-Object System.Collections.Generic.List[string]

  if ($text -match "compress|compression|token|context|rag chunk|logs" -and $text -match "llm|agent|mcp|claude|codex|cursor") {
    Add-UniqueText -List $points -Value "上下文处理：在日志、文件、RAG 分块或工具输出进入 LLM 前做压缩，减少 token 占用。"
  }
  if ($text -match "\bagents?\b|\bmcp\b|tool use|tool-use|agent skill|agent-skills|claude code|claude-code|codex|cursor|copilot|coding agent") {
    Add-UniqueText -List $points -Value "Agent / 工具调用：为 AI 编程 Agent 或自动化 Agent 提供可复用技能、命令或工具接口。"
  }
  if ($text -match "anti.?slop|taste|frontend|ui|design|generic output|boring|good taste") {
    Add-UniqueText -List $points -Value "生成质量控制：为 AI 生成的前端、文案或设计结果提供审美约束，减少模板化和粗糙输出。"
  }
  if ($text -match "system prompt|system prompts|internal tools|prompt collection|prompts") {
    Add-UniqueText -List $points -Value "提示词资料库：收集和整理主流 AI 产品、编码工具或 Agent 的系统提示词与内部工具信息。"
  }
  if ($text -match "persistent memory|agent memory|memory for ai|long.?term memory") {
    Add-UniqueText -List $points -Value "Agent 记忆：为 AI 编程 Agent 或个人助手提供可持续记忆，减少重复上下文输入。"
  }
  if ($text -match "terminal|cli|lsp|subagents?|hash.?anchored|code edits") {
    Add-UniqueText -List $points -Value "终端编码工具：在命令行环境中提供代码编辑、语言服务、浏览器工具或子 Agent 协作能力。"
  }
  if ($text -match "academic|research|write|review|revise|paper|citation") {
    Add-UniqueText -List $points -Value "学术研究流程：把资料调研、写作、审阅、修改和定稿拆成可复用的 AI 辅助步骤。"
  }
  if ($text -match "document|pdf|docx|pptx|xlsx|office|markdown|markitdown") {
    Add-UniqueText -List $points -Value "文档处理：把 Office、PDF、图片或其他文件内容转换成更适合 LLM/RAG 使用的 Markdown 或文本。"
  }
  if ($text -match "\brag\b|retrieval|vector|embedding|semantic search|knowledge graph|knowledge base|search") {
    Add-UniqueText -List $points -Value "检索 / 知识库：围绕向量索引、语义搜索、知识图谱或文档问答构建检索能力。"
  }
  if ($text -match "security|vulnerabilit|malicious|scanner|scan|cve|osv") {
    Add-UniqueText -List $points -Value "安全扫描：检查 AI Agent 技能、依赖或代码中的恶意模式、漏洞和供应链风险。"
  }
  if ($text -match "image|video|audio|voice|speech|vision|computer vision|multimodal|diffusion") {
    Add-UniqueText -List $points -Value "多模态能力：处理图像、视频、语音或视觉相关的生成、理解和自动化任务。"
  }
  if ($text -match "computer vision|classification|coco|roboflow|object detection|segmentation") {
    Add-UniqueText -List $points -Value "计算机视觉工具：围绕分类、检测、分割、数据集格式或视觉模型推理提供可复用工具。"
  }
  if ($text -match "train|fine.?tune|inference|benchmark|eval|model serving|pytorch|tensorflow|jax") {
    Add-UniqueText -List $points -Value "模型 / 评测：覆盖模型训练、推理、评测、基准测试或模型服务相关流程。"
  }
  if ($text -match "twitter|reddit|youtube|hacker news|hn|xiao.?hong.?shu|bilibili|web search|social") {
    Add-UniqueText -List $points -Value "信息检索：面向网页、社交平台或社区内容做搜索、抓取和趋势研究。"
  }
  if ($text -match "product|pm skill|marketplace|strategy|roadmap|growth|launch") {
    Add-UniqueText -List $points -Value "产品工作流：把产品发现、策略、路线图、上线和增长任务拆成可由 Agent 执行的技能/流程。"
  }

  return @($points | Select-Object -First 3)
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
  $overviewSection = Get-ReadmeSectionText -Readme $Readme -Patterns @("overview", "introduction", "about", "what\s+is", "why", "purpose")
  $featureSection = Get-ReadmeSectionText -Readme $Readme -Patterns @("feature", "capabilit", "highlight", "what.*can", "supported", "key")
  $usageSection = Get-ReadmeSectionText -Readme $Readme -Patterns @("usage", "quick.?start", "getting\s+started", "example", "demo", "use\s+case", "workflow", "how\s+to")

  $featureKeywords = "feature|support|provide|enable|allow|integrat|agent|mcp|rag|llm|model|api|sdk|cli|plugin|workflow|memory|context|search|retrieve|generate|compress|deploy|evaluate|benchmark|train|inference|automate"
  $featureCandidates = @(Select-InsightLines -Text $featureSection -FallbackText "$overviewSection`n$Readme" -Keywords $featureKeywords -Limit 3)
  if ($featureCandidates.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($Description)) {
    $featureCandidates = @($Description)
  }

  $featurePoints = New-Object System.Collections.Generic.List[string]
  $ruleFeatures = @(Get-RuleFeaturePoints `
    -FullName $FullName `
    -Description $Description `
    -Language $Language `
    -Topics $Topics `
    -Tags $Tags `
    -Readme $Readme)
  foreach ($point in $ruleFeatures) {
    Add-UniqueText -List $featurePoints -Value $point
  }
  foreach ($line in $featureCandidates) {
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
  foreach ($line in $scenarioCandidates) {
    $scenarioPoints.Add((Format-ScenarioPoint -Line $line))
  }
  if ($scenarioPoints.Count -eq 0) {
    $scenarioPoints.Add((Get-ScenarioFallback -FullName $FullName -Description $Description -Topics $Topics -Tags $Tags -FeatureLines @($featureCandidates)))
  }

  $introParts = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($Description)) {
    $introParts.Add(("仓库简介写的是：" + $Description))
  }
  if (-not [string]::IsNullOrWhiteSpace($readmeTitle)) {
    $introParts.Add(("README 标题是：" + $readmeTitle))
  }
  if ($Topics -and $Topics.Count -gt 0) {
    $introParts.Add("topics 包含 $(@($Topics | Select-Object -First 4) -join ' / ')")
  }
  if ($introParts.Count -eq 0) {
    $langText = if ($Language) { "$Language " } else { "" }
    $introParts.Add("$FullName 是一个 ${langText}GitHub 项目，README 可提供进一步判断依据")
  }

  $source = if ([string]::IsNullOrWhiteSpace($Readme)) { "metadata" } else { "readme" }

  return [pscustomobject]@{
    source = $source
    readmeTitle = $readmeTitle
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

if (-not (Test-Path $OutputDir)) {
  New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
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
