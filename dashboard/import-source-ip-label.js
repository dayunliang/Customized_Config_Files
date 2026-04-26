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

    const answer = prompt(
      "无法自动识别当前 Dashboard 类型，请输入：zashboard 或 metacubexd",
      "zashboard"
    );

    if (answer === "zashboard" || answer === "metacubexd") {
      return answer;
    }

    return "unknown";
  }

  function safeJsonParse(value, fallback) {
    try {
      if (typeof value !== "string") {
        return fallback;
      }

      if (value.trim() === "") {
        return fallback;
      }

      return JSON.parse(value);
    } catch (e) {
      console.warn("JSON 解析失败：", value, e);
      return fallback;
    }
  }

  function zashboardMapToNormalMap(zashboardMap) {
    const map = {};

    if (!zashboardMap || typeof zashboardMap !== "object" || Array.isArray(zashboardMap)) {
      return map;
    }

    for (const [sourceIP, tagName] of Object.entries(zashboardMap)) {
      if (sourceIP && tagName) {
        map[sourceIP] = tagName;
      }
    }

    return map;
  }

  function metacubeTagsToNormalMap(metacubeTags) {
    const map = {};

    if (!Array.isArray(metacubeTags)) {
      return map;
    }

    for (const item of metacubeTags) {
      if (!item || typeof item !== "object") {
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

  function normalMapToMetacubeTags(map) {
    return Object.entries(map).map(function ([sourceIP, tagName]) {
      return {
        tagName: tagName,
        sourceIP: sourceIP
      };
    });
  }

  function mergeMap(baseMap, overrideMap) {
    const result = {};

    for (const [sourceIP, tagName] of Object.entries(baseMap)) {
      result[sourceIP] = tagName;
    }

    for (const [sourceIP, tagName] of Object.entries(overrideMap)) {
      result[sourceIP] = tagName;
    }

    return result;
  }

  function getBackupSourceApp(backup) {
    if (!backup || typeof backup !== "object") {
      return "unknown";
    }

    if (backup.app === "zashboard") {
      return "zashboard";
    }

    if (backup.app === "metacubexd") {
      return "metacubexd";
    }

    return "unknown";
  }

  function buildMapFromBackup(backup, targetDashboard) {
    if (!backup.data || typeof backup.data !== "object") {
      throw new Error("备份文件格式错误：缺少 data 字段");
    }

    const backupSourceApp = getBackupSourceApp(backup);

    const zashboardRaw = backup.data[zashboardKey];
    const metacubeRaw = backup.data[metacubeKey];

    const zashboardMap = zashboardRaw
      ? zashboardMapToNormalMap(safeJsonParse(zashboardRaw, {}))
      : {};

    const metacubeMap = metacubeRaw
      ? metacubeTagsToNormalMap(safeJsonParse(metacubeRaw, []))
      : {};

    let finalMap = {};

    if (backupSourceApp === "zashboard") {
      finalMap = mergeMap(metacubeMap, zashboardMap);
      console.log("备份来源：Zashboard，优先使用 config/source-ip-label-map");
    } else if (backupSourceApp === "metacubexd") {
      finalMap = mergeMap(zashboardMap, metacubeMap);
      console.log("备份来源：MetaCubeXD，优先使用 clientSourceIPTags");
    } else {
      console.warn("备份来源未知，将根据导入目标决定优先级");

      if (targetDashboard === "zashboard") {
        finalMap = mergeMap(metacubeMap, zashboardMap);
        console.log("目标为 Zashboard，来源未知，优先使用 Zashboard 字段");
      } else if (targetDashboard === "metacubexd") {
        finalMap = mergeMap(zashboardMap, metacubeMap);
        console.log("目标为 MetaCubeXD，来源未知，优先使用 MetaCubeXD 字段");
      }
    }

    if (Object.keys(finalMap).length === 0) {
      throw new Error("备份文件中没有找到可用的源 IP 标签数据");
    }

    return finalMap;
  }

  const targetDashboard = detectCurrentDashboard();

  if (targetDashboard === "unknown") {
    alert("已取消：无法识别目标 Dashboard 类型");
    return;
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
        const finalMap = buildMapFromBackup(backup, targetDashboard);

        console.log("最终源 IP 标签 Map：", finalMap);

        if (targetDashboard === "zashboard") {
          localStorage.setItem(zashboardKey, JSON.stringify(finalMap));

          console.log("已写入 Zashboard：", zashboardKey, finalMap);
          alert("已导入到 Zashboard，页面即将刷新");
          location.reload();
          return;
        }

        if (targetDashboard === "metacubexd") {
          const metacubeTags = normalMapToMetacubeTags(finalMap);

          localStorage.setItem(metacubeKey, JSON.stringify(metacubeTags));

          console.log("已写入 MetaCubeXD：", metacubeKey, metacubeTags);
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
