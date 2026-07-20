#!/usr/bin/env tsx
import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import JSZip from "jszip";

export type RenderConfig = {
  width: number;
  height: number;
  locale: string;
  device: string;
  theme: string;
  selector: string;
};

export type ReleaseProvenance = {
  schemaVersion: 1;
  render: RenderConfig;
  sources: Array<{ path: string; sha256: string }>;
};

const SOURCE_ROOTS = ["src", "public"];
const SOURCE_FILES = [
  "bun.lock",
  "next.config.ts",
  "package.json",
  "tsconfig.json",
  "scripts/export-playwright.ts",
  "scripts/release-package.ts",
  "scripts/validate-exports.ts",
];

function portablePath(value: string): string {
  return value.split(path.sep).join(path.posix.sep);
}

async function walkFiles(root: string): Promise<string[]> {
  const entries = (await readdir(root, { withFileTypes: true })).sort((a, b) =>
    a.name.localeCompare(b.name)
  );
  const files: string[] = [];
  for (const entry of entries) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) files.push(...(await walkFiles(fullPath)));
    else if (entry.isFile()) files.push(fullPath);
  }
  return files;
}

async function sha256(filePath: string): Promise<string> {
  return createHash("sha256").update(await readFile(filePath)).digest("hex");
}

export async function buildSourceProvenance(
  packageRoot: string,
  render: RenderConfig
): Promise<ReleaseProvenance> {
  const files = [
    ...SOURCE_FILES.map((file) => path.resolve(packageRoot, file)),
    ...(await Promise.all(
      SOURCE_ROOTS.map((root) => walkFiles(path.resolve(packageRoot, root)))
    )).flat(),
  ].sort();
  const sources = await Promise.all(
    files.map(async (file) => ({
      path: portablePath(path.relative(packageRoot, file)),
      sha256: await sha256(file),
    }))
  );
  return { schemaVersion: 1, render, sources };
}

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label} does not match the current screenshot sources`);
  }
}

export async function verifyReleasePackage(
  packageRoot: string,
  exportRoot: string,
  render: RenderConfig
): Promise<void> {
  const provenancePath = path.join(exportRoot, "_provenance.json");
  const committedProvenance = JSON.parse(
    await readFile(provenancePath, "utf8")
  ) as ReleaseProvenance;
  const currentProvenance = await buildSourceProvenance(packageRoot, render);
  assertEqual(committedProvenance, currentProvenance, "release provenance");

  const manifestPath = path.join(exportRoot, "_manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8")) as Array<{
    path: string;
    width: number;
    height: number;
    locale: string;
    device: string;
    theme: string;
  }>;
  if (manifest.length === 0) throw new Error("release manifest is empty");
  const manifestPaths = manifest.map((item) => item.path).sort();
  if (new Set(manifestPaths).size !== manifestPaths.length) {
    throw new Error("release manifest contains duplicate screenshot paths");
  }
  for (const item of manifest) {
    assertEqual(
      {
        width: item.width,
        height: item.height,
        locale: item.locale,
        device: item.device,
        theme: item.theme,
      },
      {
        width: render.width,
        height: render.height,
        locale: render.locale,
        device: render.device,
        theme: render.theme,
      },
      `manifest entry ${item.path}`
    );
  }

  const screenshotRoot = path.join(exportRoot, "screenshots");
  const diskScreenshotPaths = (await walkFiles(screenshotRoot))
    .map((file) => portablePath(path.relative(exportRoot, file)))
    .sort();
  assertEqual(diskScreenshotPaths, manifestPaths, "manifest screenshot inventory");

  const zipPath = path.join(
    exportRoot,
    `app-store-screenshots-${render.width}x${render.height}.zip`
  );
  const zip = await JSZip.loadAsync(await readFile(zipPath));
  const expectedEntries = [
    "_contact-sheet.jpg",
    "_manifest.json",
    "_provenance.json",
    "_validation.txt",
    ...manifestPaths,
  ].sort();
  const zipEntries = Object.values(zip.files)
    .filter((entry) => !entry.dir)
    .map((entry) => entry.name)
    .sort();
  assertEqual(zipEntries, expectedEntries, "release ZIP inventory");

  for (const relative of expectedEntries) {
    const archiveEntry = zip.file(relative);
    if (!archiveEntry) throw new Error(`release ZIP is missing ${relative}`);
    const [archiveBytes, diskBytes] = await Promise.all([
      archiveEntry.async("nodebuffer"),
      readFile(path.join(exportRoot, relative)),
    ]);
    if (!archiveBytes.equals(diskBytes)) {
      throw new Error(`release ZIP entry differs from committed ${relative}`);
    }
  }
}

async function main() {
  const packageRoot = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    ".."
  );
  await verifyReleasePackage(
    packageRoot,
    path.join(packageRoot, "exports", "app-store-screenshots"),
    {
      width: 1242,
      height: 2688,
      locale: "en-US",
      device: "iphone-6.5",
      theme: "shibuya-red",
      selector: "[data-export-slide]",
    }
  );
  process.stdout.write("Release screenshot provenance and ZIP integrity passed.\n");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
