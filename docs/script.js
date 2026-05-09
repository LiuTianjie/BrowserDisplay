const navToggle = document.querySelector("[data-nav-toggle]");
const nav = document.querySelector("[data-nav]");
const header = document.querySelector("[data-header]");
const navLinks = Array.from(document.querySelectorAll(".site-nav a"));

navToggle?.addEventListener("click", () => {
  const isOpen = nav?.classList.toggle("is-open") ?? false;
  navToggle.setAttribute("aria-expanded", String(isOpen));
});

navLinks.forEach((link) => {
  link.addEventListener("click", () => {
    nav?.classList.remove("is-open");
    navToggle?.setAttribute("aria-expanded", "false");
  });
});

const sections = navLinks
  .map((link) => document.querySelector(link.getAttribute("href")))
  .filter(Boolean);

const observer = new IntersectionObserver(
  (entries) => {
    const visible = entries
      .filter((entry) => entry.isIntersecting)
      .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];

    if (!visible) return;

    navLinks.forEach((link) => {
      link.classList.toggle("is-active", link.getAttribute("href") === `#${visible.target.id}`);
    });
  },
  {
    rootMargin: "-18% 0px -64% 0px",
    threshold: [0.12, 0.28, 0.48],
  }
);

sections.forEach((section) => observer.observe(section));

const revealItems = Array.from(
  document.querySelectorAll(
    ".quickstart-copy, .step-strip li, .section-heading, .feature-card, .arch-item, .use-card, .quality-pills, .faq-row details, .virtual-grid article, .command-card"
  )
);

const revealObserver = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("is-visible");
        revealObserver.unobserve(entry.target);
      }
    });
  },
  {
    rootMargin: "0px 0px 16% 0px",
    threshold: 0.04,
  }
);

revealItems.forEach((item, index) => {
  item.classList.add("reveal");
  item.style.transitionDelay = `${Math.min(index % 6, 4) * 55}ms`;
  revealObserver.observe(item);
});

document.querySelectorAll("[data-copy-target]").forEach((button) => {
  button.addEventListener("click", async () => {
    const target = document.getElementById(button.dataset.copyTarget);
    const value = target?.textContent?.trim();
    if (!value) return;

    try {
      let copied = false;
      if (navigator.clipboard && window.isSecureContext) {
        try {
          await navigator.clipboard.writeText(value);
          copied = true;
        } catch {
          copied = false;
        }
      }

      if (!copied) {
        const textarea = document.createElement("textarea");
        textarea.value = value;
        textarea.setAttribute("readonly", "");
        textarea.style.position = "fixed";
        textarea.style.left = "-9999px";
        document.body.appendChild(textarea);
        textarea.focus();
        textarea.select();
        textarea.setSelectionRange(0, value.length);
        copied = document.execCommand("copy");
        textarea.remove();
      }

      if (!copied) throw new Error("copy command unavailable");

      const original = button.textContent;
      button.textContent = "已复制";
      window.setTimeout(() => {
        button.textContent = original;
      }, 1400);
    } catch {
      button.textContent = "复制失败";
      window.setTimeout(() => {
        button.textContent = "复制";
      }, 1400);
    }
  });
});

window.addEventListener("scroll", () => {
  header?.classList.toggle("is-scrolled", window.scrollY > 12);
});
