(function () {
  /*
   * Dashboard Source IP Label Universal Export Script
   *
   * Export target format:
   *
   * {
   *   "type": "source-ip-label-backup",
   *   "formatVersion": 4,
   *   "app": "zashboard" | "metacubexd" | "unknown",
   *   "dashboardVersion": "3.5.1" | null,
   *   "origin": "http://192.168.12.1:9090",
   *   "pathname": "/ui/zashboard/",
   *   "exportedAt": "...",
   *   "count": 3,
   *   "normalizedData": [
   *     {
   *       "sourceIP": "192.168.12.2",
   *       "tagName": "Andy Da`s iMac"
   *     }
   *   ]
   * }
   *
   * Supported source formats:
   *
   * 1. MetaCubeXD
   *    Key: clientSourceIPTags
   *    Format: [{ tagName, sourceIP }]
   *
   * 2. Zashboard >= 3.5.1
   *    Key: config/source-ip-label-list
   *    Format: [{ key, label, id }]
   *
   * 3. Zashboard < 3.5.1
   *    Key: config/source-ip-label-map
   *    Format: { "IP": "Label" }
   */

  const metaKey = "clientSourceIPTags";
  const zashListKey = "config/source-ip-label-list";
  const zashMapKey = "config/source-ip-label-map";

  const zashVersionThreshold = "3.5.1";

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

  function compareVersions(a, b) {
    const pa = String(a).replace(/^v/i, "").split(".").map(Number);
    const pb = String(b).replace(/^v/i, "").split(".").map(Number);
    const len = Math.max(pa.length, pb.length);

    for (let i = 0; i < len; i++) {
      const na = pa[i] || 0;
      const nb = pb[i] || 0;

      if (na > nb) {
        return 1;
      }

      if (na < nb) {
        return -1;
      }
    }

    return 0;
  }

  function detectCurrentDashboard() {
    const href = location.href.toLowerCase();
    const path = location.pathname.toLowerCase();

    if (href.includes("metacubexd") || path.includes("metacubexd")) {
      return "metacubexd";
    }

    if (href.includes("zashboard") || path.includes("zashboard")) {
      return "zashboard";
    }

    return "unknown";
  }

  function findZashboardVersionFromPage() {
    const text = document.body ? document.body.innerText : "";
    const match = text.match(/zashboard\s*v?(\d+\.\d+\.\d+)/i);

    if (match && match[1]) {
      return match[1];
    }

    return null;
  }

  function findZashboardVersionFromLocalStorage() {
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);

      if (!key) {
        continue;
      }

      if (!key.includes("Zephyruso/zashboard/releases/latest")) {
        continue;
      }

      try {
        const value = JSON.parse(localStorage.getItem(key));

        if (value && value.version) {
          return String(value.version).replace(/^v/i, "");
        }

        if (value && value.tag_name) {
          return String(value.tag_name).replace(/^v/i, "");
        }

        if (value && value.name) {
          const match = String(value.name).match(/v?(\d+\.\d+\.\d+)/i);

          if (match && match[1]) {
            return match[1];
          }
        }
      } catch (e) {
        console.warn("解析 Zashboard release cache 失败：", e);
      }
    }

    return null;
  }

  function detectZashboardVersion() {
    let version = findZashboardVersionFromPage();

    if (!version) {
      version = findZashboardVersionFromLocalStorage();
    }

    if (version) {
      if (compareVersions(version, zashVersionThreshold) >= 0) {
        return {
          version: version,
          versionType: "new"
        };
      }

      return {
        version: version,
        versionType: "old"
      };
    }

    return {
      version: null,
      versionType: "unknown"
    };
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

  function normalizeFromZashMap(obj) {
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) {
      return [];
    }

    return Object.entries(obj)
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

  let zashboardInfo = {
    version: null,
    versionType: null
  };

  if (detectedApp === "zashboard") {
    zashboardInfo = detectZashboardVersion();
  }

  const metaRaw = localStorage.getItem(metaKey);
  const zashListRaw = localStorage.getItem(zashListKey);
  const zashMapRaw = localStorage.getItem(zashMapKey);

  const metaTags = normalizeFromMeta(safeJsonParse(metaRaw, []));
  const zashListTags = normalizeFromZashList(safeJsonParse(zashListRaw, []));
  const zashMapTags = normalizeFromZashMap(safeJsonParse(zashMapRaw, {}));

  let exportTags = [];
  let sourceKey = null;
  let sourceFormat = null;

  if (detectedApp === "metacubexd") {
    if (metaTags.length > 0) {
      exportTags = mergeTags(exportTags, metaTags);
      sourceKey = metaKey;
      sourceFormat = "metacubexd";
      console.log("当前 Dashboard：MetaCubeXD，导出字段：", metaKey);
    } else if (zashListTags.length > 0) {
      exportTags = mergeTags(exportTags, zashListTags);
      sourceKey = zashListKey;
      sourceFormat = "zashboard-new-fallback";
      console.log("MetaCubeXD 页面未找到 clientSourceIPTags，回退导出：", zashListKey);
    } else if (zashMapTags.length > 0) {
      exportTags = mergeTags(exportTags, zashMapTags);
      sourceKey = zashMapKey;
      sourceFormat = "zashboard-old-fallback";
      console.log("MetaCubeXD 页面未找到 clientSourceIPTags，回退导出：", zashMapKey);
    }
  } else if (detectedApp === "zashboard") {
    if (zashboardInfo.versionType === "new") {
      if (zashListTags.length > 0) {
        exportTags = mergeTags(exportTags, zashListTags);
        sourceKey = zashListKey;
        sourceFormat = "zashboard-new";
        console.log("当前 Dashboard：Zashboard 新版，导出字段：", zashListKey);
      } else if (zashMapTags.length > 0) {
        exportTags = mergeTags(exportTags, zashMapTags);
        sourceKey = zashMapKey;
        sourceFormat = "zashboard-old-fallback";
        console.log("Zashboard 新版未找到新版字段，回退导出旧字段：", zashMapKey);
      } else if (metaTags.length > 0) {
        exportTags = mergeTags(exportTags, metaTags);
        sourceKey = metaKey;
        sourceFormat = "metacubexd-fallback";
        console.log("Zashboard 新版未找到 Zashboard 字段，回退导出 Meta 字段：", metaKey);
      }
    } else if (zashboardInfo.versionType === "old") {
      if (zashMapTags.length > 0) {
        exportTags = mergeTags(exportTags, zashMapTags);
        sourceKey = zashMapKey;
        sourceFormat = "zashboard-old";
        console.log("当前 Dashboard：Zashboard 旧版，导出字段：", zashMapKey);
      } else if (zashListTags.length > 0) {
        exportTags = mergeTags(exportTags, zashListTags);
        sourceKey = zashListKey;
        sourceFormat = "zashboard-new-fallback";
        console.log("Zashboard 旧版未找到旧字段，回退导出新版字段：", zashListKey);
      } else if (metaTags.length > 0) {
        exportTags = mergeTags(exportTags, metaTags);
        sourceKey = metaKey;
        sourceFormat = "metacubexd-fallback";
        console.log("Zashboard 旧版未找到 Zashboard 字段，回退导出 Meta 字段：", metaKey);
      }
    } else {
      console.warn("无法判断 Zashboard 版本，按字段优先级兜底导出");

      if (zashListTags.length > 0) {
        exportTags = mergeTags(exportTags, zashListTags);
        sourceKey = zashListKey;
        sourceFormat = "zashboard-new-fallback";
      } else if (zashMapTags.length > 0) {
        exportTags = mergeTags(exportTags, zashMapTags);
        sourceKey = zashMapKey;
        sourceFormat = "zashboard-old-fallback";
      } else if (metaTags.length > 0) {
        exportTags = mergeTags(exportTags, metaTags);
        sourceKey = metaKey;
        sourceFormat = "metacubexd-fallback";
      }
    }
  } else {
    console.warn("无法识别当前 Dashboard，按字段优先级兜底导出");

    if (zashListTags.length > 0) {
      exportTags = mergeTags(exportTags, zashListTags);
      sourceKey = zashListKey;
      sourceFormat = "zashboard-new-fallback";
    } else if (zashMapTags.length > 0) {
      exportTags = mergeTags(exportTags, zashMapTags);
      sourceKey = zashMapKey;
      sourceFormat = "zashboard-old-fallback";
    } else if (metaTags.length > 0) {
      exportTags = mergeTags(exportTags, metaTags);
      sourceKey = metaKey;
      sourceFormat = "metacubexd-fallback";
    }
  }

  if (exportTags.length === 0) {
    alert("当前页面没有找到可导出的源 IP 标签数据");
    console.warn("未找到可导出的源 IP 标签数据");
    return;
  }

  const backup = {
    type: "source-ip-label-backup",
    formatVersion: 4,
    app: detectedApp,
    dashboardVersion: zashboardInfo.version,
    dashboardVersionType: zashboardInfo.versionType,
    sourceKey: sourceKey,
    sourceFormat: sourceFormat,
    origin: location.origin,
    pathname: location.pathname,
    exportedAt: now.toISOString(),
    count: exportTags.length,
    normalizedData: exportTags
  };

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

  console.log("源 IP 标签已导出为统一中间格式：", backup);
})();
