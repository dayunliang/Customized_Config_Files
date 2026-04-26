(function () {
  const zashListKey = "config/source-ip-label-list";
  const zashMapKey = "config/source-ip-label-map";
  const metaKey = "clientSourceIPTags";

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

  function makeId() {
    if (crypto.randomUUID) {
      return crypto.randomUUID();
    }

    return String(Date.now()) + "-" + Math.random().toString(16).slice(2);
  }

  function detectZashboardVersion() {
    const zashListValue = localStorage.getItem(zashListKey);
    const zashMapValue = localStorage.getItem(zashMapKey);

    if (zashListValue !== null) {
      return "new";
    }

    if (zashMapValue !== null) {
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
    const map = {};

    for (const item of tags) {
      if (item.sourceIP && item.tagName) {
        map[item.sourceIP] = item.tagName;
      }
    }

    return map;
  }

  function getTagsFromBackup(backup) {
    if (!backup || typeof backup !== "object") {
      throw new Error("备份文件格式错误");
    }

    let finalTags = [];

    if (Array.isArray(backup.normalizedData)) {
      finalTags = mergeTags(
        finalTags,
        normalizeFromNormalizedData(backup.normalizedData)
      );
    }

    if (backup.data && typeof backup.data === "object") {
      const metaRaw = backup.data[metaKey];
      const zashListRaw = backup.data[zashListKey];
      const zashMapRaw = backup.data[zashMapKey];

      const metaTags = normalizeFromMeta(safeJsonParse(metaRaw, []));
      const zashListTags = normalizeFromZashList(safeJsonParse(zashListRaw, []));
      const zashMapTags = normalizeFromZashMap(safeJsonParse(zashMapRaw, {}));

      if (backup.app === "metacubexd") {
        finalTags = mergeTags(finalTags, zashMapTags);
        finalTags = mergeTags(finalTags, zashListTags);
        finalTags = mergeTags(finalTags, metaTags);
        console.log("备份来源为 MetaCubeXD，优先使用 clientSourceIPTags");
      } else if (backup.app === "zashboard") {
        finalTags = mergeTags(finalTags, metaTags);
        finalTags = mergeTags(finalTags, zashMapTags);
        finalTags = mergeTags(finalTags, zashListTags);
        console.log("备份来源为 Zashboard，优先使用 Zashboard 字段");
      } else {
        finalTags = mergeTags(finalTags, zashMapTags);
        finalTags = mergeTags(finalTags, metaTags);
        finalTags = mergeTags(finalTags, zashListTags);
        console.log("备份来源未知，合并所有字段");
      }
    }

    if (finalTags.length === 0) {
      throw new Error("备份文件中没有找到可用的源 IP 标签数据");
    }

    return finalTags;
  }

  const zashVersion = detectZashboardVersion();

  if (zashVersion === "unknown") {
    alert("已取消：无法判断 Zashboard 版本");
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
        const tags = getTagsFromBackup(backup);

        if (zashVersion === "new") {
          const zashList = tagsToZashList(tags);
          localStorage.setItem(zashListKey, JSON.stringify(zashList));

          localStorage.removeItem(metaKey);

          console.log("已按新版 Zashboard 格式写入：", zashListKey, zashList);
        }

        if (zashVersion === "old") {
          const zashMap = tagsToZashMap(tags);
          localStorage.setItem(zashMapKey, JSON.stringify(zashMap));

          localStorage.removeItem(metaKey);

          console.log("已按旧版 Zashboard 格式写入：", zashMapKey, zashMap);
        }

        alert(
          "已导入到 Zashboard " +
            (zashVersion === "new" ? "新版" : "旧版") +
            "，共 " +
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
