extends RefCounted
## 测试套件基类：断言只收集失败信息，runner 每个用例前清零。
## 套件写法：extends "res://tests/_suite_base.gd"，方法名以 test_ 开头即被 runner 发现。
## 断言：ok(条件, 消息)；eq(实得, 期望, 消息)。失败不抛异常，跑完统一汇报。

var failures: Array = []
var assert_count := 0

func ok(cond: bool, msg: String) -> void:
	assert_count += 1
	if not cond:
		failures.append(msg)

func eq(got, want, msg: String) -> void:
	assert_count += 1
	if got != want:
		failures.append("%s（实得 %s，期望 %s）" % [msg, str(got), str(want)])
