#ifndef CELESTIA_SHADE_MATERIAL
#define CELESTIA_SHADE_MATERIAL

struct ShadeMaterial {
	float3 normal;
	float3 f0;
	float roughness;
	float diffuse;
	float ao;
	float emission;
	float porosity;
	float scattering;
};

static inline bool shadeMaterialEnabled(constant ShadeLook &L) {
	return shadeFeature(L, SHADE_FEATURE_PBR_NORMAL | SHADE_FEATURE_PBR_SPECULAR);
}

static inline float3 shadeMaterialNormal(float2 rg, float3 n, float3 dx, float3 dy, float2 du, float2 dv) {
	float det = du.x * dv.y - du.y * dv.x;
	if (abs(det) < 1e-14) return n;
	float3 tangent = (dx * dv.y - dy * du.y) * sign(det);
	float lenSq = dot(tangent, tangent);
	if (lenSq < 1e-24) return n;
	tangent *= rsqrt(lenSq);
	// Atlas V increases downwards. Use the UV Jacobian to preserve that direction on mirrored faces.
	float3 bitangent = cross(n, tangent);
	bitangent *= dot(bitangent, (dy * du.x - dx * dv.x) * sign(det)) < 0.0 ? -1.0 : 1.0;
	float2 xy = clamp((rg * 255.0 - 128.0) / 127.0, -1.0, 1.0);
	float z = sqrt(max(0.0, 1.0 - dot(xy, xy)));
	return normalize(tangent * xy.x + bitangent * xy.y + n * z);
}

static inline void shadeMaterialSpecular(thread ShadeMaterial &m, float4 packed, float3 albedo) {
	uint green = uint(round(packed.g * 255.0));
	uint blue = uint(round(packed.b * 255.0));
	uint alpha = uint(round(packed.a * 255.0));
	bool metal = green >= 230;
	float linear = 1.0 - packed.r;
	m.roughness = linear * linear;
	m.f0 = metal ? albedo : float3(packed.g);
	m.diffuse = metal ? 0.0 : 1.0 - packed.g;
	m.emission = alpha == 255 ? 0.0 : float(alpha) / 254.0;
	m.porosity = blue <= 64 ? float(blue) / 64.0 : 0.0;
	m.scattering = blue >= 65 ? float(blue - 65) / 190.0 : 0.0;
}

static ShadeMaterial shadeMaterial(float3 n, float3 albedo, float2 uv, float3 dx, float3 dy, float2 du, float2 dv,
                                   constant ShadeLook &L, constant ShadeResources &R) {
	ShadeMaterial m = {n, float3(0.0), 1.0, 1.0, 1.0, 0.0, 0.0, 0.0};
	if (!any(abs(du) + abs(dv) > 0.0)) return m;
	if (shadeFeature(L, SHADE_FEATURE_PBR_NORMAL)) {
		constexpr sampler normalSampler(address::clamp_to_edge, filter::linear, mip_filter::nearest);
		float3 raw = R.pbrNormal.sample(normalSampler, uv, gradient2d(du, dv)).rgb;
		// The atlas clears regions without a companion to zero. Valid normals cannot encode zero in both XY channels.
		if (any(raw.rg > 0.0)) {
			m.normal = shadeMaterialNormal(raw.rg, n, dx, dy, du, dv);
			m.ao = raw.b;
		}
	}
	if (shadeFeature(L, SHADE_FEATURE_PBR_SPECULAR)) {
		// Nearest filtering keeps hardcoded metal IDs and the porosity/scattering boundary intact.
		constexpr sampler specSampler(address::clamp_to_edge, filter::nearest, mip_filter::nearest);
		shadeMaterialSpecular(m, R.pbrSpecular.sample(specSampler, uv, gradient2d(du, dv)), albedo);
	}
	return m;
}

static inline float3 shadeMaterialFresnel(float cosine, float3 f0) {
	float grazing = 1.0 - saturate(cosine);
	float square = grazing * grazing;
	return f0 + (1.0 - f0) * square * square * grazing;
}

static float3 shadeMaterialLight(ShadeMaterial m, float3 albedo, float3 radiance, float3 p, float3 geomNormal,
	                            half sky, half shadow, constant ShadeFrame &f, texture2d<half> lut, sampler s) {
	float3 emission = albedo * (m.emission * 4.0);
	if (f.flags.x != SHADE_DIM_OVERWORLD) return radiance * m.ao + emission;
	radiance = radiance * (m.ao * m.diffuse) + emission;
	float3 light = f.lightDirWorld.xyz;
	float3 sun = f.sunColor.xyz * (float(shadow) * powr(float(sky), 4.0));
	if (m.scattering > 0.0) {
		float transmission = 0.2 + 0.8 * saturate(-dot(geomNormal, light));
		radiance += albedo * sun * (m.scattering * transmission * 0.35);
	}
	if (!any(m.f0 > 0.0)) return radiance;

	float3 v = -p * rsqrt(max(dot(p, p), 1e-6));
	float nv = max(dot(m.normal, v), 1e-3);
	float3 reflected = reflect(-v, m.normal);
	float3 environment = shadeSkyLookup(reflected, lut, s, f);
	float sSky = float(shadeSkyCurve(sky));
	radiance += mix(environment, f.ambientSky.xyz, m.roughness) * shadeMaterialFresnel(nv, m.f0)
	          * (sSky * (0.5 + 0.5 * m.ao));

	float nl = saturate(dot(m.normal, light));
	if (nl > 0.0 && any(sun > 0.0) && dot(geomNormal, light) > 0.0) {
		float3 h = v + light;
		h *= rsqrt(max(dot(h, h), 1e-6));
		float nh = saturate(dot(m.normal, h));
		float rough = max(m.roughness, 0.05);
		float a2 = rough * rough;
		float d = 1.0 + nh * nh * (a2 - 1.0);
		float distribution = a2 / (3.14159265 * d * d);
		float visibility = 0.5 / max(nl * sqrt(nv * nv * (1.0 - a2) + a2)
		                           + nv * sqrt(nl * nl * (1.0 - a2) + a2), 1e-4);
		radiance += sun * min(distribution * visibility * nl, 8.0) * shadeMaterialFresnel(dot(v, h), m.f0);
	}
	return radiance;
}

#endif
