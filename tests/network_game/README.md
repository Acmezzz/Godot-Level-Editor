# Freight Yard

独立运行时读取编辑器设置的正式启动地图、生产配方与产量、仓库订单和出货顺序。游戏负责按路线分配库存，订单全部满足才结算为成功。代码不引用编辑器源码。

从编辑器工程根目录只跑本项作者验收：

```powershell
godot --path . --rendering-method gl_compatibility --audio-driver Dummy --script res://tests/run_network_authoring.gd
```

验收只预装游戏代码和字段声明。作者创建地图、布置工厂和仓库，在实例表单配置订单与有序端口列表，保存重开，再设为正式入口并启动独立游戏。流程同时检查整图复制与项目审计如何处理多个出货目标。
