#!/usr/bin/env -S deno run --allow-all

/**
 * gemini-rag.ts - RAG tool using Gemini File Search API
 * Uses the NEW SDK: @google/genai (not @google/generative-ai)
 */

import { GoogleGenAI } from "npm:@google/genai";
import { walk } from "jsr:@std/fs/walk";
import { basename, extname } from "jsr:@std/path";
import { parseArgs } from "jsr:@std/cli/parse-args";

// ==========================================
// Functional Core & Types
// ==========================================

type Result<T, E = Error> =
  | { success: true; value: T }
  | { success: false; error: E };

const ok = <T>(value: T): Result<T> => ({ success: true, value });
const fail = <E>(error: E): Result<never, E> => ({ success: false, error });
const isSuccess = <T, E>(r: Result<T, E>): r is { success: true; value: T } => r.success;

const safeAsync = async <T>(fn: () => Promise<T>): Promise<Result<T, Error>> => {
  try {
    return ok(await fn());
  } catch (e) {
    return fail(e instanceof Error ? e : new Error(String(e)));
  }
};

// ==========================================
// Configuration & Env
// ==========================================

const API_KEY = Deno.env.get("GEMINI_API_KEY");
if (!API_KEY) {
  console.error("Error: GEMINI_API_KEY is not set.");
  Deno.exit(1);
}

// New SDK: GoogleGenAI
const ai = new GoogleGenAI({ apiKey: API_KEY });

const SUPPORTED_EXTENSIONS = new Set([
  ".txt", ".md", ".py", ".js", ".ts", ".html", ".css", ".json", ".yaml", ".yml",
  ".sh", ".bash", ".zsh", ".nix", ".hs", ".c", ".cpp", ".h", ".rs", ".go",
  ".pdf", ".csv",
]);

const getScope = () => basename(Deno.cwd());

// ==========================================
// MIME Type Helper
// ==========================================

const getMimeType = (path: string): string => {
  const ext = extname(path).toLowerCase();
  const overrides: Record<string, string> = {
    ".ts": "text/plain",
    ".tsx": "text/plain",
    ".js": "text/plain",
    ".jsx": "text/plain",
    ".py": "text/plain",
    ".sh": "text/plain",
    ".nix": "text/plain",
    ".md": "text/markdown",
    ".json": "application/json",
    ".html": "text/html",
    ".css": "text/css",
    ".yaml": "text/yaml",
    ".yml": "text/yaml",
    ".hs": "text/plain",
    ".c": "text/plain",
    ".cpp": "text/plain",
    ".h": "text/plain",
    ".go": "text/plain",
    ".rs": "text/plain",
    ".txt": "text/plain",
    ".pdf": "application/pdf",
    ".csv": "text/csv",
  };
  return overrides[ext] || "text/plain";
};

// ==========================================
// File System
// ==========================================

interface LocalFile {
  path: string;
  filename: string;
  displayName: string;
}

const isSupported = (path: string) => {
  const ext = extname(path).toLowerCase();
  return SUPPORTED_EXTENSIONS.has(ext) && !basename(path).startsWith(".");
};

const expandPath = async (pathStr: string): Promise<string[]> => {
  try {
    const stat = await Deno.stat(pathStr);
    if (stat.isFile) {
      return isSupported(pathStr) ? [pathStr] : [];
    } else if (stat.isDirectory) {
      const paths: string[] = [];
      for await (const entry of walk(pathStr, { includeDirs: false })) {
        if (isSupported(entry.path) && !entry.name.startsWith(".")) {
          paths.push(entry.path);
        }
      }
      return paths;
    }
  } catch (_e) {
    // Ignore
  }
  return [];
};

const resolveTargets = async (pathStrs: string[]): Promise<LocalFile[]> => {
  const allPaths: string[] = [];
  for (const p of pathStrs) {
    allPaths.push(...(await expandPath(p)));
  }
  const uniquePaths = Array.from(new Set(allPaths));
  return uniquePaths.map(p => ({
    path: p,
    filename: basename(p),
    displayName: basename(p),
  }));
};

// ==========================================
// Gemini API: File Search Stores
// ==========================================

const getOrCreateStore = async (displayName: string): Promise<Result<any>> => {
  try {
    const listResp = await ai.fileSearchStores.list();
    // @ts-ignore: async iterable
    for await (const store of listResp) {
      if (store.config?.displayName === displayName || store.displayName === displayName) {
        console.error(`INFO: Found existing store: ${displayName} (${store.name})`);
        return ok(store);
      }
    }

    console.error(`INFO: Creating new store: ${displayName}`);
    const newStore = await ai.fileSearchStores.create({
      config: { displayName }
    });
    return ok(newStore);
  } catch (e) {
    return fail(e instanceof Error ? e : new Error(String(e)));
  }
};

const uploadFileToStore = async (storeName: string, localFile: LocalFile): Promise<Result<void>> => {
  console.error(`INFO: Uploading ${localFile.displayName}...`);
  try {
    let op = await ai.fileSearchStores.uploadToFileSearchStore({
      file: localFile.path,
      fileSearchStoreName: storeName,
      config: {
        displayName: encodeURIComponent(localFile.displayName),
        mimeType: getMimeType(localFile.path),
      }
    });

    while (!op.done) {
      await new Promise(resolve => setTimeout(resolve, 2000));
      op = await ai.operations.get({ operation: op });
    }

    if (op.error) {
      return fail(new Error(`Upload failed: ${JSON.stringify(op.error)}`));
    }

    return ok(undefined);
  } catch (e) {
    return fail(e instanceof Error ? e : new Error(String(e)));
  }
};

const retry = async <T>(fn: () => Promise<Result<T>>, retries = 3, delay = 2000): Promise<Result<T>> => {
  const res = await fn();
  if (isSuccess(res)) return res;
  if (retries <= 0) return res;

  console.error(`WARN: Retrying... (${res.error.message})`);
  await new Promise(r => setTimeout(r, delay));
  return retry(fn, retries - 1, delay * 2);
};

// ==========================================
// Actions
// ==========================================

const doUpsert = async (paths: string[]): Promise<Result<string>> => {
  const scope = getScope();
  const targets = await resolveTargets(paths);
  if (targets.length === 0) return fail(new Error("No supported files found."));

  const storeRes = await getOrCreateStore(scope);
  if (!isSuccess(storeRes)) return fail(storeRes.error);
  const store = storeRes.value;

  const LIMIT = 5;
  const results: Result<void>[] = [];

  for (let i = 0; i < targets.length; i += LIMIT) {
    const batch = targets.slice(i, i + LIMIT);
    const batchResults = await Promise.all(
      batch.map(f => retry(() => uploadFileToStore(store.name!, f)))
    );
    results.push(...batchResults);
  }

  const failures = results.filter(r => !r.success);
  if (failures.length > 0) {
    return fail(new Error(`Some uploads failed: ${(failures[0] as any).error.message}`));
  }

  return ok(`Synced ${targets.length} files to store '${scope}' (${store.name}).`);
};

const doAsk = async (query: string): Promise<Result<string>> => {
  const scope = getScope();
  const storeRes = await getOrCreateStore(scope);
  if (!isSuccess(storeRes)) return fail(storeRes.error);
  const store = storeRes.value;

  try {
    console.error(`INFO: Querying store ${store.config?.displayName} (${store.name})...`);

    // Use new sdk: ai.models.generateContent
    const resp = await ai.models.generateContent({
      model: "gemini-3-flash-preview",
      contents: query,
      config: {
        tools: [{
          fileSearch: {
            fileSearchStoreNames: [store.name!]
          }
        }]
      }
    });

    return ok(resp.text || "No response text.");
  } catch (e) {
    return fail(e instanceof Error ? e : new Error(String(e)));
  }
};

const doList = async (): Promise<Result<string>> => {
  const scope = getScope();
  const storeRes = await getOrCreateStore(scope);
  if (!isSuccess(storeRes)) return fail(storeRes.error);
  const store = storeRes.value;

  try {
    const docsResp = await ai.fileSearchStores.documents.list({
      parent: store.name!
    });

    const docs: any[] = [];
    // @ts-ignore
    for await (const d of docsResp) {
      docs.push(d);
    }

    if (docs.length === 0) return ok("No documents in store.");

    return ok(docs.map(d => `${d.name} | ${d.displayName || '(No Name)'}`).join("\n"));
  } catch (e) {
    return fail(e instanceof Error ? e : new Error(String(e)));
  }
};

// ==========================================
// Main
// ==========================================

const main = async () => {
  const args = parseArgs(Deno.args);
  const cmd = args._[0];

  let res: Result<string>;

  if (cmd === "upsert") {
    const paths = args._.slice(1).map(String);
    res = await doUpsert(paths);
  } else if (cmd === "ask") {
    const query = args._[1] ? String(args._[1]) : "";
    res = await doAsk(query);
  } else if (cmd === "list") {
    res = await doList();
  } else {
    res = fail(new Error("Usage: gemini-rag [upsert <paths> | ask <query> | list]"));
  }

  if (isSuccess(res)) {
    console.log(res.value);
    Deno.exit(0);
  } else {
    console.error(`Error: ${res.error.message}`);
    Deno.exit(1);
  }
};

if (import.meta.main) {
  main();
}
