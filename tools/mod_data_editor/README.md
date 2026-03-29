# WXAuto 模组数据编辑器

这是一个基于 HTML 的本地编辑器，用于编辑 `mods/*/data/*/*.json`，并按 `data/*/_schema/*.json` 动态生成表单。

## 功能

- 中文界面。
- 支持 `mods`、`分类`、`文件` 三层选择。
- 按 schema 自动渲染字段（`object`、`array`、`string`、`number`、`integer`、`boolean`、`enum`、`$ref`、`additionalProperties`）。
- 支持数组条目新增/克隆/删除。
- 支持 `JSON 模式` 直接编辑。
- 支持 Mod 元信息编辑（`mod.json`：名称、作者、版本、`load_order` 等）。
- 支持引用选择弹窗（搜索 + 分页）：
  - 功法、装备、单位、Tag、Buff、地形、VFX、Stage、Effect Op。
  - 引用源仅来自“当前 Mod 之前加载顺序的 Mod”（按 `load_order` + `id` 排序）。
- EXE 模式下提供控制窗口：
  - `最小化到托盘`
  - `关闭程序`
  - 托盘菜单可再次 `打开窗口` 或 `退出`

## 启动

在项目根目录运行：

```powershell
python .\tools\mod_data_editor\server.py
```

浏览器打开：

```text
http://127.0.0.1:8765
```

## 自检

```powershell
python .\tools\mod_data_editor\server.py --check
```

## 说明

- 保存路径严格限制在 `mods/<mod>/data/<category>/*.json` 与 `mods/<mod>/mod.json`。
- 本工具为本地编辑器，不应暴露到公网。
- 条件校验（如 schema 的 `if/then`）目前只做基础必填提示，最终建议配合现有测试/校验流程。
