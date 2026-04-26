(function () {
  const zashListKey = "config/source-ip-label-list";
  const zashMapKey = "config/source-ip-label-map";
  const metaKey = "clientSourceIPTags";

  function detectCurrentDashboard() {
    const href = location.href.toLowerCase();
    const path = location.pathname.toLowerCase();

    if (href.includes("zashboard") || path.includes("zashboard")) {
      return "zashboard";
    }

    if (href.includes("metacubexd") || path.includes("metacubexd")) {
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

  function normalizeFromZashList(list) {
    const map = {};

    if (!Array.isArray(list)) {
      return [];
    }

    for (const item of list) {
      if (!item || typeof item !== "object") {
        continue;
      }

      const sourceIP = item.key;
      const tagName = item.label;

      if (sourceIP && tagName) {
        map[sourceIP] = tagName;
      }
    }

    return Object.entries(map).map(function ([sourceIP, tagName]) {
      return {
        sourceIP: sourceIP,
        tagName: tagName
      };
    });
  }

  function normalizeFromZashMap(map) {
    if (!map || typeof map !== "object" || Array.isArray(map)) {
      return [];
    }

    return Object.entries(map)
      .filter(function ([sourceIP, tagName]) {
        return sourceIP && tagName;
      })
      .map(function ([sourceIP, tagName]) {
        return {
          sourceIP: sourceIP,
          tagName: tagName
        };
      });
  }

  function normalizeFromMeta(tags) {
    const map = {};

    if (!Array.isArray(tags)) {
      return [];
    }

    for (const item of tags) {
      if (!item || typeof item !== "object") {
        continue;
      }

      const sourceIP = item.sourceIP;
      const tagName = item.tagName;

      if (sourceIP && tagName) {
        map[sourceIP] = tagName;
      }
    }

    return Object.entries(map).map(function ([sourceIP, tagName]) {
      return {
        sourceIP: sourceIP,
        tagName: tagName
      };
    });
  }

  function tagsToZashList(tags) {
    return tags.map(function (item) {
      return {
        key: item.sourceIP,
        label: item.tagName,
        id: crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + "-" + Math.random()
      };
    });
  }

  function tagsToZashMap(tags) {
    const map = {};

    for (const item of tags) {
      if (item.sourceIP && item.tagName) {
        map[item.sourceIP] = item.tagName;
      }
    }

    return map;
  }

  function tagsToMeta(tags) {
    return tags.map(function (item) {
      return {
        tagName: item.tagName,
        sourceIP: item.sourceIP
      };
    });
  }

  function mergeTags(baseTags, overrideTags) {
    const map = {};

    for (const item of baseTags) {
      if (item && item.sourceIP && item.tagName) {
        map[item.sourceIP] = item.tagName;
      }
    }

    for (const item of overrideTags) {
      if (item && item.sourceIP && item.tagName) {
        map[item.sourceIP] = item.tagName;
      }
    }

    return Object.entries(map).map(function ([sourceIP, tagName]) {
      return {
        sourceIP: sourceIP,
        tagName: tagName
      };
    });
  }

  const now = new Date();
  const timestamp = makeTimestamp(now);
  const detectedApp = detectCurrentDashboard();

  const zashListRaw = localStorage.getItem(zashListKey);
  const zashMapRaw = localStorage.getItem(zashMapKey);
  const metaRaw = localStorage.getItem(metaKey);

  const zashListTags = normalizeFromZashList(safeJsonParse(zashListRaw, []));
  const zashMapTags = normalizeFromZashMap(safeJsonParse(zashMapRaw, {}));
  const metaTags = normalizeFromMeta(safeJsonParse(metaRaw, []));

  let exportTags = [];

  if (detectedApp === "zashboard") {
    if (zashListTags.length > 0) {
      exportTags = mergeTags(exportTags, zashListTags);
      console.log("Zashboard：使用新版字段", zashListKey);
    } else if (zashMapTags.length > 0) {
      exportTags = mergeTags(exportTags, zashMapTags);
      console.log("Zashboard：使用旧版字段", zashMapKey);
    } else if (metaTags.length > 0) {
      exportTags = mergeTags(exportTags, metaTags);
      console.log("Zashboard：使用兼容字段", metaKey);
    }
  } else if (detectedApp === "metacubexd") {
    if (metaTags.length > 0) {
      exportTags = mergeTags(exportTags, metaTags);
      console.log("MetaCubeXD：使用字段", metaKey);
    } else if (zashListTags.length > 0) {
      exportTags = mergeTags(exportTags, zashListTags);
      console.log("MetaCubeXD：使用残留 Zashboard 新版字段", zashListKey);
    } else if (zashMapTags.length > 0) {
      exportTags = mergeTags(exportTags, zashMapTags);
      console.log("MetaCubeXD：使用残留 Zashboard 旧版字段", zashMapKey);
    }
  } else {
    exportTags = mergeTags(exportTags, zashMapTags);
    exportTags = mergeTags(exportTags, metaTags);
    exportTags = mergeTags(exportTags, zashListTags);
  }

  if (exportTags.length === 0) {
    alert("当前页面没有找到可导出的源 IP 标签数据");
    console.warn("未找到可导出的源 IP 标签数据");
    return;
  }

  const backup = {
    app: detectedApp,
    type: "source-ip-label-backup",
    formatVersion: 3,
    origin: location.origin,
    pathname: location.pathname,
    exportedAt: now.toISOString(),
    count: exportTags.length,
    normalizedData: exportTags,
    data: {}
  };

  backup.data[zashListKey] = JSON.stringify(tagsToZashList(exportTags));
  backup.data[zashMapKey] = JSON.stringify(tagsToZashMap(exportTags));
  backup.data[metaKey] = JSON.stringify(tagsToMeta(exportTags));

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
