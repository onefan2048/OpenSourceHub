/**
 * Release 附件识别：扩展名 + 文件名关键词 + Content-Type 组合判断。
 * 注意：识别结果仅表示“可能的平台/类型”，不代表文件一定可安装（confidence 字段表示可信度）。
 */
export type Platform = "macos" | "windows" | "linux" | "ios" | "android" | "cross" | "unknown";
export type Arch = "arm64" | "x64" | "x86" | "universal" | "armv7" | "riscv64" | "unknown";
export type AssetKind = "installer" | "package" | "archive" | "binary" | "metadata" | "other";

export interface AssetInfo {
  platform: Platform;
  arch: Arch;
  fileType: string;
  kind: AssetKind;
  confidence: "high" | "medium" | "low";
}

export const PLATFORM_LABELS: Record<Platform, string> = {
  macos: "macOS",
  windows: "Windows",
  linux: "Linux",
  ios: "iOS",
  android: "Android",
  cross: "跨平台",
  unknown: "其他",
};

export const ARCH_LABELS: Record<Arch, string> = {
  arm64: "ARM64",
  x64: "x64",
  x86: "x86",
  universal: "Universal",
  armv7: "ARMv7",
  riscv64: "RISC-V",
  unknown: "未知架构",
};

export const KIND_LABELS: Record<AssetKind, string> = {
  installer: "安装包",
  package: "软件包",
  archive: "压缩包",
  binary: "二进制",
  metadata: "校验/元数据",
  other: "其他文件",
};

// 多段扩展名优先匹配
const MULTI_EXT = ["tar.gz", "tar.xz", "tar.bz2", "tar.zst", "app.zip", "app.tar.gz", "pkg.tar.zst"];

const METADATA_RE = /\.(sha256|sha256sum|sha512|sha1|md5|sig|asc|pem|crt|minisig|sbom|spdx|intoto\.jsonl|blockmap|json|ya?ml|txt|sum)$/i;
const METADATA_NAME_RE = /(checksums?|sha256sums?|sbom|provenance|latest(-mac|-linux)?\.ya?ml)/i;

export function getFileType(name: string): string {
  const lower = name.toLowerCase();
  for (const e of MULTI_EXT) if (lower.endsWith(`.${e}`)) return e === "app.tar.gz" ? "tar.gz" : e;
  if (lower.endsWith(".tgz")) return "tar.gz";
  const m = lower.match(/\.([a-z0-9]{1,10})$/);
  if (!m) return "binary";
  const ext = m[1];
  if (lower.endsWith(".appimage")) return "AppImage";
  // 版本号形如 tool-v1.2.3 不是扩展名
  if (/^\d+$/.test(ext)) return "binary";
  return ext;
}

const KW: Record<Exclude<Platform, "cross" | "unknown">, RegExp> = {
  macos: /(mac|macos|osx|darwin|apple(?!-?tv))/i,
  windows: /(win(dows)?(32|64)?|\.exe|msvc|mingw)(?![a-z])/i,
  linux: /(linux|ubuntu|debian|fedora|centos|el[789]|musl|gnu|appimage|flatpak|snap)(?![a-z])/i,
  ios: /(ios|iphone|ipados)(?![a-z])/i,
  android: /(android)/i,
};

export function detectArch(name: string): Arch {
  const n = name.toLowerCase();
  if (/universal|univ(?![a-z])|fat(?![a-z])/.test(n)) return "universal";
  if (/(arm64|aarch64|armv8|apple[-_]?silicon|m1)(?![a-z0-9])/.test(n)) return "arm64";
  if (/(x86[-_]64|amd64|x64|win64|64[-_]?bit)(?![a-z0-9])/.test(n)) return "x64";
  if (/(armv7|armhf|armeabi|arm32|armv6)/.test(n)) return "armv7";
  if (/riscv64/.test(n)) return "riscv64";
  if (/(i[3-6]86|x86|win32|ia32|32[-_]?bit|386)(?![a-z0-9])/.test(n)) return "x86";
  return "unknown";
}

function detectPlatformByKeyword(name: string): Platform | null {
  const n = name.replace(/[_.-]/g, " ").toLowerCase();
  // 先判断移动端，避免 "ios" 与 "macos" 互相干扰
  if (KW.android.test(n)) return "android";
  if (/(^|\s)(ios|iphone|ipados)(\s|$)/.test(n)) return "ios";
  if (KW.macos.test(n)) return "macos";
  if (/(^|\s)(win|windows|win32|win64|msvc|mingw|pc)(\s|$)/.test(n) || /windows/.test(n)) return "windows";
  if (KW.linux.test(n)) return "linux";
  return null;
}

export function classifyAsset(name: string, contentType?: string | null): AssetInfo {
  const fileType = getFileType(name);
  const ct = (contentType ?? "").toLowerCase();
  const arch = detectArch(name);
  const kw = detectPlatformByKeyword(name);

  if (METADATA_RE.test(name) || METADATA_NAME_RE.test(name)) {
    // .json / .txt 等可能是普通文件，但在 Release 附件里绝大多数为校验或更新元数据
    return { platform: kw ?? "unknown", arch, fileType, kind: "metadata", confidence: "medium" };
  }

  const r = (platform: Platform, kind: AssetKind, confidence: AssetInfo["confidence"]): AssetInfo => ({ platform, arch, fileType, kind, confidence });

  switch (fileType) {
    case "dmg":
    case "pkg":
      return r("macos", "installer", ct.includes("diskimage") || fileType === "pkg" ? "high" : "high");
    case "app.zip":
      return r("macos", "archive", "high");
    case "app":
      return r("macos", "package", "medium");
    case "exe":
      return r("windows", "installer", ct.includes("msdownload") || ct.includes("dosexec") || ct === "" || ct.includes("octet") ? "high" : "medium");
    case "msi":
    case "msix":
    case "appx":
      return r("windows", "installer", "high");
    case "deb":
    case "rpm":
      return r("linux", "installer", "high");
    case "AppImage":
    case "flatpak":
    case "snap":
      return r("linux", "package", "high");
    case "pkg.tar.zst":
      return r("linux", "package", "high");
    case "ipa":
      return r("ios", "installer", "high");
    case "apk":
      return r("android", "installer", "high");
    case "aab":
      return r("android", "package", "high"); // AAB 需上架商店转换，不能直接安装
    case "jar":
      return r("cross", "package", "medium");
    case "whl":
      return r(kw ?? "cross", "package", "medium");
    case "zip":
    case "7z":
    case "rar":
    case "tar.gz":
    case "tar.xz":
    case "tar.bz2":
    case "tar.zst":
    case "gz":
    case "xz":
    case "bz2":
    case "zst":
      return r(kw ?? "unknown", "archive", kw ? "medium" : "low");
    case "binary":
      if (kw || ct.includes("octet-stream") || ct.includes("executable")) return r(kw ?? "unknown", "binary", kw ? "medium" : "low");
      return r("unknown", "other", "low");
    case "vsix":
      return r("cross", "package", "medium");
    case "nupkg":
      return r("windows", "package", "medium");
    default:
      return r(kw ?? "unknown", "other", "low");
  }
}

/** 统计为“安装包/可下载软件”的附件类型（不含校验文件等元数据） */
export const SOFTWARE_KINDS: AssetKind[] = ["installer", "package", "archive", "binary"];

export function isSoftwareAsset(a: { kind: string }) {
  return (SOFTWARE_KINDS as string[]).includes(a.kind);
}

/** GitHub digest 字段格式："sha256:<hex>"，仅此来源视为可靠校验值 */
export function parseDigest(digest: unknown): string | null {
  if (typeof digest !== "string") return null;
  const m = digest.match(/^sha256:([a-f0-9]{64})$/i);
  return m ? m[1].toLowerCase() : null;
}

export function formatBytes(n: number) {
  if (!n) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(u.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  return `${(n / 1024 ** i).toFixed(i === 0 ? 0 : 1)} ${u[i]}`;
}
