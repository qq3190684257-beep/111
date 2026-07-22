# PoolTrajectoryLab

## MatchProbe 0.1.0 合并诊断版

- 单 dylib 合并“无黄线”Overlay 与 NativeTrajectory 0.1.2。
- 只绘制青色母球碰后线和粉色目标球线。
- `PocketCueUI._numReflectSubNode` 使用动态范围，不再固定等于 64。
- 台面边界按 `PhysicsCoordinate -> 六袋锚点 -> 固定标准台面` 降级。
- 固定台面不依赖匹配模式的桌面对象，只动态读取球、母球和瞄准方向。
- CSV 新增 `replica_*` 字段，记录对象数、有效数、写入/读回、节点数和 ScaleAim。

为兼容原来的 GitHub 仓库和旧 workflow，构建产物继续命名为
`NativeTrajectory.dylib`。只注入这一个文件，不要再同时注入旧版。

## 0.1.9.4.1 无黄线版

- 不再绘制黄色母球碰前路线。
- 保留青色母球碰后路线和粉色目标球路线。
- 黄色路线仍在内部参与首碰选择和日志记录，碰撞结果不受影响。

## 0.1.9.4 sret 写入验证探针

- 0.1.9.3 的实机日志确认：33 次直接 ARM64 调用均返回四段零结构，不能仅凭零初始化判断函数是否实际写回返回缓冲区。
- 本版先用本地 `0xA5` 哨兵填充返回体，记录 `native_direct_sret_changed_bytes`；再直接调用 `CollisionInfoFinal.ValidCount`，记录 `native_direct_collision_valid_count`。
- 这一步只区分 ABI/返回缓冲区路径与接口语义，不切换正式绘制，不写入游戏状态；`.github` 保持不变。

## 0.1.9.3 ARM64 sret 原生返回探针

- `getAllCollisionDataFinalSimple` 现改为直接走 ARM64 的大结构 `sret` 返回；不再通过 `runtime_invoke` 对返回值装箱。
- 原生 `OneCollisionDataFinal` 的 `ballIndex` 按最高位有效标志、低 31 位球号解析；日志保留原始值、有效位、解码球号、缓冲区字节数和 getter 计数。
- CSV 新增 `native_direct_sret_used` 与 `native_direct_valid_count`。正式青/粉线保持旧路径，只有确认原生路线可稳定解析后才切换。
- 仍是只读 10Hz 探针：不调用 `simulate/onShoot/setAllBallData`，不写游戏状态；`.github` 未改，继续手动构建。

## 0.1.9.2 原生路线布局探针

- 修正原生物理坐标与 Transform 的比较：先应用 `coordinateScale` 和
  `coordinateOffset`，再计算逐球误差。
- 新增 `CollisionInfoFinal.GetAllValidCollisionData()` 解析，按 IL2CPP 值类型数组的
  内联 `0x58` 元素读取最多四条路线。
- `GetCollisionData()` 不再无条件跳过 `0x10`；同时记录返回地址本体和确认过对象头后的
  boxed payload，并用 `IsValid/TrajectoryPointCount/CollisionPointCount` 交叉验证。
- CSV 新增 managed array、候选布局、getter 计数和最终选源字段。原生路线解析成功前不切换
  正式青/粉绘制。
- 仍为只读 10Hz 探针，不调用 `simulate/onShoot/setAllBallData`；`.github` 未修改，继续手动编译。

## 0.1.9.1 原生物理状态与返回解析探测

- 保留 `PhysicsEx.PhysicsCall.getAllCollisionDataFinalSimple` 的只读 10Hz 调用。
- 新增 `getBallCount/getBallType/getBallPos/getBallSpeed` 只读探测，将原生物理球位与
  Transform 球位逐球对照，确认当前物理后端是否已同步。
- 使用 `CollisionInfoFinal.ValidCount` 与 `GetCollisionData()` 读取托管返回值，并通过
  `il2cpp_value_box + runtime_invoke` 调用 `ArrayBuffer.ToArray()`；同时记录四条原始 route header。
- 不调用 `simulate/onShoot/setAllBallData`，不写入游戏球位；青/粉绘制仍保持上一版，
  先用日志判断 `empty` 来自物理状态还是返回结构解析。
- 实测界面满力显示 506，但内部 `shootInfo.fForce` 为 5.05；后续以内部值为准。

## 0.1.9.0 原生物理接口探测

## 0.1.8.9.1 八球稳定版、按钮调节

- 移除斯诺克22球路径，运行时只枚举 `Ball_0_H`～`Ball_15_H`。
- 预测只使用实时Transform球位；`shootInfo.xPosList/yPosList` 仅写入诊断日志，不再覆盖当前球坐标。
- 碰库固定在黄色虚线外边界后折射。
- 角度1、角度2均使用 `－ / ＋` 调节，每次 `0.50°`，范围 `-30.00°～+30.00°`，点击立即生效并保存。
- 角度2可选择联动角度1或独立调整；联动时角度2按钮自动禁用。
- 折射次数使用 `－ / ＋` 调节，范围 `1～6`，不再显示数字键盘和“应用”按钮。
- Crosshair目标球搜索限制在 `2.8×球半径` 内，避免锁到无关球。

## 0.1.8.9 实验版（已撤回）

- 该实验版曾尝试支持斯诺克22球。实测确认 `shootInfo.xPosList/yPosList` 是开局/击球快照而不是逐帧实时球位，因此已禁止其参与预测。
- 角度1用于第一次碰库；角度2用于第二次及后续碰库。开启“二角联动”时，角度2自动跟随角度1。
- “碰库线：虚线”让预测线到黄色桌面外框后再折射；“碰库线：球心”保持旧版在绿色内缩线折射。新版默认选择黄色虚线。
- 日志新增模式、球坐标来源、22球映射、Crosshair、`_lastDir`、游戏白线方向、击球阶段、三条完整预测路线和当前轨迹参数。
- `.github/workflows/build-ios.yml` 仍只有手动 `workflow_dispatch`，不会因上传文件或提交代码自动编译。

## 0.1.8.8.2 手动反射参数

菜单可输入反射开合角 `-30.00° ~ +30.00°` 和最大碰库次数 `1 ~ 6`，点击“应用”立即生效并保存。
`0.00° / 1次` 与 0.1.8.8 原始两段轨迹完全一致；正角度让反射更贴库，负角度让反射更接近垂直离库。
菜单底部实时显示运行时桌长、桌宽、开合角和碰库次数。所有多段路线进入袋口后都会停止继续反射。

## 0.1.8.8 物理桌边

有效 `PhysicsCoordinate` 现在优先于六袋口外接矩形。`DAI_Rx/DAI_Ry` 作为完整宽高，乘
`gCoordScale` 后除以二得到外边界；轨迹计算再向内缩进一次 `BALL_SCREEN_R`。打开“标记”时，黄色虚线是外边界，
绿色实线是球心实际碰库线。日志会记录 `bounds_source`、`table_*` 和 `rail_*` 字段。

## 0.1.8.7 物理边界诊断

本版只读获取 `Plugin.Physics.PocketAIModel` 的 `m_edgeInfos` 和 `m_holeInfos`，不调用
`InitHoleAndEdgeInfo()`，也不修改游戏物理状态。打开“标记”后，紫色线表示 `EdgeInfo` 库边，橙色短线和圆点表示
`HoleInfo` 袋角与袋心；原有青色六袋口外接矩形保留用于对照。CSV 新增 `physics_*`、`coord_*` 和
`ball_screen_radius` 字段。请在练习环境记录约 10 秒，并同时保存完整横屏截图与 CSV/TXT。

腾讯桌球 iOS 3.61.0 / Unity 2022.3.28f1 的离线、训练与授权测试轨迹可视化原型。

项目不保存堆地址或 Instance ID。每次启动后，它会重新解析 UnityFramework 的
IL2CPP API，并按程序集、类型及字段重新获取运行时对象。

## 当前数据路径

1. 动态定位 `Main Camera`，调用 `Camera.WorldToScreenPoint`。
2. 读取 `PocketBallUI._holdTransformArr`，缓存六个袋口与16个球的 Transform。
3. 每帧读取 `PocketCueUI.shootInfo.xPosList/yPosList` 作为日志诊断，但不参与预测。
4. 若缓存尚未初始化，枚举包含 `ball_0`～`ball_15` 索引的 Transform 兜底。
5. 优先读取 Crosshair 方向，失败时回退 `PocketCueUI._lastDir`。
6. 读取 `PhysicsCoordinate` 的桌面尺寸、坐标缩放、偏移与球半径。
7. 在桌内二维坐标中寻找射线上最先碰到的球，计算母球碰前、碰后及目标球多段路线。
8. 使用透明 UIKit 覆盖层绘制，不修改游戏物理或网络数据。

## GitHub Actions 云编译

不要上传 IPA、Dump、账号数据或其他游戏文件。仓库只需要本目录中的源码。

1. 在 GitHub 创建一个空的 Private repository。
2. 将本目录所有文件上传到仓库根目录，包括 `.github/workflows/build-ios.yml`。
3. 打开仓库的 **Actions** 页面。
4. 选择 **Build iOS arm64 dylib**，点击 **Run workflow**。
5. 构建完成后，在该次任务底部下载 `PoolTrajectoryLab-arm64`。
6. 解压后得到 `PoolTrajectoryLab.dylib`，其最低系统版本为 iOS 13，架构为 arm64。

不需要 Apple Developer 证书。云端构建会对 dylib 做 ad-hoc codesign。

## 首次校准

用 TrollFools 注入 dylib 后，先在离线或训练环境启动游戏：

- `预测：开/关` 控制轨迹。
- `标记：开/关` 控制估算桌框、球心圆圈和球号。
- 青色圆圈应落在母球中心。
- 绿色圆圈应落在其他球中心。
- 紫色圆圈表示当前检测到的目标球。
- 黄色线是母球碰前路线，青色线是母球碰后路线，紫色线是目标球路线。

第一次运行请保留“标记：开”，截取完整横屏画面。若状态停在等待阶段或球心有偏移，
同时提供屏幕录制；若闪退，提供 iOS“分析与改进 → 分析数据”中的对应崩溃日志。

## 当前限制

- 桌框橙色虚线目前使用 iPhone 13 Pro 横屏画面的初始估算值；物理碰撞边界优先读取
  `PhysicsCoordinate`，不会依赖这条虚线。
- 首包用于验证 Runtime API、字段名、坐标轴和投影。不同场景或资源版本可能需要增加
  对象命名兜底。
- 当前模型按等质量球的二维理想碰撞计算，未加入旋转、塞、摩擦、袋口圆角和游戏随机量。

## 版本记录

- `0.1.1-overlay-window`：覆盖层改为独立的高层透明 `UIWindow`，不再依附启动页
  的 Unity 窗口，修复启动画面显示后进入游戏消失的问题；窗口不会成为 key window，
  仅两个中文按钮接收触摸，其余区域继续穿透给游戏。
- `0.1.2-table-scale`：加入“桌框－ / 桌框＋”实时缩放按钮，范围 70%～110%，
  每次调整 2%，结果写入 `NSUserDefaults` 并在重启后保留；默认桌框缩小为 94%。
- `0.1.3-one-rail`：增加一次碰库反射。母球未直接碰球时会画到第一库、反射后继续
  搜索目标球；母球碰球后的残余路线和目标球路线也会在首次碰库后绘制反射段。
- `0.1.4-six-pockets`：根据设备截图重新确认 `_holdTransformArr[0..5]` 是六个袋口
  锚点而不是 0～5 号球。覆盖层现在用这六个运行时锚点动态绘制桌面方框和六个洞，
  不再显示混乱的球号圆圈；真正的球只从 `Ball_0_H`～`Ball_15_H` Transform 枚举。
  预测默认关闭，先完成桌框和袋口校准。
- `0.1.5-anchor-layout`：进一步按设备证据修正 `_holdTransformArr` 布局为
  `[0..5]=六袋口、[6..21]=0～15号球`，解决 1～5 号球没有标记的问题；增加独立
  “球标：开/关”按钮，预测仍默认关闭。
- `0.1.6-promotion`：修复覆盖层被主动限制在 8～15Hz、首选 10Hz 导致的拖影。
  iOS 15+ 现在请求 60～120Hz、首选 120Hz；IL2CPP Camera/对象枚举改为每 750ms
  刷新缓存，每帧只读取已缓存 Transform 和投影，避免高刷下重复遍历对象。
  状态栏增加实测“刷新:xxHz”。实际最高刷新率仍取决于游戏本身的帧率和 iOS 调度。
- `0.1.7-floating-menu`：启动时只显示“菜单”悬浮按钮，预测、标记、球标和运行状态收进可展开面板。
  桌框调节改为独立输入长/宽百分比：长控制左右 X，宽控制上下 Y，范围 50～120；点击“应用”后
  立即绘制并写入 `NSUserDefaults`，重启继续使用。数字键盘打开时覆盖层临时成为 key window，收起菜单后
  自动把焦点还给 Unity 游戏窗口，面板外区域继续触摸穿透。
- `0.1.8-calibrated-rails`：预测边界不再使用比例不匹配的 `PhysicsCoordinate` 常量，改为每帧根据六个袋口的
  世界坐标建立桌面边界，并应用长/宽校准后计算碰库；绘制时再按校准桌框裁剪，预测线不会显示到桌外。
  长、宽和洞径均支持最多两位小数，六个袋口的洞径统一可调（50～200%）。菜单按钮支持拖动，面板自动跟随、
  自动避开屏幕边缘，松手后保存位置。
- `0.1.8.1-crosshair-pocket-screen`：保持菜单按钮单独显示、预测/标记/球标默认关闭。瞄准方向改为优先读取
  游戏白线使用的 `_crosshairTransform`，只有准星不可用时才回退 `_lastDir`；准星方向禁止反向自动择球。
  入袋停止改在 `WorldToScreenPoint` 后按校准后的六袋口圆裁剪，任一路线进入袋口后取消其下一段反弹。
- `0.1.8.2-crosshair-impact`：游戏白圈附近存在目标球时，不再用插件半径重新做首次射线碰撞，而是把
  `_crosshairTransform` 直接作为母球碰撞中心，并选择白圈附近最近的前方球作为目标。黄线精确止于白圈，
  青色母球余速线和粉色目标球线从该确定碰撞几何重新计算；白圈附近无球时继续使用普通碰库预测。
- `0.1.8.3-shot-hide`：每帧读取 `PocketCueUI._isShowLine`。游戏处于瞄准阶段时允许计算和绘制预测；击球后
  游戏关闭白色瞄准线的同一时刻，插件立即停止计算并隐藏黄/青/粉预测线，下一次瞄准恢复时自动重新显示。

## 本地/云端命令

```bash
make test       # 纯 C++ 几何测试
make dylib      # 使用当前 Xcode 的 iPhoneOS SDK 编译 arm64 dylib
make package    # 测试、编译、签名、计算 SHA-256 并压缩
```

## 0.1.8.5 数据日志

展开菜单后可使用“开始记录 / 停止记录 / 导出日志 / 清空日志”。单次记录最多 90 秒，采样上限为 60Hz。
日志保存在应用沙盒的 `Documents/PoolTrajectoryLab/Logs`，每次生成一个 CSV 和一个同名 TXT；点击“导出日志”
会打开 iOS 系统分享面板。开始记录后再调整力度，击球并等待球停止，然后停止并导出。

`0.1.8.6-ui-log-fix` 删除长、宽、洞径输入，桌面边界继续直接读取六个袋口运行时锚点。日志导出改为
系统文件选择器，可将同名 CSV/TXT 直接保存到“文件”应用；若系统界面仍不可用，也可从应用沙盒的
`Documents/PoolTrajectoryLab/Logs` 取出。
