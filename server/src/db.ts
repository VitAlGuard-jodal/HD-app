import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { initializeSchema } from "./store.ts";

export function openDb(path: string): DatabaseSync {
  if (path !== ":memory:") mkdirSync(dirname(resolve(path)), { recursive: true });
  const db = new DatabaseSync(path);
  try {
    initializeSchema(db);
    return db;
  } catch (error) {
    db.close();
    throw error;
  }
}
