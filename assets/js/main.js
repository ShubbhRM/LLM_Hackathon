/* ============================================================
   LLM HACKATHON — GPU / CUDA Dark · JavaScript
   ============================================================ */
'use strict';

const REDUCED = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/* ============================================================
   1. GPU PARTICLE CANVAS — CUDA thread network
   ============================================================ */
(function initGPUCanvas() {
  const canvas = document.getElementById('gpu-canvas');
  if (!canvas || REDUCED) return;
  const ctx = canvas.getContext('2d');

  function resize() {
    canvas.width  = canvas.offsetWidth  || window.innerWidth;
    canvas.height = canvas.offsetHeight || window.innerHeight;
  }
  resize();
  window.addEventListener('resize', resize);

  const COUNT = 65;
  const GREEN = '118,185,0';

  const particles = Array.from({ length: COUNT }, () => ({
    x: Math.random() * canvas.width,
    y: Math.random() * canvas.height,
    r: Math.random() * 1.5 + 0.4,
    vx: (Math.random() - 0.5) * 0.28,
    vy: (Math.random() - 0.5) * 0.28,
    alpha: Math.random() * 0.5 + 0.1,
    type: Math.random() < 0.15 ? 'core' : 'thread', // 15% are bright "core" nodes
  }));

  function draw() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    /* Draw connections */
    for (let i = 0; i < particles.length; i++) {
      for (let j = i + 1; j < particles.length; j++) {
        const a = particles[i], b = particles[j];
        const dx = a.x - b.x, dy = a.y - b.y;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < 110) {
          const alpha = (1 - dist / 110) * 0.18;
          ctx.beginPath();
          ctx.strokeStyle = `rgba(${GREEN},${alpha})`;
          ctx.lineWidth = 0.8;
          ctx.moveTo(a.x, a.y);
          ctx.lineTo(b.x, b.y);
          ctx.stroke();
        }
      }
    }

    /* Draw particles */
    particles.forEach(p => {
      ctx.beginPath();
      ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
      if (p.type === 'core') {
        ctx.fillStyle = `rgba(${GREEN},${p.alpha * 1.8})`;
        ctx.shadowColor = `rgba(${GREEN},0.8)`;
        ctx.shadowBlur  = 8;
      } else {
        ctx.fillStyle = `rgba(${GREEN},${p.alpha})`;
        ctx.shadowBlur = 0;
      }
      ctx.fill();
      ctx.shadowBlur = 0;

      /* Move */
      p.x += p.vx; p.y += p.vy;
      if (p.x < -10) p.x = canvas.width + 10;
      if (p.x > canvas.width + 10)  p.x = -10;
      if (p.y < -10) p.y = canvas.height + 10;
      if (p.y > canvas.height + 10) p.y = -10;
    });

    requestAnimationFrame(draw);
  }
  draw();
})();

/* ============================================================
   2. TYPEWRITER — Hero title + token-stream subtitle
   ============================================================ */
(function initTypewriter() {
  const titleEl = document.getElementById('hero-title');
  const subEl   = document.getElementById('hero-subtitle');
  if (!titleEl) return;

  const TITLE_WORDS = ['LOCAL', 'RAG', 'CODE', 'TUTOR'];
  const GREEN_WORD  = 'RAG';
  const SUBTITLE    = 'Offline Retrieval-Augmented Generation · Qwen2.5-Coder-14B · ChromaDB · cuDF';

  /* Build title spans first so cursor appears inline */
  if (REDUCED) {
    TITLE_WORDS.forEach((w, i) => {
      const span = document.createElement('span');
      span.textContent = w + (i < TITLE_WORDS.length - 1 ? ' ' : '');
      if (w === GREEN_WORD) span.className = 'green-word';
      titleEl.appendChild(span);
    });
    if (subEl) subEl.textContent = SUBTITLE;
    return;
  }

  const cursor = document.createElement('span');
  cursor.className = 'cursor'; cursor.setAttribute('aria-hidden', 'true');

  let wi = 0;
  function typeWord() {
    if (wi >= TITLE_WORDS.length) {
      titleEl.removeChild(cursor);
      if (subEl) { subEl.appendChild(cursor); setTimeout(() => typeSub(0), 120); }
      return;
    }
    const word = TITLE_WORDS[wi];
    const span = document.createElement('span');
    if (word === GREEN_WORD) span.className = 'green-word';
    titleEl.insertBefore(span, cursor);
    let ci = 0;
    function typeChar() {
      if (ci < word.length) {
        span.textContent = word.slice(0, ++ci);
        setTimeout(typeChar, 60 + Math.random() * 40);
      } else {
        if (wi < TITLE_WORDS.length - 1) {
          span.textContent += ' ';
        }
        wi++;
        setTimeout(typeWord, 90);
      }
    }
    typeChar();
  }
  titleEl.appendChild(cursor);
  setTimeout(typeWord, 400);

  function typeSub(i) {
    if (!subEl || i >= SUBTITLE.length) {
      if (subEl) subEl.removeChild(cursor);
      return;
    }
    const textNode = subEl.childNodes[0] || subEl.insertBefore(document.createTextNode(''), cursor);
    textNode.textContent = SUBTITLE.slice(0, i + 1);
    setTimeout(() => typeSub(i + 1), 12 + Math.random() * 8);
  }
})();

/* ============================================================
   3. COUNTER ANIMATION — Stats HUD numbers count up
   ============================================================ */
(function initCounters() {
  if (REDUCED) {
    const el = id => document.getElementById(id);
    if (el('stat-files'))   el('stat-files').textContent   = '8,528';
    if (el('stat-offline')) el('stat-offline').textContent = '0';
    if (el('stat-params'))  el('stat-params').textContent  = '14';
    if (el('stat-latency')) el('stat-latency').textContent = '2';
    return;
  }

  const targets = [
    { id: 'stat-files',   end: 8528,  duration: 1800, format: v => v >= 1000 ? Math.round(v).toLocaleString() : Math.round(v) },
    { id: 'stat-offline', end: 0,     duration: 600,  format: v => Math.round(v) },
    { id: 'stat-params',  end: 14,    duration: 900,  format: v => Math.round(v) },
    { id: 'stat-latency', end: 2,     duration: 700,  format: v => Math.round(v) },
  ];

  const hud = document.querySelector('.hero-hud');
  if (!hud) return;

  const observer = new IntersectionObserver(entries => {
    if (!entries[0].isIntersecting) return;
    observer.disconnect();

    targets.forEach(({ id, end, duration, format }) => {
      const el = document.getElementById(id);
      if (!el) return;
      const start = performance.now();
      function tick(now) {
        const p = Math.min((now - start) / duration, 1);
        const eased = 1 - Math.pow(1 - p, 3);
        el.textContent = format(eased * end);
        if (p < 1) requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    });
  }, { threshold: 0.3 });
  observer.observe(hud);
})();

/* ============================================================
   4. RAG PIPELINE ANIMATOR — Stages stagger in on scroll
   ============================================================ */
(function initPipelineAnim() {
  const pipeline = document.getElementById('rag-pipeline');
  if (!pipeline) return;

  const stages = pipeline.querySelectorAll('.arch-stage');

  if (REDUCED) {
    stages.forEach(s => { s.style.opacity = 1; s.style.transform = 'none'; });
    return;
  }

  const observer = new IntersectionObserver(entries => {
    if (!entries[0].isIntersecting) return;
    observer.disconnect();

    stages.forEach((stage, i) => {
      setTimeout(() => {
        stage.classList.add('stage-active');
      }, i * 180);
    });
  }, { threshold: 0.2 });
  observer.observe(pipeline);
})();

/* ============================================================
   5. MODE TABS — Click to expand/collapse mode cards
   ============================================================ */
(function initModeTabs() {
  const cards = document.querySelectorAll('.mode-card');
  if (!cards.length) return;

  function activateCard(target) {
    cards.forEach(c => {
      c.classList.remove('mode-card--active');
      c.setAttribute('aria-selected', 'false');
    });
    target.classList.add('mode-card--active');
    target.setAttribute('aria-selected', 'true');
  }

  cards.forEach(card => {
    card.addEventListener('click', () => activateCard(card));
    card.addEventListener('keydown', e => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        activateCard(card);
      }
    });
  });
})();

/* ============================================================
   6. SCROLL SPY — Highlight active nav link
   ============================================================ */
(function initScrollSpy() {
  const sections = document.querySelectorAll('section[id]');
  const links    = document.querySelectorAll('.nav-link[href^="#"]');
  if (!sections.length || !links.length) return;

  const observer = new IntersectionObserver(entries => {
    entries.forEach(e => {
      if (e.isIntersecting) {
        links.forEach(l => l.classList.remove('active'));
        const active = document.querySelector(`.nav-link[href="#${e.target.id}"]`);
        if (active) active.classList.add('active');
      }
    });
  }, { rootMargin: '-40% 0px -55% 0px' });

  sections.forEach(s => observer.observe(s));

  /* Smooth scroll */
  document.querySelectorAll('a[href^="#"]').forEach(a => {
    a.addEventListener('click', e => {
      const target = document.querySelector(a.getAttribute('href'));
      if (target) { e.preventDefault(); target.scrollIntoView({ behavior: 'smooth' }); }
    });
  });
})();

/* ============================================================
   7. MOBILE NAV TOGGLE
   ============================================================ */
(function initNav() {
  const toggle = document.getElementById('nav-toggle');
  const links  = document.getElementById('nav-links');
  if (!toggle || !links) return;

  toggle.addEventListener('click', () => {
    const open = links.classList.toggle('open');
    toggle.setAttribute('aria-expanded', String(open));
  });

  /* Close on link click */
  links.querySelectorAll('.nav-link').forEach(l => {
    l.addEventListener('click', () => {
      links.classList.remove('open');
      toggle.setAttribute('aria-expanded', 'false');
    });
  });

  /* Close on outside click */
  document.addEventListener('click', e => {
    if (!toggle.contains(e.target) && !links.contains(e.target)) {
      links.classList.remove('open');
      toggle.setAttribute('aria-expanded', 'false');
    }
  });
})();
