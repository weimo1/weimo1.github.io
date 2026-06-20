---
title: PBR
date: 2026-06-20
categories:
  - ["计算机图形学", "渲染技术"]
publish: true
---

# PBR

> 适用范围：Physically Based Rendering——基于物理的渲染理论，涵盖渲染方程、BRDF、Cook-Torrance 微面元模型、Fresnel、能量守恒等核心概念。

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

- 定义：PBR（Physically Based Rendering）是一种基于真实物理光行为的渲染方法，核心是渲染方程 + 微面元 BRDF 模型（Cook-Torrance），保证能量守恒和物理正确性。
- 关键词：渲染方程、BRDF、Cook-Torrance、微面元、Fresnel、GGX、能量守恒、金属度/粗糙度工作流
- 适用场景/边界：AAA 游戏、电影级离线渲染、实时可视化；PBR 本身不处理次表面散射（SSS）和色散等特殊光学现象。

## 二、详细解析（≥200字）

### 原理拆解（三层递进）

**第一层：渲染方程**

\[
L_o(p, \omega_o) = L_e(p, \omega_o) + \int_{\Omega} f_r(p, \omega_i, \omega_o) L_i(p, \omega_i) (\omega_i \cdot n) d\omega_i
\]

- \(L_o\)：出射 radiance（最终看到的颜色）
- \(L_e\)：自发光项
- \(f_r\)：BRDF（双向反射分布函数）
- \(L_i\)：入射 radiance
- \(\omega_i \cdot n\)：Lambert 余弦项

**第二层：Cook-Torrance 微面元 BRDF**

现代 PBR 的镜面反射 BRDF 采用 Cook-Torrance 模型：

\[
f_r = \frac{D \cdot F \cdot G}{4 (n \cdot \omega_i)(n \cdot \omega_o)}
\]

| 项 | 含义 | 常用实现 |
|----|------|----------|
| **D**（法线分布函数） | 微面元法线朝向分布 | GGX / Trowbridge-Reitz |
| **F**（Fresnel 项） | 反射率随角度变化 | Schlick 近似 |
| **G**（几何遮蔽函数） | 微面元间的遮挡/阴影 | Smith GGX |

**第三层：能量守恒**

PBR 的核心约束：出射能量 ≤ 入射能量。漫反射 + 镜面反射不能超过 1：

\[
k_d + k_s \leq 1.0
\]

其中 \(k_s = F\)（Fresnel），\(k_d = (1 - F)(1 - \text{metallic})\)。金属度（metallic）为 1 时无漫反射——金属不产生漫反射，所有颜色来自镜面反射的 Fresnel 色。

### 关键公式

GGX 法线分布函数：
\[
D_{GGX}(n, h, \alpha) = \frac{\alpha^2}{\pi((n \cdot h)^2(\alpha^2 - 1) + 1)^2}
\]
其中 \(\alpha = roughness^2\)，\(h\) 为半程向量 \(\frac{L+V}{|L+V|}\)。

Schlick Fresnel 近似：
\[
F = F_0 + (1 - F_0)(1 - \cos\theta)^5
\]
\(F_0\) 为基础反射率（0°入射），金属用 tinted \(F_0\)，非金属约 0.04。

## 三、动手实践（代码案例）

### 3.1 GGX + Schlick + Smith 完整 PBR Shader

```glsl
// GGX 法线分布函数
float DistributionGGX(vec3 N, vec3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;
    float denom = NdotH2 * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom);
}

// Schlick Fresnel
vec3 FresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// Smith GGX 几何函数
float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;       // 直接光照
    // float k = roughness * roughness / 2.0;  // IBL
    return NdotV / (NdotV * (1.0 - k) + k);
}

float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
    return GeometrySchlickGGX(max(dot(N, V), 0.0), roughness) *
           GeometrySchlickGGX(max(dot(N, L), 0.0), roughness);
}

// 完整 PBR 直接光照
vec3 PBRDirectLight(vec3 N, vec3 V, vec3 L, vec3 radiance,
                    vec3 albedo, float metallic, float roughness) {
    vec3 H = normalize(V + L);
    vec3 F0 = mix(vec3(0.04), albedo, metallic);

    float NDF = DistributionGGX(N, H, roughness);
    vec3  F   = FresnelSchlick(max(dot(H, V), 0.0), F0);
    float G   = GeometrySmith(N, V, L, roughness);

    vec3 numerator = NDF * F * G;
    float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.0001;
    vec3 specular = numerator / denominator;

    vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);
    float NdotL = max(dot(N, L), 0.0);
    return (kD * albedo / PI + specular) * radiance * NdotL;
}
```

### 3.2 金属度/粗糙度工作流

```glsl
// 标准 PBR 材质输入
uniform sampler2D albedoMap;    // 基础色
uniform sampler2D normalMap;    // 法线贴图
uniform sampler2D metallicMap;  // 金属度 (R通道)
uniform sampler2D roughnessMap; // 粗糙度 (G通道)
uniform sampler2D aoMap;        // 环境光遮蔽

void main() {
    vec3 albedo    = texture(albedoMap, uv).rgb;
    float metallic = texture(metallicMap, uv).r;
    float roughness = texture(roughnessMap, uv).g;
    float ao       = texture(aoMap, uv).r;

    vec3 N = getNormalFromMap();  // 从法线贴图解码
    vec3 V = normalize(camPos - worldPos);

    // F0: 非金属 0.04, 金属取 albedo
    vec3 F0 = mix(vec3(0.04), albedo, metallic);

    vec3 Lo = vec3(0.0);
    // 遍历所有光源...
    Lo += PBRDirectLight(N, V, L, radiance, albedo, metallic, roughness);

    // 环境光 = ibl * ao
    vec3 ambient = texture(irradianceMap, N).rgb * albedo * ao;
    FragColor = vec4(ambient + Lo, 1.0);
}
```

## 四、进阶应用（≥500字）

### 与其他主题的关联

- **IBL（Image-Based Lighting）**：环境光照通过预过滤环境贴图（Prefiltered Environment Map）+ BRDF LUT 实现，利用 Split-Sum 近似
- **SSAO**（[SSAO.md](SSAO.md)）：环境光遮蔽补充间接光照的遮挡信息
- **TAA**（[TAA.md](TAA.md)）：时间抗锯齿处理 PBR 高光走样

### 工程中的真实用法

- **UE5**：默认 PBR 工作流，Metallic/Roughness 模型，额外支持 Clear Coat（清漆层）、Sheen（布料微绒毛）
- **Unity HDRP**：基于 GGX 的 Standard Lit Shader，支持 Subsurface Scattering（扩散剖面）
- **Disney Principled BRDF**：2012 年 Disney 提出的"原则化 BRDF"，用少量艺术友好的参数（metallic, roughness, specularTint, sheen, clearcoat 等）统一描述各种材质

### 常见优化策略

- **预计算 BRDF LUT**：2D LUT（NdotV × roughness），在运行时只需一次纹理查询得到镜面反射 IBL 的 BRDF 积分
- **粗糙度 mip 链**：不同 roughness 对应不同 mip level 的预过滤环境贴图，利用 trilinear 过滤平滑过渡
- **简化 Fresnel**：非金属的 \(F_0\) 统一取 0.04，避免逐像素计算 tinted \(F_0\)
- **LTC（Linearly Transformed Cosines）**：用线性变换余弦分布近似面光源的 BRDF 积分，避免面光源的暴力采样

## 五、源码解析和实践感悟（≥1000字）

### 关键实现路径：GGX 的数值细节（补充）

GGX 中的 roughness 映射通常用 Disney 的重映射：

```glsl
float perceptualRoughness = texture(roughnessMap, uv).r;  // [0,1]
float alpha = perceptualRoughness * perceptualRoughness;   // roughness^2
```

这个平方映射的原因：GGX 的 D 项中 roughness 是以 \(\alpha^2\) 形式出现的，直接传入线性 roughness 会导致高光范围过窄。平方后 roughness 在靠近 0 时变化更细腻——符合艺术家直觉（粗糙度滑条在低值区更敏感）。

### 难点与易错点

**陷阱1：GGX 分母的 "4"**

`4 * (N·V) * (N·L)` 来自微面元模型的雅可比变换，缺少这个 4 会导致镜面反射亮 4 倍。许多人手写 BRDF 时漏掉这个分母。

**陷阱2：Fresnel 中 F0 的物理值**

非导体的 \(F_0\) 约 0.02-0.05，常见材质：水=0.02，塑料=0.04，宝石=0.05-0.17。如果给非金属设定 \(F_0=1.0\)（像金属一样），边缘 Fresnel 会全白——看起来像镀铬塑料，不真实。

**陷阱3：金属度不是 0 或 1**

现实中存在半金属（semi-metals）和氧化金属（oxidized metals），但 PBR 工作流中 metallic 通常用 0 或 1 二值，因为中间值缺乏物理意义。如果需要锈蚀金属效果，应该用材质混合（Material Blending）。

### 经验总结（补充）

1. **PBR 的核心不是"真实"而是"一致"**：PBR 的目标是同一材质在所有光照条件下看起来一致，而不是照片级真实感。这是艺术工作流的最大价值
2. **漫反射项 `/π` 的意义**：很多初学者遗漏这个 \(\frac{1}{\pi}\)，导致漫反射亮 π 倍。它的来源是 Lambertian 漫反射在半球上的积分归一化
3. **镜面反射 lobe 的形状**：GGX 在 grazing angle（掠射角）有"长尾"——高光在边缘处比 Beckmann 更宽更软，更符合真实材质的反射特性
4. **IBL 和直接光照的 G 项 k 值不同**：直接光照 \(k = (r+1)^2/8\)，IBL 用 \(k = r^2/2\)。因为 IBL 是多次反射积分的近似，G 项需要调整

## 六、面试准备

### 6.1 高频问法（≥8个）

**基础理解：**

Q1：什么是 PBR？和传统 Phong/Blinn-Phong 有什么区别？

A：PBR 基于物理的光行为建模，核心是渲染方程 + Cook-Torrance 微面元 BRDF，满足能量守恒。Phong/Blinn-Phong 是经验模型，不保证能量守恒，高光范围和 Fresnel 效果不真实。

Q2：PBR 的 Cook-Torrance BRDF 包含哪几项？

A：三项：D（法线分布函数，用 GGX）、F（Fresnel 项，用 Schlick 近似）、G（几何遮蔽函数，用 Smith GGX）。组合为镜面反射项 \(\frac{DFG}{4(N·V)(N·L)}\)。

Q3：金属度（Metallic）和粗糙度（Roughness）分别控制什么？

A：金属度控制 F0——非金属约 0.04，金属取 albedo 颜色。同时控制漫反射比例——金属无漫反射（\(k_d=0\)）。粗糙度控制微面元法线分散程度，粗糙度越高高光越散、反射越模糊。

**原理深入：**

Q4：GGX 法线分布函数为什么比 Beckmann 更常用？

A：GGX 在 grazing angle 有更长的"尾巴"——高光边缘过渡更柔和，更匹配真实世界材质的反射特性。Beckmann 尾部长宽下降太快，高光边缘过于锐利。

Q5：Fresnel 的物理含义是什么？为什么金属和非金属的 F0 差异大？

A：Fresnel 描述光在介质界面上的反射比例随入射角的变化。金属的 F0 高（0.5-0.95）因为其自由电子将大部分光反射；非金属的 F0 低（0.02-0.05）因为光主要进入介质内部经次表面散射再射出。非金属在 grazing angle 时反射率仍接近 1。

**实践应用：**

Q6：PBR 中 energy compensation 是什么意思？

A：Smith G 项假设微面元间只有一次遮挡，忽略了光在微面元间的多次弹射（尤其是粗糙材质）。这导致高粗糙度材质偏暗。Kulla-Conty 近似通过预计算的多次散射 LUT 补偿能量损失。

Q7：IBL 中 Split-Sum Approximation 的原理？

A：渲染方程中 IBL 的 BRDF 积分无法实时计算，Split-Sum 将其拆为两个独立积分：1) 预过滤环境贴图（随 roughness 变化），2) BRDF LUT（2D 纹理，NdotV × roughness），在 shader 中用两次纹理查询完成。

Q8：为什么 PBR 中漫反射项要除以 π？

A：对 Lambertian BRDF \(f_r = \frac{albedo}{\pi}\) 在半球的渲染方程积分结果为 \(\pi \times \frac{albedo}{\pi} = albedo\)，保证了能量归一化。不加 \(\frac{1}{\pi}\) 会导致漫反射亮约 3.14 倍。

### 6.2 反问点/陷阱点（≥5个）

- 您在实际项目中是使用标准的 Metallic/Roughness 工作流，还是扩展了其他参数（如 Clear Coat、Sheen）？
- 多层材质的 PBR（如车漆 = 基底 + 清漆层）在贵公司如何实现？是手动合成还是运行时混合？
- 预计算 BRDF LUT 有没有遇到过精度问题（尤其是移动端 half-float）？怎么解决的？

**常见陷阱：**

- 陷阱1：非金属材质误给高 metallic 值 → 材质会像金属一样产生彩色反射，能量不守恒，看起来像塑料镀铬。
- 陷阱2：粗糙度直接用线性值而不是平方映射 → GGX 在高粗糙度区（0.5-1.0）变化不明显，艺术家难以精确控制。
- 陷阱3：fragment shader 中计算 `PI` 用字面量 `3.14159265359` 而不是预定义宏——精度不如内置常量，且可能被编译器优化掉导致跨平台差异。

### 6.3 一句话答案（≥5个）

- PBR 的三大支柱：渲染方程、Cook-Torrance BRDF、能量守恒。
- GGX 比 Beckmann 好的原因是 grazing angle 有长尾，边缘过渡更自然。
- 金属度=1 → 无漫反射，F0=tinted；金属度=0 → F0≈0.04，有漫反射。
- PBR 漫反射除以 π 是为了半球积分归一化，保证能量守恒。
- Split-Sum Approximation 的核心是把 IBL 的 BRDF 积分拆成两张预计算纹理查表。

**情景模拟：**

- 被问到"PBR 和卡通渲染的关系"→ "PBR 是物理正确，卡通渲染是风格化。但可以用 PBR 的光照结果做 ramp 映射，得到物理基础 + 风格化效果的混合。"
- 被问到"为什么现在都默认用 PBR"→ "因为 PBR 让材质在所有光照下表现一致，大幅降低了美术迭代成本——不用为每个场景重新调材质参数。"

## 附录（模板外原内容收纳）

### 参考资料

- [Physically Based Rendering: From Theory to Implementation (pbr-book.org)](https://www.pbr-book.org/3ed-2018/contents) — PBR 领域权威著作，涵盖完整渲染器实现
- [PBR 理论介绍 (知乎)](https://zhuanlan.zhihu.com/p/545848268)
