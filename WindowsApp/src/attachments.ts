export interface BrowserDroppedFile {
  name: string;
  path?: string;
  webkitRelativePath?: string;
}

export function mergeAttachmentPaths(current: readonly string[], incoming: readonly string[]): string[] {
  const merged: string[] = [];
  const seen = new Set<string>();

  for (const candidate of [...current, ...incoming]) {
    const path = candidate.trim();
    if (!path) continue;
    const key = attachmentPathKey(path);
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(path);
  }

  return merged;
}

export function browserDroppedFilePaths(files: ArrayLike<BrowserDroppedFile>): string[] {
  return Array.from(files, (file) => file.path?.trim() || file.webkitRelativePath?.trim() || file.name.trim())
    .filter(Boolean);
}

function attachmentPathKey(path: string): string {
  const slashNormalized = path.replace(/\//g, "\\").replace(/\\+/g, "\\");
  const isWindowsPath = /^[a-zA-Z]:\\/.test(slashNormalized) || slashNormalized.startsWith("\\\\");
  return isWindowsPath ? slashNormalized.toLocaleLowerCase("en-US") : path;
}
