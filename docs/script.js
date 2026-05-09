const navToggle = document.querySelector("[data-nav-toggle]");
const nav = document.querySelector("[data-nav]");
const header = document.querySelector("[data-header]");
const navLinks = Array.from(document.querySelectorAll(".site-nav a"));
const languageToggle = document.querySelector("[data-lang-toggle]");
const languageCurrent = document.querySelector("[data-lang-current]");
const languageNext = document.querySelector("[data-lang-next]");

const translations = {
  en: {
    "meta.title": "BrowserDisplay | Local browser display for Mac",
    "meta.description":
      "BrowserDisplay turns a browser device on your local network into a temporary display for your Mac, with screen, window, and virtual display capture over WebRTC.",
    "nav.homeAria": "BrowserDisplay home",
    "nav.advantages": "Advantages",
    "nav.how": "How it works",
    "nav.usage": "Usage",
    "nav.virtual": "Virtual display",
    "nav.githubAria": "View BrowserDisplay on GitHub",
    "nav.languageAria": "Switch language",
    "hero.eyebrow": "macOS · WebRTC · Browser receiver",
    "hero.title": "Turn a browser into a Mac display",
    "hero.lede":
      "Select a screen, window, or dedicated virtual display on your Mac. BrowserDisplay streams it over WebRTC to a browser on the same local network.",
    "hero.actionsAria": "Primary actions",
    "hero.primaryCta": "Get started",
    "hero.secondaryCta": "See how it works",
    "hero.statusAria": "BrowserDisplay status example",
    "stats.aria": "Core capabilities",
    "stats.sourceLabel": "Source",
    "hero.screenshotAlt":
      "BrowserDisplay app screenshot showing capture sources, WebViewer, virtual display, and quality settings",
    "hero.caption": "Capture sources, browser connections, virtual displays, and quality presets live in one Mac app.",
    "quick.aria": "Quick start",
    "quick.title": "Connect in three steps",
    "quick.step1Title": "Choose a source",
    "quick.step1Body": "Select a screen, window, or create a BrowserDisplay virtual display.",
    "quick.step2Title": "Open a browser",
    "quick.step2Body": "Scan the QR code or enter the WebViewer URL, then pair on the receiver.",
    "quick.step3Title": "Start streaming",
    "quick.step3Body": "Pick a quality preset for the network and start the stream.",
    "advantages.title": "Built for temporary side displays and clean demos",
    "advantages.card1Title": "No receiver app",
    "advantages.card1Body":
      "A phone, tablet, or another computer can receive the stream as long as its browser supports WebRTC.",
    "advantages.card2Title": "Show only what matters",
    "advantages.card2Body": "Virtual display mode isolates the demo surface while your main screen stays private.",
    "advantages.card3Title": "One control surface",
    "advantages.card3Body":
      "Sources, ports, QR code, viewer count, pairing code, and quality presets are managed in one place.",
    "architecture.title": "A local display link",
    "architecture.body":
      "BrowserDisplay does not require a native receiver app. The Mac handles capture, encoding, and signaling; the browser receives and renders.",
    "architecture.step1": "ScreenCaptureKit captures screens or windows; BetterDisplay provides the optional virtual display.",
    "architecture.step2": "WebViewer opens from a local HTTP page and uses a pairing code to establish the session.",
    "architecture.step3": "Video streams to the browser over WebRTC, with quality controlled by presets.",
    "usage.title": "Run and grant permission",
    "usage.runTitle": "Build and launch",
    "usage.permissionTitle": "Reset Screen Recording permission",
    "usage.qualityAria": "Quality presets",
    "copy.label": "Copy",
    "copy.success": "Copied",
    "copy.failure": "Copy failed",
    "virtual.title": "Put demo content on its own display",
    "virtual.body":
      "With BetterDisplay installed, BrowserDisplay can create a dedicated virtual display. Move windows onto it, then stream that display to the browser.",
    "virtual.cta": "Start setup",
    "footer.top": "Back to top",
  },
  zh: {
    "meta.title": "BrowserDisplay | 把浏览器变成 Mac 显示器",
    "meta.description":
      "BrowserDisplay 把同一局域网里的浏览器设备变成 Mac 的临时显示器，支持屏幕、窗口和虚拟屏捕获，并通过 WebRTC 传输。",
    "nav.homeAria": "BrowserDisplay 首页",
    "nav.advantages": "优势",
    "nav.how": "原理",
    "nav.usage": "使用方法",
    "nav.virtual": "虚拟屏",
    "nav.githubAria": "在 GitHub 上查看 BrowserDisplay",
    "nav.languageAria": "切换语言",
    "hero.eyebrow": "macOS · WebRTC · 浏览器接收端",
    "hero.title": "把浏览器变成 Mac 显示器",
    "hero.lede": "在 Mac 上选择屏幕、窗口或专用虚拟屏，BrowserDisplay 通过 WebRTC 把画面送到同一局域网里的浏览器。",
    "hero.actionsAria": "主要操作",
    "hero.primaryCta": "开始使用",
    "hero.secondaryCta": "查看原理",
    "hero.statusAria": "BrowserDisplay 状态示例",
    "stats.aria": "核心能力",
    "stats.sourceLabel": "来源",
    "hero.screenshotAlt": "BrowserDisplay 应用界面截图，展示捕获源、WebViewer、虚拟屏和画质设置",
    "hero.caption": "所有捕获源、浏览器连接、虚拟屏和画质都在一个 Mac 应用里完成。",
    "quick.aria": "快速开始",
    "quick.title": "三步连接",
    "quick.step1Title": "选来源",
    "quick.step1Body": "选择屏幕、窗口，或创建一块 BrowserDisplay 虚拟屏。",
    "quick.step2Title": "打开浏览器",
    "quick.step2Body": "扫码或输入 WebViewer 地址，在接收端完成配对。",
    "quick.step3Title": "开始传输",
    "quick.step3Body": "按网络状况选择画质，点击开始传输。",
    "advantages.title": "为临时副屏和干净演示而做",
    "advantages.card1Title": "接收端不装 App",
    "advantages.card1Body": "手机、平板、另一台电脑，只要浏览器支持 WebRTC，就能作为接收端。",
    "advantages.card2Title": "只展示该展示的窗口",
    "advantages.card2Body": "虚拟屏模式把演示内容隔离出来，主屏保持私密。",
    "advantages.card3Title": "状态都在一处",
    "advantages.card3Body": "源、端口、二维码、连接数、配对码和画质预设集中管理。",
    "architecture.title": "一条本地链路",
    "architecture.body": "BrowserDisplay 不要求接收端安装原生应用。Mac 负责采集、编码和信令，浏览器负责接收和渲染。",
    "architecture.step1": "ScreenCaptureKit 捕获屏幕或窗口；虚拟屏由 BetterDisplay 提供。",
    "architecture.step2": "WebViewer 通过本地 HTTP 页面进入，按配对码建立会话。",
    "architecture.step3": "视频经 WebRTC 推送到浏览器，画质按预设切换。",
    "usage.title": "运行和授权",
    "usage.runTitle": "构建并启动",
    "usage.permissionTitle": "重置屏幕录制权限",
    "usage.qualityAria": "画质预设",
    "copy.label": "复制",
    "copy.success": "已复制",
    "copy.failure": "复制失败",
    "virtual.title": "把演示内容放进独立屏幕",
    "virtual.body": "安装 BetterDisplay 后，BrowserDisplay 可以创建一块专用虚拟屏。把窗口拖进去，再把这块屏幕发送到浏览器。",
    "virtual.cta": "开始配置",
    "footer.top": "回到顶部",
  },
};

let currentLanguage = "en";

const getInitialLanguage = () => {
  const params = new URLSearchParams(window.location.search);
  const queryLanguage = params.get("lang");
  if (queryLanguage === "zh" || queryLanguage === "en") return queryLanguage;

  const storedLanguage = window.localStorage?.getItem("browserdisplay.docs.language");
  return storedLanguage === "zh" || storedLanguage === "en" ? storedLanguage : "en";
};

const translate = (key) => translations[currentLanguage]?.[key] ?? translations.en[key] ?? "";

const applyLanguage = (language) => {
  currentLanguage = language === "zh" ? "zh" : "en";
  document.documentElement.lang = currentLanguage === "zh" ? "zh-CN" : "en";

  document.querySelectorAll("[data-i18n]").forEach((element) => {
    element.textContent = translate(element.dataset.i18n);
  });

  document.querySelectorAll("[data-i18n-aria]").forEach((element) => {
    element.setAttribute("aria-label", translate(element.dataset.i18nAria));
  });

  document.querySelectorAll("[data-i18n-alt]").forEach((element) => {
    element.setAttribute("alt", translate(element.dataset.i18nAlt));
  });

  document.querySelectorAll("[data-i18n-content]").forEach((element) => {
    element.setAttribute("content", translate(element.dataset.i18nContent));
  });

  if (languageCurrent && languageNext) {
    languageCurrent.textContent = currentLanguage === "zh" ? "中文" : "EN";
    languageNext.textContent = currentLanguage === "zh" ? "EN" : "中文";
  }

  window.localStorage?.setItem("browserdisplay.docs.language", currentLanguage);
};

applyLanguage(getInitialLanguage());

languageToggle?.addEventListener("click", () => {
  applyLanguage(currentLanguage === "zh" ? "en" : "zh");
});

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
    ".quickstart-lead, .step-grid li, .section-heading, .feature-card, .flow-grid article, .command-card, .quality-row, .virtual-band"
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
      button.textContent = translate("copy.success");
      window.setTimeout(() => {
        button.textContent = original;
      }, 1400);
    } catch {
      button.textContent = translate("copy.failure");
      window.setTimeout(() => {
        button.textContent = translate("copy.label");
      }, 1400);
    }
  });
});

window.addEventListener("scroll", () => {
  header?.classList.toggle("is-scrolled", window.scrollY > 12);
});
