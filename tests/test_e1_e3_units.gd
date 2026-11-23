extends "res://tests/_suite_base.gd"
## E1 / E3：字段行说明与地图菜单身份、改尺寸裁剪的纯逻辑。

const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const MapMenuIdentity := preload("res://src/ui/map_menu_identity.gd")
const MapResize := preload("res://src/ui/map_resize.gd")

## E1：字段说明只从已声明的键拼（id/码/类型/范围/缺省），契约没有说明/单位键就不编
func test_decl_tooltip_from_declared_keys() -> void:
	var t := FieldWidgets.decl_tooltip({"id": "count", "code": "C1D2", "kind": "input",
		"type": "int", "min": 1, "max": 9, "default": 3})
	ok(t.contains("count") and t.contains("C1D2"), "带字段 id 与执行码: " + t)
	ok(t.contains("int") and t.contains("min 1") and t.contains("max 9"), "带类型与范围: " + t)
	ok(t.contains("缺省 3"), "带声明缺省: " + t)
	var t2 := FieldWidgets.decl_tooltip({"id": "pick", "kind": "choice", "options": ["a", "b"],
		"multiple": true})
	ok(t2.contains("可选：a,b") and t2.contains("可多选"), "choice 列可选值与多选: " + t2)
	var t3 := FieldWidgets.decl_tooltip({"id": "target", "kind": "choice", "source": "entity_inst:"})
	ok(t3.contains("来源 entity_inst:"), "choice 列 source: " + t3)
	ok(not t3.contains("说明") and not t3.contains("单位"), "不凭空生成说明/单位字样")
	eq(FieldWidgets.decl_tooltip({}), "", "空声明不出空串以外的内容")

## E3：菜单项绑定身份解析——下标越界/文件消失/码变化/同名当前图/正常切换
func test_map_menu_identity_resolve() -> void:
	var binds := [{"name": "a", "code": "AAAA", "path": "a.json"},
		{"name": "b", "code": "BBBB", "path": "b.json"}, {"name": "", "code": ""}]
	eq(str(MapMenuIdentity.resolve(binds, 0, true, "AAAA", "b").status), MapMenuIdentity.OK, "身份一致")
	eq(str(MapMenuIdentity.resolve(binds, 0, true, "AAAA", "a").status), MapMenuIdentity.SAME, "当前图")
	eq(str(MapMenuIdentity.resolve(binds, 0, false, "", "a").status), MapMenuIdentity.MISSING, "文件消失")
	eq(str(MapMenuIdentity.resolve(binds, 0, true, "ZZZZ", "a").status), MapMenuIdentity.RECODE, "码变化")
	eq(str(MapMenuIdentity.resolve(binds, 2, true, "", "a").status), MapMenuIdentity.STALE, "空绑定")
	eq(str(MapMenuIdentity.resolve(binds, 9, true, "", "a").status), MapMenuIdentity.STALE, "下标越界")
	eq(str(MapMenuIdentity.resolve([], 0, true, "", "a").status), MapMenuIdentity.STALE, "空菜单")
	# 老图无码：不做码比较，只按文件存在 + 图名
	eq(str(MapMenuIdentity.resolve(binds, 1, true, "", "a").status), MapMenuIdentity.OK, "无码按名解析")
	eq(str(MapMenuIdentity.resolve(binds, 0, true, "", "b").status), MapMenuIdentity.OK,
		"文件此刻无码不误报失效")

## E3：改尺寸裁剪——预览计数与实际裁剪同判据，扩大不裁
func test_map_resize_crop() -> void:
	var d := {"tiles": {"L1": [[0, 0, "a", 0, 0, 0], [5, 5, "a", 0, 0, 0],
			[9, 1, "a", 0, 0, 0], ["bad"]]},
		"collision": [{"x": 1, "y": 1}, {"x": 7, "y": 2}, [8, 0]],
		"objects": [{"asset": "e", "code": "K1", "x": 2.5, "y": 1.0},
			{"asset": "e", "code": "K2", "x": 9.0, "y": 2.0}]}
	eq(MapResize.counts(d), {"tiles": 4, "collision": 3, "objects": 2}, "现有计数")
	var crop := MapResize.crop_counts(d, 6, 6)
	eq(int(crop.tiles), 1, "瓦片裁 1 条（9,1 界外；残条不是合法瓦片、不计入）")
	eq(int(crop.collision), 2, "碰撞裁 2 条（对象 7,2 与退役数组 8,0）")
	eq(int(crop.objects), 1, "摆放物裁 1 条（9.0 界外；2.5 半格在界内）")
	var grow := MapResize.crop_counts(d, 40, 40)
	eq(int(grow.tiles) + int(grow.collision) + int(grow.objects), 0, "扩大不裁")
	# 实际裁剪与预览同一判据：界外条目消失，界内条目与原有顺序保留
	MapResize.crop_data(d, 6, 6)
	eq((d.tiles.L1 as Array).size(), 2, "瓦片剩界内 2 条，残条被剔除")
	eq(int((d.tiles.L1 as Array)[0][0]), 0, "界内第一条件原样在前")
	eq((d.collision as Array).size(), 1, "碰撞只剩界内 1 条")
	eq((d.objects as Array).size(), 1, "摆放物只剩界内 1 条")
	eq(str((d.objects[0] as Dictionary).get("code")), "K1", "保留的是界内那条")

func test_triangular_resize_boundaries() -> void:
	var d := {"meta": {"w": 12, "h": 8}, "tiles": {"L": [[15, 7], [16, 7], [90, 0]]},
		"collision": [{"x": 15, "y": 7}, [16, 7]], "objects": [{"x": 7.9, "y": 7}, {"x": 8.0, "y": 7}]}
	var before := d.duplicate(true)
	eq(MapResize.crop_counts(d, 13, 8, true), {"tiles": 0, "collision": 0, "objects": 0}, "扩大不裁")
	MapResize.crop_data(d, 13, 8, true)
	eq(d, before, "扩大保留已有界外数据")
	eq(MapResize.crop_counts(d, 8, 8, true), {"tiles": 2, "collision": 1, "objects": 1}, "三角列与连续坐标判界")
	MapResize.crop_data(d, 8, 8, true)
	eq(d.tiles.L, [[15, 7]], "保留最右三角瓦片")
	eq(d.collision, [{"x": 15, "y": 7}], "保留最右三角碰撞")
	eq(d.objects, [{"x": 7.9, "y": 7}], "摆放物仍用连续坐标")
