(function () {
  /*
   * Dashboard Source IP Label Universal Import Script
   *
   * Supported formats:
   *
   * 1. MetaCubeXD
   *    Key: clientSourceIPTags
   *    Format:
   *    [
   *      {
   *        tagName: "Device Name",
   *        sourceIP: "192.168.12.2"
   *      }
   *    ]
   *
   * 2. Zashboard >= 3.5.1
   *    Key: config/source-ip-label-list
   *    Format:
   *    [
   *      {
   *        key: "192.168.12.2",
   *        label: "Device Name",
   *        id: "uuid"
   *      }
   *    ]
   *
   * 3. Zashboard < 3.5.1
   *    Key: config/source-ip-label-map
   *    Format:
   *    {
   *      "192.168.12.2": "Device Name"
   *    }
   */

  const metaKey = "clientSourceIPTags";
  const zashListKey = "config/source-ip-label-list";
  const zashMapKey = "config/source-ip-label-map";

  const zashVersionThreshold = "3.5.1";

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

    const answer = prompt(
      "无法自动识别当前 Dashboard 类型。\n请输入：zashboard 或 metacubexd",
      "zashboard"
    );

    if (answer === "zashboard" || answer === "metacubexd") {
      return answer;
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
      console.log("检测到 Zashboard 版本：", version);

      if (compareVersions(version, zashVersionThreshold) >= 0) {
        console.log("Zashboard >= 3.5.1，按新版处理：", zashListKey);
        return "new";
      }

      console.log("Zashboard < 3.5.1，按旧版处理：", zashMapKey);
      return "old";
    }

    console.warn("无法通过版本号判断 Zashboard 版本，回退到字段判断");

    const zashListValue = localStorage.getItem(zashListKey);
    const zashMapValue = localStorage.getItem(zashMapKey);

    if (zashListValue !== null) {
      console.log("检测到字段 " + zashListKey + "，按新版 Zashboard 处理");
      return "new";
    }

    if (zashMapValue !== null) {
      console.log("检测到字段 " + zashMapKey + "，按旧版 Zashboard 处理");
      return "old";
    }

    const answer = prompt(
      "无法自动判断 Zashboard 版本。\n新版请输入 new，旧版请输入 old。",
      "new"
    );

    if (answer === "new" || answer === "old") {
      return answer;
    }

    return "unknown";
  }

  function makeId() {
    if (crypto.randomUUID) {
      return crypto.randomUUID();
    }

    return String(Date.now()) + "-" + Math.random().toString(16).slice(2);
  }

  /*
   * Normalize all possible source formats to this internal format:
   *
   * [
   *   {
   *     sourceIP: "192.168.12.2",
   *     tagName: "Device Name"
   *   }
   * ]
   */

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

  function normalizeFromNormalizedData(data) {
    const map = {};

    if (!Array.isArray(data)) {
      return [];
    }

    for (const item of data) {
      if (!item || typeof item !== "object") {
        continue;
      }

      const sourceIP = item.sourceIP || item.key;
      const tagName = item.tagName || item.label;

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

  function tagsToMeta(tags) {
    return tags.map(function (item) {
      return {
        tagName: item.tagName,
        sourceIP: item.sourceIP
      };
    });
  }

  function tagsToZashList(tags) {
    return tags.map(function (item) {
      return {
        key: item.sourceIP,
        label: item.tagName,
        id: makeId()
      };
    });
  }

  function tagsToZashMap(tags) {
    const obj = {};

    for (const item of tags) {
      if (item && item.sourceIP && item.tagName) {
        obj[item.sourceIP] = item.tagName;
      }
    }

    return obj;
  }

  function getTagsFromBackup(backup) {
    if (!backup || typeof backup !== "object") {
      throw new Error("备份文件格式错误：不是有效 JSON 对象");
    }

    let finalTags = [];

    if (Array.isArray(backup.normalizedData)) {
      const normalizedTags = normalizeFromNormalizedData(backup.normalizedData);

      if (normalizedTags.length > 0) {
        finalTags = mergeTags(finalTags, normalizedTags);
        console.log("使用 normalizedData：", normalizedTags);
      }
    }

    if (backup.data && typeof backup.data === "object") {
      const metaRaw = backup.data[metaKey];
      const zashListRaw = backup.data[zashListKey];
      const zashMapRaw = backup.data[zashMapKey];

      const metaTags = normalizeFromMeta(safeJsonParse(metaRaw, []));
      const zashListTags = normalizeFromZashList(safeJsonParse(zashListRaw, []));
      const zashMapTags = normalizeFromZashMap(safeJsonParse(zashMapRaw, {}));

      console.log("备份 app：", backup.app || "unknown");
      console.log(metaKey + " 数量：", metaTags.length, metaTags);
      console.log(zashListKey + " 数量：", zashListTags.length, zashListTags);
      console.log(zashMapKey + " 数量：", zashMapTags.length, zashMapTags);

      if (backup.app === "metacubexd") {
        finalTags = mergeTags(finalTags, zashMapTags);
        finalTags = mergeTags(finalTags, zashListTags);
        finalTags = mergeTags(finalTags, metaTags);
        console.log("备份来源为 MetaCubeXD，优先使用：", metaKey);
      } else if (backup.app === "zashboard") {
        finalTags = mergeTags(finalTags, metaTags);
        finalTags = mergeTags(finalTags, zashMapTags);
        finalTags = mergeTags(finalTags, zashListTags);
        console.log("备份来源为 Zashboard，优先使用 Zashboard 字段");
      } else {
        finalTags = mergeTags(finalTags, zashMapTags);
        finalTags = mergeTags(finalTags, metaTags);
        finalTags = mergeTags(finalTags, zashListTags);
        console.log("备份来源未知，合并所有字段，Zashboard 新版字段最后覆盖");
      }
    }

    finalTags = mergeTags([], finalTags);

    if (finalTags.length === 0) {
      throw new Error("备份文件中没有找到可用的源 IP 标签数据");
    }

    return finalTags;
  }

  const targetDashboard = detectCurrentDashboard();

  if (targetDashboard === "unknown") {
    alert("已取消：无法识别当前 Dashboard 类型");
    return;
  }

  let zashVersion = null;

  if (targetDashboard === "zashboard") {
    zashVersion = detectZashboardVersion();

    if (zashVersion === "unknown") {
      alert("已取消：无法判断 Zashboard 版本");
      return;
    }
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
        const tags = getTagsFromBackup(backup);

        if (targetDashboard === "metacubexd") {
          const metaTags = tagsToMeta(tags);

          localStorage.removeItem(zashListKey);
          localStorage.removeItem(zashMapKey);

          localStorage.setItem(metaKey, JSON.stringify(metaTags));

          console.log("目标：MetaCubeXD");
          console.log("已删除新版 Zashboard 字段：", zashListKey);
          console.log("已删除旧版 Zashboard 字段：", zashMapKey);
          console.log("已按 MetaCubeXD 格式写入：", metaKey, metaTags);
        }

        if (targetDashboard === "zashboard" && zashVersion === "new") {
          const zashList = tagsToZashList(tags);

          localStorage.removeItem(metaKey);
          localStorage.removeItem(zashMapKey);

          localStorage.setItem(zashListKey, JSON.stringify(zashList));

          console.log("目标：Zashboard 新版 >= " + zashVersionThreshold);
          console.log("已删除 MetaCubeXD 字段：", metaKey);
          console.log("已删除旧版 Zashboard 字段：", zashMapKey);
          console.log("已按新版 Zashboard 格式写入：", zashListKey, zashList);
        }

        if (targetDashboard === "zashboard" && zashVersion === "old") {
          const zashMap = tagsToZashMap(tags);

          localStorage.removeItem(metaKey);
          localStorage.removeItem(zashListKey);

          localStorage.setItem(zashMapKey, JSON.stringify(zashMap));

          console.log("目标：Zashboard 旧版 < " + zashVersionThreshold);
          console.log("已删除 MetaCubeXD 字段：", metaKey);
          console.log("已删除新版 Zashboard 字段：", zashListKey);
          console.log("已按旧版 Zashboard 格式写入：", zashMapKey, zashMap);
        }

        alert(
          "源 IP 标签导入完成，共导入 " +
            tags.length +
            " 条记录。页面即将刷新。"
        );

        location.reload();
      } catch (e) {
        console.error("导入失败：", e);
        alert("导入失败：" + e.message);
      }
    };

    reader.readAsText(file);
  };

  input.click();
})();
