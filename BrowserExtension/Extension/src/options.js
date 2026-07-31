const copy = {
  en: {
    eyebrow: "ZBS Eye · local-only",
    lede: "Capture useful page text that Accessibility cannot see.",
    captureHeading: "Browser Capture",
    captureBody: "Off by default. When enabled, only the active tab in the focused Chromium window is eligible—and only while ZBS Eye is recording.",
    enable: "Enable",
    connectHeading: "Connect to this Mac",
    connectBody: "In ZBS Eye, open Settings → Browser Capture and copy the write-only token.",
    tokenLabel: "Browser token",
    save: "Save",
    sentHeading: "Stays on this Mac",
    sentBody: "Visible rendered text, page title, and URL go only to 127.0.0.1.",
    neverHeading: "Never collected",
    neverBody: "Passwords, form values, hidden content, scripts, styles, and background tabs.",
    fineprint: "If Eye is closed or paused, the extension does not extract page text.",
    status: {
      disabled: "Disabled",
      "token-required": "Token required",
      saved: "Saved — waiting for Eye",
      connected: "Connected",
      paused: "Eye is paused",
      disconnected: "Eye not found",
      "payload-rejected": "Page was too large",
      default: "Not configured",
    },
    lastConnected: "last connected",
  },
  ru: {
    eyebrow: "ZBS Eye · только локально",
    lede: "Сохраняет полезный текст страниц, который не видит Accessibility.",
    captureHeading: "Захват браузера",
    captureBody: "По умолчанию выключен. После включения доступна только активная вкладка активного окна Chromium — и только пока ZBS Eye записывает.",
    enable: "Включить",
    connectHeading: "Подключить к этому Mac",
    connectBody: "В ZBS Eye откройте Настройки → Захват браузера и скопируйте токен только для записи.",
    tokenLabel: "Токен браузера",
    save: "Сохранить",
    sentHeading: "Остаётся на этом Mac",
    sentBody: "Видимый текст, заголовок и URL идут только на 127.0.0.1.",
    neverHeading: "Никогда не собирается",
    neverBody: "Пароли, значения форм, скрытый контент, скрипты, стили и фоновые вкладки.",
    fineprint: "Если Eye закрыт или на паузе, расширение не извлекает текст страницы.",
    status: {
      disabled: "Выключено",
      "token-required": "Нужен токен",
      saved: "Сохранено — ждём Eye",
      connected: "Подключено",
      paused: "Eye на паузе",
      disconnected: "Eye не найден",
      "payload-rejected": "Страница слишком большая",
      default: "Не настроено",
    },
    lastConnected: "последнее подключение",
  },
};

const language = chrome.i18n.getUILanguage().toLowerCase().startsWith("ru") ? "ru" : "en";
const strings = copy[language];
document.documentElement.lang = language;
for (const element of document.querySelectorAll("[data-i18n]")) {
  element.textContent = strings[element.dataset.i18n];
}

const enabledInput = document.querySelector("#enabled");
const tokenInput = document.querySelector("#token");
const status = document.querySelector("#status");

async function render() {
  const stored = await chrome.storage.local.get([
    "captureEnabled", "browserIngestToken", "bridgeStatus", "bridgeError", "bridgeLastConnectedAt",
  ]);
  enabledInput.checked = stored.captureEnabled === true;
  tokenInput.value = stored.browserIngestToken || "";
  const key = stored.bridgeStatus || "default";
  status.textContent = strings.status[key] || strings.status.default;
  if (stored.bridgeLastConnectedAt) {
    status.textContent += ` · ${strings.lastConnected} ${new Date(stored.bridgeLastConnectedAt).toLocaleString()}`;
  }
  if (stored.bridgeError) status.textContent += ` · ${stored.bridgeError}`;
  status.dataset.state = key;
}

enabledInput.addEventListener("change", async () => {
  await chrome.storage.local.set({
    captureEnabled: enabledInput.checked,
    bridgeStatus: enabledInput.checked ? "saved" : "disabled",
    bridgeError: "",
  });
  await render();
});

document.querySelector("#save").addEventListener("click", async () => {
  const token = tokenInput.value.trim();
  await chrome.storage.local.set({
    browserIngestToken: token,
    bridgeStatus: token ? (enabledInput.checked ? "saved" : "disabled") : "token-required",
    bridgeError: "",
  });
  await render();
});

chrome.storage.onChanged.addListener(render);
render();
