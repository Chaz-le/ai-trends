const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const dataDir = path.join(root, "data");
function readJson(filePath, fallback) {
  try {
    const raw = fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "");
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

const data = readJson(path.join(dataDir, "trends.json"), {
  source: "GitHub Trending",
  generatedAt: null,
  weekly: [],
  monthly: [],
});
const historyPath = path.join(dataDir, "history.json");
const fmt = new Intl.NumberFormat("zh-CN");

const tagLabels = {
  agent: "Agent",
  llm: "LLM",
  rag: "RAG",
  coding: "Code",
  multimodal: "Multimodal",
  ml: "ML Ops",
  generation: "GenAI",
  learning: "Learning",
};

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function normalizeDate(value) {
  if (!value) return "更新时间未知";
  return String(value).replace("T", " ").slice(0, 16);
}

function snapshotDate(value) {
  return String(value || new Date().toISOString()).slice(0, 10);
}

function readHistory() {
  if (!fs.existsSync(historyPath)) return { generatedAt: null, snapshots: [] };
  try {
    const parsed = readJson(historyPath, { generatedAt: null, snapshots: [] });
    return {
      generatedAt: parsed.generatedAt || null,
      snapshots: Array.isArray(parsed.snapshots) ? parsed.snapshots : [],
    };
  } catch {
    return { generatedAt: null, snapshots: [] };
  }
}

function allItems() {
  return [...(data.weekly || []), ...(data.monthly || [])];
}

function recordSnapshot(history) {
  const repos = {};
  for (const item of allItems()) {
    const stars = Number(item.totalStars);
    if (item.fullName && Number.isFinite(stars) && stars > 0) {
      repos[item.fullName] = {
        stars,
        periodGain: Number(item.starsGained || 0),
      };
    }
  }
  if (!Object.keys(repos).length) return history;

  const today = snapshotDate(data.generatedAt);
  const snapshots = history.snapshots.filter((snapshot) => snapshot.date !== today);
  snapshots.push({
    date: today,
    generatedAt: data.generatedAt || new Date().toISOString(),
    repos,
  });
  snapshots.sort((a, b) => String(a.date).localeCompare(String(b.date)));

  return {
    generatedAt: new Date().toISOString(),
    snapshots: snapshots.slice(-60),
  };
}

function writeHistory(history) {
  fs.writeFileSync(historyPath, JSON.stringify(history, null, 2), "utf8");
}

let history = readHistory();
history = recordSnapshot(history);
writeHistory(history);

const weekly = data.weekly || [];
const monthly = data.monthly || [];

function topItem(items) {
  return items.reduce((best, item) => {
    return !best || Number(item.starsGained || 0) > Number(best.starsGained || 0) ? item : best;
  }, null);
}

function topGrowth() {
  const top = topItem(allItems());
  return top ? `+${fmt.format(top.starsGained || 0)}` : "-";
}

function dailyGains(fullName) {
  const points = history.snapshots
    .map((snapshot) => {
      const repo = snapshot.repos && snapshot.repos[fullName];
      return repo && Number.isFinite(Number(repo.stars))
        ? { date: snapshot.date, stars: Number(repo.stars) }
        : null;
    })
    .filter(Boolean);

  const gains = [];
  for (let index = 1; index < points.length; index += 1) {
    gains.push({
      date: points[index].date,
      gain: Math.max(0, points[index].stars - points[index - 1].stars),
    });
  }
  return gains.slice(-7);
}

function fallbackSummary(item) {
  const repoName = item.fullName || `${item.owner || ""}/${item.repo || ""}`;
  const description = String(item.description || "").trim();
  const language = item.language ? `${item.language} ` : "";
  const tags = Array.isArray(item.tags) ? item.tags : [];
  const topics = Array.isArray(item.topics) ? item.topics : [];
  const signals = [...tags, ...topics].filter(Boolean).slice(0, 4).join(" / ");
  const signalText = signals ? `，关联方向包括 ${signals}` : "";

  return {
    feature: description
      ? `基于项目简介，它主要用于：${description}`
      : `${repoName} 是一个 ${language}GitHub 项目${signalText}，当前可先从项目简介、标签和增长数据判断其关注价值。`,
    scenario: `适合想了解 ${repoName} 的开发者或 AI 工具使用者，先通过 GitHub README、示例和 issue 进一步判断是否适合接入自己的工作流。`,
  };
}

function splitSummary(item) {
  const summary = item && typeof item === "object" ? item.zhSummary : item;
  const value = String(summary || "").trim();
  const match = value.match(/功能[:：]\s*([\s\S]*?)使用场景[:：]\s*([\s\S]*)/);
  if (!match) {
    if (value) return { feature: value, scenario: fallbackSummary(item || {}).scenario };
    return fallbackSummary(item || {});
  }
  return {
    feature: match[1].trim().replace(/[。；;]\s*$/, ""),
    scenario: match[2].trim().replace(/^[。；;]\s*/, ""),
  };
}

function renderTags(item) {
  const tags = Array.isArray(item.tags) ? item.tags : [];
  const topics = Array.isArray(item.topics) ? item.topics : [];
  const primary = tags
    .slice(0, 3)
    .map((tag) => `<span class="pill pill-strong">${escapeHtml(tagLabels[tag] || tag)}</span>`)
    .join("");
  const topicHtml = topics
    .slice(0, 3)
    .map((topic) => `<span class="pill">${escapeHtml(topic)}</span>`)
    .join("");
  const language = item.language ? `<span class="pill lang">${escapeHtml(item.language)}</span>` : "";
  return `${language}${primary}${topicHtml}`;
}

function renderTrend(item, days) {
  const gains = dailyGains(item.fullName);
  const average = Math.max(0, Math.round(Number(item.starsGained || 0) / days));

  if (!gains.length) {
    const width = Math.max(8, Math.min(100, Math.round((average / 2000) * 100)));
    return `
              <div class="trend-box">
                <div class="trend-head"><span>每日趋势</span><b>日均 +${fmt.format(average)}</b></div>
                <div class="trend-meter"><i style="width:${width}%"></i></div>
                <p>暂无连续快照，先用当前周期日均增长作为参考。</p>
              </div>`;
  }

  const max = Math.max(...gains.map((point) => point.gain), 1);
  const bars = gains
    .map((point) => {
      const height = Math.max(12, Math.round((point.gain / max) * 58));
      const label = `${point.date.slice(5)} +${fmt.format(point.gain)}`;
      return `<span class="spark-bar" style="height:${height}px" title="${escapeHtml(label)}"><em>${escapeHtml(label)}</em></span>`;
    })
    .join("");
  const total = gains.reduce((sum, point) => sum + point.gain, 0);
  return `
              <div class="trend-box">
                <div class="trend-head"><span>近 ${gains.length} 日趋势</span><b>+${fmt.format(total)}</b></div>
                <div class="sparkline">${bars}</div>
                <p>来自每日自动记录的 star 快照。</p>
              </div>`;
}

function rankClass(index) {
  if (index === 0) return " rank-gold";
  if (index === 1) return " rank-silver";
  if (index === 2) return " rank-bronze";
  return "";
}

function asTextList(value, limit = 3) {
  if (!Array.isArray(value)) return [];
  const seen = new Set();
  const result = [];
  for (const item of value) {
    const text = String(item || "").replace(/\s+/g, " ").trim();
    const key = text.toLowerCase();
    if (!text || seen.has(key)) continue;
    seen.add(key);
    result.push(text);
    if (result.length >= limit) break;
  }
  return result;
}

function getStructuredInsight(item) {
  const insight = item && typeof item === "object" && item.insight && typeof item.insight === "object"
    ? item.insight
    : null;

  if (insight) {
    const title = String(insight.zhTitle || "").trim();
    const intro = String(insight.zhIntro || insight.projectIntro || "").trim();
    const featurePoints = asTextList(insight.featurePoints, 3);
    const scenarioPoints = asTextList(insight.scenarioPoints, 2);
    if (title || intro || featurePoints.length || scenarioPoints.length) {
      return {
        title,
        intro,
        featurePoints,
        scenarioPoints,
        source: insight.source || "readme",
      };
    }
  }

  const parts = splitSummary(item);
  return {
    title: "",
    intro: "",
    featurePoints: [parts.feature].filter(Boolean),
    scenarioPoints: [parts.scenario].filter(Boolean),
    source: "legacy",
  };
}

function renderPointList(points) {
  const items = asTextList(points, 3);
  if (!items.length) return "<p>README 信息不足，暂不生成具体说明。</p>";
  return `<ul>${items.map((point) => `<li>${escapeHtml(point)}</li>`).join("")}</ul>`;
}

function renderSummary(item) {
  const insight = getStructuredInsight(item);
  const sourceTag = insight.source === "readme"
    ? `<em class="summary-source">README 提炼</em>`
    : `<em class="summary-source">基础信息</em>`;
  return `
              <div class="summary-lines">
                <div class="summary-line summary-feature"><span>核心功能</span><div>${renderPointList(insight.featurePoints)}</div></div>
                <div class="summary-line summary-scenario"><span>使用场景</span><div>${renderPointList(insight.scenarioPoints)}</div></div>
                ${sourceTag}
              </div>`;
}

function renderCard(item, index, periodText, days, maxGrowth) {
  const growth = Number(item.starsGained || 0);
  const intensity = Math.max(6, Math.round((growth / Math.max(maxGrowth, 1)) * 100));
  const description = item.description || "暂无 GitHub 简介。";
  const totalStars = Number(item.totalStars || 0);
  const repoName = item.fullName || `${item.owner || ""}/${item.repo || ""}`;
  const insight = getStructuredInsight(item);
  const zhTitle = insight.title || "AI 开源项目";
  const zhIntro = insight.intro || description;

  return `
          <article class="project-row">
            <div class="rank-block${rankClass(index)}">
              <span>#${index + 1}</span>
              <i style="height:${intensity}%"></i>
            </div>
            <div class="project-copy">
              <div class="repo-line">
                <a href="${escapeHtml(item.url)}" target="_blank" rel="noreferrer">${escapeHtml(repoName)}</a>
                <span>${escapeHtml(periodText)}</span>
              </div>
              <div class="zh-heading">
                <strong>${escapeHtml(zhTitle)}</strong>
                <p>${escapeHtml(zhIntro)}</p>
              </div>
              <p class="repo-desc"><span>来源简介</span>${escapeHtml(description)}</p>
              ${renderSummary(item)}
              <div class="pill-row">${renderTags(item)}</div>
            </div>
            <aside class="growth-panel">
              <div class="growth-top">
                <span>新增 Stars</span>
                <strong>+${fmt.format(growth)}</strong>
              </div>
              <div class="growth-meta">
                <span>约 +${fmt.format(Math.round(growth / days))} / 天</span>
                ${totalStars ? `<span>总计 ${fmt.format(totalStars)}</span>` : ""}
              </div>
              ${renderTrend(item, days)}
            </aside>
          </article>`;
}

function renderPanel(id, title, subtitle, items, periodText, days) {
  const maxGrowth = Math.max(...items.map((item) => Number(item.starsGained || 0)), 1);
  const leader = topItem(items);
  return `
        <section class="period-panel" id="${id}">
          <div class="panel-head">
            <div>
              <span class="panel-kicker">${escapeHtml(periodText)}</span>
              <h2>${escapeHtml(title)}</h2>
              <p>${escapeHtml(subtitle)}</p>
            </div>
            <div class="leader-card">
              <span>本期第一</span>
              <strong>${leader ? escapeHtml(leader.fullName) : "-"}</strong>
              <b>${leader ? `+${fmt.format(leader.starsGained || 0)}` : "-"}</b>
            </div>
          </div>
          <div class="project-list">
${items.map((item, index) => renderCard(item, index, periodText, days, maxGrowth)).join("\n")}
          </div>
        </section>`;
}

const html = `<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="utf-8" />
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>GitHub AI 项目增长榜</title>
    <style>
:root {
  color-scheme: light;
  --page: #eef2f6;
  --ink: #101828;
  --muted: #667085;
  --soft: #f8fafc;
  --card: #ffffff;
  --line: #d9e1ea;
  --line-strong: #c7d2df;
  --navy: #102033;
  --navy-2: #152b45;
  --teal: #0f766e;
  --cyan: #22d3ee;
  --blue: #2563eb;
  --amber: #b7791f;
  --green-soft: #e6f6f1;
  --blue-soft: #eaf1ff;
  --shadow: 0 18px 45px rgba(16, 32, 51, 0.12);
}

* { box-sizing: border-box; }

body {
  margin: 0;
  min-height: 100vh;
  background:
    linear-gradient(180deg, #dfe8ef 0, #eef2f6 270px, #f7f9fb 100%);
  color: var(--ink);
  font-family: "Microsoft YaHei", "PingFang SC", "Segoe UI", sans-serif;
}

a { color: inherit; text-decoration: none; }

.shell {
  width: min(1320px, calc(100% - 36px));
  margin: 0 auto;
  padding: 24px 0 56px;
}

.hero {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 360px;
  gap: 18px;
  min-height: 214px;
  padding: 24px;
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: 14px;
  background:
    radial-gradient(circle at 88% 12%, rgba(34, 211, 238, 0.32), transparent 26%),
    linear-gradient(135deg, var(--navy), var(--navy-2));
  color: #fff;
  box-shadow: var(--shadow);
}

.hero-kicker {
  margin: 0 0 10px;
  color: #93e7de;
  font-size: 12px;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.hero h1 {
  margin: 0;
  max-width: 760px;
  font-size: clamp(36px, 5vw, 68px);
  line-height: 0.95;
  letter-spacing: 0;
}

.hero-copy {
  margin: 16px 0 0;
  max-width: 760px;
  color: #c9d8e5;
  font-size: 15px;
  line-height: 1.7;
}

.hero-meta,
.pill-row {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.hero-meta { margin-top: 20px; }

.hero-meta span,
.pill,
.view-tabs label {
  display: inline-flex;
  align-items: center;
  min-height: 30px;
  border-radius: 999px;
}

.hero-meta span {
  padding: 0 12px;
  background: rgba(255, 255, 255, 0.1);
  color: #dce8f1;
  font-size: 12px;
}

.hero-board {
  display: grid;
  gap: 10px;
  align-content: start;
}

.board-card {
  padding: 14px 16px;
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 10px;
  background: rgba(255, 255, 255, 0.08);
}

.board-card span {
  display: block;
  color: #aebfd0;
  font-size: 12px;
}

.board-card strong {
  display: block;
  margin-top: 8px;
  font-size: 28px;
  line-height: 1;
}

.board-card b {
  display: block;
  margin-top: 8px;
  color: #93e7de;
  font-size: 12px;
  font-weight: 700;
}

.view-switcher { margin-top: 18px; }

.view-radio {
  position: absolute;
  opacity: 0;
  pointer-events: none;
}

.view-tabs {
  display: inline-grid;
  grid-template-columns: repeat(2, minmax(150px, 1fr));
  gap: 6px;
  padding: 6px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.74);
  box-shadow: 0 8px 24px rgba(16, 32, 51, 0.08);
}

.view-tabs label {
  justify-content: center;
  min-height: 42px;
  padding: 0 18px;
  color: var(--muted);
  font-size: 14px;
  font-weight: 800;
  cursor: pointer;
}

#view-weekly:checked ~ .view-tabs label[for="view-weekly"],
#view-monthly:checked ~ .view-tabs label[for="view-monthly"] {
  background: var(--navy);
  color: #fff;
  box-shadow: 0 8px 20px rgba(16, 32, 51, 0.18);
}

.period-panel {
  display: none;
  margin-top: 18px;
}

#view-weekly:checked ~ .period-panels #weekly,
#view-monthly:checked ~ .period-panels #monthly { display: block; }

.panel-head {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 260px;
  gap: 18px;
  align-items: end;
  margin-bottom: 14px;
}

.panel-kicker {
  display: inline-flex;
  margin-bottom: 8px;
  color: var(--teal);
  font-size: 12px;
  font-weight: 900;
  text-transform: uppercase;
}

.panel-head h2 {
  margin: 0;
  font-size: 28px;
  letter-spacing: 0;
}

.panel-head p {
  margin: 7px 0 0;
  color: var(--muted);
  font-size: 14px;
}

.leader-card {
  padding: 14px 16px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--card);
  box-shadow: 0 10px 26px rgba(16, 32, 51, 0.08);
}

.leader-card span,
.leader-card b {
  display: block;
  color: var(--muted);
  font-size: 12px;
}

.leader-card strong {
  display: block;
  margin: 6px 0;
  overflow: hidden;
  text-overflow: ellipsis;
  color: var(--ink);
  font-size: 15px;
  white-space: nowrap;
}

.leader-card b {
  color: var(--teal);
  font-size: 20px;
}

.project-list {
  display: grid;
  gap: 12px;
}

.project-row {
  display: grid;
  grid-template-columns: 54px minmax(0, 1fr) 280px;
  gap: 16px;
  align-items: stretch;
  padding: 16px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: rgba(255, 255, 255, 0.92);
  box-shadow: 0 8px 22px rgba(16, 32, 51, 0.06);
}

.rank-block {
  position: relative;
  display: grid;
  place-items: center;
  overflow: hidden;
  min-height: 154px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: #f2f6f8;
}

.rank-block i {
  position: absolute;
  inset: auto 0 0;
  display: block;
  background: linear-gradient(180deg, rgba(15, 118, 110, 0.18), rgba(15, 118, 110, 0.5));
}

.rank-block span {
  position: relative;
  z-index: 1;
  color: var(--navy);
  font-size: 15px;
  font-weight: 900;
}

.rank-gold { background: #fff7e8; }
.rank-gold i { background: linear-gradient(180deg, rgba(183, 121, 31, 0.2), rgba(183, 121, 31, 0.58)); }
.rank-silver { background: #f4f7fb; }
.rank-bronze { background: #fff1e8; }

.project-copy {
  min-width: 0;
  padding: 2px 0;
}

.repo-line {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 10px;
  margin-bottom: 8px;
}

.repo-line a {
  color: var(--ink);
  font-size: 20px;
  font-weight: 900;
  line-height: 1.25;
}

.repo-line a:hover { color: var(--teal); }

.repo-line > span {
  display: inline-flex;
  align-items: center;
  min-height: 25px;
  padding: 0 9px;
  border-radius: 999px;
  background: var(--blue-soft);
  color: var(--blue);
  font-size: 12px;
  font-weight: 800;
}

.repo-desc {
  display: flex;
  flex-wrap: wrap;
  gap: 7px;
  align-items: baseline;
  margin: 0 0 11px;
  color: var(--muted);
  font-size: 13px;
  line-height: 1.55;
}

.repo-desc span {
  flex: 0 0 auto;
  color: #344054;
  font-size: 12px;
  font-weight: 900;
}

.zh-heading {
  display: grid;
  gap: 5px;
  max-width: 860px;
  margin: 0 0 8px;
}

.zh-heading strong {
  color: var(--navy);
  font-size: 17px;
  font-weight: 900;
  line-height: 1.35;
}

.zh-heading p {
  margin: 0;
  color: #344054;
  font-size: 14px;
  font-weight: 600;
  line-height: 1.65;
  text-wrap: pretty;
}

.summary-lines {
  position: relative;
  display: grid;
  gap: 8px;
  max-width: 920px;
}

.summary-intro,
.summary-line {
  display: grid;
  grid-template-columns: 92px minmax(0, 1fr);
  gap: 10px;
  align-items: start;
  margin: 0;
  padding: 9px 11px;
  border-radius: 10px;
  line-height: 1.65;
}

.summary-intro {
  border: 1px solid #e2e8f0;
  background: #fbfdff;
  color: #344054;
}

.summary-intro span,
.summary-line span {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 24px;
  border-radius: 999px;
  font-size: 12px;
  font-weight: 900;
  white-space: nowrap;
}

.summary-intro span {
  background: #eef2f6;
  color: #344054;
}

.summary-feature {
  border: 1px solid #cce9e3;
  background: #f0faf7;
  color: #145c55;
}

.summary-feature span {
  background: #d9f2ec;
  color: #0f766e;
}

.summary-scenario {
  border: 1px solid #d8e3f8;
  background: #f2f6ff;
  color: #243f68;
}

.summary-scenario span {
  background: #dfe9ff;
  color: #2563eb;
}

.summary-line b {
  color: inherit;
  font-size: 15px;
  font-weight: 650;
}

.summary-line ul {
  display: grid;
  gap: 6px;
  margin: 0;
  padding: 0;
  list-style: none;
}

.summary-line li {
  position: relative;
  padding-left: 16px;
  color: inherit;
  font-size: 14px;
  font-weight: 650;
}

.summary-line li::before {
  content: "";
  position: absolute;
  left: 0;
  top: 0.78em;
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: currentColor;
  opacity: 0.72;
}

.summary-line p {
  margin: 0;
  color: inherit;
  font-size: 14px;
  font-weight: 650;
}

.summary-source {
  justify-self: start;
  min-height: 22px;
  padding: 3px 8px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: #fff;
  color: var(--muted);
  font-size: 11px;
  font-style: normal;
  font-weight: 800;
}

.pill-row {
  margin-top: 13px;
}

.pill {
  min-height: 26px;
  padding: 0 10px;
  border: 1px solid var(--line);
  background: #fff;
  color: var(--muted);
  font-size: 12px;
  font-weight: 700;
}

.pill-strong {
  border-color: #cce9e3;
  background: var(--green-soft);
  color: var(--teal);
}

.lang {
  border-color: #d5def2;
  background: var(--blue-soft);
  color: var(--blue);
}

.growth-panel {
  display: grid;
  gap: 10px;
  min-width: 0;
}

.growth-top,
.trend-box {
  border: 1px solid var(--line);
  border-radius: 12px;
  background: #fbfdff;
}

.growth-top { padding: 14px; }

.growth-top span,
.growth-meta span,
.trend-head span,
.trend-box p {
  color: var(--muted);
  font-size: 12px;
}

.growth-top strong {
  display: block;
  margin-top: 7px;
  color: var(--teal);
  font-size: 30px;
  line-height: 1;
}

.growth-meta {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
}

.growth-meta span {
  min-height: 32px;
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: #fff;
  text-align: center;
}

.trend-box { padding: 12px; }

.trend-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 10px;
}

.trend-head b {
  color: var(--navy);
  font-size: 13px;
}

.trend-meter {
  height: 9px;
  overflow: hidden;
  margin: 10px 0 8px;
  border-radius: 999px;
  background: #e8eef5;
}

.trend-meter i {
  display: block;
  height: 100%;
  border-radius: inherit;
  background: linear-gradient(90deg, var(--teal), var(--cyan));
}

.sparkline {
  display: grid;
  grid-template-columns: repeat(7, minmax(10px, 1fr));
  align-items: end;
  gap: 5px;
  height: 62px;
  margin: 10px 0 8px;
}

.spark-bar {
  display: block;
  min-height: 12px;
  border-radius: 5px 5px 2px 2px;
  background: linear-gradient(180deg, var(--cyan), var(--blue));
}

.spark-bar em {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
}

.trend-box p {
  margin: 0;
  line-height: 1.45;
}

@media (max-width: 1040px) {
  .hero,
  .panel-head,
  .project-row {
    grid-template-columns: 1fr;
  }

  .rank-block { min-height: 46px; }

  .rank-block i {
    inset: 0 auto 0 0;
    width: 42%;
    height: auto !important;
  }

  .growth-panel { grid-template-columns: minmax(0, 1fr); }
}

@media (max-width: 680px) {
  .shell { width: min(100% - 20px, 1320px); padding-top: 12px; }
  .hero { padding: 18px; border-radius: 12px; }
  .hero h1 { font-size: 38px; }
  .view-tabs { width: 100%; grid-template-columns: 1fr 1fr; }
  .growth-meta { grid-template-columns: 1fr; }
  .project-row { padding: 12px; }
  .summary-line { grid-template-columns: 1fr; }
}
    </style>
  </head>
  <body>
    <main class="shell">
      <section class="hero">
        <div>
          <p class="hero-kicker">Public GitHub AI Watch</p>
          <h1>AI 项目增长榜</h1>
          <p class="hero-copy">追踪 GitHub 上近一周与近一个月增长最快的 AI 使用相关项目，保留增长数据、项目简介、功能说明和适用场景，方便每天快速筛选值得关注的新工具。</p>
          <div class="hero-meta">
            <span>更新于 ${escapeHtml(normalizeDate(data.generatedAt))}</span>
            <span>${escapeHtml(data.source || "GitHub Trending")}</span>
            <span>每日自动更新的静态榜单</span>
          </div>
        </div>
        <aside class="hero-board" aria-label="榜单概览">
          <div class="board-card"><span>近一周项目</span><strong>${fmt.format(weekly.length)}</strong><b>${weekly[0] ? escapeHtml(weekly[0].fullName) : "-"}</b></div>
          <div class="board-card"><span>近一个月项目</span><strong>${fmt.format(monthly.length)}</strong><b>${monthly[0] ? escapeHtml(monthly[0].fullName) : "-"}</b></div>
          <div class="board-card"><span>本期最高增长</span><strong>${escapeHtml(topGrowth())}</strong><b>按新增 Stars 排序</b></div>
        </aside>
      </section>

      <section class="view-switcher">
        <input class="view-radio" id="view-weekly" type="radio" name="period" checked />
        <input class="view-radio" id="view-monthly" type="radio" name="period" />
        <nav class="view-tabs" aria-label="时间范围">
          <label for="view-weekly">近一周</label>
          <label for="view-monthly">近一个月</label>
        </nav>
        <div class="period-panels">
${renderPanel("weekly", "近一周增长最快", "优先观察短期爆发的新工具、Agent 能力、LLM 工作流和开发者效率项目。", weekly, "stars / week", 7)}
${renderPanel("monthly", "近一个月增长最快", "更适合判断项目是否有持续热度，并结合每日增长趋势观察增长是否稳定。", monthly, "stars / month", 30)}
        </div>
      </section>
    </main>
  </body>
</html>
`;

const output = "\uFEFF" + html;
const outputs = ["index.html", "ai-trends-standalone.html", "ai-trends-redesign-v2.html"];
for (const file of outputs) {
  fs.writeFileSync(path.join(root, file), output, "utf8");
}
console.log("Built static AI trends pages:");
for (const file of outputs) console.log(`- ${file}`);
