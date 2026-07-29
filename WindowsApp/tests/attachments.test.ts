import assert from "node:assert/strict";
import test from "node:test";
import { browserDroppedFilePaths, mergeAttachmentPaths } from "../src/attachments.ts";

test("merges picker and drop attachments without replacing existing files", () => {
  assert.deepEqual(
    mergeAttachmentPaths(
      ["C:\\Users\\Roy\\Documents\\brief.docx"],
      ["C:\\Users\\Roy\\Documents\\resume.pdf"],
    ),
    [
      "C:\\Users\\Roy\\Documents\\brief.docx",
      "C:\\Users\\Roy\\Documents\\resume.pdf",
    ],
  );
});

test("deduplicates Windows paths case-insensitively while preserving display spelling", () => {
  assert.deepEqual(
    mergeAttachmentPaths(
      ["C:\\Users\\Roy\\Documents\\Resume.PDF"],
      ["c:/users/roy/documents/resume.pdf", "  C:\\Users\\Roy\\Documents\\notes.md  "],
    ),
    [
      "C:\\Users\\Roy\\Documents\\Resume.PDF",
      "C:\\Users\\Roy\\Documents\\notes.md",
    ],
  );
});

test("retains distinct POSIX paths for local Tauri development", () => {
  assert.deepEqual(
    mergeAttachmentPaths(["/tmp/Report.md"], ["/tmp/report.md"]),
    ["/tmp/Report.md", "/tmp/report.md"],
  );
});

test("extracts native browser file paths and falls back to a visible filename", () => {
  assert.deepEqual(
    browserDroppedFilePaths({
      0: { name: "resume.pdf", path: "C:\\Users\\Roy\\Documents\\resume.pdf" },
      1: { name: "brief.docx" },
      length: 2,
    }),
    ["C:\\Users\\Roy\\Documents\\resume.pdf", "brief.docx"],
  );
});
