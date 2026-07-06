/* ============================================================
   c4core.js — C4 노드 그래프 엔진 (L1·L2 공용)
   사용: <script src="c4core.js"></script>
        <script>c4Graph([ {from,to,type,label,dash}, ... ]);</script>
   type: actor | ext | hw | data
   ※ views/ 의 c4.js 와 무관 (완전 분리)
   ============================================================ */
function c4Graph(EDGES) {
  const svg = document.getElementById('edges');
  const scene = document.getElementById('scene');
  if (!svg || !scene) return;

  const MK = { actor: 'm-a', ext: 'm-e', hw: 'm-h', data: 'm-d', int: 'm-i' };
  const CLS = { actor: 'el-actor', ext: 'el-ext', hw: 'el-hw', data: 'el-data', int: 'el-int' };
  const COLOR = { actor: '#34d399', ext: '#a78bfa', hw: '#22d3ee', data: '#fbbf24', int: '#60a5fa' };

  function getRect(id) {
    const el = document.getElementById(id);
    if (!el) return null;
    const r = el.getBoundingClientRect(), sr = scene.getBoundingClientRect();
    return { cx: r.left - sr.left + r.width / 2, cy: r.top - sr.top + r.height / 2, hw: r.width / 2, hh: r.height / 2 };
  }
  function edgePoint(rect, a) {
    const dx = Math.cos(a), dy = Math.sin(a);
    const sx = dx === 0 ? Infinity : rect.hw / Math.abs(dx);
    const sy = dy === 0 ? Infinity : rect.hh / Math.abs(dy);
    const s = Math.min(sx, sy) + 4;
    return { x: rect.cx + dx * s, y: rect.cy + dy * s };
  }
  function draw() {
    const w = scene.offsetWidth, h = scene.offsetHeight;
    svg.setAttribute('viewBox', `0 0 ${w} ${h}`); svg.setAttribute('width', w); svg.setAttribute('height', h);
    let defs = '<defs>';
    for (const [t, id] of Object.entries(MK))
      defs += `<marker id="${id}" markerWidth="10" markerHeight="8" refX="9" refY="4" orient="auto"><path d="M0,0 L10,4 L0,8 Z" fill="${COLOR[t]}"/></marker>`;
    svg.innerHTML = defs + '</defs>';
    EDGES.forEach(e => {
      const fr = getRect(e.from), tr = getRect(e.to);
      if (!fr || !tr) return;
      const f = edgePoint(fr, Math.atan2(tr.cy - fr.cy, tr.cx - fr.cx));
      const t = edgePoint(tr, Math.atan2(fr.cy - tr.cy, fr.cx - tr.cx));
      const mx = (f.x + t.x) / 2, my = (f.y + t.y) / 2;
      const cx = mx + (f.y - t.y) * 0.1, cy = my + (t.x - f.x) * 0.1;
      const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      p.setAttribute('d', `M${f.x},${f.y} Q${cx},${cy} ${t.x},${t.y}`);
      p.setAttribute('class', `edge-line ${CLS[e.type] || 'el-ext'}`);
      p.setAttribute('marker-end', `url(#${MK[e.type] || 'm-e'})`);
      if (e.dash) p.classList.add('edge-flow');
      svg.appendChild(p);
      const lb = document.getElementById(e.label);
      if (lb) {
        const qx = 0.25 * f.x + 0.5 * cx + 0.25 * t.x, qy = 0.25 * f.y + 0.5 * cy + 0.25 * t.y;
        lb.style.left = (qx - lb.offsetWidth / 2) + 'px';
        lb.style.top = (qy - lb.offsetHeight / 2) + 'px';
      }
    });
  }

  // 드래그 (마우스 + 터치)
  let drag = null, ox = 0, oy = 0;
  function start(n, x, y) { drag = n; const r = n.getBoundingClientRect(); ox = x - r.left - r.width / 2; oy = y - r.top - r.height / 2; n.classList.add('dragging'); }
  function move(x, y) { if (!drag) return; const sr = scene.getBoundingClientRect(); drag.style.left = ((x - ox - sr.left) / scene.offsetWidth * 100) + '%'; drag.style.top = ((y - oy - sr.top) / scene.offsetHeight * 100) + '%'; draw(); }
  function end() { if (drag) { drag.classList.remove('dragging'); drag = null; } }
  document.querySelectorAll('.node').forEach(n => {
    n.addEventListener('mousedown', e => { if (e.button !== 0) return; e.preventDefault(); start(n, e.clientX, e.clientY); });
    n.addEventListener('touchstart', e => { if (e.touches.length !== 1) return; start(n, e.touches[0].clientX, e.touches[0].clientY); }, { passive: true });
  });
  document.addEventListener('mousemove', e => { if (drag) { e.preventDefault(); move(e.clientX, e.clientY); } });
  document.addEventListener('mouseup', end);
  document.addEventListener('touchmove', e => { if (!drag) return; e.preventDefault(); move(e.touches[0].clientX, e.touches[0].clientY); }, { passive: false });
  document.addEventListener('touchend', end);

  window.addEventListener('load', () => {
    document.querySelectorAll('.node:not(.center-node)').forEach((n, i) => { n.style.animationDelay = (i * 50) + 'ms'; });
    draw();
  });
  window.addEventListener('resize', draw);
  // 폰트 로드 후 라벨 위치 보정
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(draw);
}
