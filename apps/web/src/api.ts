import type { AccountRef, AnalysisJob, EngineeringReport, GraphPage } from "@gitscope/contracts";

const apiBase = (import.meta.env.VITE_API_URL as string | undefined)?.replace(/\/$/, "") || "http://localhost:8080";

export class ApiError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
    this.name = "ApiError";
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${apiBase}${path}`, init);
  } catch {
    throw new ApiError("无法连接分析服务，请确认 API 已启动并检查网络");
  }
  if (!response.ok) {
    const data = await response.json().catch(() => ({})) as { error?: string };
    throw new ApiError(data.error || `请求失败（${response.status}）`, response.status);
  }
  return response.status === 204 ? undefined as T : response.json() as Promise<T>;
}

export async function analyzeRepository(url: string, accessToken?: string): Promise<string> {
  const job = await request<AnalysisJob>("/v1/analysis-jobs", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(accessToken ? { authorization: `Bearer ${accessToken}` } : {}),
    },
    body: JSON.stringify({ url }),
  });
  for (let attempt = 0; attempt < 120; attempt += 1) {
    const current = await request<AnalysisJob>(`/v1/analysis-jobs/${encodeURIComponent(job.id)}`);
    if (current.status === "completed" && current.projectId) return current.projectId;
    if (current.status === "failed") throw new ApiError(current.error || "仓库分析失败");
    await new Promise((resolve) => window.setTimeout(resolve, Math.min(750 + attempt * 40, 3000)));
  }
  throw new ApiError("分析等待超时，任务可能仍在后台执行");
}

export function getGraph(projectId: string, cursor?: string): Promise<GraphPage> {
  const query = cursor ? `?cursor=${encodeURIComponent(cursor)}` : "";
  return request<GraphPage>(`/v1/projects/${encodeURIComponent(projectId)}/graph${query}`);
}

export function getReport(projectId: string): Promise<EngineeringReport> {
  return request<EngineeringReport>(`/v1/projects/${encodeURIComponent(projectId)}/reports`);
}

export function deleteRemoteProject(projectId: string): Promise<void> {
  return request<void>(`/v1/projects/${encodeURIComponent(projectId)}`, { method: "DELETE" });
}

export async function verifyGithubToken(token: string): Promise<AccountRef> {
  let response: Response;
  try {
    response = await fetch("https://api.github.com/user", {
      headers: {
        accept: "application/vnd.github+json",
        authorization: `Bearer ${token}`,
        "x-github-api-version": "2022-11-28",
      },
    });
  } catch {
    throw new ApiError("无法连接 GitHub，请检查网络后重试");
  }
  if (!response.ok) throw new ApiError(response.status === 401 ? "令牌无效或已过期" : "GitHub 账号验证失败", response.status);
  const user = await response.json() as { id: number; login: string; avatar_url?: string };
  return {
    id: String(user.id),
    provider: "github",
    login: user.login,
    avatarUrl: user.avatar_url,
    isDefault: false,
    lastUsedAt: new Date().toISOString(),
  };
}
