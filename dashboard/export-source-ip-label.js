(function () {
  const zashboardKey = "clientSourceIPTags";
  const metacubeKey = "clientSourceIPTags";

  function detectCurrentDashboard() {
    const href = location.href.toLowerCase();
    const path = location.pathname.toLowerCase();

    if (href.includes("zashboard") || path.includes("zashboard")) {
      return "zashboard";
    }

    if (href.includes("metacubexd") || path.includes("metacubexd")) {
      return "metacubexd";
    }

    const zashboardValue = localStorage.getItem(zashboardKey);
    const metacubeValue = localStorage.getItem(metacubeKey);

    if (zashboardValue && zashboardValue !== "{}" && (!metacubeValue || metacubeValue === "[]")) {
      return "zashboard";
    }

    if (metacubeValue && metacubeValue !== "[]" && (!zashboardValue || zashboardValue === "{}")) {
      return "metacubexd";
    }

    return "unknown";
  }

  function pad(num) {
    return String(num).padStart(2, "0");
  }

  function makeTimestamp(date) {
    return (
      date.getFullYear() +
      pad(date.getMonth() + 1) +
      pad(date.getDate()) +
      pad(date.getHours()) +
      pad(date.getMinutes())
    );
  }

  const now = new Date();
  const timestamp = makeTimestamp(now);

  const detectedApp = detectCurrentDashboard();

  const zashboardValue = localStorage.getItem(zashboardKey);
  const metacubeValue = localStorage.getItem(metacubeKey);

  const backup = {
    app: detectedApp,
    type: "source-ip-label-backup",
    origin: location.origin,
    pathname: location.pathname,
    exportedAt: now.toISOString(),
    data: {}
  };

  if (zashboardValue !== null) {
    backup.data[zashboardKey] = zashboardValue;
  }

  if (metacubeValue !== null) {
    backup.data[metacubeKey] = metacubeValue;
  }

  if (
    backup.data[zashboardKey] === undefined &&
    backup.data[metacubeKey] === undefined
  ) {
    alert("当前页面没有找到 Zashboard 或 MetaCubeXD 的源 IP 标签数据");
    console.warn("未找到可导出的源 IP 标签数据");
    return;
  }

  const text = JSON.stringify(backup, null, 2);
  const blob = new Blob([text], { type: "application/json" });
  const url = URL.createObjectURL(blob);

  const a = document.createElement("a");
  a.href = url;
  a.download = "dashboard-source-ip-label-backup-" + timestamp + ".json";
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);

  URL.revokeObjectURL(url);

  console.log("源 IP 标签通用备份已导出：", backup);
})();
