// Draws the picker animation of each gl-transition (24 frames, 96 x 64,
// side by side in one WebP) with the same two sample scenes the app uses,
// and checks each compiles as OpenGL ES 1.00 (what Android runs).
// Usage: node tool/glt_render/render.js   (after gen_gl_transitions.py)
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../..');
const entries = JSON.parse(fs.readFileSync(path.join(__dirname, 'sources.json')));
const outDir = path.join(root, 'assets/transitions');
fs.mkdirSync(outDir, { recursive: true });

(async () => {
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage();
  await page.setContent('<canvas id=c width=96 height=64></canvas><canvas id=s width=2304 height=64></canvas>');
  const results = await page.evaluate(async (entries) => {
    const W = 96, H = 64, N = 24;
    const c = document.getElementById('c');
    const gl = c.getContext('webgl', { preserveDrawingBuffer: true, premultipliedAlpha: false });
    const sheet = document.getElementById('s').getContext('2d');
    function sunset(u, v) {
      const hill = 0.72 + 0.08 * Math.sin(u * 7);
      if (v > hill) return [0.25, 0.12, 0.18];
      const dx = (u - 0.32) * 1.5, dy = v - 0.42;
      if (dx * dx + dy * dy < 0.025) return [1, 0.93, 0.55];
      return [1, 0.55 - 0.25 * v, 0.25 + 0.3 * v];
    }
    function sea(u, v) {
      if (v > 0.6) return [0.05, 0.3 + 0.2 * (1 - v), 0.55];
      const sail = u > 0.58 && u < 0.78 && v > 0.18 && v < 0.6 && (u - 0.58) < (v - 0.18) * 0.5;
      if (sail) return [1, 1, 1];
      return [0.55 + 0.3 * v, 0.78 + 0.1 * v, 0.95];
    }
    function tex(f, unit) {
      const px = new Uint8Array(W * H * 4);
      for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
        // GL rows start at the bottom.
        const col = f((x + 0.5) / W, 1 - (y + 0.5) / H);
        const i = (y * W + x) * 4;
        px[i] = Math.round(col[0] * 255); px[i + 1] = Math.round(col[1] * 255);
        px[i + 2] = Math.round(col[2] * 255); px[i + 3] = 255;
      }
      const t = gl.createTexture();
      gl.activeTexture(gl.TEXTURE0 + unit);
      gl.bindTexture(gl.TEXTURE_2D, t);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, W, H, 0, gl.RGBA, gl.UNSIGNED_BYTE, px);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    }
    tex(sunset, 0); tex(sea, 1);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const VS = 'attribute vec4 aFramePosition; varying vec2 vUv; void main(){ gl_Position = aFramePosition; vUv = aFramePosition.xy * 0.5 + 0.5; }';
    const WRAP_HEAD = "precision highp float;\nuniform sampler2D uA;\nuniform sampler2D uB;\nuniform float progress;\nuniform float ratio;\nvarying vec2 vUv;\nvec4 getFromColor(vec2 uv) { return texture2D(uA, uv); }\nvec4 getToColor(vec2 uv) { return texture2D(uB, uv); }\n";
    const WRAP_TAIL = "\nvoid main() { gl_FragColor = transition(vUv); }\n";
    const results = [];
    for (const e of entries) {
      const fsrc = WRAP_HEAD + e.body + WRAP_TAIL;
      const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
      const vs = sh(gl.VERTEX_SHADER, VS), fs = sh(gl.FRAGMENT_SHADER, fsrc);
      if (!gl.getShaderParameter(fs, gl.COMPILE_STATUS)) {
        results.push({ name: e.name, error: gl.getShaderInfoLog(fs) });
        continue;
      }
      const p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aFramePosition');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
        results.push({ name: e.name, error: gl.getProgramInfoLog(p) });
        continue;
      }
      gl.useProgram(p);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      gl.uniform1i(gl.getUniformLocation(p, 'uA'), 0);
      gl.uniform1i(gl.getUniformLocation(p, 'uB'), 1);
      const lr = gl.getUniformLocation(p, 'ratio');
      if (lr) gl.uniform1f(lr, W / H);
      const lp = gl.getUniformLocation(p, 'progress');
      sheet.clearRect(0, 0, W * N, H);
      for (let f = 0; f < N; f++) {
        if (lp) gl.uniform1f(lp, f / (N - 1));
        gl.viewport(0, 0, W, H);
        gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        sheet.drawImage(c, f * W, 0);
      }
      const err = gl.getError();
      results.push({ name: e.name, error: err ? 'GL error ' + err : null,
        webp: document.getElementById('s').toDataURL('image/webp', 0.8) });
    }
    return results;
  }, entries);
  let bad = 0;
  for (const r of results) {
    if (r.error) { bad++; console.log('FAIL', r.name, r.error.slice(0, 300)); continue; }
    fs.writeFileSync(path.join(outDir, r.name + '.webp'), Buffer.from(r.webp.split(',')[1], 'base64'));
  }
  console.log(`${results.length - bad} drawn, ${bad} failed`);
  await browser.close();
})();
