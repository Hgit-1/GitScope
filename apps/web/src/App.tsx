import { useCallback, useEffect, useMemo, useRef, useState, type ChangeEvent, type CSSProperties, type ReactNode } from "react";
import ReactEChartsCore from "echarts-for-react/lib/core";
import * as echarts from "echarts/core";
import { BarChart } from "echarts/charts";
import { GridComponent, TooltipComponent } from "echarts/components";
import { CanvasRenderer } from "echarts/renderers";
import {
  ArrowClockwise,
  ArrowLeft,
  GitBranch as Branch,
  ChartBar,
  Check,
  CaretRight,
  ClockCounterClockwise,
  CloudArrowDown,
  Code,
  FileCode,
  GearSix,
  GitCommit,
  GitMerge,
  GithubLogo,
  House,
  ImageSquare,
  LinkSimple,
  Lock,
  MagnifyingGlass,
  Moon,
  Plus,
  PushPin,
  SlidersHorizontal,
  Sun,
  Trash,
  UserCircle,
  Users,
  WarningCircle,
  X,
} from "@phosphor-icons/react";
import type { AccountRef, CommitNode, EngineeringReport, GitProvider, SavedProject, ThemeSettings } from "@gitscope/contracts";
import { analyzeRepository, deleteRemoteProject, getGraph, getReport, verifyGithubToken } from "./api";
import {
  clearUserData,
  getSessionToken,
  loadAccounts,
  loadProjects,
  removeSessionToken,
  saveAccounts,
  saveProjects,
  saveSessionToken,
} from "./storage";

echarts.use([BarChart, GridComponent, TooltipComponent, CanvasRenderer]);

type NavKey = "import" | "projects" | "accounts" | "settings";
type ProjectTab = "graph" | "reports" | "activity";

const defaultTheme: ThemeSettings = {
  mode: "system",
  accentMode: "manual",
  accent: "#4ade80",
  background: { kind: "gradient", value: "radial-gradient(circle at 80% 0%, rgba(74,222,128,.12), transparent 34%)", opacity: 0.8, blur: 0 },
};

function readTheme(): ThemeSettings {
  try {
    const value = localStorage.getItem("gitscope.theme");
    return value ? { ...defaultTheme, ...JSON.parse(value) as ThemeSettings } : defaultTheme;
  } catch {
    return defaultTheme;
  }
}

export function foregroundForAccent(hex: string): "#06100a" | "#ffffff" {
  const match = /^#([0-9a-f]{6})$/i.exec(hex);
  if (!match) return "#06100a";
  const channels = [0, 2, 4].map((offset) => Number.parseInt(match[1].slice(offset, offset + 2), 16) / 255)
    .map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  const luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
  return luminance > 0.42 ? "#06100a" : "#ffffff";
}

function useResolvedTheme(mode: ThemeSettings["mode"]): "light" | "dark" {
  const query = useMemo(() => window.matchMedia("(prefers-color-scheme: light)"), []);
  const [systemMode, setSystemMode] = useState<"light" | "dark">(query.matches ? "light" : "dark");
  useEffect(() => {
    const onChange = (event: MediaQueryListEvent) => setSystemMode(event.matches ? "light" : "dark");
    query.addEventListener("change", onChange);
    return () => query.removeEventListener("change", onChange);
  }, [query]);
  return mode === "system" ? systemMode : mode;
}

function IconButton({ label, children, onClick, disabled = false }: { label: string; children: ReactNode; onClick?: () => void; disabled?: boolean }) {
  return <button className="icon-button" type="button" aria-label={label} onClick={onClick} disabled={disabled}>{children}</button>;
}

function ProviderMark({ provider = "generic" }: { provider?: GitProvider }) {
  return <span className="provider-mark" aria-hidden="true">{provider === "github" ? <GithubLogo size={20} weight="fill" /> : <Branch size={20} weight="bold" />}</span>;
}

function detectProvider(hostname: string): GitProvider {
  if (hostname === "github.com" || hostname.endsWith(".github.com")) return "github";
  if (hostname === "gitlab.com" || hostname.endsWith(".gitlab.com")) return "gitlab";
  if (hostname === "bitbucket.org" || hostname.endsWith(".bitbucket.org")) return "bitbucket";
  return "generic";
}

function EmptyState({ icon, title, body, action }: { icon: ReactNode; title: string; body: string; action?: ReactNode }) {
  return <div className="empty-state"><span className="empty-icon" aria-hidden="true">{icon}</span><strong>{title}</strong><p>{body}</p>{action}</div>;
}

function App() {
  const [nav, setNav] = useState<NavKey>("import");
  const [project, setProject] = useState<SavedProject | null>(null);
  const [projectTab, setProjectTab] = useState<ProjectTab>("graph");
  const [projectRevision, setProjectRevision] = useState(0);
  const [savedProjects, setSavedProjects] = useState<SavedProject[]>(loadProjects);
  const [accounts, setAccounts] = useState<AccountRef[]>(loadAccounts);
  const [theme, setTheme] = useState<ThemeSettings>(readTheme);
  const [accountSheet, setAccountSheet] = useState(false);
  const [themeSheet, setThemeSheet] = useState(false);
  const [infoSheet, setInfoSheet] = useState<"privacy" | "limits" | null>(null);
  const [toast, setToast] = useState("");
  const resolvedMode = useResolvedTheme(theme.mode);

  useEffect(() => saveProjects(savedProjects), [savedProjects]);
  useEffect(() => saveAccounts(accounts), [accounts]);
  useEffect(() => localStorage.setItem("gitscope.theme", JSON.stringify(theme)), [theme]);
  useEffect(() => {
    if (!toast) return;
    const timer = window.setTimeout(() => setToast(""), 3600);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const defaultAccount = accounts.find((account) => account.isDefault) || accounts[0];
  const style = {
    "--accent": theme.accent,
    "--on-accent": foregroundForAccent(theme.accent),
    "--custom-bg": theme.background.value || "none",
    "--custom-opacity": String(theme.background.opacity),
    "--custom-blur": `${theme.background.blur}px`,
  } as CSSProperties;

  const openProject = (next: SavedProject) => {
    setProject(next);
    setProjectTab("graph");
  };
  const onNav = (next: NavKey) => {
    setProject(null);
    setNav(next);
  };
  const setDefaultAccount = (id: string) => setAccounts((items) => items.map((item) => ({ ...item, isDefault: item.id === id })));
  const removeAccount = (id: string) => {
    removeSessionToken(id);
    setAccounts((items) => {
      const remaining = items.filter((item) => item.id !== id);
      return remaining.map((item, index) => ({ ...item, isDefault: index === 0 && !remaining.some((entry) => entry.isDefault) ? true : item.isDefault }));
    });
    setToast("账号已从当前设备移除");
  };
  const connectAccount = async (token: string) => {
    const verified = await verifyGithubToken(token);
    setAccounts((items) => {
      const exists = items.some((item) => item.id === verified.id);
      const next = { ...verified, isDefault: items.length === 0 || items.find((item) => item.id === verified.id)?.isDefault === true };
      return exists ? items.map((item) => item.id === verified.id ? next : item) : [...items, next];
    });
    saveSessionToken(verified.id, token);
    setToast(`已连接 GitHub 账号 ${verified.login}`);
    return verified;
  };
  const clearEverything = () => {
    if (!window.confirm("清除当前设备上的账号元数据、项目历史和会话令牌？此操作不会删除 GitHub 仓库。")) return;
    clearUserData();
    setAccounts([]);
    setSavedProjects([]);
    setProject(null);
    setInfoSheet(null);
    setToast("本地用户数据已清除");
  };

  return <div className={`site theme-${resolvedMode}`} style={style} data-theme={resolvedMode}>
    <div className="ambient" aria-hidden="true" />
    <a className="skip-link" href="#main-content">跳到主要内容</a>
    <div className="app-shell">
      <header className={`topbar ${project ? "contextual-topbar" : ""}`}>
        {project ? <>
          <IconButton label="返回项目库" onClick={() => setProject(null)}><ArrowLeft size={22} /></IconButton>
          <div className="contextual-title"><span>{project.owner}</span><strong>{project.name}</strong></div>
          <IconButton label="重新加载项目数据" onClick={() => setProjectRevision((value) => value + 1)}><ArrowClockwise size={21} /></IconButton>
        </> : <>
          <div className="brand-lockup"><span className="brand-icon"><Branch size={22} weight="bold" /></span><div><strong>GitScope</strong><span>代码工作台</span></div></div>
          <div className="top-actions">
            <button className="account-pill" type="button" onClick={() => setAccountSheet(true)} aria-label={defaultAccount ? `当前账号 ${defaultAccount.login}` : "连接 GitHub 账号"}>
              <span className="avatar">{defaultAccount ? defaultAccount.login.slice(0, 2).toUpperCase() : <UserCircle size={21} />}</span>
              <span className="account-name">{defaultAccount?.login || "连接账号"}</span>
              {defaultAccount && <span className="online-dot" aria-label="本次会话已授权" />}
            </button>
            <IconButton label="打开主题设置" onClick={() => setThemeSheet(true)}><SlidersHorizontal size={22} /></IconButton>
          </div>
        </>}
      </header>

      <main id="main-content" tabIndex={-1}>
        {project ? <ProjectDetail project={project} tab={projectTab} setTab={setProjectTab} revision={projectRevision} />
          : nav === "import" ? <ImportScreen accounts={accounts} recent={savedProjects.slice(0, 3)} onOpen={openProject} onShowProjects={() => setNav("projects")} onImport={(next) => { setSavedProjects((items) => [next, ...items.filter((item) => item.id !== next.id)]); openProject(next); }} />
            : nav === "projects" ? <ProjectsScreen projects={savedProjects} onOpen={openProject} onTogglePin={(id) => setSavedProjects((items) => items.map((item) => item.id === id ? { ...item, pinned: !item.pinned } : item))} onDelete={async (item) => { await deleteRemoteProject(item.id).catch(() => undefined); setSavedProjects((items) => items.filter((entry) => entry.id !== item.id)); setToast("项目历史已删除"); }} />
              : nav === "accounts" ? <AccountsScreen accounts={accounts} onAdd={() => setAccountSheet(true)} onDefault={setDefaultAccount} onRemove={removeAccount} />
                : <SettingsScreen theme={theme} onTheme={() => setThemeSheet(true)} onPrivacy={() => setInfoSheet("privacy")} onLimits={() => setInfoSheet("limits")} />}
      </main>
      {!project && <BottomNav active={nav} onChange={onNav} />}
    </div>

    {accountSheet && <AccountSheet accounts={accounts} onClose={() => setAccountSheet(false)} onDefault={(id) => { setDefaultAccount(id); setAccountSheet(false); }} onConnect={connectAccount} />}
    {themeSheet && <ThemeSheet value={theme} onChange={setTheme} onClose={() => setThemeSheet(false)} onToast={setToast} />}
    {infoSheet === "privacy" && <InfoSheet title="隐私与数据" onClose={() => setInfoSheet(null)}><p>项目源码只在分析服务的临时目录中使用，任务结束后删除。Web 版只持久化账号名称和项目历史，访问令牌仅保存在当前浏览器会话。</p><button className="danger-button" type="button" onClick={clearEverything}><Trash size={19} />清除本地用户数据</button></InfoSheet>}
    {infoSheet === "limits" && <InfoSheet title="分析限制" onClose={() => setInfoSheet(null)}><dl className="limit-list"><div><dt>最长任务</dt><dd>5 分钟</dd></div><div><dt>最大提交</dt><dd>20,000</dd></div><div><dt>图谱分页</dt><dd>每页 300</dd></div><div><dt>临时空间</dt><dd>1 GB</dd></div></dl></InfoSheet>}
    {toast && <div className="toast" role="status"><Check size={18} weight="bold" />{toast}</div>}
  </div>;
}

function BottomNav({ active, onChange }: { active: NavKey; onChange: (key: NavKey) => void }) {
  const items: Array<[NavKey, string, ReactNode]> = [["import", "导入", <House size={22} />], ["projects", "项目", <ClockCounterClockwise size={22} />], ["accounts", "账号库", <UserCircle size={22} />], ["settings", "设置", <GearSix size={22} />]];
  return <nav className="bottom-nav" aria-label="主要导航">{items.map(([key, label, icon]) => <button type="button" key={key} className={active === key ? "active" : ""} aria-current={active === key ? "page" : undefined} onClick={() => onChange(key)}>{icon}<span>{label}</span></button>)}</nav>;
}

function ImportScreen({ accounts, recent, onOpen, onImport, onShowProjects }: { accounts: AccountRef[]; recent: SavedProject[]; onOpen: (project: SavedProject) => void; onImport: (project: SavedProject) => void; onShowProjects: () => void }) {
  const [url, setUrl] = useState("");
  const [accountId, setAccountId] = useState(accounts.find((account) => account.isDefault)?.id || "");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  useEffect(() => {
    if (accountId && !accounts.some((account) => account.id === accountId)) setAccountId("");
  }, [accountId, accounts]);

  const submit = async () => {
    setError("");
    let parsed: URL;
    try { parsed = new URL(url.trim()); } catch { setError("请输入完整的 HTTPS Git 仓库地址"); return; }
    if (parsed.protocol !== "https:") { setError("仅支持 HTTPS 仓库链接"); return; }
    if (parsed.username || parsed.password || (parsed.port && parsed.port !== "443")) { setError("链接不能包含凭据或自定义端口"); return; }
    const segments = parsed.pathname.replace(/\.git$/, "").split("/").filter(Boolean);
    if (segments.length < 2) { setError("地址中需要包含仓库所有者和仓库名称"); return; }
    const provider = detectProvider(parsed.hostname);
    if (accountId && provider !== "github") { setError("GitHub 账号令牌只能用于 github.com；其他平台目前仅支持公开仓库"); return; }
    setLoading(true);
    try {
      const projectId = await analyzeRepository(parsed.toString(), getSessionToken(accountId));
      const owner = segments.at(-2)!;
      const name = segments.at(-1)!;
      onImport({ id: projectId, url: parsed.toString(), name, owner, provider, visibility: accountId ? "unknown" : "public", pinned: false, lastAnalyzedAt: new Date().toISOString() });
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "仓库分析失败");
    } finally {
      setLoading(false);
    }
  };

  return <div className="screen import-screen mobile-home">
    <section className="mobile-page-head"><div><p>仓库分析与历史</p><h1>仓库工作台</h1></div><span className="sync-state"><span />API 模式</span></section>
    <section className="workspace-summary" aria-label="工作区摘要"><div><strong>{recent.length}</strong><span>最近项目</span></div><div><strong>{accounts.length}</strong><span>已连接账号</span></div><div><strong>只读</strong><span>访问模式</span></div></section>
    <section className="import-card" aria-labelledby="import-title">
      <div className="card-heading"><div><span className="import-symbol"><Plus size={18} weight="bold" /></span><div><h2 id="import-title">添加仓库</h2><p>使用分析服务读取真实 Git 历史</p></div></div><span className="secure-label"><Lock size={14} />只读</span></div>
      <label htmlFor="repo-url">Git 仓库链接</label>
      <div className={`url-field ${error ? "invalid" : ""}`}><LinkSimple size={20} aria-hidden="true" /><input id="repo-url" value={url} placeholder="https://github.com/owner/repository" onChange={(event) => setUrl(event.target.value)} inputMode="url" autoCapitalize="none" spellCheck={false} aria-invalid={Boolean(error)} aria-describedby={error ? "url-error" : "url-help"} /><ProviderMark /></div>
      {error ? <p className="field-error" id="url-error" role="alert">{error}</p> : <p className="field-help" id="url-help">公开仓库无需账号；私有仓库请选择已连接账号</p>}
      <label htmlFor="account">分析账号</label>
      <div className="select-wrap"><GithubLogo size={20} aria-hidden="true" /><select id="account" value={accountId} onChange={(event) => setAccountId(event.target.value)}><option value="">不使用账号（公开仓库）</option>{accounts.map((account) => <option key={account.id} value={account.id}>{account.login}{account.isDefault ? " · 默认" : ""}</option>)}</select><span className="status-connected">{accountId ? "会话授权" : "公开"}</span></div>
      <button type="button" className="primary-button" onClick={submit} disabled={loading || !url.trim()}>{loading ? <><span className="spinner" />正在克隆并分析</> : <><CloudArrowDown size={21} weight="bold" />导入并分析</>}</button>
      <div className="privacy-note"><Lock size={16} /><span>分析完成或失败后都会删除临时源码</span></div>
    </section>
    <section className="recent-section"><div className="section-title"><div><h2>最近项目</h2><span>{recent.length}</span></div>{recent.length > 0 && <button type="button" onClick={onShowProjects}>全部项目</button>}</div>
      {recent.length === 0 ? <EmptyState icon={<Code size={25} />} title="尚无项目" body="完成第一次仓库分析后会显示在这里。" /> : <div className="mobile-repo-list">{recent.map((item) => <button className="mobile-repo-row" type="button" key={item.id} onClick={() => onOpen(item)}><ProviderMark provider={item.provider} /><span className="mobile-repo-main"><strong>{item.owner} / {item.name}</strong><small>{new Date(item.lastAnalyzedAt || "").toLocaleString("zh-CN")}</small></span><span className="repo-health"><i />已分析</span><CaretRight size={17} aria-hidden="true" /></button>)}</div>}
    </section>
  </div>;
}

function ProjectsScreen({ projects, onOpen, onTogglePin, onDelete }: { projects: SavedProject[]; onOpen: (project: SavedProject) => void; onTogglePin: (id: string) => void; onDelete: (project: SavedProject) => Promise<void> }) {
  const [query, setQuery] = useState("");
  const filtered = projects.filter((project) => `${project.owner}/${project.name}`.toLowerCase().includes(query.toLowerCase())).sort((a, b) => Number(b.pinned) - Number(a.pinned));
  return <div className="screen list-screen"><div className="page-intro"><h1>项目</h1><p>真实分析历史与置顶仓库</p></div>
    <label className="search-box"><MagnifyingGlass size={20} aria-hidden="true" /><span className="sr-only">搜索项目</span><input placeholder="搜索所有者或仓库" value={query} onChange={(event) => setQuery(event.target.value)} /></label>
    {filtered.length === 0 ? <EmptyState icon={<Branch size={26} />} title={projects.length === 0 ? "项目库为空" : "没有匹配项目"} body={projects.length === 0 ? "从导入页分析仓库后，项目会自动保存在此设备。" : "请尝试其他搜索词。"} /> : <div className="project-list">{filtered.map((item) => <article className="project-row" key={item.id}><button type="button" className="project-main" onClick={() => onOpen(item)}><ProviderMark provider={item.provider} /><span><strong>{item.owner} / {item.name}</strong><small>{item.visibility === "private" ? "私有仓库" : item.visibility === "public" ? "公开仓库" : "授权仓库"} · {new Date(item.lastAnalyzedAt || "").toLocaleDateString("zh-CN")}</small></span></button><IconButton label={item.pinned ? "取消置顶" : "置顶项目"} onClick={() => onTogglePin(item.id)}><PushPin size={20} weight={item.pinned ? "fill" : "regular"} /></IconButton><IconButton label="删除项目历史" onClick={() => void onDelete(item)}><Trash size={20} /></IconButton></article>)}</div>}
  </div>;
}

function AccountsScreen({ accounts, onAdd, onDefault, onRemove }: { accounts: AccountRef[]; onAdd: () => void; onDefault: (id: string) => void; onRemove: (id: string) => void }) {
  return <div className="screen list-screen"><div className="page-intro"><h1>账号库</h1><p>这里只显示你亲自验证过的 GitHub 账号</p></div>
    {accounts.length === 0 ? <EmptyState icon={<UserCircle size={28} />} title="尚未连接账号" body="公开仓库可直接分析；私有仓库需要连接 GitHub 访问令牌。" action={<button type="button" className="primary-button compact-action" onClick={onAdd}><Plus size={20} />连接 GitHub 账号</button>} /> : <><div className="account-list">{accounts.map((account) => <article className="account-row" key={account.id}><span className="large-avatar">{account.login.slice(0, 2).toUpperCase()}</span><div><strong>{account.login}</strong><span><GithubLogo size={14} aria-hidden="true" />GitHub · 当前会话令牌{getSessionToken(account.id) ? "有效" : "需重新验证"}</span></div>{account.isDefault ? <span className="default-badge"><Check size={14} />默认</span> : <button type="button" className="text-button" onClick={() => onDefault(account.id)}>设为默认</button>}<IconButton label={`移除 ${account.login}`} onClick={() => onRemove(account.id)}><Trash size={19} /></IconButton></article>)}</div><button type="button" className="secondary-button" onClick={onAdd}><Plus size={20} />连接另一个 GitHub 账号</button></>}
  </div>;
}

function SettingsScreen({ theme, onTheme, onPrivacy, onLimits }: { theme: ThemeSettings; onTheme: () => void; onPrivacy: () => void; onLimits: () => void }) {
  return <div className="screen list-screen"><div className="page-intro"><h1>设置</h1><p>外观、隐私与分析限制</p></div>
    <button className="setting-card" type="button" onClick={onTheme}><span className="setting-icon"><Moon size={22} /></span><span><strong>外观与背景</strong><small>{theme.mode === "system" ? "跟随系统" : theme.mode === "dark" ? "深色模式" : "浅色模式"} · {theme.background.kind === "image" ? "自定义图片" : theme.background.kind === "none" ? "无背景" : "动态渐变"}</small></span><span className="color-preview" style={{ background: theme.accent }} /></button>
    <button className="setting-card" type="button" onClick={onPrivacy}><span className="setting-icon"><Lock size={22} /></span><span><strong>隐私与数据</strong><small>查看存储策略或清除本地数据</small></span><CaretRight size={19} /></button>
    <button className="setting-card" type="button" onClick={onLimits}><span className="setting-icon"><Code size={22} /></span><span><strong>分析限制</strong><small>任务、提交、分页和空间限制</small></span><CaretRight size={19} /></button>
    <div className="version">GitScope 0.6.1</div>
  </div>;
}

function ProjectDetail({ project, tab, setTab, revision }: { project: SavedProject; tab: ProjectTab; setTab: (tab: ProjectTab) => void; revision: number }) {
  const [commits, setCommits] = useState<CommitNode[]>([]);
  const [report, setReport] = useState<EngineeringReport | null>(null);
  const [nextCursor, setNextCursor] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState("");
  const load = useCallback(async () => {
    setLoading(true); setError("");
    try {
      const [graph, nextReport] = await Promise.all([getGraph(project.id), getReport(project.id)]);
      setCommits(graph.commits); setNextCursor(graph.nextCursor); setReport(nextReport);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "项目数据加载失败");
    } finally { setLoading(false); }
  }, [project.id]);
  useEffect(() => { void load(); }, [load, revision]);
  const more = async () => {
    if (!nextCursor) return;
    setLoadingMore(true);
    try { const graph = await getGraph(project.id, nextCursor); setCommits((items) => [...items, ...graph.commits]); setNextCursor(graph.nextCursor); }
    catch (reason) { setError(reason instanceof Error ? reason.message : "加载更多提交失败"); }
    finally { setLoadingMore(false); }
  };
  if (loading) return <div className="screen state-screen" role="status"><span className="spinner large-spinner" /><strong>正在加载项目数据</strong><p>读取提交图谱与工程报表</p></div>;
  if (error && commits.length === 0) return <div className="screen state-screen"><WarningCircle size={34} /><strong>无法加载项目</strong><p>{error}</p><button className="primary-button compact-action" type="button" onClick={() => void load()}>重试</button></div>;
  return <div className="screen project-screen">
    {error && <div className="inline-alert" role="alert"><WarningCircle size={18} />{error}</div>}
    <div className="repo-meta"><span className="branch-chip"><Branch size={15} />{report?.branches ?? 0} 分支</span><span><GitCommit size={15} />{report?.totalCommits ?? commits.length} commits</span><span><Users size={15} />{report?.contributors.length ?? 0} 贡献者</span></div>
    <nav className="subtabs" aria-label="项目详情"><button type="button" className={tab === "graph" ? "active" : ""} aria-current={tab === "graph" ? "page" : undefined} onClick={() => setTab("graph")}><Branch size={18} />图谱</button><button type="button" className={tab === "reports" ? "active" : ""} aria-current={tab === "reports" ? "page" : undefined} onClick={() => setTab("reports")}><ChartBar size={18} />报表</button><button type="button" className={tab === "activity" ? "active" : ""} aria-current={tab === "activity" ? "page" : undefined} onClick={() => setTab("activity")}><ClockCounterClockwise size={18} />动态</button></nav>
    {tab === "graph" ? <GitGraph commits={commits} nextCursor={nextCursor} loadingMore={loadingMore} onMore={() => void more()} /> : tab === "reports" ? <Reports report={report} /> : <Activity commits={commits} />}
  </div>;
}

function GitGraph({ commits, nextCursor, loadingMore, onMore }: { commits: CommitNode[]; nextCursor?: string; loadingMore: boolean; onMore: () => void }) {
  const [selected, setSelected] = useState<CommitNode | null>(commits[0] || null);
  const [zoom, setZoom] = useState(1);
  const laneX = [24, 51, 78];
  useEffect(() => { if (!selected && commits.length > 0) setSelected(commits[0]); }, [commits, selected]);
  if (commits.length === 0) return <EmptyState icon={<GitCommit size={27} />} title="仓库没有提交" body="分析服务未在默认分支中找到提交记录。" />;
  return <section className="graph-section">
    <div className="graph-toolbar"><div><span className="live-badge"><span />真实数据</span><strong>提交演进</strong></div><div className="zoom-tools"><button type="button" onClick={() => setZoom(Math.max(.8, zoom - .1))} disabled={zoom <= .8} aria-label="缩小图谱">−</button><span>{Math.round(zoom * 100)}%</span><button type="button" onClick={() => setZoom(Math.min(1.4, zoom + .1))} disabled={zoom >= 1.4} aria-label="放大图谱">＋</button></div></div>
    <div className="graph-card"><div className="lane-legend"><span><i className="lane-main" />main</span><span><i className="lane-feature" />feature/fix</span><span><i className="lane-docs" />docs</span></div><div className="commit-list" style={{ fontSize: `${zoom}em` }} role="list" aria-label="提交图谱"><svg className="graph-lines" viewBox={`0 0 104 ${commits.length * 78}`} preserveAspectRatio="none" aria-hidden="true">{laneX.map((x, lane) => <path key={x} d={`M${x} 0 V${commits.length * 78}`} className={lane === 0 ? "line-main" : lane === 1 ? "line-feature" : "line-docs"} />)}</svg>{commits.map((commit) => { const lane = Math.min(2, Math.max(0, commit.lane)); return <button type="button" role="listitem" className={`commit-row ${selected?.id === commit.id ? "selected" : ""}`} key={commit.id} onClick={() => setSelected(commit)}><span className={`commit-node lane-${lane}`} style={{ left: laneX[lane] }}><GitMerge size={12} weight="bold" /></span><span className="commit-content"><span className="commit-title">{commit.message}</span><span className="commit-byline"><code>{commit.shortId}</code> · {commit.author} · {new Date(commit.authoredAt).toLocaleDateString("zh-CN", { month: "short", day: "numeric" })}</span>{commit.refs.length > 0 && <span className="ref-list">{commit.refs.map((ref) => <i key={ref}>{ref}</i>)}</span>}</span></button>; })}</div></div>
    {selected && <div className="commit-detail"><div><code>{selected.shortId}</code>{selected.refs[0] && <span>{selected.refs[0]}</span>}</div><h3>{selected.message}</h3><p>{selected.author} 在 {new Date(selected.authoredAt).toLocaleString("zh-CN")} 提交</p><div className="diff-stats"><span>{selected.parentIds.length} 个父提交</span><span>{selected.refs.length} 个引用</span></div></div>}
    {nextCursor && <button type="button" className="load-more" onClick={onMore} disabled={loadingMore}>{loadingMore ? "正在加载…" : "继续加载更早的提交"}</button>}
  </section>;
}

function Reports({ report }: { report: EngineeringReport | null }) {
  if (!report) return <EmptyState icon={<ChartBar size={27} />} title="报表不可用" body="当前项目没有可显示的聚合数据。" />;
  const labels = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
  const chartOption = useMemo(() => ({ animationDuration: 350, grid: { left: 8, right: 8, top: 18, bottom: 22, containLabel: true }, tooltip: { trigger: "axis" }, xAxis: { type: "category", data: labels, axisLabel: { color: "#b7c4bc", fontSize: 10 } }, yAxis: { type: "value", axisLabel: { color: "#b7c4bc" }, splitLine: { lineStyle: { color: "rgba(183,196,188,.16)" } } }, series: [{ name: "提交", data: report.commitsByWeekday, type: "bar", itemStyle: { color: "#4ade80", borderRadius: [4, 4, 0, 0] } }] }), [report.commitsByWeekday]);
  const maxHotspot = Math.max(1, ...report.hotspots.map((item) => item.changes));
  return <section className="reports-section">
    <div className="range-row"><div><span className="eyebrow"><span />GENERATED REPORT</span><h2>工程报表</h2></div><span className="generated-at">{new Date(report.generatedAt).toLocaleDateString("zh-CN")}</span></div>
    <div className="metric-grid"><Metric icon={<GitCommit size={19} />} label="总提交" value={report.totalCommits.toLocaleString()} delta={report.availability.git === "truncated" ? "已截断" : "完整"} /><Metric icon={<Users size={19} />} label="贡献者" value={String(report.contributors.length)} delta="按作者统计" /><Metric icon={<Branch size={19} />} label="分支" value={String(report.branches)} delta="默认克隆" /><Metric icon={<GitMerge size={19} />} label="标签" value={String(report.tags)} delta="Git refs" /></div>
    <ChartCard title="每周提交分布" subtitle="按提交时间统计；柱高与数值共同表达差异。"><ReactEChartsCore echarts={echarts} option={chartOption} style={{ height: 240 }} /></ChartCard>
    <div className="report-card"><div className="report-title"><div><Users size={20} /><span><strong>核心贡献者</strong><small>按提交数量排序</small></span></div></div>{report.contributors.length === 0 ? <p className="report-empty">暂无贡献者数据</p> : <div className="contributors">{report.contributors.slice(0, 10).map((person, index) => <div key={person.name}><span className="rank">{String(index + 1).padStart(2, "0")}</span><span className="person-avatar">{person.name.slice(0, 2).toUpperCase()}</span><span className="person"><strong>{person.name}</strong><small>提交贡献</small></span><strong>{person.commits}</strong></div>)}</div>}</div>
    <div className="report-card"><div className="report-title"><div><FileCode size={20} /><span><strong>文件热点</strong><small>过去一年变更行数最多的路径</small></span></div></div>{report.hotspots.length === 0 ? <p className="report-empty">当前仓库没有可用热点数据</p> : report.hotspots.slice(0, 10).map((item) => <div className="hotspot" key={item.path}><div><code title={item.path}>{item.path}</code><span>{item.changes} 行</span></div><i><b style={{ width: `${item.changes / maxHotspot * 100}%` }} /></i></div>)}</div>
  </section>;
}

function Metric({ icon, label, value, delta }: { icon: ReactNode; label: string; value: string; delta: string }) { return <div className="metric-card"><div>{icon}<span>{label}</span></div><strong>{value}</strong><small>{delta}</small></div>; }
function ChartCard({ title, subtitle, children }: { title: string; subtitle: string; children: ReactNode }) { return <div className="report-card"><div className="report-title"><div><ChartBar size={20} /><span><strong>{title}</strong><small>{subtitle}</small></span></div></div><div role="img" aria-label={`${title}。${subtitle}`}>{children}</div></div>; }

function Activity({ commits }: { commits: CommitNode[] }) {
  if (commits.length === 0) return <EmptyState icon={<ClockCounterClockwise size={27} />} title="暂无动态" body="提交记录加载后会按时间显示在这里。" />;
  return <section className="activity-section"><div className="section-title"><div><ClockCounterClockwise size={19} /><h2>提交动态</h2></div><span>{commits.length}</span></div><div className="timeline">{commits.slice(0, 30).map((commit) => <article key={commit.id}><span className="timeline-icon"><GitCommit size={17} /></span><div><code>{commit.shortId}</code><strong>{commit.message}</strong><small>{commit.author} · {new Date(commit.authoredAt).toLocaleString("zh-CN")}</small></div></article>)}</div></section>;
}

function AccountSheet({ accounts, onClose, onDefault, onConnect }: { accounts: AccountRef[]; onClose: () => void; onDefault: (id: string) => void; onConnect: (token: string) => Promise<AccountRef> }) {
  const [showForm, setShowForm] = useState(accounts.length === 0);
  const [token, setToken] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const connect = async () => {
    const value = token.trim();
    if (value.length < 20 || (!value.startsWith("github_pat_") && !value.startsWith("ghp_")) || /\s/.test(value)) { setError("请输入有效的 GitHub fine-grained 或 classic token"); return; }
    setLoading(true); setError("");
    try { await onConnect(value); setToken(""); setShowForm(false); }
    catch (reason) { setError(reason instanceof Error ? reason.message : "账号连接失败"); }
    finally { setLoading(false); }
  };
  return <div className="sheet-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}><section className="bottom-sheet" role="dialog" aria-modal="true" aria-labelledby="account-sheet-title"><div className="sheet-handle" /><div className="sheet-heading"><div><span className="eyebrow"><span />ACCOUNT VAULT</span><h2 id="account-sheet-title">GitHub 账号</h2></div><IconButton label="关闭账号面板" onClick={onClose}><X size={20} /></IconButton></div>
    {accounts.map((account) => <button className="sheet-account" type="button" key={account.id} onClick={() => onDefault(account.id)}><span className="large-avatar">{account.login.slice(0, 2).toUpperCase()}</span><span><strong>{account.login}</strong><small>{getSessionToken(account.id) ? "本次会话已授权" : "需要重新输入令牌"}</small></span>{account.isDefault && <Check size={20} weight="bold" />}</button>)}
    {showForm ? <div className="token-form"><label htmlFor="github-token">GitHub 访问令牌</label><input id="github-token" type="password" value={token} onChange={(event) => setToken(event.target.value)} autoComplete="off" placeholder="github_pat_… 或 ghp_…" aria-describedby={error ? "token-error" : "token-help"} /><p id={error ? "token-error" : "token-help"} className={error ? "field-error" : "field-help"} role={error ? "alert" : undefined}>{error || "支持 fine-grained 和 classic PAT。classic PAT 访问私有仓库需要 repo 权限；令牌仅保留在当前 Web 会话。"}</p><button className="primary-button" type="button" onClick={() => void connect()} disabled={loading}>{loading ? <><span className="spinner" />正在验证</> : <><GithubLogo size={21} />验证并连接</>}</button><button className="text-button full-width" type="button" onClick={() => setShowForm(false)} disabled={accounts.length === 0}>取消</button></div> : <button className="secondary-button" type="button" onClick={() => setShowForm(true)}><Plus size={20} />连接新账号</button>}
    <p className="oauth-note"><Lock size={15} />Web 版不把访问令牌写入持久化存储</p>
  </section></div>;
}

function ThemeSheet({ value, onChange, onClose, onToast }: { value: ThemeSettings; onChange: (value: ThemeSettings) => void; onClose: () => void; onToast: (message: string) => void }) {
  const inputRef = useRef<HTMLInputElement>(null);
  const pickImage = (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0]; if (!file) return;
    if (!file.type.startsWith("image/") || file.size > 8 * 1024 * 1024) { onToast("请选择小于 8 MB 的图片文件"); return; }
    const reader = new FileReader();
    reader.onload = () => {
      const image = new Image();
      image.onload = () => {
        const canvas = document.createElement("canvas"); canvas.width = 32; canvas.height = 32;
        const context = canvas.getContext("2d"); if (!context) { onToast("浏览器无法读取图片颜色"); return; }
        context.drawImage(image, 0, 0, 32, 32);
        const pixels = context.getImageData(0, 0, 32, 32).data; let red = 0; let green = 0; let blue = 0; let count = 0;
        for (let index = 0; index < pixels.length; index += 16) { if (pixels[index + 3] < 128) continue; red += pixels[index]; green += pixels[index + 1]; blue += pixels[index + 2]; count += 1; }
        const accent = count ? `#${[red, green, blue].map((channel) => Math.round(channel / count).toString(16).padStart(2, "0")).join("")}` : value.accent;
        onChange({ ...value, accentMode: "auto", accent, background: { kind: "image", value: `url(${reader.result as string})`, opacity: .58, blur: 2 } });
        onToast(`已提取主题色 ${accent}；文字表面保持高对比遮罩`);
      };
      image.onerror = () => onToast("图片读取失败");
      image.src = reader.result as string;
    };
    reader.readAsDataURL(file);
  };
  return <div className="sheet-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}><section className="bottom-sheet theme-sheet" role="dialog" aria-modal="true" aria-labelledby="theme-title"><div className="sheet-handle" /><div className="sheet-heading"><div><span className="eyebrow"><span />APPEARANCE</span><h2 id="theme-title">主题与背景</h2></div><IconButton label="关闭主题面板" onClick={onClose}><X size={20} /></IconButton></div>
    <fieldset><legend>显示模式</legend><div className="segmented">{[["system", <SlidersHorizontal size={19} />, "自动"], ["dark", <Moon size={19} />, "深色"], ["light", <Sun size={19} />, "浅色"]].map(([mode, icon, label]) => <button key={String(mode)} type="button" className={value.mode === mode ? "active" : ""} aria-pressed={value.mode === mode} onClick={() => onChange({ ...value, mode: mode as ThemeSettings["mode"] })}>{icon}{label}</button>)}</div></fieldset>
    <fieldset><legend>强调色</legend><div className="accent-row">{["#4ade80", "#38bdf8", "#a78bfa", "#fb7185", "#fbbf24"].map((color) => <button key={color} type="button" className={value.accent === color ? "selected" : ""} style={{ background: color }} aria-label={`选择强调色 ${color}`} aria-pressed={value.accent === color} onClick={() => onChange({ ...value, accentMode: "manual", accent: color })}>{value.accent === color && <Check size={17} color="#07100b" weight="bold" />}</button>)}<input aria-label="自定义强调色" type="color" value={value.accent} onChange={(event) => onChange({ ...value, accentMode: "manual", accent: event.target.value })} /></div></fieldset>
    <fieldset><legend>自定义背景</legend><input ref={inputRef} hidden type="file" accept="image/*" onChange={pickImage} /><button type="button" className="upload-zone" onClick={() => inputRef.current?.click()}><ImageSquare size={25} /><span><strong>选择本地图片</strong><small>自动提取主色，并使用独立表面保障文字可读</small></span></button><div className="background-actions"><button type="button" onClick={() => onChange({ ...value, background: defaultTheme.background })}>动态渐变</button><button type="button" onClick={() => onChange({ ...value, background: { kind: "none", opacity: 0, blur: 0 } })}>清除背景</button></div></fieldset>
  </section></div>;
}

function InfoSheet({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  return <div className="sheet-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}><section className="bottom-sheet info-sheet" role="dialog" aria-modal="true" aria-labelledby="info-title"><div className="sheet-handle" /><div className="sheet-heading"><h2 id="info-title">{title}</h2><IconButton label={`关闭${title}`} onClick={onClose}><X size={20} /></IconButton></div>{children}</section></div>;
}

export default App;
