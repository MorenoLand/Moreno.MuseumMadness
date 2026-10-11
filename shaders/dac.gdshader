shader_type canvas_item;

// VGA DAC model from the original's palette writer (17ea:ef6e, with brightness from 27c4:41ee).
// Each 8-bit palette component is scaled as (v * brightness) >> 8 into a 6-bit DAC value.
// The display expands that as (v6 << 2) | (v6 >> 4). DAC entry 0 is written as black.
uniform sampler2D indices : filter_nearest, repeat_disable;
uniform sampler2D palette : filter_nearest, repeat_disable;
uniform int brightness : hint_range(0, 64) = 64;

int to_dac(float c, int bl) {
	return (int(c * 255.0 + 0.5) * bl) >> 8;
}

float expand6(int v6) {
	return float((v6 << 2) | (v6 >> 4)) / 255.0;
}

void fragment() {
	int index = int(texture(indices, UV).r * 255.0 + 0.5);
	vec3 rgb = vec3(0.0);
	if (index != 0) {
		vec3 entry = texture(palette, vec2((float(index) + 0.5) / 256.0, 0.5)).rgb;
		rgb = vec3(
			expand6(to_dac(entry.r, brightness)),
			expand6(to_dac(entry.g, brightness)),
			expand6(to_dac(entry.b, brightness)));
	}
	COLOR = vec4(rgb, 1.0);
}
