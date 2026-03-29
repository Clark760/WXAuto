extends RefCounted
class_name RecyclePricing

# 回收定价规则
# 说明：
# 1. 只根据条目品质给出默认回收价。
# 2. 不关心库存、银两写回和日志。

const QUALITY_SELL_PRICE: Dictionary = {
	"white": 1,
	"green": 2,
	"blue": 3,
	"purple": 5,
	"orange": 8
}


# 非角色条目出售时按品质表读取银两回收价。
static func item_sell_price(item_data: Dictionary) -> int:
	var quality_key: String = str(item_data.get("quality", "white")).strip_edges().to_lower()
	return int(QUALITY_SELL_PRICE.get(quality_key, 1))
