extends RefCounted
class_name BattleLogRingBuffer

## 战斗日志环形缓冲区
## 说明：
## 1. write_head 使用“累计写入序号”，避免取模后丢失溢出信息。
## 2. drain_since 以外部保存的 write_head 为游标，自动跳过已被覆盖的旧数据。
## 3. push/drain 都保持 O(1) 或 O(n_new)，不做头删搬移。

const RING_CAPACITY: int = 128

var _buffer: Array[Dictionary] = []
var _write_head: int = 0
var _count: int = 0


func push(event: Dictionary) -> void:
	if event.is_empty():
		return
	var slot: int = _write_head % RING_CAPACITY
	var event_copy: Dictionary = event.duplicate(true)
	if _buffer.size() < RING_CAPACITY and slot == _buffer.size():
		_buffer.append(event_copy)
	else:
		_buffer[slot] = event_copy
	_write_head += 1
	_count = mini(_count + 1, RING_CAPACITY)


func drain_since(last_read_head: int) -> Array[Dictionary]:
	if _count <= 0:
		return []
	var oldest_head: int = _write_head - _count
	var start_head: int = maxi(last_read_head, oldest_head)
	if start_head >= _write_head:
		return []

	var output: Array[Dictionary] = []
	for read_head in range(start_head, _write_head):
		output.append(_buffer[read_head % RING_CAPACITY])
	return output


func get_write_head() -> int:
	return _write_head


func clear() -> void:
	_buffer.clear()
	_write_head = 0
	_count = 0
