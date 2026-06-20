---
title: SSAO
date: 2026-06-20
categories:
  - ["计算机图形学", "渲染技术"]
publish: true
---

# SSAO

> 适用范围：屏幕空间环境光遮蔽（SSAO/HBAO）——在屏幕空间模拟间接光照中的环境光遮挡效果，是实时渲染中"穷人版全局光照"的核心组件。

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

- 定义：SSAO（Screen Space Ambient Occlusion）在屏幕空间以当前像素法线为轴，在其指向的半球空间内生成随机采样点，将采样点深度值与深度缓冲比较，统计被遮挡比例，计算出该点的环境光遮蔽强度。HBAO（Horizon-Based Ambient Occlusion）是其增强版，通过计算地平线角度做半球积分。
- 关键词：HBAO、屏幕空间、深度缓冲、地平线角、半球积分、蓝噪声、平面相交优化
- 适用场景/边界：实时渲染中低成本的间接光照近似；本质是屏幕空间方法——屏幕外几何体不会产生遮蔽，不适用于需要精确 GI 的场景。

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：基本工作原理**

SSAO 的核心思路：对于屏幕上的每个像素，在它的周围半球空间采样若干点，如果采样点的深度比深度缓冲中的对应值更远（被遮挡），则增加遮蔽。

**第二层：HBAO 多切片算法流程**

1. 从 GBuffer 获取当前像素的世界坐标、法线、视线方向
2. 使用蓝噪声生成随机旋转角度，避免带状瑕疵
3. 计算自适应采样半径（远距离大半径，近距离限制最大半径）
4. 循环多个切片（slice），每个切片代表一个采样方向：
   - 将 3D 问题投影到该切片的 2D 平面
   - 沿正反两个方向做步进采样（平方分布，近处采样点更密集）
   - 对每个采样点计算地平线角度余弦 `sampleCos`
   - 取最大的余弦值（即最小的角度 = 最高的遮挡物）
5. 如果当前采样点比之前的地平线更高，触发平面相交优化
6. 用 `integrateHalfArc` 做半球积分，得到该切片的遮蔽贡献
7. 对所有切片取平均，apply power + intensity 后处理

**第三层：地平线积分的数学原理**

半球内某方向的遮蔽效果取决于地平线角度 \(h\) 和法线角度 \(n\)：

\[
\text{integrateHalfArc}(h, n) = \frac{\cos(n) + 2h \cdot \sin(n) - \cos(2h - n)}{4}
\]

这个函数计算从法线角到地平线角的半球面积比例，返回值 0-1（0=无遮蔽，1=完全遮蔽）。

### 关键数据结构

- **GBuffer**：深度缓冲（重建世界坐标）、法线纹理（确定遮挡半球方向）
- **蓝噪声纹理**：128×128，为每个像素提供随机旋转角度和偏移
- **SSAO 纹理**：单通道 R8 或 R16F，存储 0-1 的遮蔽值

## 三、动手实践（代码案例）

### 3.1 初始化与 GBuffer 采样

```glsl
ivec2 workPos = ivec2(dispatchId);
vec2 uv = (vec2(workPos) + vec2(0.5f)) * texelSize;

float depth = texture(sampler2D(inDepth, pointClampEdgeSampler), uv).r;
if (depth <= 0.0) {
    imageStore(imageSSAO, workPos, vec4(1.0)); // 背景 → 无遮蔽
    return;
}
vec3 worldNormal = unpackWorldNormal(inGbufferBValue.rgb);
vec3 worldPos = getWorldPos(uv, depth, frameData);
vec3 worldEyeDir = normalize(frameData.cameraPos - worldPos);
```

### 3.2 蓝噪声采样

```glsl
float noise_x = samplerBlueNoiseErrorDistribution_128x128_OptimizedFor_2d2d2d2d(...);
float noise_y = samplerBlueNoiseErrorDistribution_128x128_OptimizedFor_2d2d2d2d(...);
```

### 3.3 自适应采样半径

```glsl
float linearDepth = length(worldPos - frameData.cameraPos);
float sliceUvRadius = frameData.postprocessing.ssao_uvRadius / linearDepth;
sliceUvRadius = min(sliceUvRadius, maxDu * kSSAOMaxPixelScreenRadius);
// 远处大半径，近处限制最大半径（防止纹理缓存失效）
```

### 3.4 多切片遍历

```glsl
for (int sliceIndex = 0; sliceIndex < ssao_sliceCount; sliceIndex++) {
    float sliceAngle = ((sliceIndex + noise_x) * sliceCountInverse) * kPI;
    vec2 sliceUvDir = vec2(cos(sliceAngle), -sin(sliceAngle)) * sliceUvRadius;

    // 3D→2D 投影
    vec3 sliceWorldDir = ...;
    vec3 orthoWorldDir = sliceWorldDir - dot(sliceWorldDir, worldEyeDir) * worldEyeDir;
    vec3 projAxisDir = normalize(cross(orthoWorldDir, worldEyeDir));
    vec3 projWorldNormal = worldNormal - dot(worldNormal, projAxisDir) * projAxisDir;
}
```

### 3.5 双向步进采样

```glsl
for (int sideIndex = 0; sideIndex < 2; ++sideIndex) {
    float prevHorizonCos = cos(projWorldNormalAngle + sideSigns[sideIndex] * kPI * 0.5);
    float horizonCos = prevHorizonCos;

    for (int stepIndex = 0; stepIndex < ssaoStepCount; stepIndex++) {
        float sampleStep = stepIndex * stepCountInverse;
        sampleStep *= sampleStep;  // 平方分布
        sampleStep += (noise_y + 1e-5f) * stepCountInverse;

        vec2 sampleUv = uv + sideSigns[sideIndex] * sampleUvOffset;
        float sampleDepth = sampleDepthFunc(sampleUv);
        vec3 sampleWorldPos = getWorldPos(sampleUv, sampleDepth, frameData);

        vec3 horizonWorldDir = sampleWorldPos - worldPos;
        float sampleCos = dot(horizonWorldDir, worldEyeDir) / length(horizonWorldDir);

        // 取最大余弦 = 最高遮挡物
        if (sampleCos >= prevHorizonCos) {
            // 平面相交优化...
        }
        prevHorizonCos = max(prevHorizonCos, sampleCos);
    }
}
```

### 3.6 遮蔽积分与后处理

```glsl
// 半球积分
float integrateHalfArc(float horizonAngle, float normalAngle) {
    return (cos(normalAngle) + 2.0 * horizonAngle * sin(normalAngle)
            - cos(2.0 * horizonAngle - normalAngle)) / 4.0;
}

// 累加遮蔽
ambientOcclusion += projWorldNormalLen *
    integrateHalfArc(horizonAngles[sideIndex], projWorldNormalAngle);

// 平均 + 后处理
ambientOcclusion *= sliceCountInverse;
ambientOcclusion = 1.0 - (1.0 - pow(ambientOcclusion, ssao_power)) * ssao_intensity;

imageStore(imageSSAO, ivec2(workPos), vec4(ambientOcclusion));
```

## 四、进阶应用（≥500字）

### 与其他主题的关联

- **PBR/IBL**：SSAO 提供间接光照的遮挡信息，与 IBL 环境光相乘得到带遮蔽的间接漫反射
- **SSGI**：屏幕空间全局光照，SSAO 的扩展——不仅计算遮蔽，还计算光的多次弹射
- **TAA**（[TAA.md](TAA.md)）：SSAO 的噪声由 TAA 时域累积消除

### 工程中的真实用法

- **HBAO+ (NVIDIA)**：NVIDIA 的 HBAO 增强版，使用物理正确的积分模型
- **GTAO (Ground Truth Ambient Occlusion)**：Activision 的改进算法，考虑距离衰减，结果更接近 Ground Truth
- **RTAO (Ray-Traced Ambient Occlusion)**：用 DXR/Vulkan RT 做真正的光线追踪 AO，替代 SSAO 的位置

### 常见优化策略

- **半分辨率**：SSAO 以半分辨率渲染，再用 bilateral upsample 恢复——带宽和 ALU 双双减半
- **Compute Shader**：SSAO 天然适合 Compute Shader（无固定管线依赖），用 shared memory 缓存深度值
- **蓝噪声**：相比白噪声，蓝噪声的频谱集中在高频，TAA 更容易消除，收敛更快
- **平方步进**：近处采样点多、远处少——近处几何细节对遮蔽影响更大

## 五、源码解析和实践感悟（≥1000字）

### 关键实现路径：平面相交优化

当采样到一个"悬浮"几何体时，其实际高度可能被高估，导致本应被 floor/wall 遮挡的区域被判定为可见。平面相交优化将采样点投影到其所在表面的平面上：

```glsl
float intersectDirPlaneOneSided(vec3 rayOrigin, vec3 planeNormal, vec3 planePoint) {
    float denom = dot(planeNormal, worldEyeDir);
    if (abs(denom) < 1e-6) return 1.0;
    return max(0.0, dot(planeNormal, planePoint - rayOrigin) / denom);
}

// 取两个平面的最小投影距离
vec3 closestWorldPos = prevSampleWorldPos * min(
    intersectDirPlaneOneSided(prevSampleWorldPos, sampleWorldNormal, sampleWorldPos),
    intersectDirPlaneOneSided(prevSampleWorldPos, worldNormal, worldPos)
);
```

### 难点与易错点

**陷阱1：采样半径与场景尺度的关系**

`ssao_uvRadius` 是 UV 空间的采样半径，实际世界空间半径 = UV半径 × 深度。在远处深度大时采样半径变得极大（覆盖半屏），导致性能崩溃。解决方案是 `min(sliceUvRadius, maxDu * kSSAOMaxPixelScreenRadius)`。

**陷阱2：平方步进分布（补充）**

步进采样中 `sampleStep *= sampleStep` 产生平方分布：若 6 个步进点，分布为 \(0^2, (1/5)^2, (2/5)^2, ...\) = 0, 0.04, 0.16, 0.36, 0.64, 1.0。近处密集、远处稀疏——因为近处的几何变化对遮蔽影响更大。

**陷阱3：Bilateral Upsample 的 haloing 问题**

半分辨率 SSAO 上采样时，深度不连续的边界（前景物体边缘）会将背景的低精度 AO 值混合进来，产生 halo 光晕。解决：bilateral weight 中深度差异大的像素给极低权重。

### 经验总结（补充）

1. **HBAO 优于传统 SSAO 的核心原因是"地平线"概念**：传统 SSAO 随机采样，结果随机性强（noise）；HBAO 沿确定方向找"最高遮挡物"，结果更稳定
2. **`ssao_power` 和 `ssao_intensity` 的参数顺序有讲究**：`1-(1-ao^p)*i` — 先 power 拉伸对比度（保留暗部层次），再乘 intensity 控制整体强度。如果先乘后 power，暗部会被压平
3. **蓝噪声的关键优势**：白噪声在低频残留（形成明显的噪声斑块），蓝噪声能量集中在高频，TAA 一帧就能消除大部分
4. **AO 不是越强越好**：过度 AO 会让画面"脏"——暗角过重。UE 默认的 AO 强度约 0.5-0.7（不是 1.0）

## 六、面试准备

### 6.1 高频问法（≥8个）

**基础理解：**

Q1：SSAO 的基本原理是什么？

A：在屏幕空间，以像素法线为轴在半球内生成采样点，将采样点深度与深度缓冲比较，统计被遮挡比例得到遮蔽强度。核心假设：周围几何体高度（深度差）越大 → 遮挡越严重。

Q2：SSAO 和 HBAO 的区别？

A：SSAO 随机采样半球内的点，统计遮挡比例；HBAO 沿确定方向找最高遮挡物（地平线），然后做半球积分。HBAO 结果更稳定、噪声更少。

Q3：SSAO 有哪些局限性？

A：1) 屏幕空间——屏幕外的几何体不影响结果（如头顶的屋顶不会遮蔽角色）；2) 无颜色信息——不考虑间接光的颜色反弹；3) 深度缓冲精度限制——远处的深度误差导致假 AO。

**原理深入：**

Q4：HBAO 中为什么用平方步进分布？

A：近处的几何变化对遮蔽判断影响更大（近处的一堵墙 vs 远处的山），平方分布让更多采样点集中在近处，提高遮蔽精度。

Q5：`integrateHalfArc` 的数学含义？

A：在半球上计算从法线角到地平线角的面积比例。结果是 0-1 的值，表示该方向被遮挡的程度。cos/sin 的组合来自球面坐标的积分。

**实践应用：**

Q6：如何优化 SSAO 的性能？

A：1) 半分辨率渲染 + Bilateral Upsample；2) Compute Shader 替代 Pixel Shader；3) 蓝噪声减少所需采样数；4) 限制最大采样半径防止远处性能崩溃。

Q7：半分辨率 SSAO 的 Bilateral Upsample 怎么避免 haloing？

A：Bilateral 滤波在深度差异大的边界像素给极低权重，防止前景和背景的 AO 值混合。使用深度和法线双重引导。

Q8：SSAO 结果中条带瑕疵（banding）怎么解决？

A：使用蓝噪声替代白噪声：白噪声低频能量集中产生条带，蓝噪声高频分布经 TAA 后迅速消除。也可以在采样时加入随机旋转角度。

### 6.2 反问点/陷阱点（≥5个）

- 贵公司的 SSAO 方案是用 HBAO、GTAO 还是自己实现的？Profile 下来哪个环节最耗时？
- 在移动端，SSAO 开销通常是瓶颈吗？有没有用过预烘焙 AO 替代实时 SSAO？
- RTAO 在你们项目中是否已经替换了 SSAO？混合使用还是一刀切？

**常见陷阱：**

- 陷阱1：采样半径没做远处 clamp → 在远处物体（如天空盒附近的远景）上采样半径可达半屏，SSAO pass 时间爆炸。
- 陷阱2：Bilateral Upsample 只用了深度没用 normal → 同一平面上但不同朝向的面（如墙角的两面墙）可能被错误混合。
- 陷阱3：SSAO 直接乘到 diffuse 上 → 正确做法是乘到 ambient/indirect 项上，漫反射直接光照不应被 AO 影响。

### 6.3 一句话答案（≥5个）

- HBAO 比 SSAO 好的原因是：定向找地平线而不是随机采样，结果更稳定。
- SSAO 的"屏幕空间"意味着：看不到的东西不算——屏幕外、被遮挡的几何体不参与计算。
- 平方步进的原因：近处几何比远处几何对遮蔽影响更大，采样应集中在近处。
- SSAO 的 blue noise 优势：能量集中在高频，TAA 一帧消除，收敛比白噪声快得多。
- HBAO 积分公式 `integrateHalfArc` 的含义：在半球上从法线到地平线的面积比例。

**情景模拟：**

- 被问到"SSAO 为什么是黑色的"→ "因为 AO 模拟的是环境光到达不了的地方——凹角、缝隙——这些地方间接光照被遮挡，所以更暗。"
- 被问到"移动端 SSAO 怎么做"→ "半分辨率 + 4 个采样方向 + TAA 时域累积。移动端带宽紧张，宁可少采样多累积，也不做高采样率。"

## 附录（模板外原内容收纳）

> 以下为原笔记中完整的算法流程描述，原样保留。

### 总体流程概述

这是一个**HBAO（地平线遮蔽）算法的屏幕空间实现**，用于计算**环境光遮蔽（SSAO）**和可选的间接光照（SSGI）。通过分析周围像素的深度和法线信息，模拟物体间相互遮挡导致的环境光照减弱效果。

### 核心处理流程

1. **初始化阶段**：获取当前像素屏幕坐标，从 GBuffer 获取深度、世界坐标、世界法线、视线方向。如果深度为 0（背景），直接输出无遮蔽（1.0）并返回。

2. **随机噪声生成**：使用蓝噪声纹理生成随机旋转角度和偏移，消除带状瑕疵。

3. **计算采样半径**：根据当前像素线性深度和 `ssao_uvRadius` 计算采样半径 `sliceUvRadius`。对最大采样半径做限制（`kSSAOMaxPixelScreenRadius`）避免相机过近时性能下降。

4. **循环处理多个切片（slice）**：每个切片对应一个方向，计算该切片的 UV 方向和视图空间方向。将世界空间法线投影到当前切片平面。

5. **每个切片上沿正反两个方向进行步进采样**：对每个步进计算采样点 UV 坐标和深度，重建世界坐标。计算采样点与当前像素的向量与视线方向的夹角余弦 `sampleCos`。用权重混合更新地平线余弦为最大值。如果当前采样点比之前的地平线更近，触发**平面相交优化**：获取采样点法线，计算前一个采样点与当前采样点所在平面、当前像素所在平面的交点，取较近的一个重新计算地平线角度。

6. **计算当前切片的遮蔽贡献**：将正反方向的地平线角度转换为相对于投影法线的角度，使用 `integrateHalfArc` 计算半圆弧积分，乘以投影法线长度作为权重，累加到总遮蔽值。

7. **对所有切片的遮蔽值取平均**（乘以 `sliceCountInverse`）。

8. **后处理**：如果全分辨率，应用 power 和 intensity 参数进行最终调整。

9. **输出**：将遮蔽值存储到 SSAO 纹理中。

### 关键优化技术

**平面相交优化**：当采样到"悬浮"的几何体时，将其投影到实际平面，避免错误的高点遮挡，提高精度。

**可见性判断**：只有当采样点比之前的地平线更近时（`sampleCos >= prevHorizonCos`），才计算这个点对遮挡的贡献，否则忽略（已被更近的点遮挡）。
