import fs from "node:fs";
import path from "node:path";
import type { JsonObject } from "@earendil-works/pi-durable";

export interface RhythmDayEntry {
  date: string;
  firstRound?: string;
  rounds: number;
  tasksDone: number;
  tasksOpen: number;
  dayOff: boolean;
}

export interface LessonRecord extends JsonObject {
  id: string;
  pattern: string;
  count: number;
  windowDays: number;
  firstDate: string;
  lastDate: string;
  summary: string;
  accepted: boolean;
  acceptedAt: string | null;
}

function parseMinute(clock?: string): number | null {
  if (!clock || typeof clock !== "string") return null;
  const parts = clock.trim().split(":");
  if (parts.length !== 2) return null;
  const h = Number(parts[0]);
  const m = Number(parts[1]);
  if (!Number.isInteger(h) || !Number.isInteger(m) || h < 0 || h > 23 || m < 0 || m > 59) {
    return null;
  }
  return h * 60 + m;
}

export function readRhythmDays(stateDir: string): RhythmDayEntry[] {
  const logPath = path.join(stateDir, "state.json.log");
  if (!fs.existsSync(logPath)) return [];
  let raw = "";
  try {
    raw = fs.readFileSync(logPath, "utf8");
  } catch {
    return [];
  }
  const out: RhythmDayEntry[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const parsed = JSON.parse(trimmed) as Record<string, unknown>;
      if (typeof parsed.date !== "string" || !parsed.date) continue;
      out.push({
        date: parsed.date,
        ...(typeof parsed.firstRound === "string" ? { firstRound: parsed.firstRound } : {}),
        rounds: typeof parsed.rounds === "number" ? parsed.rounds : 0,
        tasksDone: typeof parsed.tasksDone === "number" ? parsed.tasksDone : 0,
        tasksOpen: typeof parsed.tasksOpen === "number" ? parsed.tasksOpen : 0,
        dayOff: parsed.dayOff === true,
      });
    } catch {
      continue;
    }
  }
  return out;
}

export function listLessons(stateDir: string): LessonRecord[] {
  const filePath = path.join(stateDir, "lessons.jsonl");
  if (!fs.existsSync(filePath)) return [];
  let raw = "";
  try {
    raw = fs.readFileSync(filePath, "utf8");
  } catch {
    return [];
  }
  const out: LessonRecord[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const parsed = JSON.parse(trimmed) as Record<string, unknown>;
      if (typeof parsed.id !== "string" || typeof parsed.pattern !== "string") continue;
      out.push({
        id: parsed.id,
        pattern: parsed.pattern,
        count: typeof parsed.count === "number" ? parsed.count : 0,
        windowDays: typeof parsed.windowDays === "number" ? parsed.windowDays : 7,
        firstDate: typeof parsed.firstDate === "string" ? parsed.firstDate : "",
        lastDate: typeof parsed.lastDate === "string" ? parsed.lastDate : "",
        summary: typeof parsed.summary === "string" ? parsed.summary : "",
        accepted: parsed.accepted === true,
        acceptedAt: typeof parsed.acceptedAt === "string" ? parsed.acceptedAt : null,
      });
    } catch {
      continue;
    }
  }
  return out;
}

function writeLessonsAtomic(stateDir: string, lessons: LessonRecord[]): void {
  fs.mkdirSync(stateDir, { recursive: true });
  const filePath = path.join(stateDir, "lessons.jsonl");
  const tmpPath = path.join(stateDir, `.lessons.jsonl.${process.pid}.tmp`);
  const content =
    lessons.length > 0 ? lessons.map((item) => JSON.stringify(item)).join("\n") + "\n" : "";
  fs.writeFileSync(tmpPath, content, { mode: 0o600 });
  fs.renameSync(tmpPath, filePath);
}

export function runReflection(stateDir: string, windowDays = 7): LessonRecord[] {
  const clampedWindow = Math.max(1, Math.min(90, Math.round(windowDays)));
  const allDays = readRhythmDays(stateDir);
  const windowSlice = allDays.slice(-clampedWindow).filter((d) => !d.dayOff);
  const existing = new Map(listLessons(stateDir).map((l) => [l.id, l]));

  const candidates: Array<{
    pattern: string;
    matched: RhythmDayEntry[];
    describe: (days: RhythmDayEntry[]) => string;
  }> = [
    {
      pattern: "carried_frogs",
      matched: windowSlice.filter((d) => d.tasksOpen > 0),
      describe: (days) => {
        const totalOpen = days.reduce((sum, d) => sum + d.tasksOpen, 0);
        return `${days.length} of the last ${windowSlice.length} work days ended with unfinished tasks (${totalOpen} open total).`;
      },
    },
    {
      pattern: "zero_round_days",
      matched: windowSlice.filter((d) => d.rounds === 0 && d.tasksDone + d.tasksOpen > 0),
      describe: (days) =>
        `${days.length} of the last ${windowSlice.length} work days had tasks in the book but zero finished deep-work rounds.`,
    },
    {
      pattern: "late_first_round",
      matched: windowSlice.filter((d) => {
        const min = parseMinute(d.firstRound);
        return min !== null && min >= 11 * 60;
      }),
      describe: (days) =>
        `First deep-work round started at or after 11:00 on ${days.length} of the last ${windowSlice.length} work days.`,
    },
    {
      pattern: "steady_paid_days",
      matched: windowSlice.filter((d) => d.rounds >= 1 && d.tasksOpen === 0 && d.tasksDone > 0),
      describe: (days) =>
        `${days.length} of the last ${windowSlice.length} work days finished every task with at least one paid round.`,
    },
  ];

  const updated = new Map<string, LessonRecord>();
  for (const [id, lesson] of existing) {
    if (lesson.accepted) {
      updated.set(id, lesson);
    }
  }

  for (const candidate of candidates) {
    if (candidate.matched.length === 0) continue;
    const id = `lesson-${candidate.pattern}`;
    const prev = existing.get(id);
    const firstDate = candidate.matched[0]!.date;
    const lastDate = candidate.matched[candidate.matched.length - 1]!.date;
    updated.set(id, {
      id,
      pattern: candidate.pattern,
      count: candidate.matched.length,
      windowDays: clampedWindow,
      firstDate,
      lastDate,
      summary: candidate.describe(candidate.matched),
      accepted: prev?.accepted ?? false,
      acceptedAt: prev?.acceptedAt ?? null,
    });
  }

  const result = [...updated.values()];
  writeLessonsAtomic(stateDir, result);
  return result;
}

export function acceptLesson(
  stateDir: string,
  lessonID: string,
  nowIso = new Date().toISOString(),
): { lesson: LessonRecord; repoDiffHint: string } | null {
  const lessons = listLessons(stateDir);
  const idx = lessons.findIndex((item) => item.id === lessonID);
  if (idx === -1) return null;
  const target = lessons[idx]!;
  const updatedLesson: LessonRecord = {
    ...target,
    accepted: true,
    acceptedAt: target.acceptedAt ?? nowIso,
  };
  lessons[idx] = updatedLesson;
  writeLessonsAtomic(stateDir, lessons);
  return {
    lesson: updatedLesson,
    repoDiffHint: `Apply lesson ${updatedLesson.id} (${updatedLesson.pattern}) as a reviewed prompt/rule commit in git; runtime prompts stay immutable.`,
  };
}
