#!/usr/bin/env -S deno run --allow-all

/**
 * split-video.ts - Split videos into chunks using ffmpeg streams
 *
 * Philosophy:
 * - Functional Pipeline (Unix Pipe)
 * - Immutable Data
 * - No intermediate large files (Stream Copy)
 */

import { parseArgs } from "jsr:@std/cli/parse-args";
import { basename, extname, join } from "jsr:@std/path";
import { match, P } from "npm:ts-pattern";

// ==========================================
// Types
// ==========================================

type Result<T, E = Error> =
  | { readonly success: true; readonly value: T }
  | { readonly success: false; readonly error: E };

const ok = <T>(value: T): Result<T> => ({ success: true, value });
const fail = <E>(error: E): Result<never, E> => ({ success: false, error });

type Config = {
  readonly inputs: readonly string[];
  readonly outDir: string;
  readonly segmentTime: string; // "MM:SS" or "HH:MM:SS"
};

// ==========================================
// Functional Core
// ==========================================

// Parse "MM:SS" or default to "14:50" (Safe margin for 15min limit)
const normalizeTime = (t: string | undefined): string =>
  t ?? "14:50";

const parseConfig = (args: string[]): Result<Config> =>
  match(parseArgs(args))
    .with(
      { _: P.not(P.array([])), "out-dir": P.string },
      (parsed) => ok({
        inputs: parsed._.map(String),
        outDir: parsed["out-dir"],
        segmentTime: normalizeTime(String(parsed["duration"] || undefined)),
      })
    )
    .otherwise(() => fail(new Error("Usage: split-video <files...> --out-dir <dir> [--duration MM:SS]")));

// Generate output pattern: "filename_%03d.mp4"
const getOutputPattern = (inputFile: string, outDir: string): string => {
  const ext = extname(inputFile);
  const name = basename(inputFile, ext);
  return join(outDir, `${name}_%03d${ext}`);
};

// ==========================================
// IO Layer (Encapsulated)
// ==========================================

const ensureDir = (dir: string): Promise<Result<void>> =>
  Deno.mkdir(dir, { recursive: true })
    .then(() => ok(undefined))
    .catch((e) => fail(e instanceof Error ? e : new Error(String(e))));

const runFfmpeg = (
  input: string,
  outPattern: string,
  segmentTime: string
): Promise<Result<string>> => {
  console.error(`Processing: ${input} -> ${outPattern} (Chunk: ${segmentTime})`);

  // ffmpeg -i INPUT -c copy -map 0 -f segment -segment_time TIME -reset_timestamps 1 OUT_PATTERN
  const cmd = new Deno.Command("ffmpeg", {
    args: [
      "-i", input,
      "-c", "copy",
      "-map", "0",
      "-f", "segment",
      "-segment_time", segmentTime,
      "-reset_timestamps", "1",
      outPattern,
    ],
    stdout: "piped",
    stderr: "piped",
  });

  return cmd.output().then((output) =>
    output.success
      ? ok(`Success: ${input}`)
      : fail(new Error(`ffmpeg failed for ${input}: ${new TextDecoder().decode(output.stderr)}`))
  );
};

// ==========================================
// Pipeline & Orchestration
// ==========================================

const processSingleFile = (config: Config) => (input: string): Promise<Result<string>> =>
  runFfmpeg(
    input,
    getOutputPattern(input, config.outDir),
    config.segmentTime
  );

const processAll = (config: Config): Promise<readonly Result<string>[]> =>
  // Sequential execution to avoid IO saturation on SD card
  config.inputs.reduce(
    (accPromise, input) =>
      accPromise.then((results) =>
        processSingleFile(config)(input).then((res) => [...results, res])
      ),
    Promise.resolve([] as readonly Result<string>[])
  );

// ==========================================
// Main
// ==========================================

const main = () =>
  parseConfig(Deno.args).success
    ? // Valid Config path
      ensureDir((parseConfig(Deno.args) as { value: Config }).value.outDir)
        .then((dirRes) =>
          dirRes.success
            ? processAll((parseConfig(Deno.args) as { value: Config }).value)
            : Promise.resolve([fail(dirRes.error)])
        )
        .then((results) => {
          const failures = results.filter((r) => !r.success);
          const successes = results.filter((r) => r.success);

          console.log(`Processed: ${successes.length}, Failed: ${failures.length}`);
          failures.forEach((f) => console.error((f as { error: Error }).error.message));

          Deno.exit(failures.length > 0 ? 1 : 0);
        })
    : // Invalid Config path
      (console.error((parseConfig(Deno.args) as { error: Error }).error.message), Deno.exit(1));

// Entry Point
if (import.meta.main) {
  main();
}
