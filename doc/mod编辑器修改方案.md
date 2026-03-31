# Mod 数据编辑器优化建议方案

## 1. Schema 严格定义问题

**现状调查：**
通过排查 `data/_schema` 下的各配置文件（如 `buff.schema.json`, `equipment.schema.json`, `gongfa.schema.json` 等），发现几乎所有的 JSON Schema 根级或内部对象级都保留了 `"additionalProperties": true`。
这就导致在 `mod_data_editor` 的 `app.js` (`objectEditor` 函数) 中，UI 构建时如果发现 `additionalProperties` 不是 `false`，就会开放**“新增字段”**的按钮，从而让 Mod 作者可以自行填入未经校验的任意字段。

**修正方案：**
- 修改 `data/**/*.schema.json`，将所有的 `"additionalProperties": true` 改为 `"additionalProperties": false`。
- 如果确实需要一些兼容数据，应定义为显式的冗余对象或配置为具体的类型映射。
- **说明**：我已经编写脚本为您修正了项目中包含这种缺陷的 `schema.json` 文件。现在重新加载编辑器后，“新增字段”的按钮会被自动屏蔽或约束，从而解决“依然保留可以自己填入任意字段”的问题。

## 2. 报错信息未贴近字段的设计

**现状调查：**
当前 `mod_data_editor/app.js` 所有的校验错误等验证问题集中统一在 `renderEditorPanel()` 方法里处理：
```javascript
const issues = validateRequired(state.document, rootSchema, rootSchema);
// ... ...
const box = createNode("div", "validation");
box.textContent = `必填校验提醒（仅提示，不会阻止保存）:\n${issues.join("\n")}`;
el.formTab.appendChild(box);
```
在 `validateRequired` 中，返回的是拼接后的一组报错字符串（例如 `['$root.effects[0] 缺少必填字段']`），没有返回结构化的对象（比如含 path 和 message 的节点信息），进而直接塞到了页面最顶部统一显示的红字中，这就导致了“没有贴近相应字段”的情况。

**修改建议：**
1. **升级 `validateRequired`**：
   不只是校验 `required` 必填，应该顺着 `schema.json` 更进一步的校验，并且把返回值结构化。比如返回 `{ path: "$root.effects[0].op", message: "缺少该必填字段" }`。
2. **改造表单组件的挂载点，展示内联红字**：
   在渲染单个字段（例如 `buildFieldNode` 或 `primitiveInput` 和 `objectEditor`）时，传入目前已经走到的路径 `focusPath` 或者 `path` 的字符索引。比对刚刚校验的返回结果。如果在该节点位置查到了报错状态，则在生成的对应的 `<div class="field">` 的下方包裹区域内动态插入内联报错，例如：`<div class="field-error-text" style="color: red;">缺少该必填字段</div>`。
3. **消除红框堆积与视觉引导改进**：
   在页面顶部可只保留一个全局概览提示（如“当前存在 3 个校验错误”），不再做堆砌渲染。在数组等可折叠的复杂元素标题上若检测到其子级存在 error，也可以给标题加一个 ⚠️ 符号来引导用户展开修改。

## 3. 易用性 (UI / UX) 其他改进建议

除了校验功能和随意增加字段的问题外，以下易用性问题需要着重处理：

1. **强记忆成本与引用选择器（Picker）不足**：
   在填充类似 `buff_id`、`trigger`、`特效名称` 时，现有仅做了个弹窗 `openStaticPicker` 和基础列表，无法感知本地资源（如关联其他已写的 Buff ID），最好能够实现下拉自动补全：当光标焦点对准 ID 引用输入框时，给出一个智能拉取当前其它已完成 JSON 项的防抖搜索（Autocomplete）。
2. **列表的极度冗长与操作**：
   编辑器对于数组条目和深层对象（比如 `skills` 下包含多层子 `effects` 和联动的 `cases` 等）渲染的层级会因为单纯的 `append` 形成无限拉长的长页面。需要为 `arrayEditor` 添加“折叠/展开（Collapse/Expand）”组件与按钮进行多层级的视图控制。
3. **状态回滚与误操作**：
   因为去除了随处自由填写字段并且强制了校验，很容易产生删错配置的情况。可以针对表单模式给 `state.document` 设计一个简单的基于镜像队列（比如最长记录 20 步的历史数组）的全局撤销与重做（Undo/Redo）功能，减少错误修改后的重构成本。
