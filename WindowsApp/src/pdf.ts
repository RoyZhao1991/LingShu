export function decodePdfDataUri(source: string): Uint8Array {
  const comma = source.indexOf(",");
  const header = comma >= 0 ? source.slice(0, comma).toLowerCase() : "";

  if (comma < 0 || !header.startsWith("data:application/pdf") || !header.includes(";base64")) {
    throw new Error("Expected a base64 PDF data URI");
  }

  const encoded = source.slice(comma + 1).replace(/\s/g, "");
  if (!encoded) throw new Error("PDF data is empty");

  const binary = atob(encoded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}
