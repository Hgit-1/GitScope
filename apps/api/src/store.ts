import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { AnalysisJob, EngineeringReport, GraphPage } from "@gitscope/contracts";

export interface ProjectResult { id: string; url: string; graph: GraphPage; report: EngineeringReport; }
const jobs = new Map<string, AnalysisJob>();

interface StoredData { version: 1; results: ProjectResult[]; }

export class ProjectStore {
  private readonly results = new Map<string, ProjectResult>();

  constructor(private readonly dataFile?: string) {
    if (!dataFile) return;
    try {
      const data = JSON.parse(readFileSync(dataFile, "utf8")) as StoredData;
      if (data.version !== 1 || !Array.isArray(data.results)) throw new Error("unsupported data format");
      for (const result of data.results) this.results.set(result.id, result);
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code !== "ENOENT") throw new Error(`无法读取分析结果存储 ${dataFile}`, { cause: error });
    }
  }

  save(url: string, graph: GraphPage, report: EngineeringReport): ProjectResult {
    const result = { id: randomUUID(), url, graph, report };
    this.results.set(result.id, result);
    try {
      this.persist();
    } catch (error) {
      this.results.delete(result.id);
      throw error;
    }
    return result;
  }

  get(id: string): ProjectResult | undefined { return this.results.get(id); }

  delete(id: string): boolean {
    const result = this.results.get(id);
    if (!result) return false;
    this.results.delete(id);
    try {
      this.persist();
    } catch (error) {
      this.results.set(id, result);
      throw error;
    }
    return true;
  }

  private persist(): void {
    if (!this.dataFile) return;
    mkdirSync(dirname(this.dataFile), { recursive: true });
    const temporaryFile = `${this.dataFile}.${process.pid}.tmp`;
    const data: StoredData = { version: 1, results: [...this.results.values()] };
    writeFileSync(temporaryFile, JSON.stringify(data), { encoding: "utf8", mode: 0o600 });
    renameSync(temporaryFile, this.dataFile);
  }
}

const projectStore = new ProjectStore(process.env.GITSCOPE_DATA_FILE?.trim() || undefined);

export function createJob(url: string): AnalysisJob {
  const now = new Date().toISOString();
  const job: AnalysisJob = { id: randomUUID(), url, status: "queued", stage: "等待分析 Worker", progress: 0, createdAt: now, updatedAt: now };
  jobs.set(job.id, job);
  return job;
}
export function getJob(id: string): AnalysisJob | undefined { return jobs.get(id); }
export function updateJob(id: string, patch: Partial<AnalysisJob>): AnalysisJob | undefined { const current = jobs.get(id); if (!current) return; const next = { ...current, ...patch, updatedAt: new Date().toISOString() }; jobs.set(id, next); return next; }
export function saveResult(url: string, graph: GraphPage, report: EngineeringReport): ProjectResult { return projectStore.save(url, graph, report); }
export function getResult(id: string): ProjectResult | undefined { return projectStore.get(id); }
export function deleteResult(id: string): boolean { return projectStore.delete(id); }
