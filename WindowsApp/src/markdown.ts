function tableCells(line: string): string[] | undefined {
  const normalized = line.trim().replaceAll("｜", "|");
  if (!normalized.includes("|")) return undefined;

  const cells = normalized.split("|").map((cell) => cell.trim());
  if (cells[0] === "") cells.shift();
  if (cells.at(-1) === "") cells.pop();
  return cells.length >= 2 ? cells : undefined;
}

function isDelimiterRow(cells: string[]): boolean {
  return cells.every((cell) => /^:?-{3,}:?$/.test(cell.replace(/\s+/g, "")));
}

function formatRow(cells: string[]): string {
  return `| ${cells.join(" | ")} |`;
}

function expandCompactRows(line: string): string[] {
  if (!line.includes("||") && !line.includes("｜｜")) return [line];

  const parts = line
    .replaceAll("｜", "|")
    .split(/\s*\|\|\s*/)
    .map((part) => part.trim())
    .filter(Boolean);
  if (parts.length < 3 || !parts.every((part) => tableCells(part))) return [line];
  return parts;
}

export function normalizeMarkdownTables(markdown: string): string {
  const expanded: string[] = [];
  let inFence = false;

  for (const line of markdown.replace(/\r\n?/g, "\n").split("\n")) {
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence;
      expanded.push(line);
    } else {
      expanded.push(...(inFence ? [line] : expandCompactRows(line)));
    }
  }

  const output: string[] = [];
  inFence = false;
  for (let index = 0; index < expanded.length;) {
    const line = expanded[index];
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence;
      output.push(line);
      index += 1;
      continue;
    }

    const first = inFence ? undefined : tableCells(line);
    if (!first) {
      output.push(line);
      index += 1;
      continue;
    }

    const rows: Array<{ raw: string; cells: string[] }> = [];
    let cursor = index;
    while (cursor < expanded.length) {
      const cells = tableCells(expanded[cursor]);
      if (!cells) break;
      rows.push({ raw: expanded[cursor], cells });
      cursor += 1;
    }

    const columnCount = first.length;
    const consistent = rows.every((row) => row.cells.length === columnCount);
    const hasDelimiter = rows.length > 1 && isDelimiterRow(rows[1].cells);
    const looksLikeTable = consistent && (hasDelimiter || rows.length >= 3);
    if (!looksLikeTable) {
      output.push(...rows.map((row) => row.raw));
      index = cursor;
      continue;
    }

    if (output.at(-1)?.trim()) output.push("");
    output.push(formatRow(rows[0].cells));
    if (hasDelimiter) {
      output.push(formatRow(rows[1].cells));
      output.push(...rows.slice(2).map((row) => formatRow(row.cells)));
    } else {
      output.push(formatRow(Array.from({ length: columnCount }, () => "---")));
      output.push(...rows.slice(1).map((row) => formatRow(row.cells)));
    }
    if (expanded[cursor]?.trim()) output.push("");
    index = cursor;
  }

  return output.join("\n");
}
