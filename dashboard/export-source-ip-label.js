(function () {
  const zashboardKey = "config/source-ip-label-map";
  const metacubeKey = "clientSourceIPTags";

  const zashboardValue = localStorage.getItem(zashboardKey);
  const metacubeValue = localStorage.getItem(metacubeKey);

  let detectedApp = "unknown";

  if (zashboardValue && zashboardValue !== "{}") {
    detectedApp = "zashboard";
  }

  if (metacubeValue && metacubeValue !== "[]") {
    detectedApp = "metacubexd";
  }

  const backup = {
    app: detectedApp,
    type: "source-ip-label-backup",
    origin: location.origin,
    exportedAt: new Date().toISOString(),
    data: {}
  };

  if (zashboardValue !== null) {
    backup.data[zashboardKey] = zashboardValue;
  }

  if (metacubeValue !== null) {
    backup.data[metacubeKey] = metacubeValue;
  }

  const text = JSON.stringify(backup, null, 2);
  const blob = new Blob([text], { type: "application/json" });
  const url = URL.createObjectURL(blob);

  const a = document.createElement("a");
  a.href = url;
  a.download = "dashboard-source-ip-label-backup.json";
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);

  URL.revokeObjectURL(url);

  console.log("源 IP 标签通用备份已导出：", backup);
})();
