# scripts/infra

本目录承接基础设施层代码。

允许放入：

1. 单例访问收口
2. ServiceLocator 或等价依赖入口
3. 外部系统、资源加载、兼容 facade、adapter

禁止放入：

1. 直接承载业务规则
2. 继续把应用编排堆回旧场景脚本
