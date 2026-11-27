# 旧分支去向（MacWave → Summerwave）

Summerwave 仓库从 0.1.0 重新起步，所以在新的仓库里**没有保留** MacWave 的历史分支。
完整历史仍在旧的只读仓库 `MacWaveOrg/MacWave` 里（分支名未改），下表的 SHA 就是各条线的最后一个提交。

需要看某条旧线：

```sh
git clone https://github.com/MacWaveOrg/MacWave.git macwave-legacy
git -C macwave-legacy log -1 <sha>          # 或 git checkout -b 4.6.1 <sha>
```

| 旧分支 | 最后提交 | 日期 | 说明 |
| --- | --- | --- | --- |
| `1.0.0` | `4177df1` | 2026-10-07 | Point every URL at the MacWaveOrg organization |
| `1.1.0-beta` | `eb034a3` | 2026-08-27 | Update wave.py |
| `2.0.0-beta` | `0a7266e` | 2026-08-28 | Update pkginstaller.py |
| `2.0.0-dev` | `010f4ed` | 2026-10-07 | Point every URL at the MacWaveOrg organization |
| `2.1.0` | `3f2923e` | 2026-10-07 | Point every URL at the MacWaveOrg organization |
| `2.2.0` | `efc4fbb` | 2026-09-27 | List every supported package in the README |
| `2.3` | `ce94e5e` | 2026-10-07 | Point every URL at the MacWaveOrg organization |
| `2.4` | `8c1fa45` | 2026-10-07 | Point every URL at the MacWaveOrg organization |
| `2.5` | `f162cad` | 2026-10-07 | Release MacWave 2.6.1 |
| `3.0` | `fd594c3` | 2026-10-22 | Name the missing dependency instead of blaming a module |
| `3.1` | `6741402` | 2026-10-24 | Release 3.2.0 |
| `3.2` | `3fa09ca` | 2026-10-29 | Skip the four known-bad record groups when syncing payloads |
| `4.0` | `ec1fbc7` | 2026-10-29 | Merge 4.1 into main |
| `4.1` | `0e906de` | 2026-11-02 | 修正捐赠明细：AI 用量费用与域名成本 |
| `4.1-error-hints` | `fbee86b` | 2026-10-30 | Say what to type when the command or the package name is wro |
| `4.1-info-formats` | `32c4c89` | 2026-10-30 | Give `wave info` machine-readable output |
| `4.1-latest-command` | `66d4367` | 2026-10-30 | Add `wave latest` to see what has a newer version |
| `4.1-mirror-ops` | `52b2fb4` | 2026-10-30 | Skip the records that are broken on purpose |
| `4.1-silent` | `793bd05` | 2026-10-31 | Fix the flags registry's --json mix-up, and make flags_test  |
| `4.2` | `d084c9d` | 2026-11-04 | fix: 系统级安装不再把整棵树 chown 给安装者 |
| `4.3` | `f5a036c` | 2026-11-15 | docs: 4.3.4 资产清单去掉 SHA256SUMS（密钥尚未就绪） [skip ci] |
| `4.4` | `02a059c` | 2026-11-19 | feat(install): `wave install jq@` 说清是漏写版本，并进 4.4.1 |
| `4.4-261119` | `24003c0` | 2026-11-19 | fix(keys): 跟上 Keys/README.md → description.md 的改名 |
| `4.5` | `bc56573` | 2026-11-23 | docs(release): MacWave 4.5.2 发布说明 |
| `4.6` | `45e1407` | 2026-11-24 | 再修三处重定位细节：版本号库名、自引用、libiconv 换不换 |
| `4.6.1` | `9fdf9ab` | 2026-11-26 | 修 @loader_path 越界：软链接索引不能用 realpath |
| `4.7` | `f4a7c3c` | 2026-11-26 | install.sh 增加升级模式：selfupdate 以后只是「带变量调用它」 |
| `5.0` | `6c7341d` | 2026-11-26 | docs(PROJECT_CONTEXT): 5.0 是合并实验分支，长期不发布 |
| `Sha0huaZhang-patch-1` | `314987e` | 2026-10-24 | Update README.md |
| `Sha0huaZhang-patch-2` | `cac85b8` | 2026-10-29 | 更新 README.md |
| `dependabot/github_actions/4.1/actions-fa8f869f2d` | `8e329d8` | 2026-10-31 | ci: bump the actions group with 4 updates |
| `legacy-configdata` | `50b4b02` | 2026-10-07 | Release MacWave 2.6.1 |
| `legacy-infosource` | `bda7902` | 2026-10-11 | Fix the ncurses version tmux 3.6 needs, and give ncdu its mi |
| `test/arglen` | `a709d4b` | 2026-11-20 | fix(install): mw_domain 跟上 net/domains.py 的校验规则 |
