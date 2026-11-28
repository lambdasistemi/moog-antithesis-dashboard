(() => {
  const root = document.documentElement;
  const panes = ["tests", "pipeline", "mpfs", "accounts", "alarms"];
  const themes = ["system", "light", "dark"];
  const read = key => { try { return localStorage.getItem(`moog-dashboard.${key}`); } catch { return null; } };
  const save = (key, value) => { try { localStorage.setItem(`moog-dashboard.${key}`, value); } catch {} };
  const storedTheme = read("theme"), storedPane = read("pane");
  let theme = themes.includes(storedTheme) ? storedTheme : "system";
  const systemTheme = matchMedia("(prefers-color-scheme: dark)");
  root.dataset.pane = panes.includes(storedPane) ? storedPane : "tests";

  function applyTheme(value) {
    if (value === "system") delete root.dataset.theme;
    else root.dataset.theme = value;
    root.classList.toggle("wa-dark", value === "dark" || (value === "system" && systemTheme.matches));
  }
  applyTheme(theme);
  systemTheme.addEventListener("change", () => applyTheme(theme));

  function openPane(pane, persist = true) {
    if (!panes.includes(pane)) return;
    root.dataset.pane = pane;
    document.querySelectorAll('[role="tab"]').forEach(tab => {
      const selected = tab.dataset.pane === pane;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
    });
    if (persist) save("pane", pane);
  }
  globalThis.DashboardPreferences = {openPane};

  document.addEventListener("DOMContentLoaded", () => {
    const control = document.getElementById("theme");
    control.value = theme;
    control.addEventListener("change", () => {
      if (!themes.includes(control.value)) return;
      theme = control.value;
      applyTheme(theme);
      save("theme", theme);
    });
    openPane(root.dataset.pane, false);
    const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
    tabs.forEach((tab, index) => {
      tab.addEventListener("click", () => openPane(tab.dataset.pane));
      tab.addEventListener("keydown", event => {
        const next = event.key === "ArrowRight" ? (index + 1) % tabs.length
          : event.key === "ArrowLeft" ? (index + tabs.length - 1) % tabs.length
          : event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : null;
        if (next === null) return;
        event.preventDefault();
        openPane(tabs[next].dataset.pane);
        tabs[next].focus();
      });
    });
  });
})();
