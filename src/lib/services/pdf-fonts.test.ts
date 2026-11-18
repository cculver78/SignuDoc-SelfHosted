import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { PDFDocument } from "pdf-lib";

import {
  collectCodePoints,
  embedTextFaces,
  toDrawableText,
} from "./pdf-fonts.ts";

async function extractText(pdfBytes: Uint8Array): Promise<string> {
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  const document = await pdfjs.getDocument({
    data: new Uint8Array(pdfBytes),
    useSystemFonts: false,
    verbosity: 0,
  }).promise;
  const parts: string[] = [];

  for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
    const page = await document.getPage(pageNumber);
    const content = await page.getTextContent();

    parts.push(
      content.items.map((item: { str?: string }) => item.str ?? "").join(""),
    );
  }

  await document.destroy();

  return parts.join("\n");
}

test("toDrawableText keeps one line of visible characters", () => {
  assert.equal(toDrawableText("a\tb\nc\r\nd"), "a b c  d");
  assert.equal(toDrawableText("9:41 AM"), "9:41 AM");
  assert.equal(toDrawableText("zero​width﻿"), "zerowidth");
  // Decomposed "é" is drawn as the single composed character.
  assert.equal(toDrawableText("Café"), "Café");
  assert.equal(toDrawableText("\ud800"), "");
});

test("collectCodePoints walks every string in a value", () => {
  const codePoints = collectCodePoints([
    { name: "Ab", nested: { value: "c" } },
    null,
    7,
    ["山"],
  ]);

  assert.deepEqual(
    [...codePoints].sort((left, right) => left - right),
    [0x41, 0x62, 0x63, 0x5c71],
  );
});

test("text outside Windows-1252 is drawn and can be read back", async () => {
  const lines = [
    "Zażółć gęślą jaźń Łukasz",
    "Привет мир Ελληνικά Việt",
    "契約書 山田太郎 한국어 签名",
  ];
  const pdfDocument = await PDFDocument.create();
  const faces = await embedTextFaces(pdfDocument, lines, {
    bold: true,
    certificate: true,
    signature: true,
  });
  const page = pdfDocument.addPage([612, 400]);

  lines.forEach((line, index) => {
    faces.regular.drawText(page, line, {
      size: 12,
      x: 40,
      y: 340 - index * 30,
    });
    faces.bold.drawText(page, line, { size: 12, x: 40, y: 240 - index * 30 });
  });
  faces.signature.drawText(page, "Łukasz 山田", { size: 24, x: 40, y: 100 });

  const pdfBytes = await pdfDocument.save();
  const text = await extractText(pdfBytes);

  for (const line of lines) {
    assert.ok(text.includes(line), `missing: ${line}`);
  }

  assert.ok(text.includes("Łukasz 山田"));
  // Three subset fonts plus the whole script font: the 14 MB CJK font must
  // not have been embedded whole.
  assert.ok(
    pdfBytes.byteLength < 700_000,
    `PDF is ${String(pdfBytes.byteLength)} bytes`,
  );
});

test("fonts work from a symlinked release working directory", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "signudoc-font-release-"));
  const release = path.join(root, "releases", "release-1");
  const current = path.join(root, "current");
  const project = process.cwd();

  try {
    await mkdir(path.join(release, "src", "assets"), { recursive: true });
    await cp(
      path.join(project, "src", "assets", "fonts"),
      path.join(release, "src", "assets", "fonts"),
      { recursive: true },
    );
    await mkdir(path.join(release, "node_modules", "harfbuzzjs", "dist"), {
      recursive: true,
    });
    await cp(
      path.join(
        project,
        "node_modules",
        "harfbuzzjs",
        "dist",
        "harfbuzz-subset.wasm",
      ),
      path.join(
        release,
        "node_modules",
        "harfbuzzjs",
        "dist",
        "harfbuzz-subset.wasm",
      ),
    );
    await symlink(release, current);
    const result = spawnSync(
      process.execPath,
      [
        "--disable-warning=MODULE_TYPELESS_PACKAGE_JSON",
        "--test",
        "--test-name-pattern=^text outside Windows-1252",
        fileURLToPath(import.meta.url),
      ],
      { cwd: current, encoding: "utf8" },
    );
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("a mixed line is split into runs, one per font", async () => {
  const pdfDocument = await PDFDocument.create();
  const faces = await embedTextFaces(pdfDocument, [
    "Signed by 山田 太郎 today",
  ]);
  const runs = faces.regular.runs("Signed by 山田 太郎 today");

  assert.deepEqual(
    runs.map((run) => run.text),
    ["Signed by ", "山田 太郎 ", "today"],
  );
  assert.equal(runs[0]!.font, runs[2]!.font);
  assert.notEqual(runs[0]!.font, runs[1]!.font);
  assert.ok(faces.regular.widthOfTextAtSize("山田", 10) > 0);
});

test("a character no font has becomes U+FFFD instead of failing", async () => {
  const pdfDocument = await PDFDocument.create();
  const faces = await embedTextFaces(pdfDocument, ["مرحبا שלום 😀 ok"]);
  const page = pdfDocument.addPage([400, 100]);

  assert.doesNotThrow(() => {
    faces.regular.drawText(page, "مرحبا שלום 😀 ok", {
      size: 12,
      x: 10,
      y: 50,
    });
    // Text that was never announced to embedTextFaces is replaced too.
    faces.regular.drawText(page, "山", { size: 12, x: 10, y: 20 });
  });

  const text = await extractText(await pdfDocument.save());

  assert.match(text, /�+ �+ � ok/);
});

test("without a subsetter whole Latin fonts are embedded and CJK is left out", async () => {
  const pdfDocument = await PDFDocument.create();
  const faces = await embedTextFaces(pdfDocument, ["Łukasz 山田"], {
    subset: () => {
      throw new Error("no subsetter");
    },
  });
  const page = pdfDocument.addPage([400, 100]);

  faces.regular.drawText(page, "Łukasz 山田", { size: 12, x: 10, y: 50 });

  const text = await extractText(await pdfDocument.save());

  assert.ok(text.includes("Łukasz"));
  assert.ok(!text.includes("山田"));
});
