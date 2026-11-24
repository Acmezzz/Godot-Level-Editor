extends RefCounted
## 把图像裁到不透明内容的最小外接框（四周透明留白削掉）。
## 预览图多是 96×96 画布 + 中间十几像素的小图，不裁的话在画布上就是个点。
## 留 1px 余量，避免裁得过紧导致相邻像素被过滤掉。全透明图原样返回。

static func trim_alpha(img: Image) -> Image:
	if img == null:
		return null
	var used := img.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		return img
	var pad := 1
	var x0 := maxi(used.position.x - pad, 0)
	var y0 := maxi(used.position.y - pad, 0)
	var x1 := mini(used.position.x + used.size.x + pad, img.get_width())
	var y1 := mini(used.position.y + used.size.y + pad, img.get_height())
	var rect := Rect2i(x0, y0, x1 - x0, y1 - y0)
	if rect.position == Vector2i.ZERO and rect.size == img.get_size():
		return img
	var out := Image.create(rect.size.x, rect.size.y, false, img.get_format())
	out.blit_rect(img, rect, Vector2i.ZERO)
	return out
