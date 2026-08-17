import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import App from "../App";
import * as api from "../api";

vi.mock("echarts-for-react/lib/core", () => ({ default: () => <div data-testid="chart" /> }));
vi.mock("../api", async () => {
  const actual = await vi.importActual<typeof import("../api")>("../api");
  return { ...actual, analyzeRepository: vi.fn(), getGraph: vi.fn(), getReport: vi.fn(), deleteRemoteProject: vi.fn(), verifyGithubToken: vi.fn() };
});

const graph = { commits: [{ id: "abcdef123", shortId: "abcdef1", parentIds: [], author: "User", authoredAt: "2026-08-17T00:00:00Z", message: "initial commit", refs: ["main"], lane: 0 }], truncated: false };
const report = { totalCommits: 1, branches: 1, tags: 0, contributors: [{ name: "User", commits: 1, additions: 0, deletions: 0 }], commitsByWeekday: [0, 1, 0, 0, 0, 0, 0], commitsByHour: Array(24).fill(0), hotspots: [], availability: { git: "available" as const }, generatedAt: "2026-08-17T00:00:00Z" };

describe("GitScope application flows", () => {
  beforeEach(() => {
    vi.mocked(api.analyzeRepository).mockResolvedValue("project-1");
    vi.mocked(api.getGraph).mockResolvedValue(graph);
    vi.mocked(api.getReport).mockResolvedValue(report);
  });

  it("does not show reserved accounts and provides an actionable empty state", async () => {
    render(<App />);
    await userEvent.click(screen.getByRole("button", { name: "账号库" }));
    expect(screen.getByText("尚未连接账号")).toBeVisible();
    expect(screen.queryByText(/mayacodes|acme-mobile/i)).not.toBeInTheDocument();
    expect(screen.getAllByRole("button", { name: "连接 GitHub 账号" }).some((button) => !button.hasAttribute("disabled"))).toBe(true);
  });

  it("runs a real analysis client flow and renders returned commit data", async () => {
    render(<App />);
    await userEvent.type(screen.getByLabelText("Git 仓库链接"), "https://github.com/real/repository");
    await userEvent.click(screen.getByRole("button", { name: "导入并分析" }));
    await waitFor(() => expect(api.analyzeRepository).toHaveBeenCalledWith("https://github.com/real/repository", undefined));
    expect((await screen.findAllByText("initial commit"))[0]).toBeVisible();
    expect(screen.getByText("1 commits")).toBeVisible();
  });

  it("verifies a user supplied GitHub token before creating an account", async () => {
    vi.mocked(api.verifyGithubToken).mockResolvedValue({ id: "99", provider: "github", login: "actual-user", isDefault: false, lastUsedAt: "2026-08-17T00:00:00Z" });
    render(<App />);
    await userEvent.click(screen.getByRole("button", { name: "连接 GitHub 账号" }));
    await userEvent.type(screen.getByLabelText("GitHub 访问令牌"), `ghp_${"x".repeat(36)}`);
    await userEvent.click(screen.getByRole("button", { name: "验证并连接" }));
    expect((await screen.findAllByText("actual-user"))[0]).toBeVisible();
    expect(screen.queryByText("mayacodes")).not.toBeInTheDocument();
  });

  it("never sends a GitHub account token to a non-GitHub repository", async () => {
    vi.mocked(api.verifyGithubToken).mockResolvedValue({ id: "99", provider: "github", login: "actual-user", isDefault: false, lastUsedAt: "2026-08-17T00:00:00Z" });
    render(<App />);
    await userEvent.click(screen.getByRole("button", { name: "连接 GitHub 账号" }));
    await userEvent.type(screen.getByLabelText("GitHub 访问令牌"), `ghp_${"x".repeat(36)}`);
    await userEvent.click(screen.getByRole("button", { name: "验证并连接" }));
    await userEvent.type(screen.getByLabelText("Git 仓库链接"), "https://gitlab.com/verified/repository");
    await userEvent.selectOptions(screen.getByLabelText("分析账号"), "99");
    await userEvent.click(screen.getByRole("button", { name: "导入并分析" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("GitHub 账号令牌只能用于 github.com");
    expect(api.analyzeRepository).not.toHaveBeenCalled();
  });

  it("switches to dark mode without losing visible settings labels", async () => {
    render(<App />);
    await userEvent.click(screen.getByRole("button", { name: "设置" }));
    await userEvent.click(screen.getByRole("button", { name: /外观与背景/ }));
    await userEvent.click(screen.getByRole("button", { name: "深色" }));
    expect(document.querySelector(".site")).toHaveClass("theme-dark");
    expect(screen.getByText("显示模式")).toBeVisible();
    expect(screen.getByText("强调色")).toBeVisible();
  });
});
