#!/bin/bash
# 重新应用 dsh-tool-cordis 幂等补丁（dsh 升级会覆盖 node_modules，需重跑本脚本）。
#
# 背景：@deepseek-ai/dsh-tool-cordis 挂载时向进程全局单例 cordisInspect 注册
# 一组 Host inspect provider（Service/Event/Builtin/Tool）。第二个带 tool-cordis
# 的 agent preset（例如「PTC-创造 混合模式」ptc-cordis 与「创造模式」cordis 并存）
# 再挂载时，注册表已含同名 provider，抛 "Host Cordis inspect provider ... already
# registered"，导致第二个预设挂载失败、GUI 秒退为标准模式。
#
# 修复：apply() 注册前先列出已注册的 host provider，同 id 幂等跳过。
# provider 是同一包的静态目录描述，重复注册无意义也无害；
# 工具（cordis_define 等）与提示按 scope 分层各自注册，不受影响。
set -euo pipefail

TARGET=""
for cand in \
  "/Users/tny/.local/share/fnm/node-versions/"*/installation/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-tool-cordis/lib/index.js \
  "$HOME/.local/share/fnm/node-versions/"*/installation/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-tool-cordis/lib/index.js
do
  [ -f "$cand" ] && TARGET="$cand" && break
done
if [ -z "$TARGET" ]; then
  echo "未找到 dsh-tool-cordis lib/index.js，请检查 dsh 安装位置" >&2
  exit 1
fi

MARKER="PATCH: inspect provider 注册表是进程全局单例"
if grep -q "$MARKER" "$TARGET"; then
  echo "补丁已存在，跳过：$TARGET"
  exit 0
fi

cp "$TARGET" "$TARGET.bak"

# 用 node 做精确替换（避免 sed 转义地狱）
node -e '
const fs = require("fs");
const p = process.argv[1];
let s = fs.readFileSync(p, "utf8");
const old = `\tfor (const provider of hostInspectProviders(ctx)) ctx.effect(() => ctx.cordisInspect.register(provider), \`tool-cordis: inspect ${provider.manifest.id}\`);`;
const neu = `\t// PATCH: inspect provider 注册表是进程全局单例（dsh-cordis-host-runner），
\t// 同 id 已被其他预设（如 cordis / ptc-cordis）注册时直接抛
\t// "already registered"，导致第二个带 tool-cordis 的预设挂载失败。
\t// provider 是同一包的静态目录描述，重复注册无意义也无害；
\t// 工具与提示仍按 scope 分层各自注册，不受影响。这里幂等跳过。
\tconst existingHostInspect = new Set(ctx.cordisInspect.list().filter(p => p.platform === "host").map(p => p.id));
\tfor (const provider of hostInspectProviders(ctx)) {
\t\tif (existingHostInspect.has(provider.manifest.id)) continue;
\t\tctx.effect(() => ctx.cordisInspect.register(provider), \`tool-cordis: inspect ${provider.manifest.id}\`);
\t}`;
if (!s.includes(old)) { console.error("未匹配到待替换代码，请检查 dsh 版本"); process.exit(2); }
s = s.replace(old, neu);
fs.writeFileSync(p, s);
console.log("补丁已应用：", p);
'
node --check "$TARGET" && echo "语法校验通过"
echo "完成：重新启动 dsh 服务（或等 KeepAlive 自愈）后生效。"
