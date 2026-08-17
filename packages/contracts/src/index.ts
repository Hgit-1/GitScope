export type GitProvider = "github" | "gitlab" | "bitbucket" | "generic";
export type JobStatus = "queued" | "validating" | "cloning" | "analyzing" | "completed" | "failed";
export type MetricState = "available" | "unsupported" | "truncated" | "computing";

export interface AccountRef {
  id: string;
  provider: "github";
  login: string;
  avatarUrl?: string;
  isDefault: boolean;
  lastUsedAt: string;
}

export interface SavedProject {
  id: string;
  url: string;
  name: string;
  owner: string;
  provider: GitProvider;
  visibility: "public" | "private" | "unknown";
  pinned: boolean;
  lastAnalyzedAt?: string;
}

export interface CommitNode {
  id: string;
  shortId: string;
  parentIds: string[];
  author: string;
  authorEmail?: string;
  authoredAt: string;
  message: string;
  refs: string[];
  lane: number;
}

export interface GraphPage {
  commits: CommitNode[];
  nextCursor?: string;
  truncated: boolean;
}

export interface ContributorMetric {
  name: string;
  commits: number;
  additions: number;
  deletions: number;
}

export interface EngineeringReport {
  totalCommits: number;
  branches: number;
  tags: number;
  contributors: ContributorMetric[];
  commitsByWeekday: number[];
  commitsByHour: number[];
  hotspots: Array<{ path: string; changes: number }>;
  availability: Record<string, MetricState>;
  generatedAt: string;
}

export interface AnalysisJob {
  id: string;
  url: string;
  status: JobStatus;
  stage: string;
  progress: number;
  projectId?: string;
  error?: string;
  createdAt: string;
  updatedAt: string;
}

export interface ThemeSettings {
  mode: "system" | "light" | "dark";
  accentMode: "auto" | "manual";
  accent: string;
  background: {
    kind: "none" | "color" | "gradient" | "image";
    value?: string;
    opacity: number;
    blur: number;
  };
}
