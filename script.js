// Progressive enhancement only: the page is fully usable without this script.
// It marks the nav link of the section in the middle of the viewport with aria-current.
(() => {
  const nav = document.querySelector(".site-header nav");
  const sections = document.querySelectorAll("main section[id]");
  if (!nav || !("IntersectionObserver" in window)) return;

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const link = nav.querySelector(`a[href="#${entry.target.id}"]`);
        if (!link) continue;
        nav.querySelectorAll("[aria-current]").forEach((el) => el.removeAttribute("aria-current"));
        link.setAttribute("aria-current", "location");
      }
    },
    { rootMargin: "-45% 0px -50% 0px" },
  );
  sections.forEach((section) => observer.observe(section));
})();
