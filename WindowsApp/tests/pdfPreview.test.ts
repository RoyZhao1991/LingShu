import assert from "node:assert/strict";
import test from "node:test";
import { decodePdfDataUri } from "../src/pdf.ts";

test("decodePdfDataUri decodes a PDF data URI", () => {
  const content = "%PDF-1.7\npreview";
  const source = `data:application/pdf;base64,${Buffer.from(content).toString("base64")}`;

  assert.equal(Buffer.from(decodePdfDataUri(source)).toString(), content);
});

test("decodePdfDataUri rejects non-PDF data", () => {
  assert.throws(() => decodePdfDataUri("data:text/plain;base64,SGVsbG8="), /base64 PDF/);
});

test("decodePdfDataUri rejects empty PDF data", () => {
  assert.throws(() => decodePdfDataUri("data:application/pdf;base64,"), /empty/);
});
