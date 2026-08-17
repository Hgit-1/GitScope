import { describe, expect, it } from "vitest";
import { loadAccounts, loadProjects, saveAccounts, saveProjects } from "../storage";

describe("user storage", () => {
  it("starts empty and removes legacy placeholder accounts", () => {
    localStorage.setItem("gitscope.accounts", JSON.stringify([
      { id: "maya", login: "mayacodes", provider: "github", isDefault: true },
    ]));
    expect(loadAccounts()).toEqual([]);
    expect(localStorage.getItem("gitscope.accounts")).toBeNull();
  });

  it("round trips only user-created records", () => {
    const accounts = [{ id: "42", login: "real-user", provider: "github" as const, isDefault: true, lastUsedAt: "2026-01-01T00:00:00Z" }];
    const projects = [{ id: "project-id", url: "https://github.com/real/repo", owner: "real", name: "repo", provider: "github" as const, visibility: "public" as const, pinned: false }];
    saveAccounts(accounts); saveProjects(projects);
    expect(loadAccounts()).toEqual(accounts);
    expect(loadProjects()).toEqual(projects);
  });
});
