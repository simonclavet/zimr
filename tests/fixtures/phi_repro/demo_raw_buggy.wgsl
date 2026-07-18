struct S14 {
  field_0: array<u32, 11>,
};

struct S22 {
  field_0: u32,
  field_1: u32,
};

struct S23 {
  field_0: S22,
  field_1: S22,
  field_2: S14,
};

struct S25 {
  field_0: u32,
  field_1: S23,
  field_2: S14,
};

struct S36 {
  field_0: u32,
  field_1: u32,
};

struct S39 {
  field_0: S36,
  field_1: array<u32, 80>,
};

struct S40 {
  field_0: u32,
  field_1: S39,
};

struct S45 {
  field_0: u32,
  field_1: u32,
  field_2: u32,
  field_3: S22,
  field_4: S22,
};

struct S46 {
  field_0: S45,
  field_1: S45,
};

struct S74 {
  field_0: array<u32, 255>,
  field_1: u32,
};

const undef_78: array<u32, 255> = array<u32, 255>();
struct S81 {
  field_0: S25,
  field_1: S40,
  field_2: u32,
  field_3: u32,
  field_4: S74,
};

const undef_96: array<u32, 255> = array<u32, 255>();
var<private> frag_tex_coord: vec2<f32>;
var<private> out_color: vec4<f32>;
struct S118 {
  field_0: vec2<f32>,
  field_1: f32,
  field_2: f32,
  field_3: vec2<f32>,
  field_4: f32,
  field_5: f32,
};

@group(2) @binding(0) var<uniform> u: S118;
struct S132 {
  field_0: vec2<f32>,
  field_1: f32,
  field_2: f32,
  field_3: vec2<f32>,
  field_4: f32,
  field_5: f32,
};

struct S133 {
  field_0: vec2<f32>,
  field_1: S132,
};

struct S165 {
  field_0: vec4<f32>,
};

const undef_174: u32 = u32();
const undef_178: u32 = u32();
const undef_193: S165 = S165();
const undef_559: u32 = u32();
const undef_853: u32 = u32();
const undef_865: u32 = u32();
const undef_879: u32 = u32();
const undef_882: u32 = u32();

struct entryInputs {
  @location(0) frag_tex_coord: vec2<f32>,
};

struct entryOutputs {
  @location(0) out_color: vec4<f32>,
};

fn externs_installSpirvEntry_Wrapper_entry() {
  var io: S133;
  var v169: S165;
  zimrmath_location__anon_835();
  zimrmath_location__anon_841();
  zimrmath_binding__anon_853();
  let _138: vec2<f32> = frag_tex_coord;
  io.field_0 = _138;
  let _144: vec2<f32> = u.field_0;
  io.field_1.field_0 = _144;
  let _149: f32 = u.field_1;
  io.field_1.field_1 = _149;
  let _152: f32 = u.field_2;
  io.field_1.field_2 = _152;
  let _156: vec2<f32> = u.field_3;
  io.field_1.field_3 = _156;
  let _159: f32 = u.field_4;
  io.field_1.field_4 = _159;
  let _163: f32 = u.field_5;
  io.field_1.field_5 = _163;
  let _164: S133 = io;
  let _166: S165 = mandelbrot_fs_shaderMain(_164);
  v169 = _166;
  let _172: vec4<f32> = v169.field_0;
  out_color = _172;
  return;
}

fn zimrmath_location__anon_835() {
  return;
}

fn mandelbrot_fs_shaderMain(p188: S133) -> S165 {
  var phi302: u32;
  var phi335: u32;
  var phi337: u32;
  var phi387: u32;
  var phi399: u32;
  var phi400: u32;
  var phi401: u32;
  var phi403: u32;
  var phi407: u32;
  var phi433: u32;
  var phi459: u32;
  var phi542: u32;
  var phi543: u32;
  var phi544: u32;
  var phi545: u32;
  var phi546: u32;
  var phi547: u32;
  var phi548: u32;
  var phi554: u32;
  var phi555: u32;
  var phi556: u32;
  var _273: vec2<f32>;
  var _417: vec4<f32>;
  var _492: f32;
  var _521: vec4<f32>;
  var v190: S133;
  var out: S165;
  var v206: vec2<f32>;
  var v218: vec2<f32>;
  var v219: vec2<f32>;
  var v230: vec2<f32>;
  var v263: vec2<f32>;
  var v264: vec2<f32>;
  var z: vec2<f32>;
  var n: f32;
  var escaped: u32;
  var i: u32;
  var v308: f32;
  var v309: vec2<f32>;
  var v342: vec2<f32>;
  var v343: vec2<f32>;
  var v344: vec2<f32>;
  var v345: vec2<f32>;
  var v346: vec2<f32>;
  var v418: vec4<f32>;
  var v419: vec4<f32>;
  var v435: f32;
  var v436: f32;
  var v437: vec2<f32>;
  var v464: f32;
  var v472: f32;
  var v493: f32;
  var v505: vec3<f32>;
  var v507: vec3<f32>;
  var v520: vec3<f32>;
  var v528: vec4<f32>;
  var v529: vec4<f32>;
  v190 = p188;
  out = undef_193;
  let _195: vec2<f32> = v190.field_0;
  let _198: vec2<f32> = v190.field_1.field_3;
  let _201: f32 = _195[0];
  let _202: f32 = _195[1];
  let _203: f32 = _198[0];
  let _204: f32 = _198[1];
  let _199: f32 = _201 * _203;
  let _200: f32 = _202 * _204;
  let _205: vec2<f32> = vec2<f32>(_199, _200);
  v206 = _205;
  let _210: f32 = v190.field_1.field_3[0u];
  let _212: f32 = _210 * 0.5;
  let _216: f32 = v190.field_1.field_3[1u];
  let _217: f32 = _216 * 0.5;
  v219[0u] = _212;
  v219[1u] = _217;
  let _222: vec2<f32> = v219;
  v218 = _222;
  let _225: bool = 41u == 41u;
  let _229: vec2<f32> = v218;
  v230 = _229;
  let _233: f32 = v190.field_1.field_1;
  let _237: f32 = v190.field_1.field_3[1u];
  let _238: f32 = _233 * _237;
  let _240: f32 = 4.0 / _238;
  let _244: f32 = v190.field_1.field_0[0u];
  let _246: f32 = v206[0u];
  let _248: f32 = v230[0u];
  let _249: f32 = _246 - _248;
  let _250: f32 = _249 * _240;
  let _251: f32 = _244 + _250;
  let _255: f32 = v190.field_1.field_0[1u];
  let _257: f32 = v206[1u];
  let _259: f32 = v230[1u];
  let _260: f32 = _257 - _259;
  let _261: f32 = _260 * _240;
  let _262: f32 = _255 - _261;
  v264[0u] = _251;
  v264[1u] = _262;
  let _267: vec2<f32> = v264;
  v263 = _267;
  let _270: bool = 113u == 113u;
  _273 = v263;
  let _275: vec2<f32> = vec2<f32>(0.0, 0.0);
  z = _275;
  n = 0.0;
  escaped = 0u;
  i = 0u;
  loop {
  let _283: u32 = i;
  let _285: bool = _283 < 1024u;
    if (_285) {
  let _289: u32 = i;
  let _290: f32 = f32(_289);
  let _293: f32 = v190.field_1.field_4;
  let _294: bool = _290 >= _293;
      if (_294) {
        phi302 = 145u;
      } else {
        phi302 = 153u;
      }
  let _304: bool = phi302 == 153u;
      if (_304) {
  let _307: vec2<f32> = z;
  v309 = _307;
  let _311: f32 = v309[0u];
  let _313: f32 = v309[0u];
  let _314: f32 = _311 * _313;
  let _316: f32 = v309[1u];
  let _318: f32 = v309[1u];
  let _319: f32 = _316 * _318;
  let _320: f32 = _314 + _319;
  v308 = _320;
  let _323: bool = 172u == 172u;
  let _326: f32 = v308;
  let _328: bool = _326 > 256.0;
        if (_328) {
  escaped = 1u;
          phi335 = 145u;
        } else {
          phi335 = 168u;
        }
  let _338: bool = phi337 == 168u;
        if (_338) {
  let _341: vec2<f32> = z;
  v344 = _341;
  v345 = _341;
  let _349: f32 = v344[0u];
  let _351: f32 = v345[0u];
  let _352: f32 = _349 * _351;
  let _354: f32 = v344[1u];
  let _356: f32 = v345[1u];
  let _357: f32 = _354 * _356;
  let _358: f32 = _352 - _357;
  v346[0u] = _358;
  let _361: f32 = v344[0u];
  let _363: f32 = v345[1u];
  let _364: f32 = _361 * _363;
  let _366: f32 = v344[1u];
  let _368: f32 = v345[0u];
  let _369: f32 = _366 * _368;
  let _370: f32 = _364 + _369;
  v346[1u] = _370;
  let _371: vec2<f32> = v346;
  v343 = _371;
  let _374: bool = 211u == 211u;
  let _377: vec2<f32> = v343;
  let _380: f32 = _377[0];
  let _381: f32 = _377[1];
  let _382: f32 = _273[0];
  let _383: f32 = _273[1];
  let _378: f32 = _380 + _382;
  let _379: f32 = _381 + _383;
  let _384: vec2<f32> = vec2<f32>(_378, _379);
  v342 = _384;
  let _388: bool = phi387 == 207u;
  let _391: vec2<f32> = v342;
  z = _391;
  let _392: f32 = n;
  let _394: f32 = _392 + 1.0;
  n = _394;
  let _395: u32 = i;
  let _396: u32 = _395 + 1u;
  i = _396;
          phi400 = phi399;
        } else {
          phi400 = phi337;
        }
        phi401 = phi400;
      } else {
        phi401 = phi302;
      }
      phi403 = phi401;
    } else {
      phi403 = 145u;
    }
  let _405: bool = phi403 == 147u;
    phi407 = phi403;
    break;
    continuing {
    }
  }
  let _409: bool = phi407 == 145u;
  if (_409) {
  let _412: u32 = escaped;
  let _413: bool = _412 == 0u;
    if (_413) {
  v419[0u] = 0.0;
  v419[1u] = 0.0;
  v419[2u] = 0.0;
  v419[3u] = 1.0;
  let _424: vec4<f32> = v419;
  v418 = _424;
  let _427: bool = 293u == 293u;
  let _430: vec4<f32> = v418;
  out.field_0 = _430;
      phi548 = phi433;
    } else {
  let _434: vec2<f32> = z;
  v437 = _434;
  let _439: f32 = v437[0u];
  let _441: f32 = v437[0u];
  let _442: f32 = _439 * _441;
  let _444: f32 = v437[1u];
  let _446: f32 = v437[1u];
  let _447: f32 = _444 * _446;
  let _448: f32 = _442 + _447;
  v436 = _448;
  let _451: bool = 319u == 319u;
  let _454: f32 = v436;
  let _455: f32 = sqrt(_454);
  v435 = _455;
  let _460: bool = phi459 == 316u;
  let _463: f32 = v435;
  let _465: f32 = log2(_463);
  v464 = _465;
  let _468: bool = 349u == 349u;
  let _471: f32 = v464;
  let _473: f32 = log2(_471);
  v472 = _473;
  let _476: bool = 356u == 356u;
  let _479: f32 = v472;
  let _480: f32 = n;
  let _481: f32 = _480 + 1.0;
  let _482: f32 = _481 - _479;
  let _485: f32 = v190.field_1.field_4;
  let _486: f32 = _482 / _485;
  let _487: f32 = zimrmath_clamp01(_486);
  let _490: f32 = 0.4 * _487;
  _492 = 0.85 + _490;
  let _494: f32 = log(_487);
  let _495: f32 = _494 * 0.4;
  let _496: f32 = exp(_495);
  v493 = _496;
  let _499: bool = 385u == 385u;
  let _502: f32 = v493;
  v507[0u] = _492;
  v507[1u] = 0.7;
  v507[2u] = _502;
  let _511: vec3<f32> = v507;
  v505 = _511;
  let _514: bool = 398u == 398u;
  let _517: vec3<f32> = v505;
  let _518: vec3<f32> = mandelbrot_fs_hsv2rgb(_517);
  v520 = _518;
  let _523: f32 = v520[0u];
  let _525: f32 = v520[1u];
  let _527: f32 = v520[2u];
  v529[0u] = _523;
  v529[1u] = _525;
  v529[2u] = _527;
  v529[3u] = 1.0;
  let _534: vec4<f32> = v529;
  v528 = _534;
  let _537: bool = 431u == 431u;
  let _540: vec4<f32> = v528;
  out.field_0 = _540;
      phi548 = phi547;
    }
  let _550: bool = phi548 == 287u;
  let _553: S165 = out;
    return _553;
  } else {
    phi554 = phi407;
  }
  return S165();
}

fn zimrmath_binding__anon_853() {
  var _273: vec2<f32>;
  var _417: vec4<f32>;
  var _492: f32;
  var _521: vec4<f32>;
  return;
}

fn mandelbrot_fs_hsv2rgb(p561: vec3<f32>) -> vec3<f32> {
  var _273: vec2<f32>;
  var _417: vec4<f32>;
  var _492: f32;
  var _521: vec4<f32>;
  var _597: vec3<f32>;
  var _648: vec3<f32>;
  var _671: vec3<f32>;
  var _740: vec3<f32>;
  var _758: vec3<f32>;
  var _806: vec3<f32>;
  var v563: vec3<f32>;
  var v564: vec4<f32>;
  var v568: vec4<f32>;
  var v579: vec4<f32>;
  var v586: vec3<f32>;
  var v587: vec3<f32>;
  var v604: vec3<f32>;
  var v605: vec3<f32>;
  var v626: vec3<f32>;
  var v637: vec3<f32>;
  var v638: vec3<f32>;
  var v649: vec3<f32>;
  var v651: vec3<f32>;
  var v672: vec3<f32>;
  var v673: vec3<f32>;
  var v694: vec3<f32>;
  var v704: vec3<f32>;
  var v705: vec3<f32>;
  var v716: vec3<f32>;
  var v729: vec3<f32>;
  var v730: vec3<f32>;
  var v747: vec3<f32>;
  var v748: vec3<f32>;
  var v765: vec3<f32>;
  var v766: vec3<f32>;
  var v813: vec3<f32>;
  var v814: vec3<f32>;
  v563 = p561;
  v568[0u] = 1.0;
  v568[1u] = 0.6666667;
  v568[2u] = 0.33333334;
  v568[3u] = 3.0;
  let _573: vec4<f32> = v568;
  v564 = _573;
  let _575: bool = 5u == 5u;
  let _578: vec4<f32> = v564;
  v579 = _578;
  let _581: f32 = v563[0u];
  let _583: f32 = v563[0u];
  let _585: f32 = v563[0u];
  v587[0u] = _581;
  v587[1u] = _583;
  v587[2u] = _585;
  let _591: vec3<f32> = v587;
  v586 = _591;
  let _594: bool = 37u == 37u;
  _597 = v586;
  let _599: f32 = v579[0u];
  let _601: f32 = v579[1u];
  let _603: f32 = v579[2u];
  v605[0u] = _599;
  v605[1u] = _601;
  v605[2u] = _603;
  let _609: vec3<f32> = v605;
  v604 = _609;
  let _612: bool = 63u == 63u;
  let _615: vec3<f32> = v604;
  let _619: f32 = _597[0];
  let _620: f32 = _597[1];
  let _621: f32 = _597[2];
  let _622: f32 = _615[0];
  let _623: f32 = _615[1];
  let _624: f32 = _615[2];
  let _616: f32 = _619 + _622;
  let _617: f32 = _620 + _623;
  let _618: f32 = _621 + _624;
  let _625: vec3<f32> = vec3<f32>(_616, _617, _618);
  v626 = _625;
  let _628: f32 = v626[0u];
  let _629: f32 = zimrmath_fract(_628);
  let _632: f32 = v626[1u];
  let _633: f32 = zimrmath_fract(_632);
  let _635: f32 = v626[2u];
  let _636: f32 = zimrmath_fract(_635);
  v638[0u] = _629;
  v638[1u] = _633;
  v638[2u] = _636;
  let _642: vec3<f32> = v638;
  v637 = _642;
  let _645: bool = 101u == 101u;
  _648 = v637;
  v651[0u] = 6.0;
  v651[1u] = 6.0;
  v651[2u] = 6.0;
  let _655: vec3<f32> = v651;
  v649 = _655;
  let _658: bool = 118u == 118u;
  let _661: vec3<f32> = v649;
  let _665: f32 = _648[0];
  let _666: f32 = _648[1];
  let _667: f32 = _648[2];
  let _668: f32 = _661[0];
  let _669: f32 = _661[1];
  let _670: f32 = _661[2];
  let _662: f32 = _665 * _668;
  let _663: f32 = _666 * _669;
  let _664: f32 = _667 * _670;
  _671 = vec3<f32>(_662, _663, _664);
  v673[0u] = 3.0;
  v673[1u] = 3.0;
  v673[2u] = 3.0;
  let _677: vec3<f32> = v673;
  v672 = _677;
  let _680: bool = 137u == 137u;
  let _683: vec3<f32> = v672;
  let _687: f32 = _671[0];
  let _688: f32 = _671[1];
  let _689: f32 = _671[2];
  let _690: f32 = _683[0];
  let _691: f32 = _683[1];
  let _692: f32 = _683[2];
  let _684: f32 = _687 - _690;
  let _685: f32 = _688 - _691;
  let _686: f32 = _689 - _692;
  let _693: vec3<f32> = vec3<f32>(_684, _685, _686);
  v694 = _693;
  let _696: f32 = v694[0u];
  let _697: f32 = abs(_696);
  let _699: f32 = v694[1u];
  let _700: f32 = abs(_699);
  let _702: f32 = v694[2u];
  let _703: f32 = abs(_702);
  v705[0u] = _697;
  v705[1u] = _700;
  v705[2u] = _703;
  let _709: vec3<f32> = v705;
  v704 = _709;
  let _712: bool = 171u == 171u;
  let _715: vec3<f32> = v704;
  v716 = _715;
  let _718: f32 = v716[0u];
  let _719: f32 = _718 - 1.0;
  let _720: f32 = zimrmath_clamp01(_719);
  let _722: f32 = v716[1u];
  let _723: f32 = _722 - 1.0;
  let _724: f32 = zimrmath_clamp01(_723);
  let _726: f32 = v716[2u];
  let _727: f32 = _726 - 1.0;
  let _728: f32 = zimrmath_clamp01(_727);
  v730[0u] = _720;
  v730[1u] = _724;
  v730[2u] = _728;
  let _734: vec3<f32> = v730;
  v729 = _734;
  let _737: bool = 212u == 212u;
  _740 = v729;
  let _742: f32 = v579[0u];
  let _744: f32 = v579[0u];
  let _746: f32 = v579[0u];
  v748[0u] = _742;
  v748[1u] = _744;
  v748[2u] = _746;
  let _752: vec3<f32> = v748;
  v747 = _752;
  let _755: bool = 238u == 238u;
  _758 = v747;
  let _760: f32 = v563[1u];
  let _762: f32 = v563[1u];
  let _764: f32 = v563[1u];
  v766[0u] = _760;
  v766[1u] = _762;
  v766[2u] = _764;
  let _770: vec3<f32> = v766;
  v765 = _770;
  let _773: bool = 264u == 264u;
  let _776: vec3<f32> = v765;
  let _780: f32 = _740[0];
  let _781: f32 = _740[1];
  let _782: f32 = _740[2];
  let _783: f32 = _758[0];
  let _784: f32 = _758[1];
  let _785: f32 = _758[2];
  let _777: f32 = _780 - _783;
  let _778: f32 = _781 - _784;
  let _779: f32 = _782 - _785;
  let _786: vec3<f32> = vec3<f32>(_777, _778, _779);
  let _790: f32 = _786[0];
  let _791: f32 = _786[1];
  let _792: f32 = _786[2];
  let _793: f32 = _776[0];
  let _794: f32 = _776[1];
  let _795: f32 = _776[2];
  let _787: f32 = _790 * _793;
  let _788: f32 = _791 * _794;
  let _789: f32 = _792 * _795;
  let _796: vec3<f32> = vec3<f32>(_787, _788, _789);
  let _800: f32 = _758[0];
  let _801: f32 = _758[1];
  let _802: f32 = _758[2];
  let _803: f32 = _796[0];
  let _804: f32 = _796[1];
  let _805: f32 = _796[2];
  let _797: f32 = _800 + _803;
  let _798: f32 = _801 + _804;
  let _799: f32 = _802 + _805;
  _806 = vec3<f32>(_797, _798, _799);
  let _808: f32 = v563[2u];
  let _810: f32 = v563[2u];
  let _812: f32 = v563[2u];
  v814[0u] = _808;
  v814[1u] = _810;
  v814[2u] = _812;
  let _818: vec3<f32> = v814;
  v813 = _818;
  let _821: bool = 297u == 297u;
  let _824: vec3<f32> = v813;
  let _828: f32 = _806[0];
  let _829: f32 = _806[1];
  let _830: f32 = _806[2];
  let _831: f32 = _824[0];
  let _832: f32 = _824[1];
  let _833: f32 = _824[2];
  let _825: f32 = _828 * _831;
  let _826: f32 = _829 * _832;
  let _827: f32 = _830 * _833;
  let _834: vec3<f32> = vec3<f32>(_825, _826, _827);
  return _834;
}

fn zimrmath_clamp01(p846: f32) -> f32 {
  var phi855: u32;
  var phi868: u32;
  var _273: vec2<f32>;
  var _417: vec4<f32>;
  var _492: f32;
  var _521: vec4<f32>;
  var _597: vec3<f32>;
  var _648: vec3<f32>;
  var _671: vec3<f32>;
  var _740: vec3<f32>;
  var _758: vec3<f32>;
  var _806: vec3<f32>;
  let _848: bool = p846 < 0.0;
  if (_848) {
    return 0.0;
  } else {
    phi855 = 2u;
  }
  let _857: bool = phi855 == 2u;
  let _860: bool = p846 > 1.0;
  if (_860) {
    return 1.0;
  } else {
    phi868 = 9u;
  }
  let _870: bool = phi868 == 9u;
  return p846;
}

fn zimrmath_fract(p874: f32) -> f32 {
  var _273: vec2<f32>;
  var _417: vec4<f32>;
  var _492: f32;
  var _521: vec4<f32>;
  var _597: vec3<f32>;
  var _648: vec3<f32>;
  var _671: vec3<f32>;
  var _740: vec3<f32>;
  var _758: vec3<f32>;
  var _806: vec3<f32>;
  let _876: f32 = floor(p874);
  let _877: f32 = p874 - _876;
  return _877;
}

fn zimrmath_location__anon_841() {
  var _273: vec2<f32>;
  var _417: vec4<f32>;
  var _492: f32;
  var _521: vec4<f32>;
  var _597: vec3<f32>;
  var _648: vec3<f32>;
  var _671: vec3<f32>;
  var _740: vec3<f32>;
  var _758: vec3<f32>;
  var _806: vec3<f32>;
  return;
}

@fragment
fn entry(inputs: entryInputs) -> entryOutputs {
  frag_tex_coord = inputs.frag_tex_coord;
  var outputs: entryOutputs;
  var _273: vec2<f32>;
  var _417: vec4<f32>;
  var _492: f32;
  var _521: vec4<f32>;
  var _597: vec3<f32>;
  var _648: vec3<f32>;
  var _671: vec3<f32>;
  var _740: vec3<f32>;
  var _758: vec3<f32>;
  var _806: vec3<f32>;
  externs_installSpirvEntry_Wrapper_entry();
  outputs.out_color = out_color;
  return outputs;
}

