(function () {
  "use strict";

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* Nav: scrolled state + progress bar */
  var nav = document.getElementById("nav");
  var progress = document.getElementById("navProgress");
  var ticking = false;

  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(function () {
      var y = window.scrollY;
      nav.classList.toggle("scrolled", y > 40);
      var max = document.documentElement.scrollHeight - window.innerHeight;
      progress.style.width = (max > 0 ? (y / max) * 100 : 0) + "%";
      parallax(y);
      ticking = false;
    });
  }

  /* Parallax on hero phone */
  var parallaxEl = document.querySelector(".parallax");
  function parallax(y) {
    if (!parallaxEl || reduced) return;
    if (y < window.innerHeight * 1.4) {
      parallaxEl.style.transform = "translateY(" + y * parseFloat(parallaxEl.dataset.speed || 0.06) * -1 + "px)";
    }
  }

  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* Scroll reveal */
  var revealEls = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduced) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          e.target.classList.add("in-view");
          io.unobserve(e.target);
        }
      });
    }, { threshold: 0.15, rootMargin: "0px 0px -40px 0px" });
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add("in-view"); });
  }

  /* Animated counters */
  var counters = document.querySelectorAll("[data-count]");
  function animateCounter(el) {
    if (reduced) { el.textContent = el.dataset.count; return; }
    var target = parseInt(el.dataset.count, 10);
    var start = null;
    var dur = 1400;
    function step(ts) {
      if (!start) start = ts;
      var p = Math.min((ts - start) / dur, 1);
      var eased = 1 - Math.pow(1 - p, 3);
      el.textContent = Math.round(target * eased);
      if (p < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  }
  if ("IntersectionObserver" in window) {
    var cio = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          animateCounter(e.target);
          cio.unobserve(e.target);
        }
      });
    }, { threshold: 0.6 });
    counters.forEach(function (el) { cio.observe(el); });
  } else {
    counters.forEach(function (el) { el.textContent = el.dataset.count; });
  }

  /* Spotlight cards: cursor-tracked glow (rAF-throttled) */
  if (window.matchMedia("(hover: hover)").matches && !reduced) {
    document.querySelectorAll(".spotlight").forEach(function (card) {
      var pending = false;
      card.addEventListener("pointermove", function (e) {
        if (pending) return;
        pending = true;
        requestAnimationFrame(function () {
          var r = card.getBoundingClientRect();
          card.style.setProperty("--mx", (e.clientX - r.left) + "px");
          card.style.setProperty("--my", (e.clientY - r.top) + "px");
          pending = false;
        });
      });
    });
  }
})();
