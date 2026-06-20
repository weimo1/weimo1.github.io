---
title: TAA
date: 2026-06-20
categories:
  - ["计算机图形学", "渲染技术"]
publish: true
---

# TAA

> 适用范围：时间抗锯齿（Temporal Anti-Aliasing）——利用多帧信息的后处理抗锯齿技术，是现代延迟渲染管线的主流 AA 方案。

## 写作约束（铁律）

- **原内容一字不删**
- **只做归纳重组+增加**
- **放不进的进附录**
- **动笔前先搜索**
- **字数硬指标**：详细解析(二)≥200字、进阶应用(四)≥500字、源码解析与实践感悟(五)≥1000字、面试准备(六)高频问法≥8个且带回答，反问点和一句话答案各≥5个。
- 先结论后细节，每节至少3条要点。
- **代码块必须标注语言**。
- 图示统一放在 `资源/图片/`。

## 一、核心概念

- 定义：TAA（Temporal Anti-Aliasing）在时间维度上累积多帧信息实现抗锯齿——每帧通过亚像素抖动（Jitter）产生微小偏移，利用运动向量（Motion Vector）将历史帧重投影到当前帧，经方差裁剪（Variance Clipping）和邻域 clamp 防止鬼影后混合。
- 关键词：Jitter、Motion Vector、重投影、邻域裁剪、鬼影/Ghosting、闪烁/Flickering、YCgCo、AABB Clamp
- 适用场景/边界：延迟渲染管线的后处理 AA；不适用于快速运动场景（运动向量失效）、半透明物体（无运动向量）、粒子系统

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：从 SSAA 到 TAA**

SSAA（Super-Sample AA）渲染 4 倍分辨率再降采样——效果最好但性能不可接受。TAA 将 4 倍采样的空间分布"分摊"到 4 帧时间维度：

| 技术 | 原理 | 性能开销 | AA 质量 |
|------|------|----------|---------|
| SSAA | 4× 分辨率渲染 | 4× ALU + 4× 带宽 | 最佳 |
| MSAA | 边缘多采样，像素着色 1 次 | 带宽大，延迟渲染不支持 | 边缘好 |
| TAA | 每帧抖动采样，时域累积 | 一个后处理 Pass | 整体好（有鬼影风险） |

**第二层：TAA 核心流程**

1. **Jitter**：每帧对投影矩阵做亚像素偏移（Halton/蓝噪声序列），使采样点覆盖像素不同位置
2. **Motion Vector**：计算每个像素从上一帧到当前帧的屏幕空间位移
3. **重投影**：当前帧 UV - Motion Vector → 历史帧 UV，采样历史颜色
4. **邻域 Clamp**：在 YCgCo 空间对历史颜色做 AABB 裁剪（当前像素 3×3 邻域 min/max）
5. **时间混合**：`result = mix(historyColor, currentColor, blendFactor)`，blendFactor 约 0.05-0.1

**第三层：为什么 MSAA 不适用于延迟渲染**

延迟渲染的 GBuffer 阶段只存每个像素的一个样本值（位置、法线、颜色），丢失了子像素覆盖信息。光照阶段无法判断哪些子 Sample 属于同一三角形，插值深度/法线会产生错误结果。因此现代延迟渲染管线几乎全部采用 TAA。

### 关键公式

运动向量计算（Motion Vector Pass）：

```glsl
vec4 clipPosPrev = prevViewProj * worldPos;
vec4 clipPosCurr = currViewProj * worldPos;
vec2 ndcPrev = clipPosPrev.xy / clipPosPrev.w;  // [-1, 1]
vec2 ndcCurr = clipPosCurr.xy / clipPosCurr.w;
vec2 motionVector = (ndcCurr - ndcPrev) * 0.5;  // [-1, 1] → UV space
```

## 三、动手实践（代码案例）

### 3.1 Jitter — Halton 序列

```glsl
vec2 getJitterOffset(int frameIndex, vec2 resolution) {
    float x = halton(frameIndex, 2) - 0.5;  // 基2, [-0.5, 0.5]
    float y = halton(frameIndex, 3) - 0.5;  // 基3
    return vec2(x, y) / resolution;          // 归一化到像素空间
}
```

### 3.2 Motion Vector Pass

```glsl
// 顶点着色器
attribute vec4 a_Position;
uniform mat4 u_LookAt;        // 当前帧 VP
uniform mat4 u_LookAtLast;    // 上一帧 VP
varying vec4 v_P;
varying vec4 v_lastP;

void main() {
    v_lastP = u_LookAtLast * a_Position;
    gl_Position = v_P = u_LookAt * a_Position;
}
```

```glsl
// 片元着色器
varying vec4 v_P, v_lastP;
void main() {
    vec2 newXY = v_P.xy / v_P.w;          // NDC [-1,1]
    vec2 oldXY = v_lastP.xy / v_lastP.w;
    gl_FragColor = vec4((newXY - oldXY) * 0.5, 0.0, 1.0);
    // 公式简化：NDC→UV映射的 +0.5 和 *0.5 相互抵消
}
```

### 3.3 TAA 主 Pass — 核心绑定

```glsl
layout(set=0,binding=0) uniform UniformFrameData { PerFrameData frameData; };
layout(set=0,binding=1) uniform texture2D inHDRSceneColor;    // RGBA16F
layout(set=0,binding=2) uniform texture2D inSceneDepth;       // D32
layout(set=0,binding=3) uniform texture2D inVelocity;         // RG16
layout(set=0,binding=4) uniform texture2D inAdaptedLumTex;    // R16F
layout(set=0,binding=5,rgba16f) uniform writeonly image2D outTAAImage;
layout(set=0,binding=6) uniform texture2D inHistory;          // RGBA16F
```

### 3.4 邻域 Clamp（AABB 裁剪）

```glsl
// 在 YCgCo 色彩空间做 clamp（比 RGB 更准确）
vec3 RGBToYCgCo(vec3 rgb) { /* ... */ }
vec3 YCgCoToRGB(vec3 ycgco) { /* ... */ }

// 3×3 邻域统计 min/max
vec3 minColor = currentColor;
vec3 maxColor = currentColor;
for (int dx = -1; dx <= 1; dx++) {
    for (int dy = -1; dy <= 1; dy++) {
        vec3 neighbor = texture(currentFrame, uv + vec2(dx,dy) * texelSize).rgb;
        minColor = min(minColor, neighbor);
        maxColor = max(maxColor, neighbor);
    }
}

// AABB 扩展（抗闪烁强度控制）
vec3 boxCenter = (minColor + maxColor) * 0.5;
vec3 boxExtent = (maxColor - minColor) * 0.5 * (1.5 + antiFlickerIntensity);
minColor = boxCenter - boxExtent;
maxColor = boxCenter + boxExtent;

historyColor = clamp(historyColor, minColor, maxColor);
```

### 3.5 时间混合

```glsl
float blendFactor = kBaseBlendFactor;  // 约 0.05-0.1
vec3 result = mix(historyColor.rgb, currentColor.rgb, blendFactor);
color = clamp(result, vec4(0.0), vec4(kMaxHalfFloat));
imageStore(outTAAImage, workPos, color);
```

## 四、进阶应用（≥500字）

### 与其他主题的关联

- **SSAO/SSR**：TAA 可消除 SSAO 和屏幕空间反射的噪声——蓝噪声 + TAA 是 SSAO 降噪的标配
- **PBR**：PBR 高光的镜面 aliasing（高粗糙度 GGX 边缘闪烁）只能靠 TAA 缓解，MSAA 无效
- **DLSS/FSR/XeSS**：TAA 是超分技术的"前身"，DLSS 的输入就是 Jitter + Motion Vector + Depth + Color，本质是 AI 增强版 TAAU

### 工程中的真实用法

- **UE5 TSR（Temporal Super Resolution）**：UE5 的 TAAU 超分方案，内置 TAA，使用更复杂的时域累积（包含深度权重、运动置信度）
- **Unity HDRP TAA**：基于 AABB Clamp + 动态混合因子，支持 YCoCg 空间处理
- **Decima Engine（Death Stranding）**：TAA + 锐化 + 动态分辨率缩放

### 抗闪烁强度系统参数详解（补充）

```
antiFlicker = 0.0 → intensity = 0.0  → AABB 扩展 = 1.5×标准差（严格 clamp，可能有 flicker）
antiFlicker = 0.5 → intensity = 1.75 → AABB 扩展 = 3.25×标准差
antiFlicker = 1.0 → intensity = 3.5  → AABB 扩展 = 5.0×标准差（宽松 clamp，消除 flicker 但可能 ghosting）
```

对比度阈值 `kContrastForMaxAntiFlicker`：高值（0.7）→ 高对比度才启动最强抗闪烁→保留细节；低值（0.4）→ 低对比度就启动→强抗闪烁。

### 常见优化策略

- **半分辨率 Motion Vector**：MV 用半分辨率 + bilinear upsample，精度损失可接受
- **Catmull-Rom 过滤历史采样**：比 bilinear 锐利，减少 TAA 固有的模糊
- **动态混合因子**：运动大 → blendFactor 增大（更相信当前帧）；静止 → blendFactor 减小（累积更多历史帧）

## 五、源码解析和实践感悟（≥1000字）

### 关键实现路径：YCgCo 色彩空间的 Clamp

在 RGB 空间直接 clamp 的问题：RGB 通道相关性高，单独 clamp 某个通道可能改变色相。YCgCo 将亮度（Y）与色度（Cg, Co）分离，clamp 更合理的物理含义。

```glsl
vec3 RGBToYCgCo(vec3 rgb) {
    float Y  =  0.25 * rgb.r + 0.5 * rgb.g + 0.25 * rgb.b;
    float Cg = -0.25 * rgb.r + 0.5 * rgb.g - 0.25 * rgb.b;
    float Co =  0.5  * rgb.r             - 0.5  * rgb.b;
    return vec3(Y, Cg, Co);
}
```

### 难点与易错点

**陷阱1：Motion Vector 的精度**

Motion Vector 存储在 RG16F 中（每通道 16-bit float）。对于高速运动的物体（如赛车游戏），MV 可能超出 [-1,1] 范围，导致历史 UV 采样到无效区域。解决方案：加大 MV buffer 范围或 clamp 到 border color。

**陷阱2：TAA 后的锐化位置**

锐化必须在 TAA 之后、UI 之前。如果锐化在 TAA 之前，会放大子像素锯齿；如果在 UI 之后，UI 文字会被过锐化。正确顺序：Scene → TAA → Sharpen → UI。

**陷阱3：Dithering 透明度与 TAA 的交互**

大量粒子效果使用 dithering（噪声阈值丢弃）模拟半透明，但 dithering noise 会被 TAA 错误地时域累积——粒子边缘变成"拖尾"而非透明。解决方案：对 dither 区域做 TAA mask 降低 blendFactor。

### 经验总结（补充）

1. **TAA 是"用模糊换平滑"**：TAA 本质上用时间域模糊替代空间域锯齿。锐化 pass 是 TAA 不可分割的一部分——没有锐化的 TAA 画面会明显发糊
2. **Jitter 序列的选择很重要**：Halton (2,3) 覆盖均匀但低帧数时有规律性伪影；蓝噪声视觉更好但实现复杂。UE 使用 Halton + 帧数取模避免周期重复
3. **TAA 的最大敌人不是性能而是鬼影**：快速的相机旋转、运动物体、光照突变都会导致历史帧失效。AABB clamp 是兜底方案，最佳做法是给"不可靠"像素降低历史权重
4. **移动端 TAA 的特殊考量**：TBDR 架构下 Motion Vector Pass 的带宽开销相对更大，且 half-float 精度让 MV 累加误差更快

## 六、面试准备

### 6.1 高频问法（≥8个）

**基础理解：**

Q1：TAA 的核心原理是什么？

A：在时间维度上累积多帧信息——每帧用亚像素抖动偏移采样位置，通过运动向量重投影历史帧到当前帧，经邻域 clamp 防止鬼影后混合。本质是把 SSAA 的空间采样分摊到时间上。

Q2：为什么延迟渲染不能用 MSAA 而要用 TAA？

A：MSAA 需要子像素覆盖信息来判断样本属于哪个三角形，但 GBuffer 只有每像素单样本，丢失了覆盖信息。TAA 不依赖几何信息，只需颜色 + 深度 + 运动向量。

Q3：TAA 中 Jitter 的作用是什么？

A：让每帧的采样点落在像素内不同位置，若干帧后采样点覆盖整个像素区域。Jitter 使单个像素能"看到"子像素细节，再用时间累积将这些细节平均化。

**原理深入：**

Q4：TAA 中为什么在 YCgCo 空间做 clamp 而不是 RGB？

A：RGB 通道相关性高，单独 clamp 某通道会改变色相。YCgCo 将亮度 Y 与色度 Cg/Co 分离，clamp 更合理——限制色度范围不会导致色偏。

Q5：AABB Clamp 的 box 扩展参数如何影响效果？

A：扩展越小（1.5×标准差）→ clamp 越严格 → 鬼影少但可能出现闪烁（历史帧被过度裁剪）；扩展越大（5.0×标准差）→ clamp 越宽松 → 闪烁少但鬼影风险增加。

**实践应用：**

Q6：Motion Vector 如何计算？精度要求如何？

A：在 Motion Vector Pass 中计算：世界坐标 × prevVP 和 × currVP，NDC 差值 × 0.5 得到 UV 空间的位移。存储用 RG16F（每通道 16 位），精度足够大部分场景。

Q7：TAA 的 blendFactor 如何选择？

A：通常 0.05-0.1。值越小 → 历史权重越大 → AA 效果好但收敛慢；值越大 → 当前帧权重大 → 收敛快但 AA 效果差。动态调整：运动大时增大 blendFactor 减少鬼影。

Q8：TAA 有哪些无法解决的问题？

A：1) 快速运动的半透明物体（无 MV 或 MV 不准）；2) 屏幕空间效果边界（被遮挡后重现的历史残留）；3) 细线/粒子（单像素宽的特征在 Jitter 下闪烁）。

### 6.2 反问点/陷阱点（≥5个）

- 贵公司的 TAA 方案使用什么 Jitter 序列？有没有遇到过 Halton 序列在特定帧数的规律性伪影？
- 对于大量半透明粒子的场景（如烟雾弹），TAA 的 ghosting 严重吗？有做特殊处理吗？
- TAA 和 TAAU（超分）的边界在哪？你们是分开实现还是统一？

**常见陷阱：**

- 陷阱1：TAA blendFactor 给太大（如 0.5）→ 历史帧权重不足，AA 效果几乎为零，只剩下画面抖动。
- 陷阱2：锐化在 TAA 之前 → 子像素锯齿被放大后再混合，AA 完全失效。
- 陷阱3：YCgCo clamp 的 AABB 范围过窄 + 强光照变化 → 闪烁（flickering），因为历史帧被过度裁剪到当前帧邻域。

### 6.3 一句话答案（≥5个）

- TAA 的核心公式：每帧抖动 + 运动向量重投影 + 邻域 clamp + 时间混合。
- TAA 的最大优势是解决了 MSAA 在延迟渲染中的失效问题。
- AABB clamp 的本质：在 YCgCo 空间限制历史颜色不超过当前像素邻域范围。
- Jitter 序列的选择影响 AA 收敛速度：蓝噪声 > Halton > 均匀分布。
- TAA 必须搭配锐化：TAA 模糊 + 锐化恢复细节 = 近似 SSAA 效果。

**情景模拟：**

- 被问到"为什么不用 MSAA"→ "延迟渲染的 GBuffer 丢失了子像素覆盖信息，MSAA 无法工作。TAA 是唯一能在延迟管线下工作的 AA 方案。"
- 被问到"TAA 和 DLSS 的关系"→ "DLSS 可以看作 AI 增强版 TAAU——输入同样是 Jitter + MV + Depth + Color，但用神经网络替代了传统的历史混合和上采样。"

## 附录（模板外原内容收纳）

### MSAA 原理详解

MSAA 在 SSAA 基础上发展而来。以 4× 为例：

1. 光栅化阶段对四个 Sample 位置做三角形覆盖判断，记录 coverage mask
2. 像素着色阶段仅在像素中心运行一次像素着色器
3. 对四个 Sample 执行深度/模板测试，通过者写入 4× 深度/模板缓冲
4. 将像素着色结果复制到通过测试的 Sample 颜色缓冲
5. 所有绘制结束后，Resolve Pass 将四个 Sample 颜色插值得到最终像素颜色

MSAA 与 SSAA 的区别：SSAA 对每个 Sample 运行完整的像素着色器，MSAA 只运行一次。MSAA 的所有缓冲区变为 4× 大小，显存和带宽消耗大。

### 延迟渲染为何不能使用 MSAA

延迟渲染的 GBuffer Pass 只有每个像素的单一样本，丢失了三角形覆盖信息和多采样深度值。在光照阶段无法判断哪些子 Sample 与中心像素在同一三角形上，对深度和法线插值会导致错误结果。

### TAA 核心思想（总结）

TAA 核心思想是在时间维度上累积多帧信息：
1. 每帧通过亚像素抖动（Jitter）产生微小偏移
2. 将当前帧与历史帧在运动补偿后进行混合
3. 通过方差裁剪（Variance Clipping）防止鬼影

### 抗闪烁强度系统参数（原笔记详细推导）

`kAntiFlickerIntensity` 从用户 0-1 滑条映射到 0.0-3.5 物理值，控制 AABB 扩展倍数（= 1.5 + intensity）。对比度阈值 `kContrastForMaxAntiFlicker = 0.7 - mix(0.0, 0.3, smoothstep(0.5, 1.0, antiFlicker))`，高值保留细节，低值强抗闪烁。

### 参考资料

- [Vulkan TAA 实现与细节](https://qiutang98.github.io/post/图形硬件api/vulkan-taa实现与细节/)
