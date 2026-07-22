# PoolTrajectoryMatchProbe 0.1.0

- 产物名保持为 `NativeTrajectory.dylib`，兼容原仓库的旧 Actions workflow。
- 合并无黄线 Overlay 与 NativeTrajectory 0.1.2。
- 保留青色母球碰后路线和粉色目标球路线。
- 匹配模式反射节点数改为动态识别。
- 原生识别统计写入同一份 CSV 的 `replica_*` 字段。
- 台面识别失败时使用实机校准固定边界：
  `(-1.3335,-0.7963796) -> (1.3335,0.5371203)`。
- 六袋对象缺失时，优先把固定世界边界通过当前 Camera 投影到屏幕，不依赖固定屏幕裁剪位置。
