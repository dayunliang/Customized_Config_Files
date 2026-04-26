(function () {
  const zashboardKey = "config/source-ip-label-map";
  const metacubeKey = "clientSourceIPTags";

  function detectCurrentDashboard() {
    const path = location.pathname.toLowerCase();
    const href = location.href.toLowerCase();

    if (path.includes("zashboard") || href.includes("zashboard")) {
      return "zashboard";
    }

    if (path.includes("metacubexd") || href.includes("metacubexd")) {
      return "metacubexd";
    }

    const hasZashboardKey = localStorage.getItem(zashboardKey) !== null;
    const hasMetacubeKey = localStorage.getItem(metacubeKey) !== null;

    if (hasZashboardKey && !hasMetacubeKey) {
      return "zashboard";
    }

    if (hasMetacubeKey && !hasZashboardKey) {
      return "metacubexd";
    }

    return "unknown";
  }

  function zashboardMapToMetacubeTags(zashboardMap) {
    return Object.entries(zashboardMap).map(function ([sourceIP, tagName]) {
      return {
        tagName: tagName,
        sourceIP: sourceIP
      };
    });
  }

  function metacubeTagsToZashboardMap(metacubeTags) {
    const map = {};

    for (const item of metacubeTags) {
      if (!item) {
        continue;
      }

      const sourceIP = item.sourceIP;
      const tagName = item.tagName;

      if (sourceIP && tagName) {
        map[sourceIP] = tagName;
      }
    }

    return map;
  }

  function extractZashboardMapFromBackup(backup) {
    if (!backup.data) {
      throw new Error("备份文件格式错误：缺少 data 字段");
    }

    if (backup.data[zashboardKey]) {
      return JSON.parse(backup.data[zashboardKey]);
    }

    if (backup.data[metacubeKey]) {
      const metacubeTags = JSON.parse(backup.data[metacubeKey]);
      return metacubeTagsToZashboardMap(metacubeTags);
    }

    throw new Error("备份文件中没有找到可用的源 IP 标签数据");
  }

  function extractMetacubeTagsFromBackup(backup) {
    if (!backup.data) {
      throw new Error("备份文件格式错误：缺少 data 字段");
    }

    if (backup.data[metacubeKey]) {
      return JSON.parse(backup.data[metacubeKey]);
    }

    if (backup.data[zashboardKey]) {
      const zashboardMap = JSON.parse(backup.data[zashboardKey]);
      return zashboardMapToMetacubeTags(zashboardMap);
    }

    throw new Error("备份文件中没有找到可用的源 IP 标签数据");
  }

  const currentDashboard = detectCurrentDashboard();

  if (currentDashboard === "unknown") {
    const answer = prompt(
      "无法自动识别当前 Dashboard 类型，请输入：zashboard 或 metacubexd",
      "zashboard"
    );

    if (answer !== "zashboard" && answer !== "metacubexd") {
      alert("已取消：请输入 zashboard 或 metacubexd");
      return;
    }

    window.__dashboardImportTarget = answer;
  } else {
    window.__dashboardImportTarget = currentDashboard;
  }

  const input = document.createElement("input");
  input.type = "file";
  input.accept = "application/json,.json";

  input.onchange = function () {
    const file = input.files[0];

    if (!file) {
      console.log("未选择文件");
      return;
    }

    const reader = new FileReader();

    reader.onload = function () {
      try {
        const backup = JSON.parse(reader.result);
        const target = window.__dashboardImportTarget;

        console.log("检测到当前目标 Dashboard：", target);
        console.log("读取到备份文件：", backup);

        if (target === "zashboard") {
          const zashboardMap = extractZashboardMapFromBackup(backup);

          localStorage.setItem(zashboardKey, JSON.stringify(zashboardMap));

          console.log("已导入为 Zashboard 格式：", zashboardMap);
          alert("已导入到 Zashboard，页面即将刷新");
          location.reload();
          return;
        }

        if (target === "metacubexd") {
          const metacubeTags = extractMetacubeTagsFromBackup(backup);

          localStorage.setItem(metacubeKey, JSON.stringify(metacubeTags));

          console.log("已导入为 MetaCubeXD 格式：", metacubeTags);
          alert("已导入到 MetaCubeXD，页面即将刷新");
          location.reload();
          return;
        }

        throw new Error("未知目标 Dashboard 类型");
      } catch (e) {
        console.error("导入失败：", e);
        alert("导入失败：" + e.message);
      }
    };

    reader.readAsText(file);
  };

  input.click();
})();
