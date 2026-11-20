extends RefCounted
## EntityFactory：实体工厂/实例码发号/占位尺寸（从 editor_canvas.gd 拆出，宿主 = editor_canvas）

const AssetDecl := preload("res://src/assets/asset_decl.gd")   # 清单资产表（assets[]）
const EntityNodeRef := preload("res://src/canvas/entity_node.gd")   # 摆放物节点（场景/实体共用）
const ContentIdRef := preload("res://src/content/content_id.gd")   # 分层身份码

var cvs   # editor_canvas 宿主

func _init(c) -> void:
	cvs = c

## 同名转发属性（读写穿透到 cvs，搬动文本零改动）
var ent_sizes:
	get: return cvs.ent_sizes
	set(v): cvs.ent_sizes = v
var thumbs:
	get: return cvs.thumbs
var manifest:
	get: return cvs.manifest
var tile_px:
	get: return cvs.tile_px
var _ent_by_id:
	get: return cvs._ent_by_id
	set(v): cvs._ent_by_id = v
var _ent_by_id_dirty:
	get: return cvs._ent_by_id_dirty
	set(v): cvs._ent_by_id_dirty = v
var map_root:
	get: return cvs.map_root

## 同名包装方法（真实实现经 cvs 转发）
func _ent_by_code_index() -> Dictionary:
	return cvs._ent_by_code_index()

## 设置实体的编辑器占位尺寸（像素）；用于画布上画真实占位框
func set_entity_sizes(sizes: Dictionary) -> void:
	ent_sizes = sizes

## 某个资产的编辑器占位尺寸（像素）；0 表示未知（退回 1 格）
func _size_of(aid: String) -> Vector2:
	var v = ent_sizes.get(aid, null)
	if v is Vector2 and (v as Vector2) != Vector2.ZERO:
		return v
	return Vector2.ZERO

## 资产声明的显示尺寸（像素）。唯一来源：清单 editorSize / prefab 碰撞尺寸；没有就用 1 格。
## 缩略图只作为贴图内容，尺寸一律由这里定——不同大小的资产因此能正确呈现。
func entity_display_size(aid: String) -> Vector2:
	var sz := _size_of(aid)
	if sz == Vector2.ZERO:
		sz = Vector2(tile_px, tile_px)
	return sz

## 实例级显示尺寸：带 sizeFields 的资产（事件区）尺寸写在实例 props 里，
## 其余等价于资产声明尺寸。旧调用点传节点，直接取节点自己的口径。
func entity_display_size_of(node: Node) -> Vector2:
	if node is EntityNode:
		return (node as EntityNode).display_size()
	return entity_display_size("")

## 建一个摆放物节点：尺寸按资产声明算，视觉（缩略图/图片/无）由 EntityNode 自己装配。
## 落层、props、code 由调用方填——这里只管「一个形状正确的空实例」。
func make_object(aid: String) -> EntityNode:
	return EntityNodeRef.create(manifest, aid, entity_display_size(aid), tile_px, thumbs)

## 该资产是否可以摆到画布上：实体（kind=entity）与图片场景（shape=image）。
## 图集型场景（shape=tile）走瓦片通道，不是摆放物。
func is_placeable(aid: String) -> bool:
	var d := AssetDecl.by_id(manifest, aid)
	if d.is_empty():
		return false
	return str(d.get("kind", "")) == "entity" or str(d.get("shape", "")) == "image"
## 老实体/新建实体没有码就补发；已有（载图恢复）保留。
## 只有 kind=entity 的资产需要实例码——场景实例（图片）永不产码。
func _ensure_code(n: EntityNode) -> void:
	if n == null or not n.is_entity():
		n.code = ""
		return
	if n.code == "":
		var c := _fresh_inst_code()
		n.code = c
		# 新码即时入索引（索引已建时）：防止同批次后续补码查不到它而撞码
		if not _ent_by_id_dirty:
			_ent_by_id[c] = n

## 生成一个本图未占用的实例码（码空间 100 万+，撞码重摇即可）
func _fresh_inst_code() -> String:
	for i in 64:
		var c := ContentIdRef.new_inst_code()
		if not _code_taken(c):
			return c
	return ContentIdRef.new_inst_code()

func _code_taken(c: String) -> bool:
	# _ent_by_code_index 是脏标记缓存——O(n) 全扫摊平为建一次索引后 O(1) 查
	return _ent_by_code_index().has(c)

