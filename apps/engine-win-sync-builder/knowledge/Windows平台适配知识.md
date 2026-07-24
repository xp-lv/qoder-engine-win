# Windows 平台适配知识

> Mac→Win 平台适配参考手册。用于平台适配者设计适配方案、同步执行者执行代码修改、回归验证者检查平台兼容性问题。

---

## 一、路径分隔符适配

### 1.1 差异对照

| 平台 | 分隔符 | 示例 |
|---|---|---|
| Mac | `/` | `/Users/xxx/project` |
| Win | `\` | `C:\Users\xxx\project` |

### 1.2 适配方法

**推荐方案：使用 Python 跨平台 API**

```python
# ❌ 硬编码（Mac 风格）
path = "/Users/xxx/project/output.json"
path = base_dir + "/subdir/file.json"

# ✅ 跨平台（推荐）
import os
path = os.path.join(base_dir, "subdir", "file.json")

# ✅ 或使用 pathlib
from pathlib import Path
path = Path(base_dir) / "subdir" / "file.json"
```

### 1.3 硬编码路径检测

以下模式需在差异分析中检出：

| 硬编码模式 | 说明 | Win 对应 |
|---|---|---|
| `/Users/` | Mac 用户目录 | `C:\Users\` 或 `%USERPROFILE%` |
| `/tmp/` | Mac 临时目录 | `%TEMP%` |
| `/usr/local/` | Mac 系统目录 | 无直接对应 |
| `/var/` | Mac 变量目录 | 无直接对应 |
| `/opt/` | Mac 可选目录 | 无直接对应 |

### 1.4 配置文件中的路径

- app.yaml 中的路径使用相对路径（相对于 WORKSPACE_ROOT）
- JSON 配置文件中的路径使用 `os.path.join()` 动态构建

---

## 二、换行符适配

### 2.1 差异对照

| 平台 | 换行符 | 说明 |
|---|---|---|
| Mac | `LF` (`\n`) | Unix 风格 |
| Win | `CRLF` (`\r\n`) | Windows 风格 |

### 2.2 Git 配置策略

```bash
# 推荐配置：提交时转为 LF，检出时不转换
git config core.autocrlf input

# 或使用 .gitattributes 统一管理
# .gitattributes 内容：
*.py text eol=lf
*.md text eol=lf
*.json text eol=lf
*.yaml text eol=lf
*.sh text eol=lf
*.cmd text eol=crlf
```

### 2.3 Python 文件读写

```python
# ❌ Mac 习惯（不指定 newline）
with open("file.txt", "w") as f:
    f.write("line1\nline2\n")

# ✅ 跨平台（使用 newline 参数）
# newline="" → 不转换，保留原始换行符
# newline="\n" → 强制使用 LF
# newline="\r\n" → 强制使用 CRLF
with open("file.txt", "w", newline="") as f:
    f.write("line1\nline2\n")
```

### 2.4 引擎中的换行符处理

- Python 源文件（.py）：统一使用 LF
- Markdown 文档（.md）：统一使用 LF
- JSON 文件（.json）：统一使用 LF
- .cmd 脚本：使用 CRLF
- .sh 脚本：使用 LF（Mac 专用，不同步到 Win）

---

## 三、Shell 命令替换

### 3.1 bash → PowerShell 语法对照表

| 操作 | bash (Mac) | PowerShell (Win) |
|---|---|---|
| 命令连接 | `cmd1 && cmd2` | `cmd1; cmd2` 或 `if ($LASTEXITCODE -eq 0) { cmd2 }` |
| 命令替换 | `result=$(cmd)` | `$result = (cmd)` 或 `$result = Invoke-Expression "cmd"` |
| 管道 | `cmd1 \| cmd2` | `cmd1 \| cmd2`（相同） |
| 重定向 | `cmd > file` | `cmd > file`（相同） 或 `cmd \| Out-File file` |
| 后台执行 | `cmd &` | `Start-Process cmd` 或 `Start-Job { cmd }` |
| 条件执行 | `if [ "$x" = "y" ]` | `if ($x -eq "y")` |
| 变量引用 | `$VAR` 或 `${VAR}` | `$VAR` 或 `$env:VAR`（环境变量） |

### 3.2 Python 代码中的 Shell 调用

```python
import subprocess

# ❌ Mac 习惯（使用 bash 语法）
subprocess.run("ls -la && echo done", shell=True)
subprocess.run("cat $(find . -name '*.py')", shell=True)

# ✅ 跨平台（使用列表参数，避免 shell=True）
subprocess.run(["ls", "-la"], check=True)
# 或使用 Python 内置功能
import glob
files = glob.glob("**/*.py", recursive=True)
```

### 3.3 chmod 命令替换

| bash (Mac) | PowerShell (Win) | 说明 |
|---|---|---|
| `chmod +x file` | `icacls file /grant Everyone:RX` | 添加执行权限 |
| `chmod 755 file` | `icacls file /grant Everyone:RX` | 设置权限位 |
| `chmod -R 755 dir` | `icacls dir /grant Everyone:RX /T` | 递归设置权限 |

### 3.4 python3 vs python 调用

| 平台 | 命令 | 说明 |
|---|---|---|
| Mac | `python3` | Mac 上 python3 指向 Python 3.x |
| Win | `python` | Win 上 python 通常指向 Python 3.x |

**适配方案**：

```python
import sys

# ❌ 硬编码
subprocess.run(["python3", "script.py"])

# ✅ 跨平台
subprocess.run([sys.executable, "script.py"])
# sys.executable 自动指向当前 Python 解释器路径
```

---

## 四、环境变量映射

### 4.1 环境变量对照表

| Mac 环境变量 | Win 环境变量 | 说明 |
|---|---|---|
| `$HOME` | `%USERPROFILE%` 或 `$env:USERPROFILE` | 用户主目录 |
| `$PATH` | `$env:PATH` | 路径变量 |
| `$TEMP` / `$TMPDIR` | `%TEMP%` 或 `$env:TEMP` | 临时目录 |
| `$SHELL` | `$env:ComSpec` | 默认 Shell |
| `$USER` | `%USERNAME%` 或 `$env:USERNAME` | 当前用户名 |
| `$PWD` | `$env:PWD` 或 `Get-Location` | 当前工作目录 |

### 4.2 PATH 分隔符差异

| 平台 | PATH 分隔符 |
|---|---|
| Mac | `:` |
| Win | `;` |

### 4.3 Python 代码中的环境变量访问

```python
import os

# ❌ Mac 习惯
home = os.environ["HOME"]
temp_dir = "/tmp"

# ✅ 跨平台
home = os.path.expanduser("~")
temp_dir = os.environ.get("TEMP", os.environ.get("TMPDIR", "/tmp"))
```

### 4.4 Shell 配置文件

| Mac | Win | 说明 |
|---|---|---|
| `~/.bashrc` | `$PROFILE` | PowerShell 配置文件 |
| `~/.bash_profile` | `$PROFILE` | 登录 Shell 配置 |
| `~/.zshrc` | 无直接对应 | Zsh 配置 |

---

## 五、平台特定文件处理

### 5.1 文件同步规则

| 文件类型 | 处理方式 | 原因 |
|---|---|---|
| `.py` 文件 | 同步（Mac→Win） | Python 跨平台 |
| `.sh` 文件 | **不同步** | Mac 专用 Shell 脚本 |
| `.cmd` 文件 | **不覆盖** | Win 专用脚本 |
| `.md` 文件 | 同步（Mac→Win） | 文档跨平台 |
| `.json` 文件 | 同步（Mac→Win） | JSON 跨平台 |
| `.yaml` 文件 | 同步（Mac→Win） | YAML 跨平台 |

### 5.2 平台分支代码识别

```python
# Python 代码中的平台判断

# os.name 判断
if os.name == 'nt':       # Windows
    # Win 特定逻辑
elif os.name == 'posix':  # Mac/Linux
    # Mac/Linux 特定逻辑

# sys.platform 判断
if sys.platform == 'win32':    # Windows
    # Win 特定逻辑
elif sys.platform == 'darwin': # Mac
    # Mac 特定逻辑
elif sys.platform.startswith('linux'):  # Linux
    # Linux 特定逻辑
```

### 5.3 平台特定代码块处理

在差异分析中，以下代码模式应被识别为平台特定：
- `os.name == 'nt'` 分支
- `sys.platform == 'win32'` 分支
- `sys.platform == 'darwin'` 分支
- `platform.system() == 'Windows'` 分支
- `platform.system() == 'Darwin'` 分支

---

## 六、PowerShell 脚本编写要点

### 6.1 执行策略

```powershell
# 查看当前执行策略
Get-ExecutionPolicy

# 设置执行策略（需管理员权限）
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 6.2 脚本参数传递

| bash | PowerShell | 说明 |
|---|---|---|
| `$1`, `$2` | `$args[0]`, `$args[1]` | 位置参数 |
| `$@` | `$args` | 全部参数 |
| `${1:-default}` | `if (-not $args[0]) { "default" }` | 默认值 |

### 6.3 错误处理

```bash
# bash
trap 'echo "Error: $?"' ERR

# PowerShell
try {
    # 可能出错的代码
} catch {
    Write-Error $_
}
```

### 6.4 字符串引号差异

| bash | PowerShell | 说明 |
|---|---|---|
| `'literal'` | `'literal'` | 单引号：不展开变量 |
| `"expand $var"` | `"expand $var"` | 双引号：展开变量 |
| `` `command` `` | `$(command)` | 命令替换 |

---

## 七、幂等性检查指南

### 7.1 幂等性定义

重复执行同步操作不产生额外变更——第二次执行同步操作的变更摘要应为空。

### 7.2 检查方法

1. 执行第一次同步操作，记录变更摘要
2. 对同一批改进项执行第二次同步操作
3. 比较两次变更摘要：
   - 第二次变更摘要为空 → 幂等性通过
   - 第二次变更摘要非空 → 幂等性失败

### 7.3 确保幂等性的编码实践

```python
# ❌ 非幂等（每次执行都追加内容）
with open("file.txt", "a") as f:
    f.write("new content\n")

# ✅ 幂等（先检查再写入）
content = "new content\n"
with open("file.txt", "r") as f:
    if content in f.read():
        pass  # 已存在，不重复写入
    else:
        with open("file.txt", "a") as f:
            f.write(content)

# ✅ 幂等（使用临时文件 + 原子替换）
import shutil
with open("file.tmp", "w") as f:
    f.write("new content")
shutil.move("file.tmp", "file.txt")
```

### 7.4 文件修改前检查

在修改文件前，检查目标文件是否已为目标状态：
- 如果文件内容已与目标一致 → 跳过修改
- 如果文件内容不同 → 执行修改

---

## 八、版本号一致性检查

### 8.1 版本号定义位置

引擎版本号定义在 `engine/scripts/init.py` 中：

```python
# init.py
ENGINE_VERSION = "2.0.0"  # 或其他版本定义方式
```

### 8.2 比对方法

1. 读取 Mac 版 `engine/scripts/init.py` 中的版本号
2. 读取同步后 Win 版 `engine/scripts/init.py` 中的版本号
3. 比对两个版本号：
   - 一致 → 版本号一致性检查通过
   - 不一致 → 版本号一致性检查失败

### 8.3 同步策略

- Mac 版版本号变更时，Win 版必须同步更新
- 版本号变更应在 P0 优先级同步
- 同步后必须验证版本号一致性

---

## 九、subprocess 编码规范

### 9.1 编码问题根源

Windows 默认控制台编码为 GBK/CP936，Python 子进程输出 UTF-8 时可能导致 `UnicodeDecodeError` 或乱码。

### 9.2 subprocess 参数规范

```python
import subprocess, sys, os

# ❌ Mac 习惯（不指定编码，依赖系统默认）
result = subprocess.run(["python3", "script.py"], capture_output=True, text=True)

# ✅ Windows 兼容（指定 encoding + errors + env）
env = os.environ.copy()
env["PYTHONIOENCODING"] = "utf-8"
result = subprocess.run(
    [sys.executable, "script.py"],
    capture_output=True,
    text=True,
    encoding="utf-8",
    errors="replace",
    env=env
)
```

### 9.3 必须添加的参数清单

| 参数 | 值 | 说明 |
|-----|---|------|
| `encoding` | `"utf-8"` | 指定 stdout/stderr 编码为 UTF-8 |
| `errors` | `"replace"` | 遇到无法解码的字符时替换而非崩溃 |
| `env["PYTHONIOENCODING"]` | `"utf-8"` | 子进程 Python IO 编码 |
| `text` / `capture_output` | `True` | 以文本模式捕获输出 |

### 9.4 Popen 编码规范

```python
# ✅ subprocess.Popen 也需指定编码
proc = subprocess.Popen(
    [sys.executable, "script.py"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    encoding="utf-8",
    errors="replace"
)
```

---

## 十、BOM 兼容处理

### 10.1 BOM 问题

Windows 下部分编辑器（如 Notepad）保存 UTF-8 文件时会添加 BOM 头（`\xef\xbb\xbf`），导致 Python `json.load()` 或 `yaml.safe_load()` 解析失败。

### 10.2 读写兼容方案

```python
# ✅ 读取时使用 utf-8-sig 自动跳过 BOM 头
with open("config.json", "r", encoding="utf-8-sig") as f:
    data = json.load(f)

# ✅ 写入时使用 utf-8（不添加 BOM）
with open("output.json", "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
```

### 10.3 引擎中的 BOM 处理策略

| 文件类型 | 读取编码 | 写入编码 | 说明 |
|---------|---------|---------|------|
| JSON 配置文件 | `utf-8-sig` | `utf-8` | 读取兼容 BOM，写入不加 BOM |
| Python 源文件 | `utf-8` | `utf-8` | Python 源文件不应有 BOM |
| YAML 文件 | `utf-8-sig` | `utf-8` | 读取兼容 BOM |
| Markdown | `utf-8` | `utf-8` | 无 BOM |

### 10.4 .gitattributes 行尾策略

```
# .gitattributes
*.py text eol=lf
*.md text eol=lf
*.json text eol=lf
*.yaml text eol=lf
*.sh text eol=lf
*.cmd text eol=crlf
```

- `.py`/`.md`/`.json`/`.yaml`：强制 LF（跨平台一致）
- `.sh`：LF（Mac/Linux 专用）
- `.cmd`：CRLF（Windows 专用）

### 10.5 Python 文件读写 newline 参数

```python
# ✅ 跨平台 newline 处理
with open("file.txt", "w", newline="\n", encoding="utf-8") as f:
    f.write("line1\nline2\n")

# ✅ 读取时不转换换行符
with open("file.txt", "r", newline="", encoding="utf-8-sig") as f:
    content = f.read()
```

---

## 十一、常见兼容性问题清单

| 问题 | 检测方法 | 修复方法 |
|---|---|---|
| 硬编码 Mac 路径 | 搜索 `/Users/`、`/tmp/`、`/usr/` | 替换为 `os.path.expanduser("~")` 或 `os.environ` |
| bash 语法在 Python 中 | 搜索 `shell=True` + bash 命令 | 改用列表参数或 Python 内置功能 |
| `chmod` 调用 | 搜索 `chmod` 字符串 | 替换为 `icacls` 或跳过 |
| `python3` 调用 | 搜索 `python3` 字符串 | 替换为 `sys.executable` |
| `$HOME` 引用 | 搜索 `$HOME` | 替换为 `os.path.expanduser("~")` |
| LF/CRLF 混用 | 检查文件换行符 | 统一为 LF（.py）或 CRLF（.cmd） |
| 平台分支遗漏 | 检查 `os.name` / `sys.platform` | 确保两个分支都正确处理 |
| subprocess 无 encoding | 搜索 subprocess.run 无 encoding 参数 | 添加 encoding='utf-8', errors='replace' |
| BOM 头导致解析失败 | 检查文件首3字节是否为 \xef\xbb\xbf | 读取时使用 encoding='utf-8-sig' |
