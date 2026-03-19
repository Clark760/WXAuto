# UI 三项 Bug 修复方案（面向代码 AI）

---

## Bug 1：功法详情悬浮框一闪即关

### 现象

在角色详情面板中，鼠标移到功法名称上时，ItemTooltip 只显示一瞬间就自动关闭。

### 根本原因：三个问题叠加

**问题 A — 触发热区太小**：悬浮检测绑定在功法 **Label 文字**上，Label 的实际像素区域只有文字本身那么大。鼠标稍微偏移到文字上方/下方的空白区域就判定为"离开"，触发消失。

**问题 B — 热区与 Tooltip 之间有间隙**：鼠标从功法名称移向 ItemTooltip 面板时，中间有几像素的空白区域，经过这段间隙鼠标既不在 Label 上也不在 Tooltip 上，会被判定为"离开"。

**问题 C — UnitTooltip 干扰**：如果 UnitDetailPanel 打开后 UnitTooltip 的 `_hover_unit` 变为 null，可能连带触发了全局 Tooltip 关闭逻辑。

### 修复方案

#### 修复 A — 用整行容器作为热区，不要用 Label 文字

```
当前错误结构（只有文字区域可触发）：
GongfaSlotRow (HBoxContainer)
├── SlotIcon (TextureRect)           ← 不触发
├── GongfaNameLabel (Label)          ← 只有文字像素触发，太小
└── SwapButton (Button)              ← 不触发

正确结构（整行都是热区）：
GongfaSlotRow (PanelContainer)       ← ★ 整行作为悬浮检测热区
├── HBox (HBoxContainer)
│   ├── SlotIcon (TextureRect)
│   ├── GongfaNameLabel (Label)
│   └── SwapButton (Button)
└── mouse_filter = MOUSE_FILTER_PASS ← 确保能接收鼠标事件
```

```gdscript
# GongfaSlotRow 应该是一个 PanelContainer 或 Button（flat 样式）
# 整行尺寸固定，如 width=整列宽度, height=32px
# 悬浮检测绑定到整个 GongfaSlotRow，而非内部的 Label

func _ready() -> void:
    for slot_row in gongfa_slot_rows:
        slot_row.mouse_entered.connect(_on_slot_row_hovered.bind(slot_row))
        slot_row.mouse_exited.connect(_on_slot_row_unhovered.bind(slot_row))

func _on_slot_row_hovered(slot_row: Control) -> void:
    var gongfa_id: String = slot_row.get_meta("gongfa_id", "")
    if gongfa_id.is_empty():
        return
    _item_hover_source = slot_row
    _item_hover_timer = 0.0
    _item_fade_timer = 0.0
    _show_item_tooltip(gongfa_id, slot_row)

func _on_slot_row_unhovered(slot_row: Control) -> void:
    # 不立即关闭！启动消失倒计时，让鼠标有机会移到 Tooltip 上
    _item_fade_timer = 0.0  # 从 0 开始计时
```

装备槽位 `EquipSlotBox` 同理，整个容器作为热区。

#### 修复 B — Tooltip 面板也是"安全区"

```gdscript
func _process_item_tooltip(delta: float) -> void:
    if not item_tooltip.visible:
        return
    
    var mouse := get_viewport().get_mouse_position()
    
    # ★ 三个安全区域：任一命中则不消失
    var in_tooltip := item_tooltip.get_global_rect().has_point(mouse)
    var in_source := (
        _item_hover_source != null 
        and is_instance_valid(_item_hover_source) 
        and _item_hover_source.get_global_rect().has_point(mouse)
    )
    # 扩大判定：Tooltip 向触发源方向延伸 8px 的"桥接区域"
    var bridge_rect := _calc_bridge_rect(_item_hover_source, item_tooltip, 8.0)
    var in_bridge := bridge_rect.has_point(mouse)
    
    if in_tooltip or in_source or in_bridge:
        _item_fade_timer = 0.0
    else:
        _item_fade_timer += delta
        if _item_fade_timer >= 0.2:  # 给 0.2s 缓冲
            item_tooltip.visible = false
            _item_hover_source = null

# 计算从触发源到 Tooltip 之间的"桥接矩形"
func _calc_bridge_rect(source: Control, tooltip: Control, padding: float) -> Rect2:
    if source == null or tooltip == null:
        return Rect2()
    var s := source.get_global_rect()
    var t := tooltip.get_global_rect()
    # 取两个矩形的合并区域，确保中间间隙被覆盖
    return s.merge(t).grow(padding)
```

#### 修复 C — DetailPanel 打开时暂停 UnitTooltip

```gdscript
func _process_unit_tooltip(delta: float) -> void:
    # 详情面板打开时，跳过 UnitTooltip 的所有检测
    if unit_detail_panel.visible:
        unit_tooltip.visible = false
        return
    # ... 原有逻辑
```

### 修复总结

| 问题 | 修复 | 关键点 |
|------|------|--------|
| 热区太小 | 整行 `PanelContainer` 作为 hover 目标 | 用 `mouse_entered`/`mouse_exited` 信号 |
| 间隙导致闪退 | 计算"桥接矩形"覆盖间隙 | `source.merge(tooltip).grow(8)` |
| 消失太快 | 缓冲时间从 0.1s 改为 **0.2s** | 给鼠标移动留充足时间 |
| Tooltip 自身是安全区 | 鼠标在 Tooltip 内不触发消失 | `item_tooltip.get_global_rect().has_point(mouse)` |
| DetailPanel 干扰 | 详情面板开启时暂停 UnitTooltip | `if detail_panel.visible: return` |

---

## Bug 2：点击查看详情与拖拽操作冲突

### 现象

布阵期左键点击战场上的棋子想打开角色详情面板，但左键同时也是拖拽操作的触发键，导致点击变成了拖拽，无法打开详情面板。

### 原因

当前代码在 `_handle_mouse_button` 中，左键按下时立即调用 `_try_begin_drag()`，没有区分"点击"和"拖拽"。

### 修复方案：用移动距离阈值区分点击和拖拽

```gdscript
const DRAG_THRESHOLD: float = 6.0  # 像素，移动超过此距离才算拖拽

var _mouse_down_pos: Vector2 = Vector2.ZERO
var _mouse_down_unit: Node = null
var _is_potential_drag: bool = false
var _drag_confirmed: bool = false

func _handle_mouse_button(event: InputEventMouseButton) -> void:
    if event.button_index != MOUSE_BUTTON_LEFT:
        return
    
    if event.pressed:
        # 按下：记录位置，暂不开始拖拽
        _mouse_down_pos = event.position
        var world_pos := world_container.to_local(event.position)
        _mouse_down_unit = _find_unit_at_world_pos(world_pos)
        
        if _mouse_down_unit == null:
            # 检查备战席
            _mouse_down_unit = bench.pick_unit_at(event.position)
        
        _is_potential_drag = (_mouse_down_unit != null)
        _drag_confirmed = false
    else:
        # 松手
        if _is_potential_drag and not _drag_confirmed:
            # 没有移动超过阈值 → 判定为"点击"
            if _mouse_down_unit != null:
                _on_unit_clicked(_mouse_down_unit)
        elif _drag_confirmed:
            # 已确认是拖拽 → 执行放下逻辑
            _try_end_drag(event.position)
        
        _is_potential_drag = false
        _drag_confirmed = false
        _mouse_down_unit = null


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
    if _is_potential_drag and not _drag_confirmed:
        var dist := event.position.distance_to(_mouse_down_pos)
        if dist >= DRAG_THRESHOLD:
            # 移动距离超过阈值 → 确认为拖拽，开始拖拽流程
            _drag_confirmed = true
            _begin_drag(_mouse_down_unit)
    
    if _drag_confirmed and _dragging_unit != null:
        _dragging_unit.update_drag(get_global_mouse_position())


func _on_unit_clicked(unit: Node) -> void:
    # 点击事件 → 打开角色详情面板
    if _stage == Stage.PREPARATION or _stage == Stage.RESULT:
        _open_unit_detail_panel(unit)
```

**核心逻辑**：

```
按下左键 → 记录位置和目标单位
  ↓
移动中检测距离
  ├── 移动 < 6px → 保持"待定"状态
  └── 移动 >= 6px → 确认为拖拽，调用 _begin_drag()
  ↓
松手
  ├── 未确认拖拽 → 判定为点击 → _on_unit_clicked()
  └── 已确认拖拽 → 执行 _try_end_drag()
```

---

## Bug 3：UnitTooltip 被底部 UI 面板遮挡

### 现象

从截图可见，棋子的属性悬浮框显示在棋子下方，被底部的侠馆/备战席面板遮住了一部分，无法看全属性。

### 原因

UnitTooltip 和 BottomPanel 都在 CanvasLayer 中，但 UnitTooltip 所在的 `HUDLayer`（layer=10）层级低于 `BottomLayer`（layer=20），导致 Tooltip 被 BottomPanel 覆盖。

### 修复方案（三选一，推荐 A）

**方案 A（推荐）：将 UnitTooltip 移到更高层级的 CanvasLayer**

```
# 在场景树中新增一个专门的 Tooltip 层
TooltipLayer (CanvasLayer, layer=30)    ← 高于 BottomLayer(20)
├── UnitTooltip
└── ItemTooltip
```

这样 Tooltip 永远显示在所有 UI 面板之上。

**方案 B：Tooltip 显示在棋子上方而非下方**

在 `_show_tooltip` 的边界检测中，优先将 Tooltip 放在鼠标上方：

```gdscript
func _show_tooltip(unit: Node, screen_pos: Vector2) -> void:
    _update_tooltip_data(unit)
    var tooltip_size := unit_tooltip.size
    var viewport_size := get_viewport().get_visible_rect().size
    
    # 优先显示在上方，避免被底部面板遮挡
    var offset := Vector2(16, -tooltip_size.y - 16)
    
    # 如果上方空间不足，再放到下方
    if screen_pos.y + offset.y < 0:
        offset.y = 16
    
    # 左右边界
    if screen_pos.x + offset.x + tooltip_size.x > viewport_size.x:
        offset.x = -tooltip_size.x - 16
    
    unit_tooltip.position = screen_pos + offset
    unit_tooltip.visible = true
```

**方案 C：两者结合**

既提升 CanvasLayer 层级，又优先显示在上方，双重保障。
