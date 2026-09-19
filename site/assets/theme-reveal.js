(() => {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let replaying = false;

  const reveal = async (toggle) => {
    const bounds = toggle.getBoundingClientRect();
    const x = bounds.left + bounds.width / 2;
    const y = bounds.top + bounds.height / 2;
    const radius = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y));
    const root = document.documentElement;
    const transition = document.startViewTransition(() => {
      root.classList.add("theme-switching");
      replaying = true;
      try {
        toggle.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      } finally {
        replaying = false;
      }
    });

    const at = `at ${(x / innerWidth) * 100}% ${(y / innerHeight) * 100}%`;
    const end = (radius / (Math.hypot(innerWidth, innerHeight) / Math.SQRT2)) * 100;
    try {
      await transition.ready;
      root.animate(
        { clipPath: [`circle(0% ${at})`, `circle(${end}% ${at})`] },
        { duration: 420, easing: "cubic-bezier(0.4, 0, 0.2, 1)", pseudoElement: "::view-transition-new(root)" },
      );
      await transition.finished;
    } catch {
    } finally {
      root.classList.remove("theme-switching");
    }
  };

  document.addEventListener(
    "click",
    (event) => {
      const toggle = event.target.closest?.("#theme-toggle");
      if (!toggle || replaying || !document.startViewTransition || reduceMotion.matches) return;
      if (document.visibilityState !== "visible") return;

      event.stopImmediatePropagation();
      reveal(toggle);
    },
    { capture: true },
  );
})();
