@group(1) @binding(0) var texture0: texture_2d<f32>;
@group(1) @binding(1) var texture0_sampler: sampler;
var<private> color: vec4<f32>;
var<private> uv: vec2<f32>;

struct mainInputs {
  @location(0) uv: vec2<f32>,
};

struct mainOutputs {
  @location(0) color: vec4<f32>,
};

@fragment
fn main(inputs: mainInputs) -> mainOutputs {
  uv = inputs.uv;
  var outputs: mainOutputs;
  zimrmath_binding__anon_521();
  let _11: texture_2d<f32> = texture0;
  let _94: sampler = texture0_sampler;
  let _16: vec2<f32> = uv;
  let _18: vec4<f32> = textureSample(_11, _94, _16);
  color = _18;
  outputs.color = color;
  return outputs;
}

fn zimrmath_binding__anon_521() {
  return;
}

