#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import mimetypes
import sys
import threading
import webbrowser
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional
from urllib.parse import parse_qs, urlparse


SCRIPT_DIR = Path(__file__).resolve().parent
JSON_INDENT = 2
DEFAULT_PAGE_SIZE = 30
MAX_PAGE_SIZE = 200
KNOWN_TRIGGER_IDS: set[str] = {
    "auto_mp_full",
    "manual",
    "auto_hp_below",
    "on_hp_below",
    "on_time_elapsed",
    "periodic_seconds",
    "passive_aura",
    "on_combat_start",
    "on_attack_hit",
    "on_attacked",
    "on_kill",
    "on_ally_death",
    "on_crit",
    "on_dodge",
    "on_attack_fail",
    "on_shield_broken",
    "on_unit_spawned_mid_battle",
    "on_damage_received",
    "on_heal_received",
    "on_thorns_triggered",
    "on_unit_move_success",
    "on_unit_move_failed",
    "on_terrain_created",
    "on_terrain_enter",
    "on_terrain_tick",
    "on_terrain_exit",
    "on_terrain_expire",
    "on_team_alive_count_changed",
    "on_debuff_applied",
    "on_buff_expired",
    "on_preparation_started",
    "on_stage_combat_started",
    "on_stage_completed",
    "on_stage_failed",
    "on_stage_loaded",
    "on_all_stages_cleared",
}


@dataclass(frozen=True)
class AppContext:
    project_root: Path
    static_root: Path
    mods_root: Path
    data_root: Path


APP_CONTEXT: Optional[AppContext] = None


def _is_frozen() -> bool:
    return bool(getattr(sys, "frozen", False))


def _candidate_roots(base: Path) -> Iterable[Path]:
    current = base.resolve()
    yield current
    for parent in current.parents:
        yield parent


def _looks_like_project_root(path: Path) -> bool:
    return (
        path.exists()
        and path.is_dir()
        and (path / "project.godot").exists()
        and (path / "mods").exists()
        and (path / "data").exists()
    )


def _find_project_root(override: str = "") -> Path:
    if override:
        candidate = Path(override).resolve()
        if _looks_like_project_root(candidate):
            return candidate
        raise ValueError(f"Invalid project_root: {candidate}")

    seeds: List[Path] = [Path.cwd().resolve()]
    if _is_frozen():
        seeds.append(Path(sys.executable).resolve().parent)
    seeds.append(SCRIPT_DIR.resolve())
    seeds.append(SCRIPT_DIR.parent.resolve())
    seeds.append(SCRIPT_DIR.parent.parent.resolve())

    visited: set[str] = set()
    for seed in seeds:
        for candidate in _candidate_roots(seed):
            key = str(candidate)
            if key in visited:
                continue
            visited.add(key)
            if _looks_like_project_root(candidate):
                return candidate

    cwd = Path.cwd().resolve()
    if (cwd / "mods").exists() and (cwd / "data").exists():
        return cwd
    raise ValueError("Project root not found. Use --project-root to specify.")


def _find_static_root() -> Path:
    if _is_frozen():
        meipass = getattr(sys, "_MEIPASS", "")
        if meipass:
            candidate = Path(meipass) / "mod_data_editor_static"
            if candidate.exists():
                return candidate
        exe_dir = Path(sys.executable).resolve().parent
        if (exe_dir / "index.html").exists():
            return exe_dir
    return SCRIPT_DIR


def _build_context(project_root_override: str = "") -> AppContext:
    project_root = _find_project_root(project_root_override)
    static_root = _find_static_root()
    return AppContext(
        project_root=project_root,
        static_root=static_root,
        mods_root=project_root / "mods",
        data_root=project_root / "data",
    )


def _must_context() -> AppContext:
    if APP_CONTEXT is None:
        raise RuntimeError("App context not initialized")
    return APP_CONTEXT


def _normalize_json_newline(text: str) -> str:
    return text.rstrip() + "\n"


def _read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fp:
        return json.load(fp)


def _write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, ensure_ascii=False, indent=JSON_INDENT)
    with path.open("w", encoding="utf-8", newline="\n") as fp:
        fp.write(_normalize_json_newline(text))


def _validate_segment(value: str, field: str) -> str:
    if not value:
        raise ValueError(f"{field} is empty")
    if "/" in value or "\\" in value or ".." in value:
        raise ValueError(f"Invalid {field}: {value!r}")
    return value


def _validate_json_filename(value: str) -> str:
    value = _validate_segment(value, "file")
    if not value.lower().endswith(".json"):
        raise ValueError("Only .json files are supported")
    return value


def _safe_document_path(mod: str, category: str, file_name: str) -> Path:
    ctx = _must_context()
    mod = _validate_segment(mod, "mod")
    category = _validate_segment(category, "category")
    file_name = _validate_json_filename(file_name)
    root = (ctx.mods_root / mod / "data" / category).resolve()
    doc_path = (root / file_name).resolve()
    if not str(doc_path).startswith(str(root)):
        raise ValueError("Document path is out of target root")
    return doc_path


def _safe_manifest_path(mod: str) -> Path:
    ctx = _must_context()
    mod = _validate_segment(mod, "mod")
    root = (ctx.mods_root / mod).resolve()
    manifest = (root / "mod.json").resolve()
    if not str(manifest).startswith(str(root)):
        raise ValueError("Manifest path is out of target root")
    return manifest


def _safe_schema_path(category: str) -> Path:
    ctx = _must_context()
    category = _validate_segment(category, "category")
    schema_dir = ctx.data_root / category / "_schema"
    if not schema_dir.exists() or not schema_dir.is_dir():
        raise FileNotFoundError(f"Schema directory not found: data/{category}/_schema")
    schema_files = sorted(schema_dir.glob("*.json"))
    if not schema_files:
        raise FileNotFoundError(f"Schema file not found: data/{category}/_schema/*.json")
    return schema_files[0]


def _normalize_mod_manifest(raw: Dict[str, Any], folder_name: str, manifest_path: Path) -> Dict[str, Any]:
    mod_id = str(raw.get("id", folder_name)).strip() or folder_name
    return {
        "folder": folder_name,
        "id": mod_id,
        "name": str(raw.get("name", mod_id)),
        "author": str(raw.get("author", "")),
        "version": str(raw.get("version", "")),
        "description": str(raw.get("description", "")),
        "game_version_min": str(raw.get("game_version_min", "")),
        "load_order": int(raw.get("load_order", 0)),
        "manifest_file": str(manifest_path.relative_to(_must_context().project_root)).replace("\\", "/"),
    }


def _discover_mods() -> List[Dict[str, Any]]:
    ctx = _must_context()
    mods: List[Dict[str, Any]] = []
    if not ctx.mods_root.exists():
        return mods

    for mod_dir in sorted(ctx.mods_root.iterdir(), key=lambda p: p.name.lower()):
        if not mod_dir.is_dir():
            continue
        manifest_path = mod_dir / "mod.json"
        if not manifest_path.exists():
            continue
        try:
            manifest = _read_json(manifest_path)
            if isinstance(manifest, dict):
                mods.append(_normalize_mod_manifest(manifest, mod_dir.name, manifest_path))
        except Exception:
            continue

    mods.sort(key=lambda m: (int(m.get("load_order", 0)), str(m.get("id", ""))))
    return mods


def _discover_categories() -> List[Dict[str, Any]]:
    ctx = _must_context()
    categories: List[Dict[str, Any]] = []
    if not ctx.data_root.exists():
        return categories

    for category_dir in sorted(ctx.data_root.iterdir(), key=lambda p: p.name.lower()):
        if not category_dir.is_dir():
            continue
        schema_dir = category_dir / "_schema"
        if not schema_dir.exists() or not schema_dir.is_dir():
            continue
        schema_files = sorted(schema_dir.glob("*.json"))
        if not schema_files:
            continue
        schema_path = schema_files[0]
        try:
            schema = _read_json(schema_path)
            title = str(schema.get("title", category_dir.name)) if isinstance(schema, dict) else category_dir.name
        except Exception:
            title = category_dir.name
        categories.append(
            {
                "id": category_dir.name,
                "title": title,
                "schema_file": str(schema_path.relative_to(ctx.project_root)).replace("\\", "/"),
            }
        )
    return categories


def _list_data_files(mod: str, category: str) -> List[str]:
    ctx = _must_context()
    mod = _validate_segment(mod, "mod")
    category = _validate_segment(category, "category")
    target = ctx.mods_root / mod / "data" / category
    if not target.exists() or not target.is_dir():
        return []
    return sorted([x.name for x in target.glob("*.json") if x.is_file()], key=str.lower)


def _mods_before_current(current_mod: str) -> List[Dict[str, Any]]:
    mods = _discover_mods()
    idx = -1
    for i, mod in enumerate(mods):
        if mod.get("folder") == current_mod:
            idx = i
            break
    if idx <= 0:
        return []
    return mods[:idx]


def _mods_before_and_self(current_mod: str) -> List[Dict[str, Any]]:
    mods = _discover_mods()
    idx = -1
    for i, mod in enumerate(mods):
        if mod.get("folder") == current_mod:
            idx = i
            break
    if idx < 0:
        return []
    return mods[: idx + 1]


def _extract_id_name_items_from_document(
    document: Any, mod_folder: str, load_order: int, file_name: str
) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []

    def add_row(item_id: str, item_name: str) -> None:
        item_id = str(item_id).strip()
        if not item_id:
            return
        rows.append(
            {
                "id": item_id,
                "name": str(item_name).strip(),
                "mod": mod_folder,
                "load_order": int(load_order),
                "file": file_name,
            }
        )

    if isinstance(document, list):
        for row in document:
            if isinstance(row, dict) and isinstance(row.get("id", None), str):
                add_row(row.get("id", ""), row.get("name", ""))
        return rows

    if isinstance(document, dict):
        if isinstance(document.get("id", None), str):
            add_row(document.get("id", ""), document.get("name", ""))
        chapters = document.get("chapters")
        if isinstance(chapters, list):
            for chapter in chapters:
                if not isinstance(chapter, dict):
                    continue
                chapter_name = str(chapter.get("name", chapter.get("chapter", "")))
                stages = chapter.get("stages")
                if isinstance(stages, list):
                    for sid in stages:
                        if isinstance(sid, str):
                            add_row(sid, chapter_name)
    return rows


def _walk_effect_ops(value: Any, out: set[str], labels: Optional[Dict[str, str]] = None) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "op" and isinstance(child, str):
                op = child.strip()
                if op:
                    out.add(op)
            elif key == "effect_op_labels" and isinstance(child, dict):
                for op_key, op_label in child.items():
                    op = str(op_key).strip()
                    if not op:
                        continue
                    out.add(op)
                    if labels is not None and isinstance(op_label, str) and op_label.strip():
                        labels[op.lower()] = op_label.strip()
            _walk_effect_ops(child, out, labels)
        return
    if isinstance(value, list):
        for item in value:
            _walk_effect_ops(item, out, labels)


def _walk_effect_param_keys(value: Any, target_op: str, out: set[str]) -> None:
    if isinstance(value, dict):
        op_value = value.get("op", None)
        if isinstance(op_value, str) and op_value.strip() == target_op:
            for key in value.keys():
                key_text = str(key).strip()
                if key_text and key_text != "op":
                    out.add(key_text)
        for child in value.values():
            _walk_effect_param_keys(child, target_op, out)
        return
    if isinstance(value, list):
        for item in value:
            _walk_effect_param_keys(item, target_op, out)


def _build_effect_param_rows(current_mod: str, target_op: str, scope: str = "before_and_self") -> List[Dict[str, Any]]:
    ctx = _must_context()
    op = target_op.strip()
    if not op:
        return []

    if scope == "before":
        prior_mods = _mods_before_current(current_mod)
    else:
        prior_mods = _mods_before_and_self(current_mod)

    dedupe: Dict[str, Dict[str, Any]] = {}
    for mod in prior_mods:
        mod_folder = str(mod.get("folder", ""))
        load_order = int(mod.get("load_order", 0))
        data_root = ctx.mods_root / mod_folder / "data"
        if not data_root.exists():
            continue
        param_set: set[str] = set()
        for file_path in data_root.rglob("*.json"):
            try:
                parsed = _read_json(file_path)
            except Exception:
                continue
            _walk_effect_param_keys(parsed, op, param_set)
        for key in sorted(param_set):
            dedupe_key = key.lower()
            if dedupe_key in dedupe:
                continue
            dedupe[dedupe_key] = {
                "id": key,
                "name": "effect 参数",
                "mod": mod_folder,
                "load_order": load_order,
                "file": "*",
            }

    rows = list(dedupe.values())
    rows.sort(key=lambda x: str(x.get("id", "")).lower())
    return rows


def _is_probable_trigger_id(value: str) -> bool:
    text = value.strip()
    if not text:
        return False
    return text in KNOWN_TRIGGER_IDS


def _walk_triggers(
    value: Any,
    out: set[str],
    labels: Optional[Dict[str, str]] = None,
    parent_key: str = "",
) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "trigger" and isinstance(child, str):
                trigger_id = child.strip()
                if _is_probable_trigger_id(trigger_id):
                    out.add(trigger_id)
            elif key == "type" and parent_key == "trigger" and isinstance(child, str):
                trigger_id = child.strip()
                if _is_probable_trigger_id(trigger_id):
                    out.add(trigger_id)
            elif key == "trigger_labels" and isinstance(child, dict):
                for trigger_key, trigger_label in child.items():
                    trigger_id = str(trigger_key).strip()
                    if not _is_probable_trigger_id(trigger_id):
                        continue
                    out.add(trigger_id)
                    if labels is not None and isinstance(trigger_label, str) and trigger_label.strip():
                        labels[trigger_id.lower()] = trigger_label.strip()
            _walk_triggers(child, out, labels, key)
        return
    if isinstance(value, list):
        for item in value:
            _walk_triggers(item, out, labels, parent_key)


def _collect_doc_trigger_ids() -> set[str]:
    ctx = _must_context()
    manual_path = ctx.project_root / "doc" / "模组触发器与特效手册.md"
    if not manual_path.exists():
        return set()
    try:
        content = manual_path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return set()

    tokens = re.findall(r"`([a-z0-9_]+)`", content)
    output: set[str] = set()
    for token in tokens:
        if _is_probable_trigger_id(token):
            output.add(token)
    return output


def _build_reference_rows(current_mod: str, kind: str, scope: str = "before_and_self") -> List[Dict[str, Any]]:
    ctx = _must_context()
    if scope == "before":
        prior_mods = _mods_before_current(current_mod)
    else:
        prior_mods = _mods_before_and_self(current_mod)
    rows: List[Dict[str, Any]] = []
    dedupe: Dict[str, Dict[str, Any]] = {}

    if kind == "effect_op":
        for mod in prior_mods:
            mod_folder = str(mod.get("folder", ""))
            load_order = int(mod.get("load_order", 0))
            data_root = ctx.mods_root / mod_folder / "data"
            if not data_root.exists():
                continue
            op_set: set[str] = set()
            op_labels: Dict[str, str] = {}
            for file_path in data_root.rglob("*.json"):
                try:
                    parsed = _read_json(file_path)
                except Exception:
                    continue
                _walk_effect_ops(parsed, op_set, op_labels)
            for op in sorted(op_set):
                key = op.lower()
                if key in dedupe:
                    continue
                dedupe[key] = {
                    "id": op,
                    "name": op_labels.get(key, op),
                    "mod": mod_folder,
                    "load_order": load_order,
                    "file": "*",
                }
        rows = list(dedupe.values())
        rows.sort(key=lambda x: str(x.get("id", "")).lower())
        return rows

    if kind == "trigger":
        label_map: Dict[str, str] = {}

        for mod in prior_mods:
            mod_folder = str(mod.get("folder", ""))
            load_order = int(mod.get("load_order", 0))
            data_root = ctx.mods_root / mod_folder / "data"
            if not data_root.exists():
                continue
            trigger_set: set[str] = set()
            for file_path in data_root.rglob("*.json"):
                try:
                    parsed = _read_json(file_path)
                except Exception:
                    continue
                _walk_triggers(parsed, trigger_set, label_map)

            for trigger_id in sorted(trigger_set):
                key = trigger_id.lower()
                if key in dedupe:
                    continue
                dedupe[key] = {
                    "id": trigger_id,
                    "name": label_map.get(key, trigger_id),
                    "mod": mod_folder,
                    "load_order": load_order,
                    "file": "*",
                }

        external_triggers: set[str] = set()
        external_triggers.update(KNOWN_TRIGGER_IDS)
        for trigger_id in sorted(external_triggers):
            key = trigger_id.lower()
            if key in dedupe:
                continue
            dedupe[key] = {
                "id": trigger_id,
                "name": label_map.get(key, trigger_id),
                "mod": "builtin",
                "load_order": -1,
                "file": "doc+scripts",
            }

        rows = list(dedupe.values())
        rows.sort(key=lambda x: str(x.get("id", "")).lower())
        return rows

    category = _validate_segment(kind, "kind")
    for mod in prior_mods:
        mod_folder = str(mod.get("folder", ""))
        load_order = int(mod.get("load_order", 0))
        category_dir = ctx.mods_root / mod_folder / "data" / category
        if not category_dir.exists() or not category_dir.is_dir():
            continue

        for file_path in sorted(category_dir.glob("*.json"), key=lambda p: p.name.lower()):
            try:
                parsed = _read_json(file_path)
            except Exception:
                continue
            for row in _extract_id_name_items_from_document(parsed, mod_folder, load_order, file_path.name):
                key = str(row.get("id", "")).lower()
                if key in dedupe:
                    continue
                dedupe[key] = row

    rows = list(dedupe.values())
    rows.sort(key=lambda x: str(x.get("id", "")).lower())
    return rows


def _filter_and_paginate(rows: List[Dict[str, Any]], q: str, page: int, page_size: int) -> Dict[str, Any]:
    q_lower = q.strip().lower()
    if q_lower:
        rows = [
            row
            for row in rows
            if q_lower in str(row.get("id", "")).lower()
            or q_lower in str(row.get("name", "")).lower()
            or q_lower in str(row.get("mod", "")).lower()
            or q_lower in str(row.get("file", "")).lower()
        ]

    total = len(rows)
    page = max(1, page)
    page_size = max(1, min(MAX_PAGE_SIZE, page_size))
    start = (page - 1) * page_size
    end = start + page_size
    return {
        "total": total,
        "page": page,
        "page_size": page_size,
        "items": rows[start:end],
    }


def _manifest_payload(mod_folder: str) -> Dict[str, Any]:
    path = _safe_manifest_path(mod_folder)
    if not path.exists():
        raise FileNotFoundError(f"mod.json not found: {path}")
    manifest = _read_json(path)
    if not isinstance(manifest, dict):
        raise ValueError(f"Invalid mod.json: {path}")
    return {
        "ok": True,
        "mod": mod_folder,
        "manifest_file": str(path.relative_to(_must_context().project_root)).replace("\\", "/"),
        "manifest": manifest,
    }


class ModDataEditorHandler(BaseHTTPRequestHandler):
    server_version = "WXAutoModDataEditor/2.0"

    def _send_json(self, payload: Dict[str, Any], status: int = HTTPStatus.OK) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, message: str, status: int = HTTPStatus.BAD_REQUEST) -> None:
        self._send_json({"ok": False, "error": message}, status=status)

    def _serve_static(self, route: str) -> None:
        ctx = _must_context()
        rel = "index.html" if route in ("", "/") else route.lstrip("/")
        path = (ctx.static_root / rel).resolve()
        if not str(path).startswith(str(ctx.static_root.resolve())):
            self._send_error("Static path denied", status=HTTPStatus.FORBIDDEN)
            return
        if not path.exists() or not path.is_file():
            self._send_error("Not found", status=HTTPStatus.NOT_FOUND)
            return
        mime, _ = mimetypes.guess_type(str(path))
        body = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", (mime or "application/octet-stream") + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        route = parsed.path
        params = parse_qs(parsed.query)

        try:
            if route == "/api/bootstrap":
                categories = _discover_categories()
                self._send_json(
                    {
                        "ok": True,
                        "project_root": str(_must_context().project_root),
                        "mods": _discover_mods(),
                        "categories": categories,
                        "reference_kinds": [c["id"] for c in categories] + ["effect_op", "trigger"],
                    }
                )
                return

            if route == "/api/files":
                mod = params.get("mod", [""])[0]
                category = params.get("category", [""])[0]
                self._send_json({"ok": True, "mod": mod, "category": category, "files": _list_data_files(mod, category)})
                return

            if route == "/api/schema":
                category = params.get("category", [""])[0]
                schema_path = _safe_schema_path(category)
                schema = _read_json(schema_path)
                self._send_json(
                    {
                        "ok": True,
                        "category": category,
                        "schema_file": str(schema_path.relative_to(_must_context().project_root)).replace("\\", "/"),
                        "schema": schema,
                    }
                )
                return

            if route == "/api/document":
                mod = params.get("mod", [""])[0]
                category = params.get("category", [""])[0]
                file_name = params.get("file", [""])[0]
                doc_path = _safe_document_path(mod, category, file_name)
                if not doc_path.exists():
                    self._send_error(f"Document not found: {doc_path}", status=HTTPStatus.NOT_FOUND)
                    return
                document = _read_json(doc_path)
                self._send_json(
                    {
                        "ok": True,
                        "mod": mod,
                        "category": category,
                        "file": file_name,
                        "document_file": str(doc_path.relative_to(_must_context().project_root)).replace("\\", "/"),
                        "document": document,
                    }
                )
                return

            if route == "/api/mod_manifest":
                mod = params.get("mod", [""])[0]
                self._send_json(_manifest_payload(mod))
                return

            if route == "/api/effect_params":
                mod = params.get("mod", [""])[0]
                op = params.get("op", [""])[0]
                scope = params.get("scope", ["before_and_self"])[0]
                page = int(params.get("page", ["1"])[0])
                page_size = int(params.get("page_size", [str(DEFAULT_PAGE_SIZE)])[0])
                q = params.get("q", [""])[0]
                if scope not in ("before", "before_and_self"):
                    self._send_error(f"Unknown scope: {scope}", status=HTTPStatus.BAD_REQUEST)
                    return
                if not str(op).strip():
                    self._send_error("Missing op", status=HTTPStatus.BAD_REQUEST)
                    return

                rows = _build_effect_param_rows(mod, str(op), scope)
                result = _filter_and_paginate(rows, q, page, page_size)
                self._send_json(
                    {
                        "ok": True,
                        "mod": mod,
                        "op": op,
                        "scope": scope,
                        "total": result["total"],
                        "page": result["page"],
                        "page_size": result["page_size"],
                        "items": result["items"],
                    }
                )
                return

            if route == "/api/references":
                mod = params.get("mod", [""])[0]
                kind = params.get("kind", [""])[0]
                scope = params.get("scope", ["before_and_self"])[0]
                page = int(params.get("page", ["1"])[0])
                page_size = int(params.get("page_size", [str(DEFAULT_PAGE_SIZE)])[0])
                q = params.get("q", [""])[0]
                if scope not in ("before", "before_and_self"):
                    self._send_error(f"Unknown scope: {scope}", status=HTTPStatus.BAD_REQUEST)
                    return

                categories = {c["id"] for c in _discover_categories()}
                if kind not in ("effect_op", "trigger") and kind not in categories:
                    self._send_error(f"Unknown kind: {kind}", status=HTTPStatus.BAD_REQUEST)
                    return

                rows = _build_reference_rows(mod, kind, scope)
                result = _filter_and_paginate(rows, q, page, page_size)
                self._send_json(
                    {
                        "ok": True,
                        "mod": mod,
                        "kind": kind,
                        "scope": scope,
                        "total": result["total"],
                        "page": result["page"],
                        "page_size": result["page_size"],
                        "items": result["items"],
                    }
                )
                return

            self._serve_static(route)
        except FileNotFoundError as exc:
            self._send_error(str(exc), status=HTTPStatus.NOT_FOUND)
        except ValueError as exc:
            self._send_error(str(exc), status=HTTPStatus.BAD_REQUEST)
        except json.JSONDecodeError as exc:
            self._send_error(f"JSON parse error: {exc}", status=HTTPStatus.BAD_REQUEST)
        except Exception as exc:  # pragma: no cover
            self._send_error(f"Internal error: {exc}", status=HTTPStatus.INTERNAL_SERVER_ERROR)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        route = parsed.path

        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8")
            payload = json.loads(raw) if raw else {}

            if route == "/api/document":
                mod = str(payload.get("mod", ""))
                category = str(payload.get("category", ""))
                file_name = str(payload.get("file", ""))
                document = payload.get("document", None)
                path = _safe_document_path(mod, category, file_name)
                _write_json(path, document)
                self._send_json(
                    {
                        "ok": True,
                        "saved": True,
                        "path": str(path.relative_to(_must_context().project_root)).replace("\\", "/"),
                    }
                )
                return

            if route == "/api/mod_manifest":
                mod = str(payload.get("mod", ""))
                manifest = payload.get("manifest", None)
                if not isinstance(manifest, dict):
                    raise ValueError("manifest must be object")
                path = _safe_manifest_path(mod)
                _write_json(path, manifest)
                self._send_json(
                    {
                        "ok": True,
                        "saved": True,
                        "path": str(path.relative_to(_must_context().project_root)).replace("\\", "/"),
                    }
                )
                return

            self._send_error("Not found", status=HTTPStatus.NOT_FOUND)
        except ValueError as exc:
            self._send_error(str(exc), status=HTTPStatus.BAD_REQUEST)
        except json.JSONDecodeError as exc:
            self._send_error(f"JSON parse error: {exc}", status=HTTPStatus.BAD_REQUEST)
        except Exception as exc:  # pragma: no cover
            self._send_error(f"Internal error: {exc}", status=HTTPStatus.INTERNAL_SERVER_ERROR)

    def log_message(self, format: str, *args: Any) -> None:
        return


def _self_check() -> int:
    mods = _discover_mods()
    categories = _discover_categories()
    print(f"project_root: {_must_context().project_root}")
    print(f"static_root: {_must_context().static_root}")
    print(f"mods: {len(mods)}")
    for mod in mods:
        print(f"- {mod['folder']} load_order={mod['load_order']} name={mod['name']}")
    print(f"categories: {len(categories)}")
    for c in categories:
        print(f"- {c['id']}: {c['schema_file']}")
    return 0


def _open_browser_later(url: str) -> None:
    def _run() -> None:
        try:
            webbrowser.open(url)
        except Exception:
            pass

    timer = threading.Timer(0.8, _run)
    timer.daemon = True
    timer.start()


def _default_open_browser() -> bool:
    return _is_frozen()


def _default_window_mode() -> bool:
    return _is_frozen()


class DesktopControlWindow:
    def __init__(self, url: str, on_exit: Callable[[], None]) -> None:
        import tkinter as tk

        self.url = url
        self.on_exit = on_exit
        self.tk = tk
        self.root = tk.Tk()
        self.root.title("WXAuto Mod Data Editor")
        self.root.geometry("420x180")
        self.root.resizable(False, False)
        self.root.protocol("WM_DELETE_WINDOW", self.close_app)

        self.tray_icon = None
        self.pystray = None

        frame = tk.Frame(self.root, padx=16, pady=14)
        frame.pack(fill=tk.BOTH, expand=True)

        title = tk.Label(frame, text="WXAuto Mod Data Editor 已启动", font=("Segoe UI", 11, "bold"))
        title.pack(anchor=tk.W)

        url_label = tk.Label(frame, text=url, fg="#0b66da", cursor="hand2")
        url_label.pack(anchor=tk.W, pady=(6, 12))
        url_label.bind("<Button-1>", lambda _ev: webbrowser.open(self.url))

        btn_row = tk.Frame(frame)
        btn_row.pack(fill=tk.X)

        open_btn = tk.Button(btn_row, text="打开编辑器", command=lambda: webbrowser.open(self.url))
        open_btn.pack(side=tk.LEFT)

        tray_btn = tk.Button(btn_row, text="最小化到托盘", command=self.minimize_to_tray)
        tray_btn.pack(side=tk.LEFT, padx=(8, 0))

        close_btn = tk.Button(btn_row, text="关闭程序", command=self.close_app)
        close_btn.pack(side=tk.RIGHT)

        hint = tk.Label(
            frame,
            text="提示：最小化到托盘后，可在托盘图标菜单中选择“打开窗口”恢复。",
            fg="#5a6980",
            justify=tk.LEFT,
        )
        hint.pack(anchor=tk.W, pady=(14, 0))

    def _make_tray_image(self):
        from PIL import Image, ImageDraw

        image = Image.new("RGBA", (64, 64), (11, 102, 218, 255))
        draw = ImageDraw.Draw(image)
        draw.rectangle((10, 10, 54, 54), fill=(255, 255, 255, 255))
        draw.rectangle((16, 16, 48, 48), fill=(11, 102, 218, 255))
        return image

    def _ensure_tray_icon(self) -> bool:
        if self.tray_icon is not None:
            return True
        try:
            import pystray
        except Exception:
            return False

        self.pystray = pystray
        image = self._make_tray_image()

        def _invoke_on_tk(action: Callable[[], None]) -> None:
            self.root.after(0, action)

        menu = pystray.Menu(
            pystray.MenuItem("打开窗口", lambda _icon, _item: _invoke_on_tk(self.restore_from_tray)),
            pystray.MenuItem("打开编辑器", lambda _icon, _item: _invoke_on_tk(lambda: webbrowser.open(self.url))),
            pystray.MenuItem("退出", lambda _icon, _item: _invoke_on_tk(self.close_app)),
        )
        self.tray_icon = pystray.Icon("WXAutoModDataEditor", image, "WXAuto Mod Data Editor", menu)
        self.tray_icon.run_detached()
        return True

    def _stop_tray_icon(self) -> None:
        if self.tray_icon is None:
            return
        icon = self.tray_icon
        self.tray_icon = None
        try:
            icon.stop()
        except Exception:
            pass

    def minimize_to_tray(self) -> None:
        if self._ensure_tray_icon():
            self.root.withdraw()
        else:
            self.root.iconify()

    def restore_from_tray(self) -> None:
        self.root.deiconify()
        self.root.lift()
        self.root.focus_force()

    def close_app(self) -> None:
        self._stop_tray_icon()
        try:
            self.on_exit()
        finally:
            try:
                self.root.destroy()
            except Exception:
                pass

    def run(self) -> None:
        self.root.mainloop()


def _run_with_control_window(server: ThreadingHTTPServer, url: str, open_browser: bool) -> int:
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    if open_browser:
        _open_browser_later(url)

    stopped = False

    def _shutdown_server() -> None:
        nonlocal stopped
        if stopped:
            return
        stopped = True
        try:
            server.shutdown()
        except Exception:
            pass
        try:
            server.server_close()
        except Exception:
            pass

    try:
        window = DesktopControlWindow(url, _shutdown_server)
        window.run()
    finally:
        _shutdown_server()
        server_thread.join(timeout=2.0)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="WXAuto Mod Data Editor Server")
    parser.add_argument("--host", default="127.0.0.1", help="bind host")
    parser.add_argument("--port", type=int, default=8765, help="bind port")
    parser.add_argument("--project-root", default="", help="project root path")
    parser.add_argument("--check", action="store_true", help="run self-check and exit")
    parser.add_argument("--open-browser", dest="open_browser", action="store_true", help="open browser after start")
    parser.add_argument("--no-open-browser", dest="open_browser", action="store_false", help="do not open browser")
    parser.add_argument("--window-mode", dest="window_mode", action="store_true", help="run with desktop control window")
    parser.add_argument("--no-window-mode", dest="window_mode", action="store_false", help="run without desktop window")
    parser.set_defaults(open_browser=_default_open_browser())
    parser.set_defaults(window_mode=_default_window_mode())
    args = parser.parse_args()

    global APP_CONTEXT
    APP_CONTEXT = _build_context(args.project_root)

    if args.check:
        return _self_check()

    server = ThreadingHTTPServer((args.host, args.port), ModDataEditorHandler)
    url = f"http://{args.host}:{args.port}"
    print(f"WXAuto Mod Data Editor started: {url}")
    print(f"project root: {_must_context().project_root}")

    if args.window_mode:
        try:
            return _run_with_control_window(server, url, args.open_browser)
        except KeyboardInterrupt:
            return 0

    if args.open_browser:
        _open_browser_later(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
