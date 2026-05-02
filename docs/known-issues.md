# Known Issues — Cutti

记录当前已知的 bug / 体验问题,按优先级列。

## P1 — Timeline 对不齐

**现象:** 时间轴上的片段边界、playhead、刻度之间对不齐,有视觉漂移。

**相关近期提交:**
- `afbea72 debug(timeline): only print layout/ui-seg log when segments change`
- `1b0212e debug(timeline): log per-segment UI cumulative start`
- `9cac938 fix(timeline): V1 pill visual must not exceed its layout slot`
- `16015cf fix(timeline): quantize pill widths to composition 1/600s timebase`
- `5858159 debug(timeline): log layout self-check numbers (...)`

**怀疑点:** 小数累加导致的亚像素漂移;pills / ticks / playhead 各自算 px 没统一量化到 1/600 时基。

## P1 — Timeline thumbnail 压缩比例不对

**现象:** 时间轴上每段的首帧缩略图纵横比被错误拉伸/压扁。

**怀疑点:** 缩略图生成时写死了目标宽高,没读原片 presentationSize;或者 `SegmentFirstFrameThumbnailView` 的 `aspectRatio`/`contentMode` 不对。

## P1 — 整体卡顿,需要性能优化

**现象:** 编辑器整体偏卡 —— 滚动、拖拽、输入响应都有肉眼可感的延迟。

**怀疑点(待查):**
- `MediaCoreViewModel` 是一个 5800+ 行的单体 ObservableObject,任意字段变化都触发大范围 SwiftUI 重建。
- 时间轴缩略图 / PiP overlay / 转写字幕都在主线程做 `AVAsset` 取帧 / string 测量。
- `AppleSilicon*` 代码路径可能重复初始化 proxy / WhisperKit 栈。

---

## 根因定位(2026-04-21 Explore 报告)

### Timeline 对不齐 — 7 处量化漂移(全部在 `TimelineDock.swift`)
所有涉及 `秒 × PPS → 像素` 的计算必须统一过 `quantizedSeconds()`,且**累加量本身要保持已量化**,否则 subtitle / detached audio / overlay 的位置会跟 V1 pill 对不齐。

| # | 位置 | 问题 |
|---|---|---|
| 1 | `TimelineDock.swift:1694-1695` | overlay 音频波形 `x / w` 用原始秒 |
| 2 | `TimelineDock.swift:2279` | V1 pill HStack 累加(间接受上游未量化影响) |
| 3 | `TimelineDock.swift:2631-2632` | detached 音频 pill `x / segWidth` 用原始秒 |
| 4 | `TimelineDock.swift:2763-2769` | subtitle pill `composedStart/End` 累加未量化 |
| 5 | `TimelineDock.swift:2860-2863` | subtitle 拖拽像素坐标用未量化字段 |
| 6 | `TimelineDock.swift:3248` | playhead normalizer 的分母用未量化 `totalDuration` |
| 7 | `TimelineDock.swift:3305-3306` | Filmstrip Canvas 遮罩 `startSeconds × pps` 未量化 |

### Thumbnail 压缩比例不对
- `PosterThumbnailView.swift:49` 用了 `.scaledToFill()`,**应改 `.scaledToFit()`**
- `TimelineDock.swift:3627` 的 `SegmentFilmstrip.thumbWidth` 硬编码 16:9,竖屏/方形视频被强行拉伸。需要读 `AVAsset.naturalSize` × `preferredTransform` 算真实 AR

### 卡顿 Top-5 性能点
1. **`TimelineDock.swift:944-965`** — GeometryReader 里每次 body 重算都跑 O(n) 的 `pillSum` 累加 + 遍历 segments。滚动时每帧触发。→ 用 `@State` 缓存签名,签名不变时跳过。
2. **`TimelineDock.swift:3648`** — `SegmentFilmstrip .task` 以 `Int(width)` 为 key,pan 时每像素变化都重跑 `AVAssetImageGenerator`。50 段 × 5 帧 = 250 次/手势。→ 对 width 取 bucket(32px 一档)或加 debounce。
3. **`TimelineDock.swift:2798`** — `composedSubtitlePills()` 每次 body 重算;500 条字幕排序+去重=每帧 O(n log n)。→ 依赖 `segments`/`composedSubtitles` 用 `@State` 记忆化。
4. **`TimelineDock.swift:3512-3566 / 3658-3684`** — `AVAssetReader` 读完整音频不可打断,pan 快时任务堆积。→ 在 for 循环里加 `try Task.checkCancellation()` / `await Task.yield()`。
5. **`MediaCoreViewModel.swift:24-178`**(30+ `@Published`)—— 太宽的 ObservedObject 订阅导致无关属性变化都重建 TimelineDock 子树。→ **留到 Phase 2**,本轮先在 `TimelineDock` 顶部套 `Equatable` view / `.equatable(by:)`,只关心自己在意的几个字段。

---

## 实施计划

**Team: `cutti-bugfix`** · 两名 teammate 并行:

- `timeline-doctor` —— 独占 `TimelineDock.swift`,按序提交:① alignment 7 处 → ② SegmentFilmstrip 真实 AR → ③ perf #1-#4(debug 循环、filmstrip bucket、subtitle 记忆化、cooperative cancel)。
- `poster-qa` —— 改 `PosterThumbnailView.swift:49`;跑 `swift build` 验证;产出 `MediaCoreViewModel` @Published 订阅审计(Phase 2 依据)。

Phase 2(后续):基于审计文档拆 MediaCoreViewModel 或引入 `.equatable` 视图边界。
