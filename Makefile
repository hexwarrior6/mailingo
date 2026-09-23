XCODEGEN_VERSION := 2.46.0
XCODEGEN := .tools/xcodegen/bin/xcodegen
DERIVED  := .build/DerivedData
CONFIG   := Debug
APP      := $(DERIVED)/Build/Products/$(CONFIG)/Mailingo.app
APPEX    := $(APP)/Contents/PlugIns/MailingoMailExtension.appex
LOGDIR   := $(HOME)/Library/Containers/com.zhuyuhao.Mailingo.MailExtension/Data/Library/Logs/Mailingo
LEGACY   := $(HOME)/Library/Logs/Mailingo
LOG      := $(LOGDIR)/probe.log
# 单元测试的临时目录（.build/ 已被 .gitignore 覆盖）
SPMDIR   := $(CURDIR)/.build/spm


.PHONY: help bootstrap gen build test run register status log stream diagnose clean reset-log install-app verify-appex refresh-plugins

help:
	@echo "make bootstrap  下载 XcodeGen 到 .tools/（无需 sudo，固定版本；克隆后先跑这个）"
	@echo "make gen        生成 Mailingo.xcodeproj（XcodeGen）"
	@echo "make build      编译（含 appex 嵌入）"
	@echo "make test       跑 EmailCore 单元测试（23 个）"
	@echo "make run        编译并启动容器 App（探针看板）"
	@echo "make register   向 pluginkit 注册 appex，并列出 Mail 扩展"
	@echo "make status     打印 S0 判定摘要"
	@echo "make log        实时跟随探针日志"
	@echo "make stream     用 os_log 实时跟随（另一个视角）"
	@echo "make diagnose   查 appex 到底有没有被 Mail 拉起（在自己的终端跑）"
	@echo "make install-app 把 App 拷到 /Applications（Mail 更可靠地发现扩展）"
	@echo "make refresh-plugins 重新注册扩展并列出 Mail 扩展"
	@echo "make reset-log  清空探针日志与落盘的 MIME"

# 为什么要有这个：XcodeGen 是我们唯一的构建工具依赖，但 .tools/ 被 .gitignore 排除
# （它是下载来的工具，不该入库）。没有 bootstrap 的话，别人克隆下来 `make gen` 会直接
# 失败，构建前提就成了口头知识。固定版本号，保证可复现。
bootstrap:
	@if [ -x "$(XCODEGEN)" ]; then \
		echo "✓ XcodeGen 已就绪：$$($(XCODEGEN) --version)"; \
	else \
		echo "== 下载 XcodeGen $(XCODEGEN_VERSION) 到 .tools/（无需 sudo）=="; \
		mkdir -p .tools; \
		curl -fsSL --retry 3 -o .tools/xcodegen.zip \
			"https://github.com/yonaskolb/XcodeGen/releases/download/$(XCODEGEN_VERSION)/xcodegen.zip" \
			|| { echo "❌ 下载失败。可手动从 https://github.com/yonaskolb/XcodeGen/releases 取得 xcodegen.zip 并解压到 .tools/"; exit 1; }; \
		unzip -oq .tools/xcodegen.zip -d .tools; \
		rm -f .tools/xcodegen.zip; \
		xattr -dr com.apple.quarantine .tools/xcodegen 2>/dev/null || true; \
		chmod +x "$(XCODEGEN)"; \
		echo "✓ 完成：$$($(XCODEGEN) --version)"; \
	fi

gen:
	@test -x "$(XCODEGEN)" || { \
		echo "❌ 缺少 XcodeGen（$(XCODEGEN)）。先跑：make bootstrap"; exit 1; }
	$(XCODEGEN) generate --spec project.yml --project .

build: gen
	xcodebuild -project Mailingo.xcodeproj -scheme Mailingo -configuration $(CONFIG) \
	  -derivedDataPath $(DERIVED) build

# 核心逻辑的单元测试。之所以用 `swift test` 而不是 xcodebuild：
#  - 不依赖 Xcode 工程与签名，跑一次不到一秒，适合边写边跑
#  - CI 里也不需要 Apple 证书
# 两个环境变量是为了绕开受限构建环境：
#  --disable-sandbox：Swift 宏让编译器用 sandbox-exec 起 plugin-server，
#    在已是沙盒的环境里嵌套 sandbox-exec 会失败。
#  TMPDIR / CLANG_MODULE_CACHE_PATH：默认缓存落在 ~/Library 与 DARWIN_USER_CACHE_DIR，
#    受限环境不可写。
test:
	@mkdir -p "$(SPMDIR)/tmp" "$(SPMDIR)/mc"
	@cd Packages/MailingoKit && \
	  TMPDIR="$(SPMDIR)/tmp" \
	  CLANG_MODULE_CACHE_PATH="$(SPMDIR)/mc" \
	  swift test --disable-sandbox --scratch-path "$(SPMDIR)/scratch"

run: build
	open "$(APP)"

register: build
	@echo "== 注册 appex =="
	-pluginkit -a "$(APPEX)"
	@echo "== 已注册的 Mail 扩展 =="
	-pluginkit -m -v -p com.apple.email.extension

status:
	@bash Scripts/s0-status.sh

log:
	@mkdir -p "$(LOGDIR)"
	@touch "$(LOG)"
	@echo "跟随 $(LOG)   (Ctrl-C 退出)"
	@tail -n 200 -f "$(LOG)"

stream:
	log stream --style compact --predicate 'subsystem == "com.zhuyuhao.Mailingo"'

# 地面真相：不依赖文件写入，直接问系统「appex 到底有没有被 Mail 拉起」。
# 在**你自己的终端**里跑（本仓库的 agent 沙盒里 log show / pluginkit 都会被拒）。
diagnose:
	@echo "=========== 1. 我们的 os_log（appex 与容器 App 都打这里）==========="
	-log show --last 2h --style compact --predicate 'subsystem == "com.zhuyuhao.Mailingo"' 2>&1 | tail -40
	@echo ""
	@echo "=========== 2. appex 进程是否被拉起过 ==========="
	-log show --last 2h --style compact --predicate 'process == "MailingoMailExtension"' 2>&1 | tail -20
	@echo ""
	@echo "=========== 3. 系统关于 MailingoMailExtension 的记录 ==========="
	-log show --last 2h --style compact --predicate 'eventMessage CONTAINS "MailingoMailExtension"' 2>&1 | tail -30
	@echo ""
	@echo "=========== 4. Mail 扩展注册情况 ==========="
	-pluginkit -m -p com.apple.email.extension -v
	@echo ""
	@echo "=========== 5. 容器目录内容 ==========="
	-ls -la "$(LOGDIR)"

reset-log:
	rm -f "$(LOG)" "$(LOGDIR)/last-message.eml"
	rm -f "$(LEGACY)/probe.log" "$(LEGACY)/last-message.eml"
	@echo "已清空 $(LOGDIR)"

# 强制让 LaunchServices/pkd 重新扫描扩展。改完 project.yml 或重装后建议跑一次。
refresh-plugins:
	-/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "/Applications/Mailingo.app"
	-pluginkit -a "$(APPEX)"
	@echo "== 已注册的 Mail 扩展 =="
	-pluginkit -m -p com.apple.email.extension -v

install-app: build verify-appex
	@echo "== 拷贝到 /Applications（会覆盖同名 App）=="
	rm -rf "/Applications/Mailingo.app"
	ditto "$(APP)" "/Applications/Mailingo.app"
	@echo "== 重新注册（必须在拷贝之后）=="
	$(MAKE) --no-print-directory refresh-plugins
	@echo ""
	@echo "下一步：完全退出 Mail（⌘Q）再重开 → Mail → 设置 → 扩展 → 勾选 Mailingo"

verify-appex:
	@bash Scripts/verify-appex.sh "$(APP)"

clean:
	rm -rf .build Mailingo.xcodeproj Support
