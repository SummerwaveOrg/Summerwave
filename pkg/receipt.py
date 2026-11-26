#!/usr/bin/env python3

# receipt.py
#
# 写每个版本目录里的 `Note` —— 「这个条目装好了」的凭据。
#
# 现阶段**只写不读**：`.is_a_tree`、`.depped_*` 与 `_DEPS` 仍然照旧由 shell 维护，
# 等 `Note` 铺开到能被 uninstaller / linker / doctor 读，再删它们。
#
# 三条约定（与 `var/VERSION.json` 同一个道理）：
#
#   * **最后一步写**：解包 → 重定位/签名 → 链接 → `Note`。
#     先写它就会留下「记录说装好了、文件却没有」的状态。
#   * **原子写**：先写 `Note.new` 再 os.replace，断电不会留半份。
#   * **不存反向依赖**：「谁依赖我」由扫描所有 `Note` 的 deps 派生
#     （几百个 JSON 是毫秒级），这样不会出现正反两向不一致。
#
# 字段含义见 docs/PROJECT_CONTEXT.md 的「运行时目录」一节。

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from configpaths import (RECEIPT_NAME, STATE_DIR_NAME, STATE_FILE_NAME,
                         internal_state_dir, load_base_dir, read_state_values)

SCHEMA = 1


def client_version():

    # 打这条记录的是哪个客户端版本。读不到就是 None —— 收据不该因为这件事失败。
    #
    # 两个来源，按可靠程度排：
    #   1. 树内状态 <base>/var/config.sh（正式安装都有）；
    #   2. 配置里的 base_dir（开发目录里代码不在安装树中，只能这样找）。

    candidates = []
    try:
        state_dir = internal_state_dir()
        if state_dir is not None:
            candidates.append(state_dir)
    except Exception:
        pass
    try:
        candidates.append(load_base_dir() / STATE_DIR_NAME)
    except SystemExit:
        pass
    except Exception:
        pass

    for directory in candidates:
        values = read_state_values(directory / STATE_FILE_NAME)
        version = (values.get("MACWAVE_VERSION") or "").strip()
        if version:
            return version
    return None


def path_for(target_dir):

    # `Note` 的位置：就在那个版本目录里，和 bin/ lib/ 平级。

    return Path(target_dir) / RECEIPT_NAME


def write_note(target_dir, name, version, arch,
               requested, linked, tree,
               deps=(), commands=(), link_note=None, bottle=None):

    # 写一份收据。任何异常都只警告、不让安装失败 —— 收据是「方便以后查」，
    # 不是「装上」的必要条件（真正的凭据仍然是版本记录 + 文件是否到位）。

    payload = {
        "schema": SCHEMA,
        "name": name,
        "version": version,
        "arch": arch,
        "requested": bool(requested),
        "linked": bool(linked),
        "link_note": link_note,
        "tree": bool(tree),
        "deps": [str(value) for value in deps if str(value).strip()],
        "commands": [str(value) for value in commands if str(value).strip()],
        "bottle": bottle or {},
        "installed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "installed_by": client_version(),
    }

    path = path_for(target_dir)
    temp = path.with_name(path.name + ".new")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(temp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=False)
            handle.write("\n")
        os.replace(temp, path)
        return path
    except OSError as error:
        try:
            os.unlink(temp)
        except OSError:
            pass
        sys.stderr.write(f"🌊 Warning: could not write {path.name}: {error}\n")
        return None


def tree_commands(target_dir):

    # 整树包：把 <版本目录>/bin/ 下的可执行文件名都列出来（一条命令一条链接）。

    bin_dir = Path(target_dir) / "bin"
    if not bin_dir.is_dir():
        return []
    return sorted(entry.name for entry in bin_dir.iterdir() if entry.is_file())
