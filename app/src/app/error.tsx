"use client";
export default function ErrorPage({reset}:{error:Error & {digest?:string};reset:()=>void}){return <div className="card p-8"><h2 className="text-xl font-semibold">暂时无法加载</h2><p className="muted mt-2 text-sm">请检查数据库和服务状态，然后重试。没有安装包的仓库不会导致此错误。</p><button className="btn-primary mt-4" onClick={reset}>重试</button></div>}
