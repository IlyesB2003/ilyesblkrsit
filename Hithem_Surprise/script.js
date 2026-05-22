/* =========================================================
   Hithem — Surprise SPA
   - Typewriter hero
   - YouTube IFrame API (start + floating toggle)
   - Falling petals (canvas)
   - Reveal-on-scroll + nav shadow
   ========================================================= */

(() => {
    'use strict';

    /* -------------------------------------------------------
       1) TYPEWRITER
       ------------------------------------------------------- */
    const TYPE_TEXT = 'إلى المهندسة التي صمّمت أجمل تفاصيل حياتي، Hithem';
    const typeEl    = document.getElementById('typewriter');

    function typeWriter(text, el, speed = 75) {
        let i = 0;
        el.textContent = '';
        return new Promise(resolve => {
            const tick = () => {
                if (i <= text.length) {
                    el.textContent = text.slice(0, i);
                    i++;
                    setTimeout(tick, speed);
                } else {
                    resolve();
                }
            };
            tick();
        });
    }

    /* -------------------------------------------------------
       2) SCROLL REVEAL + NAV STATE
       ------------------------------------------------------- */
    const nav = document.querySelector('.nav');
    const onScroll = () => {
        nav.classList.toggle('is-scrolled', window.scrollY > 12);
    };
    window.addEventListener('scroll', onScroll, { passive: true });

    const io = new IntersectionObserver(entries => {
        entries.forEach(e => {
            if (e.isIntersecting) {
                e.target.classList.add('is-visible');
                io.unobserve(e.target);
            }
        });
    }, { threshold: 0.15 });

    document.querySelectorAll('.reveal').forEach(el => io.observe(el));

    /* -------------------------------------------------------
       3) YOUTUBE IFRAME API
       ------------------------------------------------------- */
    let ytPlayer       = null;
    let ytReady        = false;
    let pendingPlay    = false;

    const audioBtn  = document.getElementById('audioToggle');
    const iconPlay  = document.getElementById('iconPlay');
    const iconPause = document.getElementById('iconPause');

    function setPlayingUI(isPlaying) {
        iconPlay.style.display  = isPlaying ? 'none'  : 'block';
        iconPause.style.display = isPlaying ? 'block' : 'none';
        audioBtn.classList.toggle('is-playing', isPlaying);
        audioBtn.setAttribute('aria-pressed', String(isPlaying));
    }

    // Called by the YouTube IFrame API once it loads
    window.onYouTubeIframeAPIReady = function () {
        ytPlayer = new YT.Player('ytPlayer', {
            events: {
                onReady: () => {
                    ytReady = true;
                    try { ytPlayer.setVolume(70); } catch (_) {}
                    if (pendingPlay) {
                        pendingPlay = false;
                        playSong();
                    }
                },
                onStateChange: (e) => {
                    if (e.data === YT.PlayerState.PLAYING)      setPlayingUI(true);
                    else if (e.data === YT.PlayerState.PAUSED)  setPlayingUI(false);
                    else if (e.data === YT.PlayerState.ENDED)   setPlayingUI(false);
                }
            }
        });
    };

    function playSong() {
        if (!ytReady || !ytPlayer) { pendingPlay = true; return; }
        try {
            ytPlayer.unMute();
            ytPlayer.playVideo();
        } catch (_) {}
    }
    function pauseSong() {
        if (!ytReady || !ytPlayer) return;
        try { ytPlayer.pauseVideo(); } catch (_) {}
    }
    function isPlaying() {
        if (!ytReady || !ytPlayer || !ytPlayer.getPlayerState) return false;
        return ytPlayer.getPlayerState() === 1; // 1 = playing
    }

    audioBtn.addEventListener('click', () => {
        if (!ytReady) { pendingPlay = true; return; }
        if (isPlaying()) pauseSong();
        else             playSong();
    });

    /* -------------------------------------------------------
       4) PETALS (canvas)
       ------------------------------------------------------- */
    const canvas = document.getElementById('petals');
    const ctx    = canvas.getContext('2d');
    let petals     = [];
    let petalsRAF  = null;
    let petalsEnd  = 0;
    let dpr        = Math.max(1, window.devicePixelRatio || 1);

    function sizeCanvas() {
        dpr = Math.max(1, window.devicePixelRatio || 1);
        canvas.width  = innerWidth  * dpr;
        canvas.height = innerHeight * dpr;
        canvas.style.width  = innerWidth  + 'px';
        canvas.style.height = innerHeight + 'px';
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    sizeCanvas();
    window.addEventListener('resize', sizeCanvas);

    function rand(min, max) { return Math.random() * (max - min) + min; }

    function createPetal() {
        return {
            x:      rand(0, innerWidth),
            y:      rand(-innerHeight * 0.6, -20),
            size:   rand(8, 16),
            speedY: rand(0.6, 1.8),
            speedX: rand(-0.6, 0.6),
            rot:    rand(0, Math.PI * 2),
            rotV:   rand(-0.04, 0.04),
            sway:   rand(0.6, 1.4),
            swayPh: rand(0, Math.PI * 2),
            color:  ['#8a1a2b', '#b03a48', '#c54a5d', '#a32338'][Math.floor(rand(0, 4))],
            alpha:  rand(0.75, 1)
        };
    }

    function drawPetal(p) {
        ctx.save();
        ctx.translate(p.x, p.y);
        ctx.rotate(p.rot);
        ctx.globalAlpha = p.alpha;
        ctx.fillStyle   = p.color;

        // soft petal shape (two arcs)
        ctx.beginPath();
        ctx.moveTo(0, 0);
        ctx.bezierCurveTo(p.size * 0.5,  -p.size * 0.5,
                          p.size * 1.2,   p.size * 0.2,
                          0,               p.size);
        ctx.bezierCurveTo(-p.size * 1.2,  p.size * 0.2,
                          -p.size * 0.5, -p.size * 0.5,
                          0, 0);
        ctx.fill();

        // subtle highlight vein
        ctx.globalAlpha = p.alpha * 0.35;
        ctx.strokeStyle = '#ffd9df';
        ctx.lineWidth   = 0.8;
        ctx.beginPath();
        ctx.moveTo(0, 0);
        ctx.lineTo(0, p.size);
        ctx.stroke();

        ctx.restore();
    }

    function animatePetals(ts) {
        ctx.clearRect(0, 0, innerWidth, innerHeight);

        for (let i = 0; i < petals.length; i++) {
            const p = petals[i];
            p.y   += p.speedY;
            p.x   += p.speedX + Math.sin((ts / 800) + p.swayPh) * p.sway * 0.4;
            p.rot += p.rotV;

            // recycle while still inside the active window
            if (p.y > innerHeight + 30 && performance.now() < petalsEnd - 2000) {
                Object.assign(p, createPetal());
                p.y = -20;
            }

            drawPetal(p);
        }

        if (performance.now() < petalsEnd || petals.some(p => p.y < innerHeight + 30)) {
            petalsRAF = requestAnimationFrame(animatePetals);
        } else {
            petals = [];
            ctx.clearRect(0, 0, innerWidth, innerHeight);
            petalsRAF = null;
        }
    }

    function startPetals(durationMs = 7000, count = 60) {
        petals    = Array.from({ length: count }, createPetal);
        petalsEnd = performance.now() + durationMs;
        if (!petalsRAF) petalsRAF = requestAnimationFrame(animatePetals);
    }

    /* -------------------------------------------------------
       5) START BUTTON
       ------------------------------------------------------- */
    const startBtn = document.getElementById('startBtn');
    let started    = false;

    startBtn.addEventListener('click', () => {
        // Always play petals + music on each click
        startPetals(7500, 70);
        playSong();

        if (!started) {
            started = true;
            startBtn.querySelector('span').textContent = 'تستحقّين كل التفاصيل ♥';
            // Smooth-scroll into the gallery shortly after the petals burst
            setTimeout(() => {
                document.getElementById('gallery')
                    .scrollIntoView({ behavior: 'smooth', block: 'start' });
            }, 1200);
        }
    });

    /* -------------------------------------------------------
       6) INIT
       ------------------------------------------------------- */
    document.addEventListener('DOMContentLoaded', () => {
        typeWriter(TYPE_TEXT, typeEl, 70);
        onScroll();
    });

    // Fallback: if DOM is already loaded
    if (document.readyState !== 'loading') {
        typeWriter(TYPE_TEXT, typeEl, 70);
        onScroll();
    }
})();
