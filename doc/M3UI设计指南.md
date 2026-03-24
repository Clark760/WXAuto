# M3 战场 UI 设计指南（面向代码 AI）

> 本文档基于参考布局图，定义 M3 阶段的新 UI 架构。
> **核心变更**：功法装备区改为右侧常驻面板、角色详情面板可拖动、装卸交互改为拖放。
> 本文档**替代** `M3装备系统整合与功法系统修改指南.md` 中第六章仓库 UI 部分。

---

## 一、主界面总布局

参照参考图，战场主界面分为以下区域：

```
┌─────────────────────────────────────────────────────────┬────────────┐
│ [回合/战场信息/FPS]                                       │ [功法][装备] │
│                                                         │            │
│ ┌──────────┐                                            │  功法装备区  │
│ │ 小地图    │          战 场 区                            │  (右侧常驻)  │
│ │          │        （棋盘+棋子）                          │ ┌──┬──┬──┐ │
│ └──────────┘                                            │ │  │  │  │ │
│ ┌──────────┐         角色详情面板                         │ │  │  │  │ │
│ │ 战斗日志  │        （浮动·可拖动）                       │ │  │  │  │ │
│ │          │                                            │ │  │  │  │ │
│ └──────────┘                                            │ └──┴──┴──┘ │
├─────────────────────────────────────────────────────────┴────────────┤
│                           备 战 区                                    │
│ ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐     │
│ │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │  │     │
│ └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘     │
└─────────────────────────────────────────────────────────────────────┘
```

### 各区域职责

| 区域 | 位置 | 说明 |
|------|------|------|
| **顶部信息栏** | 顶部居中 | 回合数、阶段名称、战力、FPS |
| **小地图** | 左上 | 缩略视图，可点击跳转视角 |
| **战斗日志** | 左下 | 战斗事件文本滚动（普攻/技能/联动触发等） |
| **功法装备区** | **右侧常驻** | 功法/装备的网格仓库，支持拖出物品 |
| **战场区** | 中央主体 | 棋盘+棋子+特效 |
| **角色详情面板** | 浮动覆盖 | 点击棋子打开，**可拖动**，含功法/装备槽位 |
| **备战区** | 底部 | 备战棋子格子，支持拖入/拖出 |

---

## 二、新场景树结构

```
BattleScene (Node2D)
│
├── Background (Node2D)
│
├── WorldContainer (Node2D)                    ← 唯一缩放/平移目标
│   ├── HexGrid (Node2D)
│   ├── UnitLayer (Node2D)
│   └── VfxLayer (Node2D)
│
├── HUDLayer (CanvasLayer, layer=10)
│   ├── TopBar (HBoxContainer)                 ← 顶部信息栏
│   │   ├── PhaseLabel
│   │   ├── RoundLabel
│   │   ├── PowerBar
│   │   └── FPSLabel
│   │
│   ├── LeftPanel (VBoxContainer)              ← 左侧面板容器
│   │   ├── MiniMap (SubViewportContainer)     ← 小地图
│   │   └── BattleLog (ScrollContainer)        ← 战斗日志
│   │       └── LogContent (RichTextLabel)
│   │
│   ├── LinkagePanel (VBoxContainer)           ← 联动面板（可折叠）
│   │
│   ├── UnitTooltip (PanelContainer)           ← 棋子悬浮信息
│   └── PhaseTransition (CenterContainer)
│
├── RightPanelLayer (CanvasLayer, layer=15)     ← ★ 右侧功法装备区
│   └── InventoryPanel (PanelContainer)
│       ├── TabBar (HBoxContainer)              ← [功法] [装备] 切换
│       │   ├── GongfaTabButton
│       │   └── EquipTabButton
│       ├── FilterBar (HBoxContainer)           ← 类型筛选 + 搜索
│       │   ├── FilterButtons (HBoxContainer)
│       │   └── SearchField (LineEdit)
│       └── ScrollContainer
│           └── ItemGrid (GridContainer, 3列)   ← 物品卡片网格
│               └── ItemCard x N (PanelContainer)
│                   ├── IconLabel               ← 类型图标
│                   ├── NameLabel               ← 名称
│                   ├── QualityBadge            ← 品质色条
│                   └── StatusLabel             ← "已装备:角色" / "空闲"
│
├── DetailLayer (CanvasLayer, layer=20)          ← ★ 可拖动角色详情
│   └── UnitDetailPanel (PanelContainer)        ← 可拖动容器
│       ├── DragHandle (PanelContainer)         ← ★ 拖动手柄（标题栏）
│       │   ├── PortraitSmall (TextureRect)     ← 小头像
│       │   ├── NameLabel                       ← "武当·张三丰 ★★★"
│       │   └── CloseButton                     ← ✕ 关闭
│       ├── ContentBody (HBoxContainer)
│       │   ├── StatsColumn (VBoxContainer)     ← 左列·属性区
│       │   │   ├── StatsGrid (GridContainer)
│       │   │   └── BonusLabel
│       │   └── SlotsColumn (VBoxContainer)     ← 右列·槽位区
│       │       ├── GongfaSlotsLabel ("功法槽位")
│       │       ├── GongfaSlotRow x 5           ← [图标][类型:名称][卸下]
│       │       │   └── DropTarget              ← ★ 拖放接收区
│       │       ├── EquipSlotsLabel ("装备槽位")
│       │       ├── EquipSlotRow x 3            ← [图标][类型:名称][卸下]
│       │       │   └── DropTarget              ← ★ 拖放接收区
│       │       └── LinkagePreview (VBoxContainer)
│       └── StatusBar (Label)                   ← "拖动功法/装备到槽位进行装备"
│
├── TooltipLayer (CanvasLayer, layer=30)         ← 浮动提示最高层
│   └── ItemTooltip (PanelContainer)
│
├── BottomLayer (CanvasLayer, layer=5)           ← 底部备战区
│   └── BottomPanel (PanelContainer)
│       ├── BenchArea (ScrollContainer)
│       │   └── BenchGrid (GridContainer)
│       ├── ShopBar (HBoxContainer)
│       ├── ResourceBar (HBoxContainer)
│       └── ActionBar (HBoxContainer)
│
└── DebugLayer (CanvasLayer, layer=100)
```

### CanvasLayer 层级总览

| 层级 | 名称 | 内容 |
|------|------|------|
| 5 | BottomLayer | 备战区+商店 |
| 10 | HUDLayer | 顶栏+左侧面板+联动+UnitTooltip |
| 15 | RightPanelLayer | 功法装备仓库 |
| 20 | DetailLayer | 角色详情面板（可拖动） |
| 30 | TooltipLayer | ItemTooltip（最高 UI） |
| 100 | DebugLayer | 调试信息 |

---

## 三、右侧功法装备区（常驻面板）

### 3.1 设计要点

- **常驻显示**，不需要按钮打开/关闭——布阵期始终可见
- 通过 **[功法] [装备]** 两个 Tab 切换内容
- 每个物品以**卡片**形式显示在 3 列网格中
- 卡片**支持拖出**：鼠标按住卡片 → 产生拖影 → 拖到角色详情的槽位上完成装备

### 3.2 功法 Tab 内容

```
┌─────────────────────┐
│ [功法]  装备          │  ← Tab 按钮（当前高亮"功法"）
├─────────────────────┤
│ [全部][内][外][轻][阵][奇]│  ← 类型过滤
├─────────────────────┤
│ ┌─────┐┌─────┐┌─────┐│
│ │📖   ││⚔   ││🏃   ││
│ │九阳  ││太极拳││梯云纵││
│ │[橙]  ││[紫]  ││[橙]  ││
│ │已:张  ││空闲  ││空闲  ││
│ └─────┘└─────┘└─────┘│
│ ┌─────┐┌─────┐┌─────┐│
│ │⚔   ││📖   ││◆   ││
│ │降龙掌││紫霞功││天罡阵││
│ │[橙]  ││[紫]  ││[紫]  ││
│ │空闲  ││空闲  ││空闲  ││
│ └─────┘└─────┘└─────┘│
│ （滚动...）           │
└─────────────────────┘
```

### 3.3 装备 Tab 内容

同上布局，过滤改为 `[全部][兵器][护甲][饰品]`。

### 3.4 卡片拖出规则

```gdscript
# ItemCard 拖放数据结构
var drag_data := {
    "type": "gongfa",           # "gongfa" 或 "equipment"
    "id": "gongfa_jiuyang",     # 物品 id
    "item_data": { ... },       # 完整数据字典
    "slot_type": "neigong"      # 功法的 type 或装备的 type
}
```

| 操作 | 行为 |
|------|------|
| 鼠标按住卡片 > 6px | 开始拖放，显示拖影 |
| 拖到角色详情的**匹配**槽位上 | 高亮槽位 → 松开后装备，刷新属性 |
| 拖到**不匹配**的槽位上 | 槽位显示红色禁止标记，松开无效 |
| 拖到空白区域松开 | 取消拖放 |
| 悬停在卡片上 | 显示 ItemTooltip |

### 3.5 交锋期行为

- 功法装备区 **变灰/半透明**（`modulate.a = 0.4`）
- 禁用所有拖放交互
- 可继续悬停查看 ItemTooltip

---

## 四、角色详情面板（可拖动）

### 4.1 核心变更

| 项目 | 旧设计 | 新设计 |
|------|--------|--------|
| 面板位置 | 屏幕居中弹窗 | **可自由拖动**，默认偏左居中 |
| 背景遮罩 | 全屏半透明 Overlay | **无遮罩**，仅面板自身有背景 |
| 关闭方式 | 点击遮罩/ESC/关闭按钮 | ESC / 关闭按钮 / 再次点击同一角色 |
| 功法更换 | 每行"更换"按钮循环切换 | **从右侧仓库拖入**到槽位 |
| 功法卸下 | 无（通过更换清空） | 每行 **"卸下"** 按钮 |
| 装备操作 | 同上 | 同上 |

### 4.2 面板布局

```
┌──────────────────────────────────────────────────────┐
│ [头像] 武当·张三丰 ★★★                          [✕] │ ← DragHandle（拖动此区域移动面板）
├──────────────────────────────────────────────────────┤
│ ┌──────────────────┐  ┌─────────────────────────────┐│
│ │  属性区           │  │  槽位区                     ││
│ │                  │  │                             ││
│ │ 外功  128 (+22)  │  │  功法槽位                    ││
│ │ 外防   86        │  │  📖 内功: 九阳神功   [卸下]  ││
│ │ 内功   95        │  │  ✖  外功: 空         —      ││
│ │ 内防   72        │  │  🏃 身法: 空         —      ││
│ │ 速度   65        │  │  ◆  阵法: 空         —      ││
│ │ 射程    2        │  │  ✨ 奇术: 空         —      ││
│ │                  │  │                             ││
│ │ HP 1280/1800     │  │  装备槽位                    ││
│ │ MP   45/80       │  │  ⚔ 兵器: 青钢剑     [卸下]  ││
│ │                  │  │  🛡 护甲: 空         —      ││
│ └──────────────────┘  │  💎 饰品: 空         —      ││
│                       │                             ││
│                       │  联动预览                    ││
│                       │  暂无已激活联动              ││
│                       └─────────────────────────────┘│
├──────────────────────────────────────────────────────┤
│ 拖动功法/装备到对应槽位进行装备                        │ ← StatusBar
└──────────────────────────────────────────────────────┘
```

### 4.3 拖动实现

```gdscript
# UnitDetailPanel 拖动逻辑
var _is_dragging_panel: bool = false
var _drag_offset: Vector2 = Vector2.ZERO

# DragHandle 区域（标题栏）的输入处理
func _on_drag_handle_gui_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT:
            if event.pressed:
                _is_dragging_panel = true
                _drag_offset = get_global_mouse_position() - unit_detail_panel.position
            else:
                _is_dragging_panel = false
    elif event is InputEventMouseMotion:
        if _is_dragging_panel:
            unit_detail_panel.position = get_global_mouse_position() - _drag_offset
            # 限制在屏幕范围内
            var vp_size := get_viewport_rect().size
            unit_detail_panel.position = unit_detail_panel.position.clamp(
                Vector2.ZERO,
                vp_size - unit_detail_panel.size
            )
```

### 4.4 槽位拖放接收

每个 SlotRow 是一个**拖放接收区（DropTarget）**：

```gdscript
# 每个 GongfaSlotRow / EquipSlotRow 需要实现：

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
    if not (data is Dictionary):
        return false
    # 功法槽位只接受对应类型的功法
    if _slot_category == "gongfa":
        return str(data.get("type", "")) == "gongfa" \
           and str(data.get("slot_type", "")) == _slot_key  # 如 "neigong"
    # 装备槽位只接受对应类型的装备
    elif _slot_category == "equipment":
        return str(data.get("type", "")) == "equipment" \
           and str(data.get("slot_type", "")) == _slot_key  # 如 "weapon"
    return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
    var item_id: String = str(data.get("id", ""))
    if item_id.is_empty():
        return
    if _slot_category == "gongfa":
        gongfa_manager.call("equip_gongfa", _detail_unit, _slot_key, item_id)
    elif _slot_category == "equipment":
        gongfa_manager.call("equip_equipment", _detail_unit, _slot_key, item_id)
    _update_detail_panel(_detail_unit)  # 刷新面板
    _rebuild_inventory_items()          # 刷新仓库卡片状态
```

### 4.5 槽位拖放视觉反馈

```
拖放到匹配槽位上时:
  ┌─────────────────────────────────────────┐
  │ 📖 内功: 九阳神功   [卸下]              │ ← 绿色高亮边框
  └─────────────────────────────────────────┘

拖放到不匹配槽位上时:
  ┌─────────────────────────────────────────┐
  │ ✖  外功: 空         —                  │ ← 红色边框 + 🚫 图标
  └─────────────────────────────────────────┘

空槽位默认:
  ┌─────────────────────────────────────────┐
  │ 🏃 身法: 空         —                  │ ← 虚线边框，暗色
  └─────────────────────────────────────────┘
```

### 4.6 "卸下" 按钮

```gdscript
func _on_unequip_pressed(slot_category: String, slot_key: String) -> void:
    if _detail_unit == null or not is_instance_valid(_detail_unit):
        return
    if _stage != Stage.PREPARATION:
        return
    if slot_category == "gongfa":
        gongfa_manager.call("unequip_gongfa", _detail_unit, slot_key)
    elif slot_category == "equipment":
        gongfa_manager.call("unequip_equipment", _detail_unit, slot_key)
    _update_detail_panel(_detail_unit)
    _rebuild_inventory_items()
```

| 槽位状态 | "卸下" 按钮 |
|---------|------------|
| 已装备物品 | 显示 **[卸下]**，可点击 |
| 空槽位 | 显示 **—**（破折号），不可点击 |

---

## 五、拖放系统总览

### 5.1 三种拖放场景

| # | 来源 | 目标 | 效果 |
|---|------|------|------|
| 1 | 右侧仓库 ItemCard | 角色详情的功法/装备槽位 | 装备物品 |
| 2 | 备战区棋子 | 棋盘 | 部署上场 |
| 3 | 棋盘棋子 | 备战区 | 下场回备战区 |

### 5.2 Godot 拖放 API 使用

```gdscript
# ItemCard 作为拖放源
func _get_drag_data(at_position: Vector2) -> Variant:
    if _stage != Stage.PREPARATION:
        return null  # 交锋期禁止拖放
    
    # 创建拖影预览
    var preview := TextureRect.new()
    preview.texture = _card_icon_texture
    preview.modulate = Color(1, 1, 1, 0.7)
    set_drag_preview(preview)
    
    return {
        "type": "gongfa",        # "gongfa" / "equipment"
        "id": _item_id,
        "slot_type": _item_type, # "neigong" / "weapon" 等
        "item_data": _item_data
    }

# SlotRow 作为拖放目标
func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
    # 验证类型匹配，返回 true 时高亮边框
    ...

func _drop_data(at_position: Vector2, data: Variant) -> void:
    # 执行装备操作
    ...
```

### 5.3 拖放与点击区分

在角色详情面板的 DragHandle 和仓库 ItemCard 上共用同一套阈值机制：

```gdscript
const DRAG_THRESHOLD: float = 6.0  # 像素

# 鼠标按下时记录起点
var _mouse_press_pos: Vector2 = Vector2.ZERO
var _is_potential_drag: bool = false

# 移动超过 DRAG_THRESHOLD 则进入拖放模式
# 未超过则在松开时判定为点击
```

---

## 六、阶段驱动 UI 状态

| UI 元素 | 布阵期 | 交锋期 | 结算期 |
|---------|--------|--------|--------|
| **功法装备区** | ✅ 正常、可拖出 | ⚠ 半透明、禁用拖放 | ❌ 隐藏 |
| **角色详情面板** | ✅ 点击棋子打开、可拖动、可装卸 | ❌ 关闭 | ❌ 关闭 |
| **备战区** | ✅ 正常 | ⚠ 收起/半透明 | ❌ 隐藏 |
| **小地图** | ✅ | ✅ | ✅ |
| **战斗日志** | ❌ 隐藏 | ✅ 显示 | ✅ 显示 |
| **联动面板** | ✅ 实时显示激活联动 | ✅ | ❌ |
| **棋子悬浮信息** | ✅ | ✅ | ❌ |
| **ItemTooltip** | ✅ 悬停仓库/槽位显示 | ✅ 仅悬停仓库 | ❌ |
| **槽位[卸下]按钮** | ✅ 可点击 | ❌ disabled | ❌ |

---

## 七、修改文件清单

### 7.1 需修改的文件

| 文件 | 修改内容 |
|------|---------|
| `scripts/board/battlefield_m3.gd` | **主要修改**：重构 UI 创建逻辑 |
| | 1. 删除旧的 `GongfaButton`/`EquipButton` 底栏按钮和弹窗式 InventoryPanel |
| | 2. 新增右侧常驻 `InventoryPanel`（RightPanelLayer, layer=15） |
| | 3. UnitDetailPanel 移入 `DetailLayer`（layer=20），添加拖动手柄 |
| | 4. 每个 SlotRow 的"更换"按钮 → "卸下"按钮，新增 `_can_drop_data`/`_drop_data` |
| | 5. ItemCard 实现 `_get_drag_data` 拖放源 |
| | 6. 新增战斗日志区（左下方 `BattleLog`） |
| `doc/M2场景显示逻辑说明.md` | 更新场景树结构、CanvasLayer 层级表、阶段驱动 UI 状态表 |

### 7.2 不需要修改的文件

| 文件 | 原因 |
|------|------|
| `gongfa_manager.gd` | `equip_gongfa`/`unequip_gongfa`/`equip_equipment`/`unequip_equipment` 接口不变 |
| `effect_engine.gd` | 纯逻辑，不涉及 UI |
| `buff_manager.gd` | 同上 |
| `linkage_detector.gd` | 同上 |
| `gongfa_registry.gd` | 同上 |

---

## 八、关键交互流程

### 8.1 装备功法

```
1. 玩家点击棋盘上的某个角色
     → 打开 UnitDetailPanel（显示属性+槽位）
2. 在右侧功法装备区找到想装备的功法（如"九阳神功"）
3. 鼠标按住该卡片拖动
     → 产生半透明拖影
4. 拖到详情面板的"内功"槽位上
     → 槽位高亮绿色（类型匹配）
5. 松开鼠标
     → 调用 gongfa_manager.equip_gongfa(unit, "neigong", "gongfa_jiuyang")
     → 槽位更新显示 "📖 内功: 九阳神功 [卸下]"
     → 左侧属性区数值实时更新（如 HP +200, MP +80）
     → 仓库中对应卡片标注 "已装备:张三丰"
```

### 8.2 卸下功法

```
1. 在详情面板中，已装备的槽位行末尾有 [卸下] 按钮
2. 点击 [卸下]
     → 调用 gongfa_manager.unequip_gongfa(unit, "neigong")
     → 槽位更新显示 "📖 内功: 空 —"
     → 属性区数值实时回落
     → 仓库中对应卡片恢复 "空闲"
```

### 8.3 替换功法（拖入已装备槽位）

```
1. 玩家拖动新功法到一个已有功法的槽位上
2. 松开后：
     → 先 unequip 旧功法
     → 再 equip 新功法
     → 刷新 UI
```

### 8.4 查看功法/装备详情

```
1. 鼠标悬停在仓库卡片或详情面板槽位上
2. 超过 0.2s 后显示 ItemTooltip（TooltipLayer, layer=30）
3. ItemTooltip 显示：名称、类型、描述、被动效果列表、技能/触发器说明、联动标签
4. 鼠标移开后 0.2s 缓冲后关闭
```

---

## 九、响应式布局规则

### 9.1 右侧面板宽度

```gdscript
# 右侧面板固定宽度，不随窗口缩放
const INVENTORY_PANEL_WIDTH: float = 260.0

# 面板高度 = 视口高度 - 顶栏高度 - 底栏高度
func _update_inventory_layout() -> void:
    var vp_size := get_viewport_rect().size
    inventory_panel.position = Vector2(vp_size.x - INVENTORY_PANEL_WIDTH, 40)
    inventory_panel.size = Vector2(INVENTORY_PANEL_WIDTH, vp_size.y - 40 - bottom_panel_height)
```

### 9.2 角色详情面板默认位置

```gdscript
# 默认居中偏左（避开右侧仓库面板）
func _default_detail_position() -> Vector2:
    var vp_size := get_viewport_rect().size
    var panel_size := unit_detail_panel.size
    return Vector2(
        (vp_size.x - INVENTORY_PANEL_WIDTH - panel_size.x) / 2.0,
        (vp_size.y - panel_size.y) / 2.0
    )
```

### 9.3 战场区可视范围

```
战场区宽度 = 视口宽度 - 右侧面板宽度(260) - 左侧面板宽度(180)
```

---

## 十、与旧 UI 的差异对照

| 项目 | 旧设计（M2+现有M3） | 新设计（本文档） |
|------|-------------------|---------------|
| 功法/装备仓库 | 底栏按钮打开弹窗 | 右侧常驻面板 |
| 装备交互 | "更换" 按钮循环切换 | **拖放** 从仓库到槽位 |
| 卸下交互 | 无（通过更换清空） | **[卸下]** 按钮 |
| 角色详情 | 全屏居中弹窗 + 半透明遮罩 | 无遮罩、**可拖动** |
| 小地图 | 右上 | **左上** |
| 战斗日志 | 无 | **左下** 新增 |
| 底栏按钮 | [升级][功法][装备] | [升级]（功法/装备按钮删除） |
| CanvasLayer | HUD=10, Bottom=20 | HUD=10, RightPanel=15, Detail=20, Tooltip=30, Bottom=5 |
| Bottom 层级 | 20（高于 HUD） | **5**（低于 HUD，确保 Tooltip 不被遮挡） |

---

## 十一、实施步骤

> **注意**：本文档仅定义 UI 结构和交互，代码 AI 应参照此文档修改 `battlefield_m3.gd` 中的 UI 创建和交互逻辑。

| 步骤 | 内容 | 说明 |
|------|------|------|
| 1 | 调整 CanvasLayer 层级 | Bottom→5, HUD→10, 新建 RightPanel→15, Detail→20, Tooltip→30 |
| 2 | 创建右侧常驻 InventoryPanel | Tab 切换 + 筛选 + ItemGrid + ItemCard 拖放源 |
| 3 | 重构 UnitDetailPanel | 移入 DetailLayer、添加 DragHandle、槽位按钮改"卸下"、实现 DropTarget |
| 4 | 实现拖放系统 | ItemCard._get_drag_data + SlotRow._can_drop_data/_drop_data |
| 5 | 新增战斗日志区 | 左下 BattleLog (RichTextLabel) |
| 6 | 移动小地图到左上 | 调整 MiniMap 位置 |
| 7 | 删除底栏旧按钮 | 移除 GongfaButton / EquipButton |
| 8 | 更新阶段驱动状态表 | 各阶段显隐/交互切换 |

---

## 十二、验证

1. **布阵期**：点击角色 → 详情面板弹出 → 可拖动面板 → 拖动标题栏移动面板
2. **装备功法**：从右侧仓库拖出功法 → 拖到详情面板内功槽位 → 绿色高亮 → 松开 → 属性更新
3. **类型不匹配**：拖出内功到外功槽位 → 红色禁止 → 松开无效
4. **卸下功法**：点击已装备槽位的 [卸下] → 功法回到仓库 → 属性回落
5. **替换功法**：拖出新功法到已有功法的槽位 → 自动替换
6. **装备操作**：切换到装备 Tab → 同上流程
7. **交锋期**：仓库半透明 → 无法拖放 → 详情面板关闭
8. **ItemTooltip**：悬停仓库卡片/槽位 → 详情弹出 → 不闪退
