(() => {
  const languageButtons = Array.from(document.querySelectorAll("[data-language]"));
  const storageKey = "lingshu-site-language";

  const normalizedLanguage = (value) => value === "zh-CN" ? "zh-CN" : "en";

  const setLanguage = (language, remember = true) => {
    const next = normalizedLanguage(language);
    document.documentElement.lang = next;
    languageButtons.forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.language === next));
    });
    const pageTitle = document.body?.dataset;
    document.title = next === "zh-CN"
      ? (pageTitle?.titleZh || "LingShu - 纯开源、模型无关的 macOS Agent")
      : (pageTitle?.titleEn || "LingShu - Open-source, model-agnostic macOS agent");
    document.querySelectorAll("[data-label-en][data-label-zh]").forEach((element) => {
      element.setAttribute("aria-label", next === "zh-CN" ? element.dataset.labelZh : element.dataset.labelEn);
    });
    document.querySelectorAll("[data-href-en][data-href-zh]").forEach((element) => {
      element.setAttribute("href", next === "zh-CN" ? element.dataset.hrefZh : element.dataset.hrefEn);
    });
    if (remember) {
      try { window.localStorage.setItem(storageKey, next); } catch (_) {}
    }
  };

  let savedLanguage = null;
  try { savedLanguage = window.localStorage.getItem(storageKey); } catch (_) {}
  const initialLanguage = savedLanguage || (navigator.language.toLowerCase().startsWith("zh") ? "zh-CN" : "en");
  setLanguage(initialLanguage, false);

  languageButtons.forEach((button) => {
    button.addEventListener("click", () => setLanguage(button.dataset.language));
  });

  const copyText = async (value) => {
    try {
      await navigator.clipboard.writeText(value);
      return true;
    } catch (_) {
      const textarea = document.createElement("textarea");
      textarea.value = value;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.opacity = "0";
      document.body.appendChild(textarea);
      textarea.select();
      const copied = document.execCommand("copy");
      textarea.remove();
      return copied;
    }
  };

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const value = button.dataset.copy || "";
      if (await copyText(value)) {
        button.textContent = document.documentElement.lang === "zh-CN" ? "已复制" : "Copied";
        window.setTimeout(() => {
          button.innerHTML = '<span class="copy-en">Copy</span><span class="copy-zh">复制</span>';
        }, 1400);
      } else {
        window.prompt(document.documentElement.lang === "zh-CN" ? "复制安装命令" : "Copy install command", value);
      }
    });
  });

  document.querySelectorAll("[data-current-year]").forEach((element) => {
    element.textContent = String(new Date().getFullYear());
  });
})();
