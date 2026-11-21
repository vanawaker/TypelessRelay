#!/usr/bin/env python3
import json
import os
import shutil
import tempfile

path = os.path.expanduser("~/Library/Application Support/Typeless/app-storage.json")
if not os.path.exists(path):
    raise SystemExit(f"Not found: {path}")

bak_path = path + ".bak"
if not os.path.exists(bak_path):
    shutil.copy2(path, bak_path)

with open(path, "r", encoding="utf-8") as f:
    store = json.load(f)

whitelist_macos = [
    "com.todesktop.230313mzl4w4u92",
    "com.tinyspeck.slackmacgap",
    "com.apple.mail",
    "com.figma.Desktop",
    "com.openai.atlas",
    "com.conductor.app",
    "com.github.wez.wezterm",
    "org.mozilla.thunderbird",
    "jp.naver.line.mac",
    "com.apple.ScreenSharing",
    "com.astro-hq.LunaDisplayMac",
    "com.netease.uuremote",
    "com.apple.RemoteDesktop",
]

blacklist_macos = [
    "com.sublimetext.4",
    "com.tencent.xinWeChat",
    "com.alibaba.DingTalkMac",
    "com.microsoft.Excel",
    "com.kingsoft.wpsoffice.mac",
    "dev.zed.Zed",
    "com.meta.endo",
]

existing_acc = store.get("accessibilityConfig") or {}
existing_data = existing_acc.get("data") or {}

for b in (existing_data.get("app_whitelist", {}).get("macos", {}).get("exact") or []):
    if b not in whitelist_macos:
        whitelist_macos.append(b)

for b in (existing_data.get("app_blacklist", {}).get("macos", {}).get("exact") or []):
    if b not in blacklist_macos:
        blacklist_macos.append(b)

store["accessibilityConfig"] = {
    "syncTime": "2099-12-31T23:59:59.000Z",
    "data": {
        "version": "99.0.0",
        "app_blacklist": {
            "macos": {"exact": blacklist_macos, "regex": []},
            "windows": existing_data.get("app_blacklist", {}).get("windows", {"exact": [], "regex": []}),
        },
        "app_whitelist": {
            "macos": {"exact": whitelist_macos, "regex": []},
            "windows": existing_data.get("app_whitelist", {}).get("windows", {"exact": [], "regex": []}),
        },
        "url_blacklist": existing_data.get(
            "url_blacklist",
            {
                "exact": [],
                "prefix": [
                    "https://docs.google.com/document/d",
                    "https://docs.qq.com/doc/",
                    "https://docs.qq.com/sheet/",
                ],
                "domain": [],
                "regex": [],
            },
        ),
        "url_whitelist": existing_data.get(
            "url_whitelist",
            {
                "exact": [],
                "prefix": ["https://www.figma.com/design/"],
                "domain": [],
                "regex": [],
            },
        ),
    },
}

dir_name = os.path.dirname(path)
with tempfile.NamedTemporaryFile("w", dir=dir_name, delete=False, encoding="utf-8") as tf:
    json.dump(store, tf, ensure_ascii=False, indent="\t")
    tmp_name = tf.name

os.replace(tmp_name, path)
print(f"Successfully updated {path} (backup at {bak_path})")
