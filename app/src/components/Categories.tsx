"use client";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { FolderPlus, Folder, FolderOpen, Pencil, Trash2, X, CornerDownRight } from "lucide-react";

export type CategoryOption = {
  id: number;
  name: string;
  parentId: number | null;
  depth: number;
  path: string;
  ancestorIds?: number[];
  directCount?: number;
  count?: number;
  childrenCount?: number;
};

/** 分类选择值：categoryId 为 "" 表示未分类；creating=true 时在 newParentId 下新建 newName */
export type CategoryValue = { categoryId: string; creating: boolean; newName: string; newParentId: string };

export const emptyCategoryValue = (id?: number | null): CategoryValue => ({
  categoryId: id ? String(id) : "",
  creating: false,
  newName: "",
  newParentId: id ? String(id) : "",
});

/** 转为提交给 API 的字段 */
export function categoryPayload(v: CategoryValue): { newCategory: string; newCategoryParentId: number | null } | { categoryId: number | null } {
  if (v.creating && v.newName.trim()) {
    return { newCategory: v.newName.trim(), newCategoryParentId: v.newParentId ? Number(v.newParentId) : null };
  }
  return { categoryId: v.categoryId ? Number(v.categoryId) : null };
}

/** 生成下拉框中的树形缩进标签 */
export function treeOptionLabel(c: Pick<CategoryOption, "name" | "depth" | "count">, showCount = true) {
  const indent = c.depth > 0 ? `${"　".repeat(c.depth)}└ ` : "";
  const suffix = showCount && c.count !== undefined ? `（${c.count}）` : "";
  return `${indent}${c.name}${suffix}`;
}

async function api(url: string, method: string, body?: unknown) {
  const r = await fetch(url, { method, headers: { "Content-Type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });
  const d = await r.json();
  if (!r.ok) throw Error(d.error || d.message || "操作失败");
  return d;
}

export function useCategories(enabled = true) {
  const [list, setList] = useState<CategoryOption[]>([]);
  const [uncategorized, setUncategorized] = useState(0);
  const reload = async () => {
    try {
      const d = await api("/api/categories", "GET");
      setList(d.categories);
      setUncategorized(d.uncategorized);
    } catch {
      /* ignore */
    }
  };
  useEffect(() => {
    if (enabled) reload();
  }, [enabled]);
  return { list, uncategorized, reload };
}

const NEW = "__new__";

/** 类似浏览器“添加书签”对话框中的多级文件夹选择：可选已有分类，或直接在任意上级分类下新建分类 */
export function CategoryPicker({
  value,
  onChange,
  categories,
  label = "分类",
}: {
  value: CategoryValue;
  onChange: (v: CategoryValue) => void;
  categories: CategoryOption[];
  label?: string;
}) {
  return (
    <div className="text-sm">
      <span className="flex items-center gap-1.5">
        <Folder size={14} />
        {label}
      </span>
      <div className="mt-1 space-y-2">
        <select
          className="input"
          aria-label="选择分类"
          value={value.creating ? NEW : value.categoryId}
          onChange={(e) =>
            e.target.value === NEW
              ? onChange({ ...value, creating: true, newParentId: value.categoryId || value.newParentId })
              : onChange({ categoryId: e.target.value, creating: false, newName: "", newParentId: e.target.value })
          }
        >
          <option value="">未分类</option>
          {categories.map((c) => (
            <option key={c.id} value={String(c.id)}>
              {treeOptionLabel(c)}
            </option>
          ))}
          <option value={NEW}>＋ 新建分类…</option>
        </select>
        {value.creating && (
          <div className="grid gap-2 sm:grid-cols-[1fr_1.4fr]">
            <select
              className="input"
              aria-label="上级分类"
              value={value.newParentId}
              onChange={(e) => onChange({ ...value, newParentId: e.target.value })}
            >
              <option value="">上级：顶级分类</option>
              {categories.map((c) => (
                <option key={c.id} value={String(c.id)}>
                  {`上级：${treeOptionLabel(c, false)}`}
                </option>
              ))}
            </select>
            <input
              className="input"
              autoFocus
              maxLength={80}
              placeholder="名称（可用 / 建多级，如 工具/macOS）"
              value={value.newName}
              onChange={(e) => onChange({ ...value, newName: e.target.value })}
            />
          </div>
        )}
      </div>
    </div>
  );
}

/** 计算不能作为目标父级的 ID 集合（自身及所有后代，防止循环嵌套） */
function forbiddenParents(list: CategoryOption[], id: number): Set<number> {
  const s = new Set<number>([id]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const c of list) {
      if (c.parentId !== null && s.has(c.parentId) && !s.has(c.id)) {
        s.add(c.id);
        changed = true;
      }
    }
  }
  return s;
}

/** 多级分类管理：新建（含子分类）、重命名、移动层级、删除（子分类上移，软件源变为未分类） */
export function CategoryManager() {
  const [open, setOpen] = useState(false);
  const { list, uncategorized, reload } = useCategories(open);
  const [newName, setNewName] = useState("");
  const [newParentId, setNewParentId] = useState("");
  const [editing, setEditing] = useState<{ id: number; name: string; parentId: string } | null>(null);
  const [addingUnder, setAddingUnder] = useState<{ parentId: number; name: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const router = useRouter();

  const forbidden = useMemo(() => (editing ? forbiddenParents(list, editing.id) : new Set<number>()), [list, editing]);

  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    try {
      await fn();
      await reload();
      router.refresh();
    } catch (e) {
      alert((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <button type="button" className="btn-ghost" onClick={() => setOpen(true)}>
        <FolderPlus size={16} />
        管理分类
      </button>
      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" role="dialog" aria-modal="true" aria-label="管理分类">
          <div className="card w-full max-w-xl p-6">
            <div className="flex items-center justify-between">
              <h2 className="text-xl font-bold">管理多级分类</h2>
              <button className="btn-ghost px-2" aria-label="关闭" onClick={() => setOpen(false)}>
                <X size={16} />
              </button>
            </div>
            <p className="muted mt-2 text-sm">
              像浏览器书签文件夹一样支持多级嵌套。可点击文件夹右侧 ＋ 直接新建子分类，或编辑移动已有分类的上级；删除分类时，软件源会变为“未分类”，子分类会自动上移一层。
            </p>
            <form
              className="mt-4 grid gap-2 sm:grid-cols-[1fr_1.4fr_auto]"
              onSubmit={(e) => {
                e.preventDefault();
                if (!newName.trim()) return;
                run(async () => {
                  await api("/api/categories", "POST", {
                    name: newName,
                    parentId: newParentId ? Number(newParentId) : null,
                  });
                  setNewName("");
                });
              }}
            >
              <select className="input" aria-label="新建分类的上级" value={newParentId} onChange={(e) => setNewParentId(e.target.value)}>
                <option value="">顶级分类</option>
                {list.map((c) => (
                  <option key={c.id} value={String(c.id)}>
                    {treeOptionLabel(c, false)}
                  </option>
                ))}
              </select>
              <input
                className="input"
                maxLength={80}
                placeholder="新分类名（支持 / 如 工具/macOS）"
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
              />
              <button className="btn-primary shrink-0" disabled={busy || !newName.trim()}>
                新建
              </button>
            </form>

            <ul className="mt-4 max-h-96 space-y-1 overflow-auto">
              {list.map((c) => (
                <li key={c.id} className="space-y-1">
                  <div
                    className="flex items-center gap-2 rounded-xl px-2 py-1.5 hover:bg-black/5 dark:hover:bg-white/5"
                    style={{ paddingLeft: `${8 + c.depth * 20}px` }}
                  >
                    {c.depth > 0 && <CornerDownRight size={13} className="muted shrink-0" />}
                    {c.childrenCount ? <FolderOpen size={15} className="text-brand-600 shrink-0" /> : <Folder size={15} className="muted shrink-0" />}
                    {editing?.id === c.id ? (
                      <form
                        className="flex flex-1 flex-wrap items-center gap-2"
                        onSubmit={(e) => {
                          e.preventDefault();
                          run(async () => {
                            await api(`/api/categories/${c.id}`, "PATCH", {
                              name: editing.name,
                              parentId: editing.parentId ? Number(editing.parentId) : null,
                            });
                            setEditing(null);
                          });
                        }}
                      >
                        <input
                          className="input min-w-28 flex-1 py-1"
                          autoFocus
                          maxLength={30}
                          value={editing.name}
                          onChange={(e) => setEditing({ ...editing, name: e.target.value })}
                        />
                        <select
                          className="input w-40 py-1"
                          aria-label="移动到上级分类"
                          value={editing.parentId}
                          onChange={(e) => setEditing({ ...editing, parentId: e.target.value })}
                        >
                          <option value="">移至：顶级分类</option>
                          {list
                            .filter((x) => !forbidden.has(x.id))
                            .map((x) => (
                              <option key={x.id} value={String(x.id)}>
                                {`移至：${treeOptionLabel(x, false)}`}
                              </option>
                            ))}
                        </select>
                        <button className="btn-primary py-1" disabled={busy}>
                          保存
                        </button>
                        <button type="button" className="btn-ghost py-1" onClick={() => setEditing(null)}>
                          取消
                        </button>
                      </form>
                    ) : (
                      <>
                        <span className="flex-1 truncate text-sm" title={c.path}>
                          {c.name}
                        </span>
                        <span
                          className="muted shrink-0 text-xs"
                          title={c.childrenCount ? `直属 ${c.directCount ?? 0} 个，含子分类共 ${c.count ?? 0} 个` : undefined}
                        >
                          {c.count ?? 0} 个
                        </span>
                        <button
                          className="btn-ghost px-2 py-1"
                          title={`在「${c.name}」下新建子分类`}
                          aria-label={`在 ${c.name} 下新建子分类`}
                          onClick={() => {
                            setEditing(null);
                            setAddingUnder({ parentId: c.id, name: "" });
                          }}
                        >
                          <FolderPlus size={14} />
                        </button>
                        <button
                          className="btn-ghost px-2 py-1"
                          title={`重命名或移动「${c.name}」`}
                          aria-label={`编辑 ${c.name}`}
                          onClick={() => {
                            setAddingUnder(null);
                            setEditing({ id: c.id, name: c.name, parentId: c.parentId ? String(c.parentId) : "" });
                          }}
                        >
                          <Pencil size={14} />
                        </button>
                        <button
                          className="btn-ghost px-2 py-1 text-red-600"
                          title={`删除「${c.name}」`}
                          aria-label={`删除 ${c.name}`}
                          disabled={busy}
                          onClick={() => {
                            const tip = c.childrenCount
                              ? `删除分类「${c.path}」？直属的 ${c.directCount ?? 0} 个软件源将变为未分类，下属 ${c.childrenCount} 个子分类将上移一层。`
                              : `删除分类「${c.path}」？其中 ${c.count ?? 0} 个软件源将变为未分类。`;
                            if (!confirm(tip)) return;
                            run(() => api(`/api/categories/${c.id}`, "DELETE"));
                          }}
                        >
                          <Trash2 size={14} />
                        </button>
                      </>
                    )}
                  </div>
                  {addingUnder?.parentId === c.id && (
                    <form
                      className="flex items-center gap-2 py-1"
                      style={{ paddingLeft: `${28 + c.depth * 20}px` }}
                      onSubmit={(e) => {
                        e.preventDefault();
                        if (!addingUnder.name.trim()) return;
                        run(async () => {
                          await api("/api/categories", "POST", { name: addingUnder.name, parentId: c.id });
                          setAddingUnder(null);
                        });
                      }}
                    >
                      <CornerDownRight size={13} className="muted shrink-0" />
                      <input
                        className="input flex-1 py-1"
                        autoFocus
                        maxLength={80}
                        placeholder={`在「${c.name}」下新建子分类…`}
                        value={addingUnder.name}
                        onChange={(e) => setAddingUnder({ parentId: c.id, name: e.target.value })}
                      />
                      <button className="btn-primary py-1" disabled={busy || !addingUnder.name.trim()}>
                        创建
                      </button>
                      <button type="button" className="btn-ghost py-1" onClick={() => setAddingUnder(null)}>
                        取消
                      </button>
                    </form>
                  )}
                </li>
              ))}
              {list.length === 0 && <li className="muted px-2 py-3 text-sm">还没有分类，在上方输入名称新建一个吧。</li>}
            </ul>
            <p className="muted mt-3 text-xs">未分类：{uncategorized} 个软件源</p>
          </div>
        </div>
      )}
    </>
  );
}
