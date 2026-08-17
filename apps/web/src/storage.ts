import type { AccountRef, SavedProject } from "@gitscope/contracts";

const accountKey = "gitscope.v2.accounts";
const projectKey = "gitscope.v2.projects";

function parseList<T>(key: string): T[] {
  try {
    const value = localStorage.getItem(key);
    return value ? JSON.parse(value) as T[] : [];
  } catch {
    return [];
  }
}

export function loadAccounts(): AccountRef[] {
  const current = parseList<AccountRef>(accountKey).filter((account) =>
    Boolean(account.id && account.login),
  );
  // 0.1 shipped demo identities under this unversioned key. Never import them
  // into the verified account store; v2 only contains accounts verified via /user.
  localStorage.removeItem("gitscope.accounts");
  return current;
}

export function saveAccounts(accounts: AccountRef[]): void {
  localStorage.setItem(accountKey, JSON.stringify(accounts));
}

export function loadProjects(): SavedProject[] {
  const current = parseList<SavedProject>(projectKey).filter((project) =>
    Boolean(project.id && project.url && project.owner && project.name),
  );
  localStorage.removeItem("gitscope.projects");
  return current;
}

export function saveProjects(projects: SavedProject[]): void {
  localStorage.setItem(projectKey, JSON.stringify(projects));
}

export function saveSessionToken(accountId: string, token: string): void {
  sessionStorage.setItem(`gitscope.token.${accountId}`, token);
}

export function getSessionToken(accountId?: string): string | undefined {
  if (!accountId) return undefined;
  return sessionStorage.getItem(`gitscope.token.${accountId}`) || undefined;
}

export function removeSessionToken(accountId: string): void {
  sessionStorage.removeItem(`gitscope.token.${accountId}`);
}

export function clearUserData(): void {
  localStorage.removeItem(accountKey);
  localStorage.removeItem(projectKey);
  for (let index = sessionStorage.length - 1; index >= 0; index -= 1) {
    const key = sessionStorage.key(index);
    if (key?.startsWith("gitscope.token.")) sessionStorage.removeItem(key);
  }
}
