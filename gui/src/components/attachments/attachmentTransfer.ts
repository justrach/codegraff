import { classifyPath } from "./attachmentTypes";

const INTERNAL_CHAT_BINDING_MIME = "application/x-codegraff-chat-binding";
const FILE_TRANSFER_TYPES = new Set([
  "Files",
  "text/uri-list",
  "public.file-url",
  "public.url",
]);
const PATH_TEXT_FORMATS = [
  "text/uri-list",
  "public.file-url",
  "public.url",
  "text/plain",
];

export type AttachmentTransferItem =
  | { kind: "path"; path: string }
  | { kind: "file"; file: File };

export interface DataTransferItemLike {
  kind: string;
  type?: string;
  getAsFile?: () => File | null;
}

export interface DataTransferLike {
  files?: ArrayLike<File> | null;
  items?: ArrayLike<DataTransferItemLike> | null;
  types?: ArrayLike<string> | DOMStringList | null;
  getData?: (format: string) => string;
}

function transferTypes(dataTransfer: DataTransferLike | null): string[] {
  const types = dataTransfer?.types;
  if (types == null) {
    return [];
  }

  const result: string[] = [];
  for (let index = 0; index < types.length; index += 1) {
    const value = types[index];
    if (typeof value === "string") {
      result.push(value);
    }
  }
  return result;
}

function hasTransferType(
  dataTransfer: DataTransferLike | null,
  type: string,
): boolean {
  return transferTypes(dataTransfer).includes(type);
}

function getTransferData(
  dataTransfer: DataTransferLike | null,
  format: string,
): string {
  try {
    return dataTransfer?.getData?.(format) ?? "";
  } catch {
    return "";
  }
}

function stripPathQuotes(value: string): string {
  const trimmed = value.trim();
  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1).trim();
  }
  return trimmed;
}

export function normalizeFileTransferPath(value: string): string | null {
  const raw = stripPathQuotes(value);
  if (raw.length === 0) {
    return null;
  }

  if (raw.startsWith("file://")) {
    try {
      const url = new URL(raw);
      if (url.protocol !== "file:") {
        return null;
      }
      const decodedPath = decodeURIComponent(url.pathname);
      if (url.host.length > 0 && url.host !== "localhost") {
        return `//${url.host}${decodedPath}`;
      }
      return decodedPath;
    } catch {
      return null;
    }
  }

  return raw.startsWith("/") ? raw : null;
}

function extractPathsFromText(text: string): string[] {
  const seen = new Set<string>();
  const paths: string[] = [];
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith("#")) {
      continue;
    }
    const path = normalizeFileTransferPath(trimmed);
    if (path != null && !seen.has(path)) {
      seen.add(path);
      paths.push(path);
    }
  }
  return paths;
}

function extractPathItems(
  dataTransfer: DataTransferLike | null,
): AttachmentTransferItem[] {
  const seen = new Set<string>();
  const items: AttachmentTransferItem[] = [];
  for (const format of PATH_TEXT_FORMATS) {
    const text = getTransferData(dataTransfer, format);
    if (text.length === 0) {
      continue;
    }
    for (const path of extractPathsFromText(text)) {
      if (!seen.has(path)) {
        seen.add(path);
        items.push({ kind: "path", path });
      }
    }
  }
  return items;
}

function fileKey(file: File): string {
  return `${file.name}:${file.size}:${file.lastModified}:${file.type}`;
}

function extractFileItems(
  dataTransfer: DataTransferLike | null,
): AttachmentTransferItem[] {
  const files = dataTransfer?.files;
  const items = dataTransfer?.items;
  const seen = new Set<string>();
  const result: AttachmentTransferItem[] = [];

  if (files != null) {
    for (let index = 0; index < files.length; index += 1) {
      const file = files[index];
      if (file == null) {
        continue;
      }
      const key = fileKey(file);
      if (!seen.has(key)) {
        seen.add(key);
        result.push({ kind: "file", file });
      }
    }
  }

  if (items != null) {
    for (let index = 0; index < items.length; index += 1) {
      const item = items[index];
      if (item?.kind !== "file" || item.getAsFile == null) {
        continue;
      }
      const file = item.getAsFile();
      if (file == null) {
        continue;
      }
      const key = fileKey(file);
      if (!seen.has(key)) {
        seen.add(key);
        result.push({ kind: "file", file });
      }
    }
  }

  return result;
}

export function dataTransferHasAttachmentPayload(
  dataTransfer: DataTransferLike | null,
): boolean {
  if (
    dataTransfer == null ||
    hasTransferType(dataTransfer, INTERNAL_CHAT_BINDING_MIME)
  ) {
    return false;
  }

  if ((dataTransfer.files?.length ?? 0) > 0) {
    return true;
  }

  const items = dataTransfer.items;
  if (items != null) {
    for (let index = 0; index < items.length; index += 1) {
      if (items[index]?.kind === "file") {
        return true;
      }
    }
  }

  if (
    transferTypes(dataTransfer).some((type) => FILE_TRANSFER_TYPES.has(type))
  ) {
    return true;
  }

  return extractPathItems(dataTransfer).length > 0;
}

export function extractAttachmentTransferItems(
  dataTransfer: DataTransferLike | null,
): AttachmentTransferItem[] {
  if (
    dataTransfer == null ||
    hasTransferType(dataTransfer, INTERNAL_CHAT_BINDING_MIME)
  ) {
    return [];
  }

  const pathItems = extractPathItems(dataTransfer);
  if (pathItems.length > 0) {
    return pathItems;
  }

  return extractFileItems(dataTransfer);
}

export function getAttachmentTransferFileName(file: File): string {
  const name = file.name.trim();
  if (name.length > 0) {
    return name;
  }

  const ext = extensionFromMimeType(file.type) ?? "txt";
  return `attachment.${ext}`;
}

export function isSupportedAttachmentTransferItem(
  item: AttachmentTransferItem,
): boolean {
  const candidate =
    item.kind === "path" ? item.path : getAttachmentTransferFileName(item.file);
  return classifyPath(candidate) != null;
}

export function filterSupportedAttachmentTransferItems(
  items: AttachmentTransferItem[],
): AttachmentTransferItem[] {
  return items.filter(isSupportedAttachmentTransferItem);
}

function extensionFromMimeType(type: string): string | null {
  switch (type.toLowerCase()) {
    case "image/png":
      return "png";
    case "image/jpeg":
      return "jpg";
    case "image/gif":
      return "gif";
    case "image/webp":
      return "webp";
    case "image/svg+xml":
      return "svg";
    case "image/bmp":
      return "bmp";
    case "image/avif":
      return "avif";
    case "application/pdf":
      return "pdf";
    case "application/json":
      return "json";
    case "text/csv":
      return "csv";
    case "text/html":
      return "html";
    case "text/markdown":
      return "md";
    case "text/plain":
      return "txt";
    default:
      return null;
  }
}
