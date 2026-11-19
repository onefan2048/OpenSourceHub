import {formatBytes} from "@/lib/assets";
import {PlatformChip,Chip} from "@/components/ui";
import {Download} from "lucide-react";

type Item={id:number;name:string;platform:string;arch:string;fileType:string;kind:string;confidence:string;size:number;downloadCount:number;downloadUrl:string;sha256:string|null;release:{tagName:string}};
type Filters={q:string;os:string;arch:string;format:string};
export function AssetList({assets,filters,platforms,arches,formats}:{assets:Item[];filters:Filters;platforms:string[];arches:string[];formats:string[]}) {
  return <>
    <form className="grid gap-2 sm:grid-cols-5" method="get">
      <input type="hidden" name="tab" value="downloads"/>
      <input className="input" name="q" defaultValue={filters.q} placeholder="搜索附件名称"/>
      {([["os",filters.os,platforms,"全部平台"],["arch",filters.arch,arches,"全部架构"],["format",filters.format,formats,"全部格式"]] as const).map(([key,value,options,label])=><select key={key} className="input" name={key} defaultValue={value}><option value="">{label}</option>{[...options].sort().map(x=><option key={x} value={x}>{x}</option>)}</select>)}
      <button className="btn-primary" type="submit">筛选</button>
    </form>
    <p className="muted my-3 text-xs">按全部已同步附件筛选；识别结果仅供参考，不保证可安装。</p>
    <div className="space-y-2">{assets.map(a=><div className="card flex flex-wrap items-center gap-3 p-4" key={a.id}><div className="min-w-0 flex-1"><div className="break-all font-medium">{a.name}</div><div className="mt-2 flex flex-wrap items-center gap-1"><PlatformChip platform={a.platform}/><Chip>{a.arch}</Chip><Chip>{a.fileType}</Chip><Chip>{a.release.tagName}</Chip><span className="muted text-xs">{formatBytes(a.size)} · 下载 {a.downloadCount} 次 · 识别可信度 {a.confidence}</span></div>{a.sha256&&<div className="muted mt-1 break-all text-xs">SHA256: {a.sha256}</div>}</div><a className="btn-ghost" href={a.downloadUrl} target="_blank" rel="noreferrer noopener"><Download size={16}/>下载</a></div>)}{!assets.length&&<p className="card muted p-6 text-sm">没有符合条件的附件。没有独立安装包不影响查看版本或源码。</p>}</div>
  </>;
}
