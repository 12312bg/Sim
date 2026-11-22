shader_type canvas_item;
// 地区着色：TEXTURE 是地区索引图（像素值 = 地区索引），region_colors 是 256x1 调色板，
// 每天由脚本按模拟状态更新。索引 0 = 海洋，调色板里为透明。
// 索引图是半分辨率，为避免锯齿，这里对相邻 4 个索引像素各自查调色板后做双线性混合
// （预乘 alpha），相当于“先查色、再过滤”，边缘平滑且不会混出错误的索引。

uniform sampler2D region_colors : filter_nearest, repeat_disable;

vec4 lookup(sampler2D ids, ivec2 p, ivec2 size) {
	p = clamp(p, ivec2(0), size - 1);
	int idx = int(round(texelFetch(ids, p, 0).r * 255.0));
	vec4 c = texelFetch(region_colors, ivec2(idx, 0), 0);
	return vec4(c.rgb * c.a, c.a);
}

void fragment() {
	ivec2 size = textureSize(TEXTURE, 0);
	vec2 p = UV * vec2(size) - 0.5;
	ivec2 i = ivec2(floor(p));
	vec2 f = fract(p);
	vec4 c = mix(
		mix(lookup(TEXTURE, i, size), lookup(TEXTURE, i + ivec2(1, 0), size), f.x),
		mix(lookup(TEXTURE, i + ivec2(0, 1), size), lookup(TEXTURE, i + ivec2(1, 1), size), f.x),
		f.y);
	COLOR = c.a > 0.0 ? vec4(c.rgb / c.a, c.a) : vec4(0.0);
}
