import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import rehypeRaw from "rehype-raw";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import rehypeKatex from "rehype-katex";
import "katex/dist/katex.min.css";

// 先解析 HTML，再过滤，最后生成不信任外部命令的 KaTeX。
const schema = {
  ...defaultSchema,
  attributes: {
    ...defaultSchema.attributes,
    "*": [...(defaultSchema.attributes?.["*"] || []), ["align", "left", "center", "right"]],
    img: [...(defaultSchema.attributes?.img || []), ["width", /^\d{1,4}$/], ["height", /^\d{1,4}$/], "srcSet", "sizes"],
    source: [...(defaultSchema.attributes?.source || []), "type", "sizes"],
    code: [...(defaultSchema.attributes?.code || []), ["className", /^language-./, "math-inline", "math-display"]],
  },
  strip: [...(defaultSchema.strip || []), "script", "style", "iframe", "object", "embed"],
};

export function Markdown({ text, baseUrl }: { text: string; baseUrl?: string }) {
  const fix = (url?: string, raw = false) => {
    if (!url || /^(https?:|mailto:|#)/i.test(url) || !baseUrl) return url;
    if (url.startsWith("//")) return `https:${url}`;
    if (/^[a-z][a-z\d+.-]*:/i.test(url)) return undefined;
    const base = raw ? baseUrl.replace("https://github.com/", "https://raw.githubusercontent.com/").replace("/blob/", "/") : baseUrl;
    try { return new URL(url, `${base.replace(/\/$/, "")}/`).toString(); } catch { return undefined; }
  };
  // srcset 可能包含多个 URL 和 1x/2x/640w 描述符。逐项转换并拒绝非 HTTP(S) 协议。
  const fixSrcSet = (input?: string) => {
    if (!input) return undefined;
    const candidates: string[] = [];
    let pos = 0;
    while (pos < input.length) {
      while (pos < input.length && /[\s,]/.test(input[pos])) pos++;
      const start = pos;
      while (pos < input.length && !/\s/.test(input[pos])) pos++;
      let url = input.slice(start, pos);
      if (!url) break;
      let descriptor = "";
      if (url.endsWith(",")) url = url.replace(/,+$/, "");
      else {
        const descStart = pos;
        while (pos < input.length && input[pos] !== ",") pos++;
        descriptor = input.slice(descStart, pos).trim();
        if (pos < input.length) pos++;
      }
      if (descriptor && !/^(?:[1-9]\d*w|(?:\d+(?:\.\d+)?|\.\d+)x)$/.test(descriptor)) continue;
      if (/^[a-z][a-z\d+.-]*:/i.test(url) && !/^https?:\/\//i.test(url)) continue;
      const resolved = fix(url, true);
      if (!resolved || !/^(https?:\/\/|\/|\.|[^:]+$)/i.test(resolved)) continue;
      candidates.push(resolved + (descriptor ? ` ${descriptor}` : ""));
    }
    return candidates.length ? candidates.join(", ") : undefined;
  };
  return <div className="prose-md">
    <ReactMarkdown
      remarkPlugins={[remarkGfm, remarkMath]}
      rehypePlugins={[rehypeRaw, [rehypeSanitize, schema], [rehypeKatex, {trust: false, throwOnError: false}]]}
      components={{
        a: ({ href, children, title }) => <a href={fix(href)} title={title} target="_blank" rel="noreferrer noopener">{children}</a>,
        // eslint-disable-next-line @next/next/no-img-element
        img: ({ src, srcSet, sizes, alt, width, height, title }) => <img src={fix(typeof src === "string" ? src : undefined, true)} srcSet={fixSrcSet(srcSet)} sizes={sizes} alt={alt ?? ""} width={width} height={height} title={title} loading="lazy" />,
        source: ({ srcSet, sizes, media, type }) => <source srcSet={fixSrcSet(srcSet)} sizes={sizes} media={media} type={type} />,
      }}
    >{text}</ReactMarkdown>
  </div>;
}
