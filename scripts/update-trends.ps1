param(
  [int]$Limit = 12,
  [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "data")
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:RepoCache = @{}

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
