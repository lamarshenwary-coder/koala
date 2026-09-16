import * as THREE from 'three'

// ---------- setup ----------
const params = new URLSearchParams(location.search)
const VSIZE = parseInt(params.get('size') || '0', 10)
const VW = parseInt(params.get('w') || '0', 10) || VSIZE, VH = parseInt(params.get('h') || '0', 10) || VSIZE
const W = VW || 320, H = VH || 320
if (params.get('bg')) document.body.classList.add('bg')

const canvas = document.getElementById('c')
if (VW) { canvas.width = W; canvas.height = H; canvas.style.width = W + 'px'; canvas.style.height = H + 'px'; document.body.style.width = W + 'px'; document.body.style.height = H + 'px' }
if (params.get('white')) document.body.classList.add('white')
const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true })
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
renderer.setSize(W, H, false)
renderer.setClearColor(0x000000, 0)
renderer.outputColorSpace = THREE.SRGBColorSpace

const scene = new THREE.Scene()
const camera = new THREE.PerspectiveCamera(30, W / H, 0.1, 50)
camera.position.set(0, 0.8, 9.0)
camera.lookAt(0, 0.05, 0)

scene.add(new THREE.HemisphereLight(0xeef2ff, 0xb9c2cf, 0.6))
scene.add(new THREE.AmbientLight(0xffffff, 0.35))
const key = new THREE.DirectionalLight(0xffffff, 1.7); key.position.set(2.5, 4, 3); scene.add(key)
const rim = new THREE.DirectionalLight(0xe4ecff, 0.9); rim.position.set(-3, 1.5, -3); scene.add(rim)

function gradientMap(steps) {
  const data = new Uint8Array(steps.length * 4)
  steps.forEach((v, i) => { data[i * 4] = data[i * 4 + 1] = data[i * 4 + 2] = v; data[i * 4 + 3] = 255 })
  const t = new THREE.DataTexture(data, steps.length, 1, THREE.RGBAFormat)
  t.minFilter = t.magFilter = THREE.NearestFilter
  t.needsUpdate = true
  return t
}
const toon = gradientMap([205, 225, 245, 255])   // flat, low-contrast -- reads as a sticker fill, not 3D shading
const INK = 0x241f33   // bold near-black-navy outline, sticker style

// ---------- palette ----------
// GREY_DARK is now only a half-step off GREY: limbs used to be noticeably darker,
// which made them read as bolted-on parts instead of the same fur. The ink outline
// is what separates a limb from the body in this style, not a value change.
// Warm ash-grey instead of the old cool blue-lavender palette -- real koala fur
// reads as warm neutral grey with a soft brown undertone, not periwinkle. That
// blue cast was quietly working against every other koala-specific shape cue
// (round ears, big nose, cream bib) by reading as a generic plush toy.
const GREY = 0xb0ac9e, GREY_DARK = 0x98937f, GREY_LIGHT = 0xdad6c8, CREAM = 0xfaf3e6, BLUSH = 0xff9cb6, NOSE = 0x1f1a17, EAR_PINK = 0xf2a8b0
// the sleepy-time log the koala hugs: warm mid-brown with a darker tone for bark rings
const LOG = 0xa9784b, LOG_DARK = 0x744c2c

const toonMat = (color) => new THREE.MeshToonMaterial({ color, gradientMap: toon })
const outlineMat = new THREE.MeshBasicMaterial({ color: INK, side: THREE.BackSide })
// Outline weight is given in WORLD units, not as a scale factor, so every part of
// the character gets the same thickness of ink around it. Passing a raw factor made
// big parts (the body) read bold and small ones (limbs, tuft, headset cups) read as
// hairlines, which is what made the koala look like glued-together primitives.
// `ref` is the part's effective radius in world units *after* any mesh scale, so the
// backface hull expands by `w` no matter how small the part is. Tiny parts are capped
// so their outline can't balloon them out of shape.
const INK_W = 0.062
function withOutline(mesh, ref = 1, w = INK_W) {
  const o = new THREE.Mesh(mesh.geometry, outlineMat)
  o.scale.setScalar(Math.min(1 + w / ref, 1.42))
  mesh.add(o)
  return mesh
}

// ---------- the koala ----------
const pet = new THREE.Group()           // squash/stretch + hover
const head = new THREE.Group()          // rotation toward cursor
pet.add(head)
scene.add(pet)

// one round dome for head and body -- koalas read as one big fluffy ball
const BX = 1.12, BY = 1.0, BZ = 1.04   // the body ellipsoid, shared by every face decal
const body = withOutline(new THREE.Mesh(new THREE.SphereGeometry(1, 128, 128), toonMat(GREY)), 1.06)
body.scale.set(BX, BY, BZ)
head.add(body)

// z of the body surface at a given (x, y) on the front
const surfZ = (x, y) => Math.sqrt(Math.max(0.0001, 1 - (x / BX) ** 2 - (y / BY) ** 2)) * BZ

// a fur tuft on top of the head -- the little cowlick that reads as "koala" in flat art.
// Rounded and fatter than the old thin spike, and with proper outline weight so it
// reads as a tuft of fur rather than a stray triangle.
const tuftGroup = new THREE.Group()
;[[-0.11, 0.17, -0.24], [0.06, 0.2, 0.0], [0.22, 0.16, 0.28]].forEach(([x, r, tilt]) => {
  const t = withOutline(new THREE.Mesh(new THREE.SphereGeometry(r, 48, 48), toonMat(GREY)), r, 0.05)
  t.position.set(x, 0.89, 0.08); t.rotation.z = tilt
  t.scale.set(0.9, 1.3, 0.7)
  tuftGroup.add(t)
})
head.add(tuftGroup)

// The cream front: ONE continuous bib running from behind the nose all the way
// down between the legs. It used to be two flat CircleGeometry discs (muzzle +
// belly) sitting at fixed z, which cut into the body sphere and left a hard clipped
// arc across the face plus a pinched snowman seam where they overlapped. Now it's a
// single mesh whose vertices are pushed onto the body ellipsoid, so it wraps the
// form cleanly with no seam and no clipping at any angle.
function bibWidth(y) {
  const ellipse = (cy, a, b) => { const u = (y - cy) / b; return Math.abs(u) >= 1 ? -1 : a * Math.sqrt(1 - u * u) }
  const w1 = ellipse(-0.12, 0.50, 0.40)   // the muzzle lobe, around the nose
  const w2 = ellipse(-0.56, 0.63, 0.40)   // the belly lobe, wider and running lower
  const k = 0.10, h = Math.max(0, k - Math.abs(w1 - w2)) / k   // smooth union, so no corner at the join
  return Math.max(Math.max(w1, w2), 0) + h * h * k * 0.25
}
function frontPatch(width, y0, y1, color, push = 0.014, rows = 56, cols = 28) {
  const pos = [], idx = []
  for (let i = 0; i <= rows; i++) {
    const y = y0 + (y1 - y0) * (i / rows), hw = width(y)
    for (let j = 0; j <= cols; j++) {
      const x = (j / cols - 0.5) * 2 * hw
      pos.push(x, y, surfZ(x, y) + push)
    }
  }
  for (let i = 0; i < rows; i++) for (let j = 0; j < cols; j++) {
    const a = i * (cols + 1) + j, c = a + cols + 1
    idx.push(a, c, a + 1, a + 1, c, c + 1)
  }
  const g = new THREE.BufferGeometry()
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3))
  g.setIndex(idx); g.computeVertexNormals()
  return new THREE.Mesh(g, new THREE.MeshBasicMaterial({ color }))
}
// the ends are exactly where each lobe's width reaches zero, so the bib terminates in
// a rounded point on the body surface instead of a flat cut running off the sphere
const bib = frontPatch(bibWidth, 0.28, -0.96, CREAM)
head.add(bib)

// big round ears with pink insides, sitting high on the sides of the head --
// the single most koala thing about a koala
function makeEar(side) {
  const g = new THREE.Group()
  const R = 0.62                          // bigger ears: more head-forward, bouncier silhouette
  const outer = withOutline(new THREE.Mesh(new THREE.SphereGeometry(R, 72, 72), toonMat(GREY)), R)
  outer.scale.set(1, 1, 0.58)
  const inner = new THREE.Mesh(new THREE.CircleGeometry(R * 0.66, 64), new THREE.MeshBasicMaterial({ color: EAR_PINK }))
  inner.position.z = R * 0.6; inner.scale.set(1, 1.04, 1)
  g.add(outer, inner)
  g.position.set(side * 1.02, 0.7, -0.04)
  g.rotation.y = side * 0.15
  return g
}
const earL = makeEar(-1), earR = makeEar(1)
head.add(earL, earR)

// flat, solid dot eyes -- almost entirely dark with one small highlight, sticker-style
function makeEye(r, pupilR, derpX, derpY, lazy) {
  const g = new THREE.Group()
  const white = withOutline(new THREE.Mesh(new THREE.SphereGeometry(r, 64, 64), new THREE.MeshBasicMaterial({ color: NOSE })), r, 0.018)
  const pupil = new THREE.Group()
  const dark = new THREE.Mesh(new THREE.SphereGeometry(pupilR, 48, 48), new THREE.MeshBasicMaterial({ color: NOSE }))
  const shine = new THREE.Mesh(new THREE.SphereGeometry(pupilR * 0.44, 32, 32), new THREE.MeshBasicMaterial({ color: 0xffffff }))
  shine.position.set(-pupilR * 0.34, pupilR * 0.4, pupilR * 0.86)
  pupil.add(dark, shine)
  pupil.position.z = r * 0.82
  // lid: a grey cap that slides down over the eye
  const lid = new THREE.Mesh(new THREE.SphereGeometry(r * 1.07, 48, 24, 0, Math.PI * 2, 0, 1.3), toonMat(GREY))
  lid.rotation.x = 0.55
  // fully closed: grey ball with a sleepy line
  const closed = new THREE.Group()
  const ball = withOutline(new THREE.Mesh(new THREE.SphereGeometry(r * 1.03, 64, 64), toonMat(GREY)), r * 1.03)
  const arc = new THREE.Mesh(new THREE.TorusGeometry(r * 0.5, 0.03, 12, 48, Math.PI), new THREE.MeshBasicMaterial({ color: INK }))
  arc.position.set(0, -r * 0.05, r * 1.0); arc.rotation.z = Math.PI
  closed.add(ball, arc); closed.visible = false
  g.add(white, pupil, lid, closed)
  g.userData = { r, pupil, lid, closed, derpX, derpY, lazy, base: null }
  return g
}
// small and set low/centre on the face -- koala eyes are tiny compared to the nose
// a touch bigger and set a little wider and higher than before: more of a cartoon
// face, and it gives the (very large) nose room to breathe underneath
const eyeL = makeEye(0.215, 0.185, -0.02, 0.02, 0.3), eyeR = makeEye(0.2, 0.17, 0.03, -0.01, 0.42)
eyeL.position.set(-0.4, 0.24, 0.88); eyeR.position.set(0.42, 0.23, 0.88)
eyeL.userData.base = eyeL.position.clone(); eyeR.userData.base = eyeR.position.clone()
head.add(eyeL, eyeR)
let eyePop = 0, eyePopV = 0

// the nose: one big glossy black wedge dominating the lower-centre of the face
const noseMat = new THREE.MeshBasicMaterial({ color: NOSE })
const nose = withOutline(new THREE.Mesh(new THREE.SphereGeometry(1, 64, 64), noseMat), 0.3)
nose.scale.set(0.32, 0.235, 0.17)
nose.position.set(0, -0.2, 1.06)
head.add(nose)
const noseShine = new THREE.Mesh(new THREE.CircleGeometry(0.06, 48), new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.85 }))
noseShine.position.set(-0.1, -0.14, 1.19)
head.add(noseShine)

// the mouth: short, gentle, sits just under the nose (koalas don't grin wide)
function facePoint(x, y, push = 0.02) {
  return new THREE.Vector3(x, y, surfZ(x, y) + push)
}
// The mouth used to sit at y = -0.36, which is squarely behind the nose -- it was
// invisible in every still. Dropped clear of the nose and widened a little so the
// smile actually reads, and so the talking "O" has somewhere to open.
const mouthPts = []
for (let i = 0; i <= 40; i++) {
  const u = i / 40 - 0.5               // -0.5..0.5
  const x = u * 0.6
  const y = -0.66 + (u * u) * 0.4
  mouthPts.push(facePoint(x, y, 0.02))
}
const mouth = new THREE.Mesh(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(mouthPts), 64, 0.024, 16, false), new THREE.MeshBasicMaterial({ color: INK }))
head.add(mouth)
const mouthO = new THREE.Mesh(new THREE.SphereGeometry(1, 48, 48), new THREE.MeshBasicMaterial({ color: INK }))
mouthO.scale.set(0.13, 0.1, 0.05); mouthO.position.copy(facePoint(0, -0.63, 0)); mouthO.visible = false
head.add(mouthO)

// cheek fluff: hidden at rest, puffs out beside the mouth while you talk. Blush rides on it.
const cheekMat = new THREE.MeshBasicMaterial({ color: BLUSH, transparent: true, opacity: 0.8 })
const pouches = [-1, 1].map(side => {
  const g = new THREE.Group()
  const ball = withOutline(new THREE.Mesh(new THREE.SphereGeometry(1, 64, 64), toonMat(GREY)), 0.3)
  const blush = new THREE.Mesh(new THREE.CircleGeometry(0.2, 48), cheekMat)
  blush.position.set(side * 0.12, -0.05, 0.98)
  g.add(ball, blush)
  // pulled in and down so the puff lands on the cheek instead of swallowing the
  // ear and the shoulder the way it did at full mic level
  g.position.copy(facePoint(side * 0.58, -0.4, -0.1))
  g.userData.side = side
  head.add(g)
  return g
})
// resting blush dots on the face
;[-0.72, 0.72].forEach(x => {
  const c = new THREE.Mesh(new THREE.CircleGeometry(0.085, 48), cheekMat)
  c.position.copy(facePoint(x * 0.9, -0.14, 0.09))
  head.add(c)
})

// legs: standing, not sitting -- two stubby vertical columns well out to the
// sides of the belly patch, so they read as separate pillars with a clear
// gap between them, feet planted on the ground. Arms hang at the sides
// rather than clasping the belly. No haunches, no stump, no fold.
const limbMat = toonMat(GREY_DARK)
const padMat = toonMat(GREY_LIGHT)
function pawClaws(parent, r, count, spread, z) {
  for (let i = 0; i < count; i++) {
    const u = count === 1 ? 0 : i / (count - 1) - 0.5
    const c = new THREE.Mesh(new THREE.SphereGeometry(r, 20, 20), new THREE.MeshBasicMaterial({ color: INK }))
    c.position.set(u * spread, -0.02, z)
    parent.add(c)
  }
}
// arms and hands are kept around so frame() can blend them between the normal
// hanging pose and a "hugging the log" pose while sleeping
const arms = [], hands = []
;[-1, 1].forEach(side => {
  // leg: a stubby vertical column well out to the side of the belly patch,
  // so the two legs read as separate pillars with a clear gap between them
  // capsules were 6x16 -- visibly faceted at this size. Round them right out; a
  // couple of hundred extra tris on a 260px canvas costs nothing.
  const leg = withOutline(new THREE.Mesh(new THREE.CapsuleGeometry(0.22, 0.2, 16, 48), limbMat), 0.22)
  leg.position.set(side * 0.57, -0.92, 0.44)
  pet.add(leg)
  // foot: one small rounded pad on the ground, toes pointing forward
  const foot = new THREE.Group()
  foot.position.set(side * 0.58, -1.2, 0.56); foot.rotation.y = side * -0.12
  const footPad = withOutline(new THREE.Mesh(new THREE.SphereGeometry(1, 64, 64), padMat), 0.24)
  footPad.scale.set(0.26, 0.13, 0.3); foot.add(footPad)
  pawClaws(foot, 0.03, 3, 0.25, 0.24)
  pet.add(foot)

  // arm: hangs down the side of the body, bent slightly inward at the elbow.
  // Shortened and pulled up/in so the shoulder end is buried in the body instead of
  // stopping in mid-air -- it used to read as a detached pill parked beside the torso.
  const arm = withOutline(new THREE.Mesh(new THREE.CapsuleGeometry(0.155, 0.38, 16, 48), limbMat), 0.155)
  // the lean used to be outward, which left the shoulder end capped in ink out in
  // open air. Tipped the other way and set back in z, so the shoulder is swallowed by
  // the body and only the forearm and paw break the silhouette -- an arm, not a pill.
  arm.position.set(side * 1.06, -0.42, 0.26); arm.rotation.set(0.06, 0, side * 0.3)
  pet.add(arm)
  // hugging pose: swung forward and tipped inward so the forearm runs down-and-in
  // across the front of the body, ending beside the log
  arm.userData.base = { p: arm.position.clone(), r: arm.rotation.clone() }
  arm.userData.hug = { p: new THREE.Vector3(side * 0.66, -0.66, 0.84), r: new THREE.Euler(-0.95, side * 0.25, -side * 1.05) }
  arms.push(arm)
  // paw: a small mitt at hip height, at the side (never in front of the belly)
  const hand = new THREE.Group()
  // sits exactly on the end of the forearm so the two read as one limb
  hand.position.set(side * 1.16, -0.79, 0.26); hand.rotation.y = side * 0.3
  const pad = withOutline(new THREE.Mesh(new THREE.SphereGeometry(1, 64, 64), padMat), 0.16)
  pad.scale.set(0.17, 0.15, 0.16); hand.add(pad)
  pawClaws(hand, 0.024, 2, 0.11, 0.14)
  pet.add(hand)
  // hugging pose: the mitt comes round to the front of the log, claws turned inward
  // so the two paws read as clasped together over the bark
  hand.userData.base = { p: hand.position.clone(), r: hand.rotation.clone() }
  hand.userData.hug = { p: new THREE.Vector3(side * 0.28, -0.74, 1.06), r: new THREE.Euler(0.2, -side * 1.35, -side * 0.5) }
  hands.push(hand)
})

// the log the koala hugs while it sleeps: a stubby brown branch standing between the
// feet and pressed against the belly, with a couple of darker bark rings. Scaled in
// and out the same way the headset is, so it grows rather than pops.
const LOG_R = 0.29, LOG_H = 1.0
const logGroup = new THREE.Group()
{
  const trunk = withOutline(new THREE.Mesh(new THREE.CylinderGeometry(LOG_R, LOG_R * 1.07, LOG_H, 48, 1), toonMat(LOG)), LOG_R)
  logGroup.add(trunk)
  // bark: short dark dashes sitting just proud of the trunk, inside the ink hull.
  // Squashed hard in z so only a stub of each ring shows on the front -- bark texture,
  // not barrel hoops.
  const barkMat = toonMat(LOG_DARK)
  ;[[0.22, 0.3], [-0.2, 0.22]].forEach(([y, sz]) => {
    const ring = new THREE.Mesh(new THREE.TorusGeometry(LOG_R * 1.01, 0.018, 10, 48), barkMat)
    ring.rotation.x = Math.PI / 2
    ring.position.y = y
    ring.scale.set(1, 1, sz)
    logGroup.add(ring)
  })
  // a couple of vertical grain lines down the front
  ;[[-0.1, 0.34, 0.06], [0.12, 0.26, -0.2]].forEach(([x, h, y]) => {
    const grain = new THREE.Mesh(new THREE.CapsuleGeometry(0.016, h, 6, 12), barkMat)
    grain.position.set(x, y, Math.sqrt(Math.max(0.0001, LOG_R ** 2 - x * x)) * 0.98)
    logGroup.add(grain)
  })
  logGroup.position.set(0, -1.08, 0.92)
  logGroup.scale.setScalar(0.001)
  logGroup.visible = false
  pet.add(logGroup)
}
let hug = 0, hugV = 0

// a eucalyptus leaf drifts by; snapped up (and re-grown) when a dictation lands
const leaf = new THREE.Group()
{
  const shape = new THREE.Shape()
  shape.moveTo(0, 0.12)
  shape.quadraticCurveTo(0.09, 0.06, 0.05, 0)
  shape.quadraticCurveTo(0.09, -0.06, 0, -0.12)
  shape.quadraticCurveTo(-0.09, -0.06, -0.05, 0)
  shape.quadraticCurveTo(-0.09, 0.06, 0, 0.12)
  const geo = new THREE.ShapeGeometry(shape)
  const blade = new THREE.Mesh(geo, new THREE.MeshBasicMaterial({ color: 0x6f9b4f, side: THREE.DoubleSide }))
  const vein = new THREE.Mesh(new THREE.PlaneGeometry(0.01, 0.2), new THREE.MeshBasicMaterial({ color: 0x4d6f37 }))
  leaf.add(blade, vein)
  leaf.scale.setScalar(2.2)
  scene.add(leaf)
}
let leafEaten = 0   // time left hidden
let leafSpeed = 1, leafPhase = 0   // drift pace; videos slow it down
let calm = 0   // 0..1: slower, softer motion for videos (gentler spring, rarer moves, deeper breathing)

// retro military headset: on while taking notes
const phones = new THREE.Group()
let led
{
  const olive = toonMat(0x6b7a3f), oliveDark = toonMat(0x4f5a2e), leather = toonMat(0x4a3728)
  const khaki = new THREE.MeshBasicMaterial({ color: 0xc9b98a })
  const grille = new THREE.MeshBasicMaterial({ color: 0x2b3326 })
  const steel = new THREE.MeshBasicMaterial({ color: 0x9aa0a6 })
  const rubber = toonMat(0x2a2a2a)
  // on a torus the "ref" is the ring radius: scaling the hull outwards is what
  // produces the visible offset ring, so pass that rather than the tube radius
  const band = withOutline(new THREE.Mesh(new THREE.TorusGeometry(1.07, 0.075, 24, 96, Math.PI), olive), 1.07)
  band.position.y = 0.05
  const pad = withOutline(new THREE.Mesh(new THREE.TorusGeometry(1.1, 0.085, 24, 48, Math.PI * 0.42), leather), 1.1)
  pad.position.y = 0.05; pad.rotation.z = Math.PI * 0.29
  const rivetL = new THREE.Mesh(new THREE.SphereGeometry(0.035, 24, 24), steel); rivetL.position.set(-0.62, 0.95, 0.1)
  const rivetR = rivetL.clone(); rivetR.position.x = 0.62
  function can(side) {
    const g = new THREE.Group()
    const cup = withOutline(new THREE.Mesh(new THREE.SphereGeometry(1, 64, 64), oliveDark), 0.27)
    cup.scale.set(0.26, 0.34, 0.28)
    const rimm = new THREE.Mesh(new THREE.TorusGeometry(0.21, 0.038, 20, 64), khaki)
    rimm.position.x = side * 0.21; rimm.rotation.y = Math.PI / 2
    const disc = new THREE.Mesh(new THREE.CircleGeometry(0.18, 64), grille)
    disc.position.x = side * 0.225; disc.rotation.y = side * Math.PI / 2
    const screw = new THREE.Mesh(new THREE.SphereGeometry(0.04, 24, 24), steel)
    screw.position.x = side * 0.23
    g.add(cup, rimm, disc, screw)
    g.position.set(side * 1.08, 0.02, 0.06)
    return g
  }
  const canL = can(-1), canR = can(1)
  const armCurve = new THREE.CatmullRomCurve3([
    new THREE.Vector3(-1.0, -0.12, 0.3), new THREE.Vector3(-0.85, -0.42, 0.72), new THREE.Vector3(-0.45, -0.5, 0.98), new THREE.Vector3(-0.22, -0.46, 1.06)])
  const arm = new THREE.Mesh(new THREE.TubeGeometry(armCurve, 48, 0.03, 16, false), rubber)
  const capsule = withOutline(new THREE.Mesh(new THREE.SphereGeometry(1, 48, 48), rubber), 0.075, 0.025)
  capsule.scale.set(0.085, 0.07, 0.07); capsule.position.set(-0.19, -0.46, 1.08)
  const capsuleTip = new THREE.Mesh(new THREE.SphereGeometry(0.032, 20, 20), steel); capsuleTip.position.set(-0.19, -0.46, 1.15)
  const coilPts = []
  for (let i = 0; i <= 90; i++) { const a = i / 90 * Math.PI * 2 * 6; coilPts.push(new THREE.Vector3(1.12 + Math.cos(a) * 0.05, -0.22 - i / 90 * 0.62, 0.12 + Math.sin(a) * 0.05)) }
  const coil = new THREE.Mesh(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(coilPts), 240, 0.015, 12, false), rubber)
  led = new THREE.Mesh(new THREE.SphereGeometry(0.038, 24, 24), new THREE.MeshBasicMaterial({ color: 0xff3b3b }))
  led.position.set(-0.99, 0.24, 0.31)
  phones.add(band, pad, rivetL, rivetR, canL, canR, arm, capsule, capsuleTip, coil, led)
  phones.position.y = 0.22
  phones.scale.setScalar(0.001)
  head.add(phones)
}
let ph = 0, phV = 0

// soft floor shadow
function radialTexture(inner, outer) {
  const c = document.createElement('canvas'); c.width = c.height = 128
  const ctx = c.getContext('2d')
  const g = ctx.createRadialGradient(64, 64, 4, 64, 64, 64)
  g.addColorStop(0, inner); g.addColorStop(1, outer)
  ctx.fillStyle = g; ctx.fillRect(0, 0, 128, 128)
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace
  return t
}
const shadow = new THREE.Mesh(new THREE.PlaneGeometry(2.6, 2.6), new THREE.MeshBasicMaterial({ map: radialTexture('rgba(30,32,40,0.35)', 'rgba(30,32,40,0)'), transparent: true, depthWrite: false }))
shadow.rotation.x = -Math.PI / 2; shadow.position.y = -1.22; shadow.scale.set(1.7, 0.55, 1)
scene.add(shadow)

// listening glow
const halo = new THREE.Mesh(new THREE.PlaneGeometry(4.6, 4.6), new THREE.MeshBasicMaterial({ map: radialTexture('rgba(200,215,255,0.9)', 'rgba(200,215,255,0)'), color: 0xffffff, transparent: true, opacity: 0, blending: THREE.AdditiveBlending, depthWrite: false }))
halo.position.z = -1.2
scene.add(halo)

// sparkles
const SPARKS = 48
const sparkGeo = new THREE.BufferGeometry()
const sparkPos = new Float32Array(SPARKS * 3)
sparkGeo.setAttribute('position', new THREE.BufferAttribute(sparkPos, 3))
const sparks = new THREE.Points(sparkGeo, new THREE.PointsMaterial({ color: 0xfff1a8, size: 0.3, transparent: true, opacity: 0, map: radialTexture('rgba(255,255,255,1)', 'rgba(255,255,255,0)'), blending: THREE.AdditiveBlending, depthWrite: false }))
scene.add(sparks)
const sparkVel = new Float32Array(SPARKS * 3)
let sparkLife = 0

// sleepy z's and a question mark
function textSprite(txt) {
  const c = document.createElement('canvas'); c.width = 64; c.height = 64
  const ctx = c.getContext('2d')
  ctx.font = 'bold 44px -apple-system, Helvetica, sans-serif'
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle'
  ctx.lineWidth = 6; ctx.strokeStyle = '#33383f'; ctx.strokeText(txt, 32, 34)
  ctx.fillStyle = '#ffffff'; ctx.fillText(txt, 32, 34)
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace
  const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: t, transparent: true, opacity: 0, depthWrite: false }))
  s.scale.setScalar(0.45)
  return s
}
const zs = [textSprite('z'), textSprite('z'), textSprite('z')]
zs.forEach(z => scene.add(z))
const qmark = textSprite('?'); qmark.scale.setScalar(0.7); scene.add(qmark)

// ---------- sounds ----------
const sfx = {
  enabled: true, ctx: null,
  ac() { if (!this.ctx) this.ctx = new (window.AudioContext || window.webkitAudioContext)(); if (this.ctx.state === 'suspended') this.ctx.resume(); return this.ctx },
  tone({ type = 'sine', from = 440, to = from, dur = 0.12, vol = 0.25, delay = 0, attack = 0.005, curve = 'exp' }) {
    const c = this.ac(), t0 = c.currentTime + delay
    const o = c.createOscillator(), g = c.createGain()
    o.type = type
    o.frequency.setValueAtTime(from, t0)
    if (curve === 'exp') o.frequency.exponentialRampToValueAtTime(Math.max(20, to), t0 + dur)
    else o.frequency.linearRampToValueAtTime(to, t0 + dur)
    g.gain.setValueAtTime(0.0001, t0)
    g.gain.exponentialRampToValueAtTime(vol, t0 + attack)
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur)
    o.connect(g).connect(c.destination)
    o.start(t0); o.stop(t0 + dur + 0.02)
  },
  noise({ dur = 0.08, vol = 0.15, delay = 0, freq = 1800, q = 1.2 }) {
    const c = this.ac(), t0 = c.currentTime + delay
    const n = Math.floor(c.sampleRate * dur), buf = c.createBuffer(1, n, c.sampleRate), d = buf.getChannelData(0)
    for (let i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / n)
    const src = c.createBufferSource(); src.buffer = buf
    const f = c.createBiquadFilter(); f.type = 'bandpass'; f.frequency.value = freq; f.Q.value = q
    const g = c.createGain(); g.gain.setValueAtTime(vol, t0); g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur)
    src.connect(f).connect(g).connect(c.destination); src.start(t0)
  },
  play(name) {
    if (!this.enabled) return
    try {
      switch (name) {
        case 'pop':      this.tone({ from: 420, to: 150, dur: 0.12, vol: 0.28 }); this.noise({ dur: 0.03, vol: 0.08, freq: 2500 }); break
        case 'gulp':     this.tone({ from: 260, to: 90, dur: 0.16, vol: 0.22 }); this.tone({ from: 150, to: 220, dur: 0.09, vol: 0.14, delay: 0.15 }); break
        case 'ding':     this.tone({ from: 1046, dur: 0.22, vol: 0.18 }); this.tone({ from: 1318, dur: 0.32, vol: 0.18, delay: 0.09 }); this.tone({ from: 2637, dur: 0.18, vol: 0.06, delay: 0.16 }); break
        case 'munch':    this.tone({ type: 'triangle', from: 260, to: 700, dur: 0.09, vol: 0.14 }); this.noise({ dur: 0.05, vol: 0.06, freq: 1200, delay: 0.07 }); break
        case 'huh':      this.tone({ type: 'triangle', from: 420, to: 300, dur: 0.16, vol: 0.18, curve: 'lin' }); this.tone({ type: 'triangle', from: 300, to: 440, dur: 0.18, vol: 0.16, delay: 0.17, curve: 'lin' }); break
        case 'radioOn':  this.noise({ dur: 0.12, vol: 0.12, freq: 1500, q: 0.8 }); this.tone({ type: 'square', from: 1200, dur: 0.06, vol: 0.06, delay: 0.1 }); this.tone({ type: 'square', from: 1600, dur: 0.07, vol: 0.06, delay: 0.18 }); break
        case 'radioOff': this.tone({ type: 'square', from: 1200, dur: 0.06, vol: 0.06 }); this.tone({ type: 'square', from: 800, dur: 0.1, vol: 0.06, delay: 0.09 }); this.noise({ dur: 0.08, vol: 0.08, freq: 1200, q: 0.8, delay: 0.18 }); break
        case 'boop':     this.tone({ from: 600, to: 800, dur: 0.07, vol: 0.2 }); this.tone({ from: 800, to: 420, dur: 0.1, vol: 0.16, delay: 0.07 }); break
        case 'yawn':     this.tone({ type: 'sine', from: 220, to: 140, dur: 0.5, vol: 0.1, attack: 0.15, curve: 'lin' }); this.tone({ type: 'sine', from: 260, to: 180, dur: 0.4, vol: 0.06, delay: 0.15, curve: 'lin' }); break
      }
    } catch (e) { /* audio not available */ }
  },
}

// ---------- state ----------
let state = 'idle'
let stateT = 0
let level = 0, levelSmooth = 0
const look = { x: 0, y: 0, tx: 0, ty: 0 }
let sq = 0, sqV = 0
let blinkT = 3.2, blink = 0
let hopT = 7 + Math.random() * 8
let talking = false
const slide = { x: 0, y: 0, tx: 0, ty: 0, speed: 3 }
const cam = { tz: camera.position.z, speed: 0 }

function impulse(v) { sqV += v * (1 - 0.5 * calm) }

window.pet = {
  name: 'koala',
  setState(s) {
    if (s === state) return
    const prev = state
    state = s; stateT = 0
    if (s === 'listening') { impulse(-3); sfx.play('pop') }
    if (s === 'thinking' && prev === 'listening') sfx.play('gulp')
    if (s === 'done') { impulse(6); burst(); sfx.play('munch'); sfx.play('ding'); leafEaten = 6 }
    if (s === 'confused') { impulse(2); sfx.play('huh') }
    if (s === 'noting') { impulse(-2); sfx.play('radioOn') }
    if (prev === 'noting' && s !== 'noting') sfx.play('radioOff')
    if (s === 'idle') { impulse(1.5); if (prev === 'loading' || prev === 'sleeping') sfx.play('yawn') }
  },
  setLevel(v) { level = Math.max(0, Math.min(1, v)) },
  lookAt(x, y) { look.tx = x; look.ty = y },
  setSounds(on) { sfx.enabled = !!on },
  setTalking(on) { talking = !!on },
  setFlySpeed(k) { leafSpeed = Math.max(0, +k || 0) },
  setCalm(c) { calm = Math.max(0, Math.min(1, +c || 0)) },
  setOffset(x, y, secs) { slide.tx = x; slide.ty = y; slide.speed = secs ? 1 / Math.max(0.05, secs) : 3 },
  ui(html) { let u = document.getElementById('ui'); if (!u) { u = document.createElement('div'); u.id = 'ui'; document.body.appendChild(u) } u.innerHTML = html || '' },
  typeInto(id, text, ms) { const el = document.getElementById(id); if (!el) return; let i = 0; const step = Math.max(12, ms / Math.max(1, text.length)); el.textContent = ''; const tick = () => { i++; el.textContent = text.slice(0, i); if (i < text.length) setTimeout(tick, step) }; setTimeout(tick, step) },
  reveal(cls, everyMs) { const els = document.querySelectorAll('.' + cls); els.forEach((el, i) => setTimeout(() => el.classList.add('on'), i * everyMs)) },
  setCaption(text) { let c = document.getElementById('cap'); if (!c) { c = document.createElement('div'); c.id = 'cap'; document.body.appendChild(c) } c.textContent = text || ''; c.style.opacity = text ? 1 : 0 },
  setZoom(z) { camera.position.z = z; cam.tz = z; cam.speed = 0 },
  zoomTo(z, secs) { cam.tz = z; cam.speed = 1 / Math.max(0.05, secs) },
  cursor(x, y) { let c = document.getElementById('cur'); if (!c) { c = document.createElement('div'); c.id = 'cur'; c.innerHTML = '<svg width="56" height="70" viewBox="0 0 24 30"><path d="M2 2 L2 24 L8 18 L12 28 L16 26 L12 17 L20 17 Z" fill="#fff" stroke="#1d1d1f" stroke-width="1.6" stroke-linejoin="round"/></svg>'; document.body.appendChild(c) } if (x == null) { c.style.display = 'none'; return } c.style.display = 'block'; c.style.left = x + 'px'; c.style.top = y + 'px' },
  boop() { impulse(5); sfx.play('boop') },
  state: () => state,
}

function burst() {
  for (let i = 0; i < SPARKS; i++) {
    const a = Math.random() * Math.PI * 2, b = (Math.random() - 0.5) * Math.PI
    const sp = 1.8 + Math.random() * 2.8
    sparkPos[i * 3] = 0; sparkPos[i * 3 + 1] = 0.1; sparkPos[i * 3 + 2] = 0.5
    sparkVel[i * 3] = Math.cos(a) * Math.cos(b) * sp
    sparkVel[i * 3 + 1] = Math.sin(b) * sp + 1.5
    sparkVel[i * 3 + 2] = Math.sin(a) * Math.cos(b) * sp * 0.5
  }
  sparkLife = 1
}

// ---------- loop ----------
const clock = new THREE.Clock()
function frame() {
  requestAnimationFrame(frame)
  const dt = Math.min(clock.getDelta(), 1 / 20)
  const t = clock.elapsedTime
  stateT += dt

  const k = 150 - 65 * calm, d = 13 + 13 * calm
  sqV += (-k * sq - d * sqV) * dt
  sq += sqV * dt

  const lk = 6 - 4 * calm
  look.x += (look.tx - look.x) * Math.min(1, dt * lk)
  look.y += (look.ty - look.y) * Math.min(1, dt * lk)
  levelSmooth += (level - levelSmooth) * Math.min(1, dt * 14)

  let hover = Math.sin(t * (1.1 - 0.9 * calm)) * (0.025 - 0.018 * calm)   // calm: a faint bob every ~30 s
  let breathe = 1 + Math.sin(t * (1.6 - 1.3 * calm)) * (0.014 + 0.024 * calm)   // calm: one slow breath
  let throatScale = 1
  let rotX = -look.y * 0.16, rotY = look.x * 0.28, rotZ = 0
  let eyeOpen = 1
  let mouthOpen = 0
  let haloOpacity = 0
  let zOpacity = 0, qOpacity = 0
  let showGrin = true

  // blink -- koalas blink slow and lazy
  blinkT -= dt
  if (blinkT <= 0) { blink = 0.18; blinkT = 3.2 + Math.random() * 5 }
  if (blink > 0) { blink -= dt; eyeOpen = blink > 0.08 ? 0 : 1 }

  // idle sway now and then -- much less bouncy than a frog, koalas barely move
  hopT -= dt
  if (hopT <= 0 && state === 'idle') { impulse(-3 + 1.5 * calm); hopT = calm ? 14 + Math.random() * 6 : 9 + Math.random() * 10 }

  if (talking && (state === 'idle' || state === 'done')) {
    const m = 0.5 + 0.5 * (0.6 * Math.sin(t * (6.1 - 1.6 * calm)) + 0.4 * Math.sin(t * (3.7 - 1.1 * calm) + 1.0))
    mouthOpen = 0.08 + m * 0.3
    showGrin = false
    throatScale = 1 + 0.08 + m * 0.08
  }
  switch (state) {
    case 'listening': {
      throatScale = 1 + 0.3 + levelSmooth * 0.6
      mouthOpen = 0.25 + levelSmooth * 0.9
      showGrin = false
      rotX += 0.08
      hover = Math.sin(t * (5 - 3 * calm)) * 0.015 * (0.3 + levelSmooth)
      haloOpacity = 0.18 + levelSmooth * 0.5
      halo.scale.setScalar(1 + levelSmooth * 0.25 + Math.sin(t * 5) * 0.02)
      break
    }
    case 'thinking': {
      rotZ = Math.sin(t * 2.6) * 0.08
      rotY += Math.sin(t * 1.3) * 0.2
      rotX -= 0.1
      mouthOpen = 0.18; showGrin = false
      throatScale = 1 + 0.22 + Math.sin(t * (7 - 4 * calm)) * 0.06
      hover += Math.abs(Math.sin(t * 4)) * 0.045
      break
    }
    case 'done': {
      eyeOpen = Math.min(eyeOpen, 0.6 + 0.4 * Math.abs(Math.sin(stateT * 3)))
      if (stateT > 1.1) window.pet.setState('idle')
      break
    }
    case 'noting': {
      led.scale.setScalar(1 + Math.max(0, Math.sin(t * 5)) * 0.7)
      rotX += 0.05 + Math.sin(t * 2) * 0.04
      rotY += Math.sin(t * 0.6) * 0.1
      hover = Math.sin(t * 1) * 0.03
      break
    }
    case 'confused': {
      rotZ = 0.18 + Math.sin(t * 8) * 0.025
      qOpacity = Math.min(1, stateT * 4)
      showGrin = false; mouthOpen = 0.08
      if (stateT > 1.8) window.pet.setState('idle')
      break
    }
    case 'loading':
    case 'sleeping': {
      eyeOpen = 0
      breathe = 1 + Math.sin(t * 1.1) * 0.035
      throatScale = 1
      rotZ = Math.sin(t * 1.1) * 0.04
      rotX = 0.14; rotY *= 0.2
      zOpacity = 1
      break
    }
    default: break
  }

  // eyes bulge forward while listening
  const popTarget = state === 'listening' ? 1 : (state === 'thinking' ? 0.3 : 0)
  eyePopV += ((popTarget - eyePop) * 110 - eyePopV * 7) * dt
  eyePop += eyePopV * dt

  // headset
  const phTarget = state === 'noting' ? 1 : 0
  phV += ((phTarget - ph) * 120 - phV * 8) * dt
  ph += phV * dt
  phones.scale.setScalar(Math.max(0.001, ph) * 1.3)

  // the sleepy hug: log grows in and the arms curl forward around it
  const hugTarget = (state === 'sleeping' || state === 'loading') ? 1 : 0
  hugV += ((hugTarget - hug) * 90 - hugV * 19) * dt   // near-critically damped: no overshoot, so the log never bounces or lingers as a stub
  hug += hugV * dt
  const hugK = Math.max(0, Math.min(1, hug))
  logGroup.visible = hug > 0.04
  logGroup.scale.setScalar(Math.max(0.001, hug))
  ;[...arms, ...hands].forEach(m => {
    const b = m.userData.base, g = m.userData.hug
    m.position.lerpVectors(b.p, g.p, hugK)
    m.rotation.set(b.r.x + (g.r.x - b.r.x) * hugK, b.r.y + (g.r.y - b.r.y) * hugK, b.r.z + (g.r.z - b.r.z) * hugK)
  })

  // apply
  const s = breathe
  pet.scale.set(s * (1 + sq * 0.55), s * (1 - sq), s * (1 + sq * 0.55))
  if (cam.speed > 0) camera.position.z += (cam.tz - camera.position.z) * Math.min(1, dt * cam.speed * 2.5)
  slide.x += (slide.tx - slide.x) * Math.min(1, dt * slide.speed * 2.2)
  slide.y += (slide.ty - slide.y) * Math.min(1, dt * slide.speed * 2.2)
  pet.position.x = slide.x
  pet.position.y = hover - Math.max(0, sq) * 0.15 + slide.y
  shadow.position.x = slide.x; shadow.position.y = -1.22 + slide.y
  head.rotation.set(rotX, rotY, rotZ)
  const closed = eyeOpen < 0.15
  ;[eyeL, eyeR].forEach((e, i) => {
    const { r, pupil, lid, closed: cl, derpX, derpY, base, lazy } = e.userData
    e.position.set(base.x, base.y + eyePop * 0.05, base.z + eyePop * 0.1)
    e.scale.setScalar(1 + eyePop * 0.1)
    cl.visible = closed
    e.children[0].visible = !closed; pupil.visible = !closed; lid.visible = !closed
    let roll = state === 'thinking' ? t * 4 : 0
    pupil.position.x = closed ? 0 : (look.x * r * 0.42 + derpX + (roll ? Math.cos(roll) * r * 0.3 : 0))
    pupil.position.y = closed ? 0 : (look.y * r * 0.38 + derpY + (roll ? Math.sin(roll) * r * 0.3 : 0))
    const droop = state === 'confused' ? (i === 1 ? 0.85 : 0.3) : (state === 'listening' || state === 'done' ? 0 : lazy)
    lid.visible = !closed && droop > 0.04
    lid.position.y = r * (0.7 - droop * 0.85)
  })
  mouth.visible = showGrin
  mouthO.visible = !showGrin
  mouthO.scale.set(0.12 + mouthOpen * 0.06, 0.08 + mouthOpen * 0.12, 0.05)
  // cheeks puff with your voice, head widens a touch
  const inf = Math.max(0, throatScale - 1)
  pouches.forEach(g => {
    const r = Math.max(0.001, inf * 0.26)
    g.scale.set(r * 1.15, r, r * 0.9)
    g.visible = r > 0.03
    g.position.x = g.userData.side * (0.58 + inf * 0.08)
  })
  head.scale.set(1 + inf * 0.06, 1, 1)
  halo.material.opacity += (haloOpacity - halo.material.opacity) * Math.min(1, dt * 10)
  halo.rotation.z = t * 0.3
  shadow.material.opacity = 1 - Math.max(0, hover) * 3
  shadow.scale.set(1.7 - hover * 1.5, 0.55 - hover * 0.6, 1)

  // the leaf drifts by, hides for a while once "eaten"
  leafEaten -= dt
  leaf.visible = leafEaten <= 0 && state !== 'noting'
  leafPhase += dt * 0.8 * leafSpeed
  const fa = leafPhase, ft = leafPhase / 0.8
  leaf.position.set(Math.cos(fa) * 1.5 + Math.sin(ft * 3) * 0.05, 0.9 + Math.sin(fa * 1.3) * 0.5 + Math.sin(ft * 5) * 0.04, Math.sin(fa) * 0.9 + 0.3)
  leaf.rotation.z = Math.sin(t * 1.6) * 0.5
  leaf.rotation.y = t * 0.9

  // sparkles
  if (sparkLife > 0) {
    sparkLife -= dt * 1.1
    for (let i = 0; i < SPARKS; i++) {
      sparkVel[i * 3 + 1] -= 6 * dt
      sparkPos[i * 3] += sparkVel[i * 3] * dt
      sparkPos[i * 3 + 1] += sparkVel[i * 3 + 1] * dt
      sparkPos[i * 3 + 2] += sparkVel[i * 3 + 2] * dt
    }
    sparkGeo.attributes.position.needsUpdate = true
    sparks.material.opacity = Math.max(0, sparkLife)
  } else sparks.material.opacity = 0

  zs.forEach((z, i) => {
    const phz = (t * 0.5 + i / 3) % 1
    z.position.set(1.1 + phz * 0.5 + i * 0.05, 0.8 + phz * 1.1, 0.5)
    z.scale.setScalar(0.3 + phz * 0.35)
    z.material.opacity += ((zOpacity * (1 - phz) * Math.min(1, phz * 4)) - z.material.opacity) * Math.min(1, dt * 8)
  })
  qmark.position.set(1.15 + Math.sin(t * 5) * 0.05, 1.15, 0.5)
  qmark.material.opacity += (qOpacity - qmark.material.opacity) * Math.min(1, dt * 8)

  renderer.render(scene, camera)
}
frame()

// ---------- browser-only demo (?demo=1) ----------
if (params.get('demo')) {
  const states = ['idle', 'listening', 'thinking', 'done', 'noting', 'confused', 'sleeping']
  let i = 0
  setInterval(() => { i = (i + 1) % states.length; window.pet.setState(states[i]) }, 2600)
  setInterval(() => { if (state === 'listening') window.pet.setLevel(Math.abs(Math.sin(performance.now() / 180)) * 0.9) }, 33)
  window.addEventListener('mousemove', e => window.pet.lookAt((e.clientX / W - 0.5) * 2, -(e.clientY / H - 0.5) * 2))
}
const forced = params.get('state')
if (forced) { window.pet.setState(forced); if (forced === 'listening') window.pet.setLevel(0.7) }
