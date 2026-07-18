var<private> frag_tex_coord: vec2<f32>;
var<private> out_color: vec4<f32>;
struct S118 {
  field_0: f32,
  field_1: f32,
  field_2: f32,
  field_3: f32,
};

@group(2) @binding(0) var<uniform> u: S118;
const undef_554: vec4<f32> = vec4<f32>();

struct entryInputs {
  @location(0) frag_tex_coord: vec2<f32>,
};

struct entryOutputs {
  @location(0) out_color: vec4<f32>,
};

@fragment
fn entry(inputs: entryInputs) -> entryOutputs {
  frag_tex_coord = inputs.frag_tex_coord;
  var outputs: entryOutputs;
  var phi542: u32;
  var phi538: f32;
  var phi534: f32;
  var phi532: u32;
  var phi574: f32;
  var phi571: u32;
  var phi549: f32;
  var phi573: f32;
  var phi570: u32;
  var phi548: f32;
  var phi543: u32;
  var phi448: u32;
  var phi572: f32;
  var phi569: u32;
  var phi547: f32;
  var phi541: u32;
  var phi450: u32;
  var phi550: f32;
  var phi559: vec4<f32>;
  var _365: vec2<f32>;
  var _369: f32;
  var _434: bool;
  var _580: u32;
  var _581: u32;
  _365 = frag_tex_coord;
  _369 = u.field_0;
  let _402: f32 = _365[0];
  phi542 = 0u;
  phi538 = 0.0;
  phi534 = _402;
  phi532 = 0u;
  loop {
  let _406: bool = phi532 < 256u;
    if (_406) {
  let _411: f32 = f32(phi532);
  let _415: bool = _411 >= _369;
  let _579: u32 = select(37u, 29u, _415);
  let _583: bool = false;
  let _584: bool = true;
  let _423: bool = _411 < _369;
      if (_423) {
  let _426: bool = phi534 > 4.0;
  _580 = select(phi542, 1u, _426);
  _581 = select(52u, 29u, _426);
  let _587: bool = false;
  let _588: bool = true;
  _434 = !(_426);
        if (_434) {
  let _438: f32 = phi534 * phi534;
  let _439: f32 = _438 + 0.5;
  let _441: f32 = phi538 + 1.0;
  let _443: u32 = phi532 + 1u;
          phi574 = _439;
          phi571 = _443;
          phi549 = _441;
        } else {
          phi574 = phi534;
          phi571 = phi532;
          phi549 = phi538;
        }
  let _582: u32 = select(_581, 31u, _434);
        phi573 = phi574;
        phi570 = phi571;
        phi548 = phi549;
        phi543 = _580;
        phi448 = _582;
      } else {
        phi573 = phi534;
        phi570 = phi532;
        phi548 = phi538;
        phi543 = phi542;
        phi448 = _579;
      }
      phi572 = phi573;
      phi569 = phi570;
      phi547 = phi548;
      phi541 = phi543;
      phi450 = phi448;
    } else {
      phi572 = phi534;
      phi569 = phi532;
      phi547 = phi538;
      phi541 = phi542;
      phi450 = 29u;
    }
  let _452: bool = phi450 == 31u;
    if (_452) {
      continue;
    } else {
      break;
    }
    continuing {
      phi542 = phi541;
      phi538 = phi547;
      phi534 = phi572;
      phi532 = phi569;
    }
  }
  let _458: bool = phi450 == 29u;
  if (_458) {
  let _461: bool = phi541 == 1u;
    if (_461) {
  let _466: f32 = phi547 * 0.00390625;
      phi550 = _466;
    } else {
      phi550 = 0.0;
    }
  let _578: vec4<f32> = vec4<f32>(phi550, phi550, phi550, 1.0);
  out_color = phi559;
    outputs.out_color = out_color;
  return outputs;
  } else {
  }
  out_color = phi559;
  outputs.out_color = out_color;
  return outputs;
}

